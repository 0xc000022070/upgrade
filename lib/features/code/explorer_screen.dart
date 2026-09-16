import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/section.dart';
import '../../design/components/segment_switch.dart';
import '../../design/layout.dart';
import '../../design/spacing.dart';
import '../../platform/workspace/workspace_model.dart';
import '../screen_scaffold.dart';
import 'change_marks.dart';
import 'diff_sheet.dart';
import 'syntax.dart';
import 'syntax_style.dart';
import 'workspace_controller.dart';

void openExplorer(BuildContext context, WorkspaceController controller) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (_) => ExplorerScreen(controller: controller),
    ),
  );
}

/// The workspace's files, as a tree the phone walks one directory at a time.
///
/// Folded and unfolded are one layout, not two. The screen is always a list
/// beside a viewer; what a fold changes is how wide each of them is, and
/// nothing else:
///
/// * folded, nothing picked — the list is the screen and the viewer is 0 wide;
/// * folded, a file picked — the viewer is the screen and the list is 0 wide;
/// * unfolded — both are on screen, the list narrow and the viewer wide.
///
/// One tree at every width is the whole point: a wrapper inserted at a
/// breakpoint discards the state under it, and unfolding the phone would throw
/// away the directory the user had walked to and the file they were reading.
/// Widths are numbers, and numbers can change mid-gesture.
class ExplorerScreen extends StatefulWidget {
  const ExplorerScreen({super.key, required this.controller});

  final WorkspaceController controller;

  @override
  State<ExplorerScreen> createState() => _ExplorerScreenState();
}

class _ExplorerScreenState extends State<ExplorerScreen> {
  /// Where the list is, relative to the workspace root. Empty is the root.
  String _directory = '';

  List<DirEntry>? _entries;
  bool _listFailed = false;

  /// The file in the viewer, relative to the root, and its text. Null when
  /// nothing is picked, which folded means the list has the screen.
  String? _file;
  String? _text;
  bool _fileFailed = false;

  /// The text cut into coloured runs, one list per line. Null until the
  /// colouring lands, which for a long file is a moment after the text does,
  /// and for a file the app has no grammar for is never.
  List<List<SyntaxSpan>>? _spans;

  /// The gutter's marks for the open file, by line number, or null while the
  /// hunks are still coming or for a file that has no change to mark.
  Map<int, LineMark>? _marks;

  /// Which of the marked lines PREV and NEXT last landed on; -1 is none yet.
  int _visit = -1;

  /// One key per marked line, so NEXT can ask the scroll view for it.
  final _markKeys = <int, GlobalKey>{};

  /// The list drawn as the flat list of changed files rather than the tree.
  bool _changedOnly = false;

  /// Bumped on every navigation so a slow listing that lands after the user
  /// has moved on is dropped rather than drawn over where they are now.
  int _walk = 0;

  @override
  void initState() {
    super.initState();
    _open('');
  }

  Future<void> _open(String directory) async {
    final walk = ++_walk;
    setState(() {
      _directory = directory;
      _entries = null;
      _listFailed = false;
    });
    final entries = await widget.controller.list(directory);
    if (!mounted || walk != _walk) return;
    setState(() {
      _entries = entries;
      _listFailed = entries == null;
    });
  }

  Future<void> _read(String path) async {
    setState(() {
      _file = path;
      _text = null;
      _spans = null;
      _marks = null;
      _visit = -1;
      _fileFailed = false;
    });
    final text = await widget.controller.read(path);
    if (!mounted || _file != path) return;
    setState(() {
      _text = text;
      _fileFailed = text == null;
    });
    if (text == null) return;
    // The colours and the marks are two answers with nothing between them, so
    // they are asked for together and each lands when it lands.
    final language = languageOf(path);
    if (language != null) {
      unawaited(
        highlightFile(text, language).then((spans) {
          if (!mounted || _file != path || _text != text) return;
          setState(() => _spans = spans);
        }),
      );
    }
    final changed = _changedFile(path);
    if (changed == null || changed.untracked || changed.binary) return;
    final lines = await widget.controller.diff(changed);
    if (!mounted || _file != path || _text != text || lines == null) return;
    setState(() => _marks = changeMarks(lines));
  }

  WorkspaceOverview? get _overview => widget.controller.overview;

  /// Every change the checkout reports, by path from the root.
  Map<String, WorkspaceChange> get _changes => {
    for (final change in _overview?.status.changes ?? const <WorkspaceChange>[])
      change.path: change,
  };

  /// The change list's row for a path, which carries the counts and is what
  /// the diff sheet is opened on. Null for a clean file.
  WorkspaceFile? _changedFile(String path) {
    for (final file in _overview?.files ?? const <WorkspaceFile>[]) {
      if (file.path == path) return file;
    }
    return null;
  }

  void _close() {
    _file = null;
    _text = null;
    _spans = null;
    _marks = null;
    _visit = -1;
  }

  String _join(String name) => _directory.isEmpty ? name : '$_directory/$name';

  /// One step back up the tree, or out of the file, or off the screen — in
  /// that order, which is the order the user walked in.
  void _back() {
    if (_file != null) {
      setState(_close);
      return;
    }
    if (_directory.isNotEmpty) {
      final cut = _directory.lastIndexOf('/');
      _open(cut < 0 ? '' : _directory.substring(0, cut));
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // The system gesture walks the tree the way the breadcrumb does, and
      // only leaves once there is nowhere left to walk back to.
      canPop: _file == null && _directory.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: ColoredBox(
        color: context.tokens.backgroundPrimary,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.screenEdge,
              Spacing.lg,
              Spacing.screenEdge,
              0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(),
                const SizedBox(height: Spacing.lg),
                Expanded(child: _panes()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    final segments = <CrumbSegment>[
      CrumbSegment(
        widget.controller.label.toUpperCase(),
        onTap: () => _open(''),
      ),
      for (var i = 0; i < _walked.length; i++)
        CrumbSegment(
          _walked[i].toUpperCase(),
          onTap: () => _open(_walked.take(i + 1).join('/')),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: TapTargets.minHeight,
          child: Row(
            children: [
              Expanded(child: _SegmentedPath(segments: segments)),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _back,
                child: Padding(
                  padding: const EdgeInsets.only(left: Spacing.md),
                  child: Text('BACK', style: context.tokens.panelHeader),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.md),
        Container(height: Borders.hairline, color: context.tokens.borderNormal),
      ],
    );
  }

  List<String> get _walked =>
      _directory.isEmpty ? const [] : _directory.split('/');

  Widget _panes() {
    // The badges and the marks are read off the workspace's own status, so a
    // REFRESH on the screen behind redraws them here.
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) => _split(),
    );
  }

  Widget _split() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final wide = width >= Layout.columnMax;
        // The one place the fold is read. Everything below is the same tree at
        // every width, holding the same state.
        final listWidth = wide
            ? width * _listShare - Spacing.md / 2
            : (_file == null ? width : 0.0);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: listWidth, child: _list()),
            SizedBox(width: wide ? Spacing.md : 0),
            Expanded(child: _viewer(wide: wide)),
          ],
        );
      },
    );
  }

  /// The list keeps a little under half: a file's lines are longer than a
  /// file's name, and the pane that is read gets the width.
  static const _listShare = 0.4;

  Widget _list() {
    final entries = _entries;
    final changes = _changes;
    return Panel(
      title: 'FILES',
      affordance: entries == null
          ? null
          : PanelAffordance('${entries.length}', showIcon: false),
      bodyPadding: EdgeInsets.zero,
      bodyFlexible: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.panelPadding,
              Spacing.sm,
              Spacing.panelPadding,
              0,
            ),
            child: SegmentSwitch(
              labels: [
                'TREE',
                changes.isEmpty ? 'CHANGED' : 'CHANGED ${changes.length}',
              ],
              currentIndex: _changedOnly ? 1 : 0,
              onSelected: (index) => setState(() => _changedOnly = index == 1),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
              child: _changedOnly ? _changedRows() : _treeRows(changes),
            ),
          ),
        ],
      ),
    );
  }

  /// The directory's entries with the checkout's word on each: a letter on a
  /// changed file, a count on a directory with changes under it, and a row
  /// for a file that was deleted here and so is not in the listing at all.
  Widget _treeRows(Map<String, WorkspaceChange> changes) {
    final entries = _entries;
    if (entries == null) {
      return Padding(
        padding: const EdgeInsets.all(Spacing.panelPadding),
        child: EmptyState(_listFailed ? 'could not read it' : 'reading…'),
      );
    }
    final gone = [
      for (final change in changes.values)
        if (change.kind == WorkspaceChangeKind.deleted &&
            _parentOf(change.path) == _directory)
          change,
    ];
    if (entries.isEmpty && gone.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(Spacing.panelPadding),
        child: EmptyState('empty'),
      );
    }
    return Padding(
      padding: panelRowsPadding,
      child: ListRowGroup(
        children: [
          for (final entry in entries) _treeRow(entry, changes),
          for (final change in gone)
            ListRow(
              title: change.path.split('/').last,
              value: _badge(change.kind),
              valueColor: _badgeColor(change.kind),
              titleColor: context.tokens.textMuted,
              onTap: () {
                final file = _changedFile(change.path);
                if (file != null) {
                  showDiffSheet(context, widget.controller, file: file);
                }
              },
            ),
        ],
      ),
    );
  }

  Widget _treeRow(DirEntry entry, Map<String, WorkspaceChange> changes) {
    final path = _join(entry.name);
    if (entry.isDirectory) {
      final under = changes.keys.where((p) => p.startsWith('$path/')).length;
      return ListRow(
        title: entry.name,
        node: true,
        value: under == 0 ? null : '$under',
        valueColor: context.tokens.warning,
        onTap: () => _open(path),
      );
    }
    final change = changes[path];
    return ListRow(
      title: entry.name,
      value: change == null ? _sizeWord(entry.size) : _badge(change.kind),
      valueColor: change == null ? null : _badgeColor(change.kind),
      titleColor: path == _file ? context.tokens.accent : null,
      onTap: () => _read(path),
    );
  }

  /// Every changed file in the checkout, flat, with the counts the workspace
  /// screen shows. A tap opens the file whole, or the diff for a file that is
  /// not there to open any more.
  Widget _changedRows() {
    final files = _overview?.files ?? const <WorkspaceFile>[];
    if (files.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(Spacing.panelPadding),
        child: EmptyState('clean'),
      );
    }
    return Padding(
      padding: panelRowsPadding,
      child: ListRowGroup(
        children: [
          for (final file in files)
            ListRow(
              title: file.path,
              subtitle: file.binary
                  ? null
                  : '+${file.added} \u2212${file.removed}',
              value: _badge(file.kind),
              valueColor: _badgeColor(file.kind),
              titleColor: file.path == _file ? context.tokens.accent : null,
              onTap: file.kind == WorkspaceChangeKind.deleted
                  ? () => showDiffSheet(context, widget.controller, file: file)
                  : () => _read(file.path),
            ),
        ],
      ),
    );
  }

  static String _parentOf(String path) {
    final cut = path.lastIndexOf('/');
    return cut < 0 ? '' : path.substring(0, cut);
  }

  static String _badge(WorkspaceChangeKind kind) => switch (kind) {
    WorkspaceChangeKind.modified => 'M',
    WorkspaceChangeKind.added => 'A',
    WorkspaceChangeKind.deleted => 'D',
    WorkspaceChangeKind.renamed => 'R',
    WorkspaceChangeKind.untracked => '?',
    WorkspaceChangeKind.conflicted => '!',
  };

  Color _badgeColor(WorkspaceChangeKind kind) => switch (kind) {
    WorkspaceChangeKind.modified ||
    WorkspaceChangeKind.renamed => context.tokens.warning,
    WorkspaceChangeKind.added ||
    WorkspaceChangeKind.untracked => context.tokens.accent,
    WorkspaceChangeKind.deleted ||
    WorkspaceChangeKind.conflicted => context.tokens.danger,
  };

  /// The line under the viewer's title on a changed file: what kind of change
  /// it is, how many places, and the three verbs that walk them.
  Widget _strip(WorkspaceFile file) {
    final marks = _marks;
    final lines = marks == null ? const <int>[] : (marks.keys.toList()..sort());
    final word = file.untracked
        ? 'UNTRACKED'
        : marks == null
        ? 'CHANGED'
        : lines.isEmpty
        ? 'NO MARKS'
        : '${lines.length} ${lines.length == 1 ? 'CHANGE' : 'CHANGES'}';
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.panelPadding,
        vertical: Spacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              word,
              style: context.tokens.panelHeader.copyWith(
                color: _badgeColor(file.kind),
              ),
            ),
          ),
          if (lines.isNotEmpty) ...[
            _verb('PREV', () => _step(lines, -1)),
            _verb('NEXT', () => _step(lines, 1)),
          ],
          _verb(
            'DIFF',
            () => showDiffSheet(context, widget.controller, file: file),
          ),
        ],
      ),
    );
  }

  Widget _verb(String label, VoidCallback onTap) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.only(left: Spacing.md),
      child: Text(label, style: context.tokens.panelHeader),
    ),
  );

  /// One marked line along, wrapping at either end, and scrolled to.
  void _step(List<int> lines, int by) {
    setState(() => _visit = (_visit + by) % lines.length);
    final target = _markKeys[lines[_visit]]?.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      alignment: 0.2,
      duration: const Duration(milliseconds: 200),
    );
  }

  Widget _viewer({required bool wide}) {
    final file = _file;
    if (file == null) {
      // Unfolded with nothing picked, this is where the pane says what it is
      // for. Folded it is zero wide and never laid out.
      return wide
          ? const Panel(title: 'VIEWER', child: EmptyState('pick a file'))
          : const SizedBox.shrink();
    }
    final changed = _changedFile(file);
    return Panel(
      title: file,
      affordance: wide
          ? null
          : PanelAffordance(
              'CLOSE',
              showIcon: false,
              onTap: () => setState(_close),
            ),
      bodyPadding: EdgeInsets.zero,
      bodyFlexible: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (changed != null) _strip(changed),
          Expanded(
            child: switch ((_text, _fileFailed)) {
              (null, false) => const Padding(
                padding: EdgeInsets.all(Spacing.panelPadding),
                child: EmptyState('reading…'),
              ),
              (null, true) => const Padding(
                padding: EdgeInsets.all(Spacing.panelPadding),
                child: EmptyState('could not read it'),
              ),
              (final text?, _) => _FileBody(
                text: text,
                spans: _spans,
                marks: _marks,
                keys: _markKeys,
              ),
            },
          ),
        ],
      ),
    );
  }
}

/// The file, unwrapped and scrolling both ways, in the same mono the diff uses
/// and coloured by the same grammars, with the whole file in view so a block
/// comment is a comment to where it ends. A gutter of line numbers, and
/// beside each one the checkout's mark on it. This is a file being read, not
/// a file being edited.
class _FileBody extends StatelessWidget {
  const _FileBody({
    required this.text,
    required this.spans,
    required this.marks,
    required this.keys,
  });

  final String text;

  /// One list of runs per line, or null while the colouring is still coming
  /// or never will, in which case every line is drawn plain.
  final List<List<SyntaxSpan>>? spans;

  /// The gutter's marks by line number. Null draws the numbers alone.
  final Map<int, LineMark>? marks;

  /// Filled here, one key per marked line, for NEXT and PREV to scroll to.
  final Map<int, GlobalKey> keys;

  @override
  Widget build(BuildContext context) {
    final style = context.tokens.noteBody;
    final lines = text.split('\n');
    final spans = this.spans;
    final marks = this.marks ?? const <int, LineMark>{};
    // Every row is one line of the same face, so one measurement is the
    // height of all of them, and the gutter can be a fixed box beside each
    // rather than a second column measured against the first.
    final painter = TextPainter(
      text: TextSpan(text: '0', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final rowHeight = painter.height;
    final digits = lines.length.toString().length;
    final gutterWidth = painter.width * digits;
    keys.removeWhere((line, _) => !marks.containsKey(line));
    for (final line in marks.keys) {
      keys.putIfAbsent(line, GlobalKey.new);
    }
    // A deletion past the last line — the file used to go on — sits on the
    // last line there is.
    LineMark? markAt(int line) =>
        marks[line] ??
        (line == lines.length && marks[line + 1] == LineMark.deleted
            ? LineMark.deleted
            : null);
    GlobalKey? keyAt(int line) =>
        keys[line] ?? (line == lines.length ? keys[line + 1] : null);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: IntrinsicWidth(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.panelPadding,
            vertical: Spacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < lines.length; i++)
                KeyedSubtree(
                  key: keyAt(i + 1),
                  child: SizedBox(
                    height: rowHeight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: gutterWidth,
                          child: Text(
                            '${i + 1}',
                            textAlign: TextAlign.right,
                            style: style.copyWith(
                              color: context.tokens.textMuted,
                            ),
                            maxLines: 1,
                          ),
                        ),
                        _Mark(mark: markAt(i + 1), height: rowHeight),
                        if (spans == null || i >= spans.length)
                          Text(
                            lines[i],
                            style: style,
                            maxLines: 1,
                            softWrap: false,
                          )
                        else
                          Text.rich(
                            TextSpan(
                              children: [
                                for (final span in spans[i])
                                  TextSpan(
                                    text: span.text,
                                    style: syntaxStyle(context, span.token),
                                  ),
                              ],
                            ),
                            style: style,
                            maxLines: 1,
                            softWrap: false,
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The bar between the number and the line: the accent down an added line,
/// the warning down a changed one, a thin line of danger along the top where
/// lines were taken out, and nothing on a line the checkout has no word on.
class _Mark extends StatelessWidget {
  const _Mark({required this.mark, required this.height});

  final LineMark? mark;
  final double height;

  static const _width = 3.0;

  @override
  Widget build(BuildContext context) {
    final mark = this.mark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
      child: SizedBox(
        width: _width,
        height: height,
        child: switch (mark) {
          null => null,
          LineMark.added => ColoredBox(color: context.tokens.accent),
          LineMark.modified => ColoredBox(color: context.tokens.warning),
          LineMark.deleted => Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              height: 2,
              child: ColoredBox(color: context.tokens.danger),
            ),
          ),
        },
      ),
    );
  }
}

/// The walked path, each segment tappable back to itself. The scaffold's own
/// crumb is a widget of its own file and private to it; this is the same
/// shape over a path that changes without the route changing.
class _SegmentedPath extends StatelessWidget {
  const _SegmentedPath({required this.segments});

  final List<CrumbSegment> segments;

  @override
  Widget build(BuildContext context) {
    // Reversed and right-aligned so the deepest segments — the ones that say
    // where the user is — are the ones that survive a narrow line.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: true,
      child: Row(
        children: [
          Text('/ ', style: context.tokens.breadcrumb),
          for (var i = 0; i < segments.length; i++) ...[
            if (i > 0) Text(' / ', style: context.tokens.breadcrumb),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: segments[i].onTap,
              child: Text(segments[i].label, style: context.tokens.breadcrumb),
            ),
          ],
        ],
      ),
    );
  }
}

/// Bytes as one short word. Sizes here are a hint about what a tap will cost,
/// not an accounting, so one decimal is one more than anybody needs.
String _sizeWord(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} K';
  return '${(bytes / (1024 * 1024)).round()} M';
}
