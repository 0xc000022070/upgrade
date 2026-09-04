import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/clips.dart';
import '../../design/colors.dart';
import '../../design/components/action_block.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/icons/hotline_icon.dart';
import '../../design/icons/hotline_icons.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import 'clip_paste.dart';
import 'photo_clip.dart';
import 'shell_sessions.dart';

/// How long the sheet shows what the paste came to before it goes.
const clipsSheetLinger = Duration(milliseconds: 700);

/// The tray over a shell: every clip held, newest first, a tap on one pasting
/// it into this session, and the way to add a photo to the tray.
Future<void> showClipsSheet(
  BuildContext context, {
  required ShellSession session,
}) => showPanelSheet<void>(
  context,
  title: 'CLIPS',
  builder: (_) => _ClipsSheet(session: session),
);

class _ClipsSheet extends ConsumerStatefulWidget {
  const _ClipsSheet({required this.session});

  final ShellSession session;

  @override
  ConsumerState<_ClipsSheet> createState() => _ClipsSheetState();
}

class _ClipsSheetState extends ConsumerState<_ClipsSheet> {
  String? _status;
  bool _busy = false;

  Future<void> _paste(Clip clip) async {
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
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = result.line;
    });
    if (result.outcome == PasteOutcome.failed) return;
    await Future<void>.delayed(clipsSheetLinger);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _addPhoto() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await pickPhotoClip(ref.read(clipStoreProvider));
    } catch (error) {
      if (mounted) setState(() => _status = 'PHOTO · $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final clips = ref.watch(clipStoreProvider);
    return ListenableBuilder(
      listenable: clips,
      builder: (context, _) {
        final held = clips.clips;
        return PanelSheetBody(
          title: 'CLIPS',
          affordance: PanelAffordance(
            'CANCEL',
            showIcon: false,
            onTap: () => Navigator.of(context).pop(),
          ),
          children: [
            if (held.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: Spacing.md),
                child: Text('NOTHING HELD', style: HotlineText.label),
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
                      onTap: () => _paste(clip),
                      onRemove: () => clips.remove(clip),
                    ),
                ],
              ),
            if (_status != null) ...[
              const SheetRule(),
              Text(
                _status!,
                key: const ValueKey('clips-status'),
                style: HotlineText.label,
              ),
            ],
            const SheetRule(),
            ActionBlock(
              key: const ValueKey('clips-add-photo'),
              label: 'ADD PHOTO',
              onTap: _addPhoto,
            ),
          ],
        );
      },
    );
  }
}

/// One clip: the picture at a fixed footprint, its size under it, `×` on it.
/// The thumbnail is decoded at twice its drawn width and no more, so eight
/// tiles cost the tray a fraction of one clip.
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
                      color: HotlineColors.borderNormal,
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
                    color: HotlineColors.surfacePrimary,
                    child: const HotlineIcon(
                      HotlineIcons.close,
                      size: IconSizes.affordance,
                      color: HotlineColors.textSecondary,
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
            style: HotlineText.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
