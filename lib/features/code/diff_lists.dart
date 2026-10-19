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

class _ShareMark extends StatelessWidget {
  const _ShareMark(this.share);

  final StagedShare share;

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (share) {
      StagedShare.none => ('○', context.tokens.textDisabled),
      StagedShare.some => ('◐', context.tokens.accentMuted),
      StagedShare.all => ('●', context.tokens.accent),
    };
    return Text(text, style: context.tokens.noteBody.copyWith(color: color));
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
    required this.writable,
  });

  final List<WorkspaceFile> files;
  final bool tree;
  final Set<String> closed;
  final String? picked;
  final List<SymbolChange> Function(WorkspaceFile file) outlineOf;
  final bool Function(WorkspaceFile file) viewed;

  final bool writable;
}

List<Widget> changeListRows(
  BuildContext context,
  ChangeRowsData data, {
  required ValueChanged<WorkspaceFile> onPick,
  required ValueChanged<WorkspaceFile> onToggleStage,
  required ValueChanged<WorkspaceFile> onToggleViewed,
  required ValueChanged<ChangeDir> onFoldDir,
  required ValueChanged<ChangeDir> onToggleDir,
  required Widget Function(WorkspaceFile file, Widget row) peekable,
}) {
  final letters = StatusLetters.width(context);
  final entries = data.tree
      ? changeRows(changeTree(data.files), data.closed)
      : [for (final file in data.files) (depth: 0, dir: null, file: file)];
  Widget indented(int depth, Widget row) => depth == 0
      ? row
      : Padding(
          padding: EdgeInsets.only(left: depth * Spacing.lg),
          child: row,
        );
  return [
    for (final entry in entries)
      if (entry.dir case final dir?)
        indented(
          entry.depth,
          ListRow(
            key: ValueKey('diff-dir-${dir.path}'),
            title: '${data.closed.contains(dir.path) ? '▸' : '▾'} ${dir.name}/',
            literalTitle: true,
            titleColor: context.tokens.textSecondary,
            leading: data.writable ? _ShareMark(dir.share) : null,
            leadingWidth: letters,
            onLeadingTap: data.writable ? () => onToggleDir(dir) : null,
            valueSpans: [
              TextSpan(text: '${dir.count}  '),
              countSpan('+${dir.added}', context.tokens.accent, dir.added),
              const TextSpan(text: ' '),
              countSpan('−${dir.removed}', context.tokens.warning, dir.removed),
            ],
            onTap: () => onFoldDir(dir),
          ),
        )
      else if (entry.file case final file?)
        indented(
          entry.depth,
          peekable(
            file,
            ListRow(
              key: ValueKey('diff-file-${file.path}'),
              title: data.tree ? baseName(file.path) : file.path,
              titleMaxLines: 2,
              literalTitle: true,
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
              onLeadingTap: data.writable ? () => onToggleStage(file) : null,
              valueSpans: fileCountSpans(context, file),
              trailing: data.writable
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
  ];
}
