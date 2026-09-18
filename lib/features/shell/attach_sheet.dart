import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/clips.dart';
import '../../design/tokens.dart';
import '../../design/components/action_block.dart';
import '../../design/components/dot_spinner.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/icons/dazzle_icon.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../design/spacing.dart';
import 'clip_paste.dart';
import 'photo_attach.dart';
import 'shell_sessions.dart';

/// How long the sheet shows what the attach came to before it goes.
const attachSheetLinger = Duration(milliseconds: 700);

/// The pause between two pictures going in. Each one is a clipboard write
/// and a keystroke, and the agent reads the clipboard on the keystroke: the
/// next write has to wait for that read.
const attachGap = Duration(milliseconds: 300);

/// What the gallery hands back, so a test can hand back something else.
typedef PhotoPicker = Future<List<Uint8List>> Function();

/// The sheet over a shell: photos from the gallery, as many as picked,
/// attached straight away; and what is held in memory, one tap each.
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

  Future<void> _attachHeld(Clip clip) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'SENDING';
    });
    final result = await pasteClip(
      store: ref.read(shellSessionsProvider),
      session: widget.session,
      clip: clip,
    );
    await _finish(result);
  }

  Future<void> _attachPhotos() async {
    if (_busy) return;
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
    final store = ref.read(shellSessionsProvider);
    PasteResult? last;
    for (var i = 0; i < photos.length; i++) {
      if (!mounted) return;
      setState(() => _status = 'ATTACHING ${i + 1} OF ${photos.length}');
      if (i > 0) await Future<void>.delayed(attachGap);
      last = await pasteImage(
        store: store,
        session: widget.session,
        fileName: freshPngName(),
        bytes: photos[i],
      );
      if (last.outcome == PasteOutcome.failed) break;
    }
    await _finish(last!, count: photos.length);
  }

  /// The last result on the sheet, then the sheet goes — unless it failed,
  /// which is left where the user can read it.
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
              onTap: _attachPhotos,
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
                      onTap: () => _attachHeld(clip),
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
            ],
          ],
        );
      },
    );
  }
}

/// What the sheet says about itself under the `?`: what a picture is for,
/// what each of the two ways in does, and what a failure falls back to. Body
/// copy is the one place the app is read rather than scanned, so it is the
/// sheet's Sans and not another tracked label.
class _AttachHelp extends StatelessWidget {
  const _AttachHelp();

  static const _lines = [
    'Puts a picture in the hands of whatever is running in this shell. '
        'An agent under the pty reads it off the clipboard, so it sees the '
        'image itself and not a file name it has to go and open.',
    'PHOTOS picks from the gallery, as many as you like. Each one is '
        'uploaded to the host, put on the host clipboard and pasted with '
        'Ctrl+V, in the order you picked them. A host with no clipboard tool '
        'gets the file path typed at the cursor instead.',
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

/// One held clip: the picture at a fixed footprint, its size under it, `×`
/// on it. The thumbnail is decoded at twice its drawn width and no more, so
/// eight tiles cost the sheet a fraction of one clip.
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
                    child: DazzleIcon(
                      DazzleIcons.close,
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
