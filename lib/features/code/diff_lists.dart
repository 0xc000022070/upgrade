import 'package:flutter/material.dart';

import 'package:striked/design/components/list_row.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/platform/workspace/workspace_model.dart';

import 'package:striked/features/code/change_tree.dart';
import 'package:striked/features/code/diff_outline.dart';
import 'package:striked/features/code/diff_pane.dart';

class StatusLetters extends StatelessWidget {
  const StatusLetters({
    super.key,
    required this.staged,
    required this.unstaged,
  });

  StatusLetters.of(WorkspaceFile file, {Key? key})
    : this(key: key, staged: file.staged, unstaged: file.unstaged);

  final String staged;
  final String unstaged;

  static double width(BuildContext context) =>
      diffCharAdvance(context) * 2 + Spacing.xs;

  @override
  Widget build(BuildContext context) {
    final style = context.tokens.noteBody;
    Color tone(String letter, Color lit) => letter == '.' || letter == ' '
        ? context.tokens.textDisabled
        : letter == '?'
        ? context.tokens.warning
        : lit;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: staged,
            style: TextStyle(color: tone(staged, context.tokens.accent)),
          ),
          TextSpan(
            text: unstaged,
            style: TextStyle(color: tone(unstaged, context.tokens.danger)),
          ),
        ],
      ),
      style: style,
      maxLines: 1,
    );
  }
}

String? outlineLine(List<SymbolChange> outline) {
  if (outline.isEmpty) return null;
  const shown = 3;
  final words = [
    for (final change in outline.take(shown)) '${change.mark} ${change.label}',
  ];
  final more = outline.length - shown;
  return [...words, if (more > 0) '+$more'].join('  ');
}

class ChangeRowsData {
  const ChangeRowsData({
    required this.files,
    required this.tree,
    required this.closed,
    required this.picked,
    required this.outlineOf,
    required this.viewed,
    required this.working,
  });

  final List<WorkspaceFile> files;
  final bool tree;
  final Set<String> closed;
  final String? picked;
  final List<SymbolChange> Function(WorkspaceFile file) outlineOf;
  final bool Function(WorkspaceFile file) viewed;

  final bool working;
}

String wrappablePath(String path) => path.replaceAll('/', '/\u200B');

Widget _countsBesideIfRoom(
  BuildContext context, {
  required String title,
  required List<TextSpan> counts,
  required double reserved,
  required ListRow Function(bool below) row,
}) {
  double measure(BuildContext context, InlineSpan span) {
    final painter = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  return LayoutBuilder(
    builder: (context, box) {
      final need =
          measure(
            context,
            TextSpan(text: title, style: context.tokens.rowTitle),
          ) +
          Spacing.lg +
          measure(
            context,
            TextSpan(children: counts, style: context.tokens.value),
          ) +
          reserved;
      return row(need > box.maxWidth);
    },
  );
}

List<Widget> changeListSlivers(
  BuildContext context,
  ChangeRowsData data, {
  required ValueChanged<WorkspaceFile> onPick,
  required ValueChanged<WorkspaceFile> onToggleViewed,
  required ValueChanged<ChangeDir> onFoldDir,
  required Widget Function(WorkspaceFile file, Widget row) peekable,
}) {
  final letters = StatusLetters.width(context);
  Widget ruled(int depth, Widget row) => DecoratedBox(
    decoration: BoxDecoration(
      color: context.tokens.surfacePrimary,
      border: Border(
        bottom: BorderSide(
          color: context.tokens.borderSubtle,
          width: Borders.hairline,
        ),
      ),
    ),
    child: Padding(
      padding: EdgeInsets.only(left: depth * Spacing.lg),
      child: row,
    ),
  );
  final lead = letters + Spacing.lg;
  Widget dirRow(ChangeDir dir, int depth) {
    final title = wrappablePath('${dir.name}/');
    final counts = [
      TextSpan(text: '${dir.count}  '),
      countSpan('+${dir.added}', context.tokens.accent, dir.added),
      const TextSpan(text: ' '),
      countSpan('−${dir.removed}', context.tokens.warning, dir.removed),
    ];
    return ruled(
      depth,
      _countsBesideIfRoom(
        context,
        title: title,
        counts: counts,
        reserved: lead,
        row: (below) => ListRow(
          key: ValueKey('diff-dir-${dir.path}'),
          title: title,
          metadataBelow: below,
          titleMaxLines: 4,
          titleColor: context.tokens.textSecondary,
          leading: Text(
            data.closed.contains(dir.path) ? '▸' : '▾',
            style: context.tokens.noteBody.copyWith(
              color: context.tokens.textMuted,
            ),
          ),
          leadingWidth: letters,
          valueSpans: counts,
          onTap: () => onFoldDir(dir),
        ),
      ),
    );
  }

  final viewedWidth = Spacing.sm + Spacing.md + diffCharAdvance(context);
  Widget fileRow(WorkspaceFile file, int depth) {
    final title = wrappablePath(data.tree ? baseName(file.path) : file.path);
    final counts = fileCountSpans(context, file);
    return ruled(
      depth,
      peekable(
        file,
        _countsBesideIfRoom(
          context,
          title: title,
          counts: counts,
          reserved: lead + (data.working ? viewedWidth : 0),
          row: (below) => ListRow(
            key: ValueKey('diff-file-${file.path}'),
            title: title,
            metadataBelow: below,
            titleMaxLines: 4,
            subtitle:
                outlineLine(data.outlineOf(file)) ??
                (file.origin == null ? null : 'from ${file.origin}'),
            subtitleMaxLines: 2,
            subtitleColor: context.tokens.textMuted,
            titleColor: file.path == data.picked
                ? context.tokens.accent
                : data.viewed(file)
                ? context.tokens.textMuted
                : null,
            leading: StatusLetters.of(file),
            leadingWidth: letters,
            valueSpans: counts,
            trailing: data.working
                ? GestureDetector(
                    key: ValueKey('diff-viewed-${file.path}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onToggleViewed(file),
                    child: Padding(
                      padding: const EdgeInsets.only(left: Spacing.md),
                      child: Text(
                        data.viewed(file) ? '✓' : '·',
                        style: context.tokens.noteBody.copyWith(
                          color: data.viewed(file)
                              ? context.tokens.accent
                              : context.tokens.textDisabled,
                        ),
                      ),
                    ),
                  )
                : null,
            onTap: () => onPick(file),
          ),
        ),
      ),
    );
  }

  List<Widget> level(ChangeDir dir, int depth) {
    final files = sortedFiles(dir);
    return [
      for (final child in sortedDirs(dir))
        SliverMainAxisGroup(
          slivers: [
            PinnedHeaderSliver(child: dirRow(child, depth)),
            if (!data.closed.contains(child.path)) ...level(child, depth + 1),
          ],
        ),
      if (files.isNotEmpty)
        SliverList.list(
          children: [for (final file in files) fileRow(file, depth)],
        ),
    ];
  }

  if (data.tree) return level(changeTree(data.files), 0);
  return [
    SliverList.list(
      children: [for (final file in data.files) fileRow(file, 0)],
    ),
  ];
}
