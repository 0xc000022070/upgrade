import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/drops/clips.dart';
import 'package:upgrade/application/formatting.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/dot_spinner.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/components/progress_bar.dart';
import 'package:upgrade/design/components/status_tag.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/features/shell/input/clip_paste.dart';
import 'package:upgrade/features/shell/input/photo_attach.dart';
import 'package:upgrade/features/shell/session/shell_sessions.dart';
import 'package:upgrade/platform/ssh/host_files.dart' show smallestFirst;

const attachSheetLinger = Duration(milliseconds: 700);

/// The pause between two pictures going in. Each one is a clipboard write and a
/// keystroke, and the agent reads the clipboard on the keystroke: the next write has to
/// wait for that read.
const attachGap = Duration(milliseconds: 300);

typedef PhotoPicker = Future<List<Uint8List>> Function();

Future<void> showAttachSheet(
  BuildContext context, {
  required ShellSession session,
  PhotoPicker pick = pickPhotos,
}) => showPanelSheet<void>(
  context,
  title: 'ATTACH',
  builder: (_) => _AttachSheet(session: session, pick: pick),
);

class _AttachSheet extends ConsumerStatefulWidget {
  const _AttachSheet({required this.session, required this.pick});

  final ShellSession session;
  final PhotoPicker pick;

  @override
  ConsumerState<_AttachSheet> createState() => _AttachSheetState();
}

class _AttachSheetState extends ConsumerState<_AttachSheet> {
  String? _status;
  bool _busy = false;
  bool _help = false;

  List<({int index, Uint8List bytes})> _queue = const [];
  List<AttachItem> _items = const [];

  Future<void> _attachHeld(UserIntent intent, Clip clip) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'SENDING';
      _queue = const [];
    });
    final result = await pasteClip(
      store: ref.read(shellSessionsProvider),
      session: widget.session,
      clip: clip,
      action: UserAction(intent),
    );
    await _finish(result);
  }

  Future<void> _attachPhotos(UserIntent intent) async {
    if (_busy) return;
    final action = UserAction(intent);
    setState(() => _busy = true);
    final List<Uint8List> photos;
    try {
      photos = await widget.pick();
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = 'PHOTOS · $error';
        });
      }
      return;
    }
    if (photos.isEmpty) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    final items = [for (final photo in photos) AttachItem(bytes: photo.length)];
    setState(() {
      _status = 'ATTACHING 1 OF ${photos.length}';
      _queue = [
        for (final i in smallestFirst([for (final p in photos) p.length]))
          (index: i, bytes: photos[i]),
      ];
      _items = items;
    });
    final last = await pasteImages(
      store: ref.read(shellSessionsProvider),
      session: widget.session,
      images: [
        for (final photo in photos) (fileName: freshPngName(), bytes: photo),
      ],
      action: action,
      before: (i) async {
        if (!mounted) return false;
        setState(() => _status = 'ATTACHING ${i + 1} OF ${photos.length}');
        if (i > 0) await Future<void>.delayed(attachGap);
        return mounted;
      },
      onItem: (index, item) {
        if (mounted) setState(() => items[index] = item);
      },
    );
    await _finish(last, count: photos.length);
  }

  /// The last result on the sheet, then the sheet goes — unless it failed, which is left
  /// where the user can read it.
  Future<void> _finish(PasteResult result, {int count = 1}) async {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = count > 1 && result.outcome != PasteOutcome.failed
          ? '${result.label} · $count'
          : result.line;
    });
    if (result.outcome == PasteOutcome.failed) return;
    await Future<void>.delayed(attachSheetLinger);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final clips = ref.watch(clipStoreProvider);
    return ListenableBuilder(
      listenable: clips,
      builder: (context, _) {
        final held = clips.clips;
        return PanelSheetBody(
          title: 'ATTACH',
          affordance: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PanelAffordance(
                '?',
                key: const ValueKey('attach-help'),
                showIcon: false,
                color: _help ? context.tokens.accent : null,
                onTap: () => setState(() => _help = !_help),
              ),
              const SizedBox(width: Spacing.lg),
              PanelAffordance(
                'CANCEL',
                showIcon: false,
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          children: [
            if (_help) ...[const _AttachHelp(), const SheetRule()],
            ActionBlock(
              key: const ValueKey('attach-photos'),
              label: 'PHOTOS',
              onTap: UserIntent.onGesture(_attachPhotos),
            ),
            const SheetRule(),
            Text('HELD', style: context.tokens.label),
            const SizedBox(height: Spacing.sm),
            if (held.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Spacing.md),
                child: Text('NOTHING HELD', style: context.tokens.label),
              )
            else
              Wrap(
                spacing: Spacing.md,
                runSpacing: Spacing.md,
                children: [
                  for (final clip in held)
                    _ClipTile(
                      key: ValueKey('clip-${clip.id}'),
                      clip: clip,
                      onTap: UserIntent.onGesture(
                        (intent) => _attachHeld(intent, clip),
                      ),
                      onRemove: () => clips.remove(clip),
                    ),
                ],
              ),
            if (_status != null) ...[
              const SheetRule(),
              Row(
                children: [
                  if (_busy) ...[
                    const DotSpinner(),
                    const SizedBox(width: Spacing.md),
                  ],
                  Expanded(
                    child: Text(
                      _status!,
                      key: const ValueKey('attach-status'),
                      style: context.tokens.label,
                    ),
                  ),
                ],
              ),
              if (_queue.isNotEmpty) ...[
                const SizedBox(height: Spacing.sm),
                _QueueCount(items: _items),
                for (final queued in _queue) ...[
                  const SizedBox(height: Spacing.md),
                  _QueueRow(
                    key: ValueKey('attach-queued-${queued.index}'),
                    bytes: queued.bytes,
                    item: _items[queued.index],
                  ),
                ],
              ],
            ],
          ],
        );
      },
    );
  }
}

class _AttachHelp extends StatelessWidget {
  const _AttachHelp();

  static const _lines = [
    'Puts a picture in the hands of whatever is running in this shell. '
        'An agent under the pty reads it off the clipboard, so it sees the '
        'image itself and not a file name it has to go and open.',
    'PHOTOS picks from the gallery, as many as you like. Each one is '
        'uploaded to the host, three at a time and the lightest first, put on '
        'the host clipboard and pasted with Ctrl+V as it lands. A host with no '
        'clipboard tool gets the file path typed at the cursor instead.',
    'HELD is what a crop off the SCREEN viewer is kept in, for as long as '
        'the app is running. Tap one to attach it, × to drop it.',
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('attach-help-body'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < _lines.length; i++) ...[
          if (i > 0) const SizedBox(height: Spacing.md),
          Text(_lines[i], style: context.tokens.prose),
        ],
      ],
    );
  }
}

/// The thumbnail is decoded at twice its drawn width and no more, so eight tiles cost the
/// sheet a fraction of one clip.
class _ClipTile extends StatelessWidget {
  const _ClipTile({
    super.key,
    required this.clip,
    required this.onTap,
    required this.onRemove,
  });

  static const _width = 96.0;
  static const _height = 72.0;

  final Clip clip;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: Container(
                  width: _width,
                  height: _height,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: context.tokens.borderNormal,
                      width: Borders.hairline,
                    ),
                  ),
                  child: Image.file(
                    clip.file,
                    width: _width,
                    height: _height,
                    fit: BoxFit.cover,
                    cacheWidth: (_width * 2).round(),
                    gaplessPlayback: true,
                  ),
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: GestureDetector(
                  key: ValueKey('clip-remove-${clip.id}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: onRemove,
                  child: Container(
                    padding: const EdgeInsets.all(Spacing.sm),
                    color: context.tokens.surfacePrimary,
                    child: UpgradeIcon(
                      UpgradeIcons.close,
                      size: IconSizes.affordance,
                      color: context.tokens.textSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            clip.sizeLabel.isEmpty
                ? clip.source.name.toUpperCase()
                : clip.sizeLabel,
            style: context.tokens.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _QueueCount extends StatelessWidget {
  const _QueueCount({required this.items});

  final List<AttachItem> items;

  @override
  Widget build(BuildContext context) {
    int count(Set<AttachStage> stages) =>
        items.where((item) => stages.contains(item.stage)).length;
    final words = [
      ('UP', count(const {AttachStage.sending})),
      ('QUEUED', count(const {AttachStage.queued})),
      (
        'IN',
        count(const {
          AttachStage.pasting,
          AttachStage.pasted,
          AttachStage.path,
        }),
      ),
    ];
    return Text(
      [for (final (word, n) in words) '$n $word'].join(' · '),
      key: const ValueKey('attach-queue-count'),
      style: context.tokens.label.copyWith(color: context.tokens.textSecondary),
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({super.key, required this.bytes, required this.item});

  static const _thumb = 44.0;

  final Uint8List bytes;
  final AttachItem item;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final (word, color) = switch (item.stage) {
      AttachStage.queued => ('QUEUED', tokens.textMuted),
      AttachStage.sending => (
        'UP ${(item.fraction * 100).floor()}%',
        tokens.accent,
      ),
      AttachStage.landed => ('LANDED', tokens.textSecondary),
      AttachStage.pasting => ('PASTING', tokens.accent),
      AttachStage.pasted => ('PASTED', tokens.accent),
      AttachStage.path => ('PATH', tokens.accent),
      AttachStage.failed => ('FAILED', tokens.danger),
      AttachStage.stopped => ('STOPPED', tokens.textDisabled),
    };
    final waiting =
        item.stage == AttachStage.queued || item.stage == AttachStage.stopped;
    final detail = item.stage == AttachStage.failed ? item.detail : null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Opacity(
          opacity: waiting ? 0.4 : 1,
          child: Container(
            width: _thumb,
            height: _thumb,
            decoration: BoxDecoration(
              border: Border.all(
                color: item.stage == AttachStage.sending
                    ? color
                    : tokens.borderNormal,
                width: Borders.hairline,
              ),
            ),
            child: Image.memory(
              bytes,
              width: _thumb,
              height: _thumb,
              fit: BoxFit.cover,
              cacheWidth: (_thumb * 2).round(),
              gaplessPlayback: true,
            ),
          ),
        ),
        const SizedBox(width: Spacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      item.stage == AttachStage.sending
                          ? '${sizeWord(item.sent)} / ${sizeWord(item.bytes)}'
                          : sizeWord(item.bytes),
                      style: tokens.value.copyWith(
                        color: waiting ? tokens.textMuted : tokens.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  StatusTag(word, color: color),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              ProgressBar(
                value: switch (item.stage) {
                  AttachStage.queued || AttachStage.stopped => 0,
                  AttachStage.sending || AttachStage.failed => item.fraction,
                  _ => 1,
                },
              ),
              if (detail != null) ...[
                const SizedBox(height: Spacing.xs),
                Text(
                  detail,
                  style: tokens.label.copyWith(color: tokens.danger),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
