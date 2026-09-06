import 'package:flutter/material.dart';

import '../../design/colors.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/components/section.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../../platform/workspace/workspace_model.dart';
import 'workspace_controller.dart';

/// One file's hunks, as a sheet over the change list.
///
/// A sheet and not a route: the list behind it is the context — which file of
/// how many — and a diff read on a phone is read one file at a time and then
/// dismissed.
Future<void> showDiffSheet(
  BuildContext context,
  WorkspaceController controller,
  WorkspaceFile file,
) {
  return showPanelSheet<void>(
    context,
    title: file.path,
    builder: (context) => _DiffSheet(controller: controller, file: file),
  );
}

class _DiffSheet extends StatefulWidget {
  const _DiffSheet({required this.controller, required this.file});

  final WorkspaceController controller;
  final WorkspaceFile file;

  @override
  State<_DiffSheet> createState() => _DiffSheetState();
}

class _DiffSheetState extends State<_DiffSheet> {
  List<DiffLine>? _lines;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final lines = await widget.controller.diff(widget.file);
    if (!mounted) return;
    setState(() {
      _lines = lines;
      _failed = lines == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final lines = _lines;
    return Panel(
      // The path, not the last segment: two files of the same name in two
      // directories are the ordinary case in a repository.
      title: widget.file.path,
      affordance: PanelAffordance(
        widget.file.binary
            ? 'BINARY'
            : '+${widget.file.added} '
                  '-${widget.file.removed}',
        showIcon: false,
      ),
      bodyPadding: EdgeInsets.zero,
      bodyFlexible: true,
      child: switch ((lines, _failed)) {
        (null, false) => const Padding(
          padding: EdgeInsets.all(Spacing.panelPadding),
          child: EmptyState('reading…'),
        ),
        (null, true) => const Padding(
          padding: EdgeInsets.all(Spacing.panelPadding),
          child: EmptyState('could not read it'),
        ),
        (final rows?, _) when rows.isEmpty => const Padding(
          padding: EdgeInsets.all(Spacing.panelPadding),
          child: EmptyState('no textual change'),
        ),
        (final rows?, _) => _DiffBody(lines: rows),
      },
    );
  }
}

/// The lines, scrolling both ways. A diff is not wrapped: a wrapped line
/// stops being the line that is in the file, and the whole point of reading
/// one is to see what the file says.
class _DiffBody extends StatelessWidget {
  const _DiffBody({required this.lines});

  final List<DiffLine> lines;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: IntrinsicWidth(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [for (final line in lines) _DiffRow(line: line)],
          ),
        ),
      ),
    );
  }
}

/// No syntax colouring, and no green and red: the palette has an accent it
/// reserves and two status colours that mean something else. What separates an
/// added line from a removed one here is the marker in the gutter and the
/// ground behind it, which is the same vocabulary every other list uses.
class _DiffRow extends StatelessWidget {
  const _DiffRow({required this.line});

  final DiffLine line;

  @override
  Widget build(BuildContext context) {
    final (marker, color, ground) = switch (line.kind) {
      DiffLineKind.added => (
        '+',
        SpectacleColors.textPrimary,
        SpectacleColors.surfaceSecondary,
      ),
      DiffLineKind.removed => (
        '-',
        SpectacleColors.textMuted,
        SpectacleColors.backgroundSecondary,
      ),
      DiffLineKind.hunk => (
        ' ',
        SpectacleColors.textMuted,
        SpectacleColors.surfacePrimary,
      ),
      DiffLineKind.meta => (' ', SpectacleColors.textDisabled, null),
      DiffLineKind.context => (' ', SpectacleColors.textSecondary, null),
    };
    return Container(
      color: ground,
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.panelPadding,
        vertical: 1,
      ),
      child: Text(
        '$marker${line.text}',
        style: SpectacleText.noteBody.copyWith(color: color),
        maxLines: 1,
        softWrap: false,
      ),
    );
  }
}
