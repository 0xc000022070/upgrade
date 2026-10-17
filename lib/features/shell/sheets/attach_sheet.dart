import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/drops/clips.dart';
import 'package:striked/application/files/phone_inbox.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/design/components/action_block.dart';
import 'package:striked/design/components/dot_spinner.dart';
import 'package:striked/design/components/panel.dart';
import 'package:striked/design/components/panel_sheet.dart';
import 'package:striked/design/icons/striked_icon.dart';
import 'package:striked/design/icons/striked_icons.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/platform/shell/shell_connection.dart';
import 'package:striked/features/shell/input/clip_paste.dart';
import 'package:striked/features/shell/input/photo_attach.dart';
import 'package:striked/features/shell/session/shell_sessions.dart';
import 'package:striked/features/files/transfer_queue.dart';
import 'package:striked/features/files/transfers.dart';
import 'package:uuid/uuid.dart';

const attachSheetLinger = Duration(milliseconds: 700);

/// The pause between two pictures going in. Each one is a clipboard write and a
/// keystroke, and the agent reads the clipboard on the keystroke: the next write has to
/// wait for that read.
const attachGap = Duration(milliseconds: 300);

typedef PhotoPicker = Future<List<Uint8List>> Function();

typedef FilePicker = Future<List<SharedFile>> Function();

Future<void> showAttachSheet(
  BuildContext context, {
  required ShellSession session,
  PhotoPicker pick = pickPhotos,
  FilePicker? pickFiles,
}) => showPanelSheet<void>(
  context,
  title: 'ATTACH',
  builder: (_) =>
      _AttachSheet(session: session, pick: pick, pickFiles: pickFiles),
);

class _AttachSheet extends ConsumerStatefulWidget {
  const _AttachSheet({
    required this.session,
    required this.pick,
    this.pickFiles,
  });

  final ShellSession session;
  final PhotoPicker pick;
  final FilePicker? pickFiles;

  @override
  ConsumerState<_AttachSheet> createState() => _AttachSheetState();
}

class _AttachSheetState extends ConsumerState<_AttachSheet> {
  String? _status;
  bool _busy = false;
  bool _help = false;

  List<QueuedFile> _queue = const [];
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

  Future<void> _attachPhotos(UserIntent intent) => _attach(
    intent,
    'PHOTOS',
    () async => [
      for (final photo in await widget.pick())
        (
          file: (
            fileName: freshPngName(),
            body: FileBody.bytes(photo),
            image: true,
          ),
          queued: QueuedFile(name: '', bytes: photo.length, thumb: photo),
        ),
    ],
  );

  Future<void> _attachFiles(UserIntent intent) => _attach(
    intent,
    'PHONE',
    () async => [
      for (final picked
          in await (widget.pickFiles ?? ref.read(phoneFilesProvider).pick)())
        (
          file: (
            fileName: '${const Uuid().v4()}/${picked.name}',
            body: FileBody.file(File(picked.path), picked.size),
            image: picked.mime == 'image/png',
          ),
          queued: QueuedFile(name: picked.name, bytes: picked.size),
        ),
    ],
  );

  Future<void> _attach(
    UserIntent intent,
    String source,
    Future<List<({PasteFile file, QueuedFile queued})>> Function() pick,
  ) async {
    if (_busy) return;
    final action = UserAction(intent);
    setState(() => _busy = true);
    final List<({PasteFile file, QueuedFile queued})> picked;
    try {
      picked = await pick();
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '$source · $error';
        });
      }
      return;
    }
    if (picked.isEmpty) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    final items = [for (final p in picked) AttachItem(bytes: p.queued.bytes)];
    final stop = TransferStop();
    final job = ref
        .read(transfersProvider)
        .begin(
          verb: 'ATTACHING',
          host: widget.session.host.name,
          files: [for (final p in picked) p.queued],
          stop: stop,
        );
    setState(() {
      _status = 'ATTACHING 1 OF ${picked.length}';
      _queue = [for (final p in picked) p.queued];
      _items = items;
    });
    final last = await pasteFiles(
      store: ref.read(shellSessionsProvider),
      session: widget.session,
      files: [
        for (final p in picked)
          (
            fileName: p.file.fileName,
            body: p.file.body.stoppedBy(stop),
            image: p.file.image,
          ),
      ],
      action: action,
      before: (i) async {
        if (!mounted || stop.stopped) return false;
        setState(() => _status = 'ATTACHING ${i + 1} OF ${picked.length}');
        if (i > 0) await Future<void>.delayed(attachGap);
        return mounted;
      },
      onItem: (index, item) {
        job.report(index, item);
        if (mounted) setState(() => items[index] = item);
      },
    ).whenComplete(job.end);
    await _finish(last, count: picked.length);
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
            Row(
              children: [
                ActionBlock(
                  key: const ValueKey('attach-photos'),
                  label: 'PHOTOS',
                  onTap: UserIntent.onGesture(_attachPhotos),
                ),
                const SizedBox(width: Spacing.md),
                ActionBlock(
                  key: const ValueKey('attach-phone'),
                  label: 'PHONE',
                  onTap: UserIntent.onGesture(_attachFiles),
                ),
              ],
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
                TransferQueue(
                  files: _queue,
                  items: _items,
                  keyPrefix: 'attach',
                ),
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
    'PHONE picks any file off the phone. A PNG goes in like a photo; '
        'anything else lands under /tmp/striked and its path is typed at the '
        'cursor.',
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
                    child: StrikedIcon(
                      StrikedIcons.close,
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
