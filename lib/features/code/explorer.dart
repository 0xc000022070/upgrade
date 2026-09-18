import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/pane_share.dart';
import '../../application/providers.dart';
import '../../design/tokens.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/section.dart';
import '../../design/components/segment_switch.dart';
import '../../design/icons/dazzle_icon.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../design/layout.dart';
import '../../design/spacing.dart';
import '../../platform/workspace/workspace_model.dart';
import 'change_marks.dart';
import 'diff_sheet.dart';
import 'file_icons.dart';
import 'syntax.dart';
import 'syntax_style.dart';
import 'workspace_controller.dart';

/// The workspace laid out the way an IDE is: a sidebar holding the tree, an
/// editor holding the open files under a row of tabs.
///
/// Nothing here swaps a list for a file and back. A file opened is a tab and
/// stays one; the tree keeps its open directories while a file is read.
/// Folded and unfolded are one layout: unfolded the sidebar and the editor
/// share the width, folded the editor has it and the sidebar is a drawer over
/// it. A fold changes the widths and nothing else, so the tabs, the drawer
/// and the open directories are the same widgets at every width — a wrapper
/// inserted at a breakpoint would discard the state under it.
class Explorer extends ConsumerStatefulWidget {
  const Explorer({super.key, required this.controller});

  final WorkspaceController controller;

  @override
  ConsumerState<Explorer> createState() => _ExplorerState();
}

/// One open file: what it says, its colours and its marks, kept for the
/// screen's life so switching back to it costs the host nothing.
class _Tab {
  _Tab(this.path);

  final String path;

  /// The cell on the tab row, for the row to scroll it into view.
  final key = GlobalKey();

  String? text;
  bool failed = false;

  /// The text cut into coloured runs, one list per line. Null until the
  /// colouring lands, which for a long file is a moment after the text does,
  /// and for a file the app has no grammar for is never.
  List<List<SyntaxSpan>>? spans;

  /// The gutter's marks by line number, or null while the hunks are still
  /// coming or for a file that has no change to mark.
  Map<int, LineMark>? marks;

  /// Which block of marked lines PREV and NEXT last landed on; -1 is none yet.
  int visit = -1;

  /// One key per marked line, so NEXT can ask the scroll view for it.
  final markKeys = <int, GlobalKey>{};

  String get name => path.split('/').last;
}

class _ExplorerState extends ConsumerState<Explorer> {
  /// The directories drawn open, by path from the root. The root always is.
  final _expanded = <String>{''};

  /// Every listing asked for so far, kept for the screen's life.
  final _listings = <String, List<DirEntry>>{};

  /// The directories whose listing failed; closing and reopening asks again.
  final _failed = <String>{};

  final _tabs = <_Tab>[];
  int _active = -1;

  /// Folded, whether the sidebar is over the editor. Open until a file is
  /// picked, so the tree is the first thing seen on a phone.
  bool _drawer = true;

  /// The sidebar drawn as the flat list of changed files rather than the tree.
  bool _changedOnly = false;

  /// Every directory asked for, answered or not, so a listing in flight is
  /// not asked for twice — by a directory closed and opened again, or by the
  /// connection coming up under a tree that has already started.
  final _asked = <String>{};

  /// The checkout on screen. The toolbar can point the sheet at a sibling
  /// worktree, and what is drawn here belonged to the one it left.
  late String _directory = widget.controller.directory;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onWorkspace);
    _onWorkspace();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onWorkspace);
    super.dispose();
  }

  /// Nothing is asked for while the connection is still coming up: a listing
  /// asked of a workspace that has nobody to ask comes back as a failure, and
  /// the root would be marked unreadable before the handshake had landed.
  void _onWorkspace() {
    if (widget.controller.directory != _directory) {
      _directory = widget.controller.directory;
      setState(_clear);
    }
    if (widget.controller.phase == WorkspacePhase.ready) _list('');
  }

  /// Back to an explorer that has read nothing, keeping the seam's width and
  /// which half of the switch is on: they are the user's, not the checkout's.
  void _clear() {
    _expanded
      ..clear()
      ..add('');
    _listings.clear();
    _failed.clear();
    _asked.clear();
    _tabs.clear();
    _active = -1;
    _drawer = true;
  }

  /// What REFRESH on the FILES panel does: the status the marks are read off,
  /// and every listing the tree is drawn from, asked for again. The open
  /// directories stay open — they are where the user is, not what was read.
  void _refresh() {
    unawaited(widget.controller.refresh());
    setState(() {
      _listings.clear();
      _failed.clear();
      _asked.clear();
    });
    for (final directory in _expanded.toList()) {
      _list(directory);
    }
  }

  Future<void> _list(String directory) async {
    if (!_asked.add(directory)) return;
    final entries = await widget.controller.list(directory);
    if (!mounted) return;
    setState(() {
      if (entries == null) {
        _failed.add(directory);
        // A directory that answered nothing is asked again when it is opened
        // again; one that answered is kept for the sheet's life.
        _asked.remove(directory);
      } else {
        _listings[directory] = entries;
      }
    });
  }

  void _toggle(String directory) {
    setState(() {
      if (!_expanded.remove(directory)) _expanded.add(directory);
    });
    if (_expanded.contains(directory)) {
      _failed.remove(directory);
      _list(directory);
    }
  }

  _Tab? get _tab => _active < 0 ? null : _tabs[_active];

  /// A file already open is gone to, not read again.
  void _read(String path) {
    final index = _tabs.indexWhere((tab) => tab.path == path);
    if (index >= 0) {
      setState(() {
        _active = index;
        _drawer = false;
      });
      _reveal();
      return;
    }
    final tab = _Tab(path);
    setState(() {
      _tabs.add(tab);
      _active = _tabs.length - 1;
      _drawer = false;
    });
    _reveal();
    _load(tab);
  }

  Future<void> _load(_Tab tab) async {
    final text = await widget.controller.read(tab.path);
    if (!mounted || !_tabs.contains(tab)) return;
    setState(() {
      tab.text = text;
      tab.failed = text == null;
    });
    if (text == null) return;
    // The colours and the marks are two answers with nothing between them, so
    // they are asked for together and each lands when it lands.
    final language = languageOf(tab.path);
    if (language != null) {
      unawaited(
        highlightFile(text, language).then((spans) {
          if (!mounted || !_tabs.contains(tab)) return;
          setState(() => tab.spans = spans);
        }),
      );
    }
    final changed = _changedFile(tab.path);
    if (changed == null || changed.untracked || changed.binary) return;
    final lines = await widget.controller.diff(changed);
    if (!mounted || !_tabs.contains(tab) || lines == null) return;
    setState(() => tab.marks = changeMarks(lines));
  }

  /// Scrolls the tab row to the tab on screen once it has been laid out.
  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _tab?.key.currentContext;
      if (target == null) return;
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 200),
      );
    });
  }

  void _closeTab(_Tab tab) {
    setState(() {
      final index = _tabs.indexOf(tab);
      _tabs.removeAt(index);
      if (_tabs.isEmpty) {
        _active = -1;
        _drawer = true;
      } else if (_active > index || _active >= _tabs.length) {
        _active -= 1;
      }
    });
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

  /// Whether the sidebar and the editor share the width, or the sidebar is a
  /// drawer over it. The one place the fold is read.
  bool _wide(BuildContext context) =>
      MediaQuery.sizeOf(context).width - 2 * Spacing.screenEdge >=
      Layout.columnMax;

  /// Folded, the drawer over a file is a thing to close before leaving; over
  /// nothing it is the screen, and back leaves.
  bool get _drawerOverFile => _drawer && _tabs.isNotEmpty;

  void _back(bool wide) {
    if (!wide && _drawerOverFile) {
      setState(() => _drawer = false);
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final wide = _wide(context);
    // The seam a finger is on is let go the moment the row says the same
    // thing, so a width written here is also the width drawn on the next open.
    for (final seam in PaneSeam.values) {
      ref.listen(paneShareProvider(seam), (_, next) {
        if (_held == seam && next.valueOrNull == _heldShare) {
          setState(() => _held = null);
        }
      });
    }
    final share = {for (final seam in PaneSeam.values) seam: _share(seam)};
    return PopScope(
      canPop: wide || !_drawerOverFile,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back(wide);
      },
      child: Padding(
        // The foot stands clear of the phone's own gesture bar: a row under
        // the bar that swipes the sheet away is a row nobody can tap.
        padding: EdgeInsets.fromLTRB(
          Spacing.screenEdge,
          Spacing.lg,
          Spacing.screenEdge,
          MediaQuery.paddingOf(context).bottom + Spacing.md,
        ),
        child: _panes(wide, share),
      ),
    );
  }

  Widget _panes(bool wide, Map<PaneSeam, double> share) {
    // The badges and the marks are read off the workspace's own status, so a
    // REFRESH on the screen behind redraws them here.
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) => wide
          ? _split(share[PaneSeam.beside]!)
          : _stacked(share[PaneSeam.over]!),
    );
  }

  /// The seam whose share the finger is holding, and what it holds. Held on
  /// past the lift, until the preferences row comes back saying the same
  /// thing, so the panes do not jump back to the old width while the write is
  /// in flight.
  PaneSeam? _held;
  double _heldShare = 0;

  double _share(PaneSeam seam) => seam == _held
      ? _heldShare
      : ref.watch(paneShareProvider(seam)).valueOrNull ?? seam.fallback;

  void _seamGrabbed(PaneSeam seam, double share) {
    setState(() {
      _held = seam;
      _heldShare = share;
    });
  }

  void _seamMoved(double moved, double width) {
    final seam = _held;
    if (seam == null) return;
    final next = seam.dragged(_heldShare, moved, width);
    if (next == _heldShare) return;
    setState(() => _heldShare = next);
  }

  /// The write happens on the lift, once, rather than on every frame of the
  /// drag: the row is one number, and nothing reading it needs sixty of them.
  void _seamDropped() {
    final seam = _held;
    if (seam == null) return;
    unawaited(
      ref.read(settingsRepositoryProvider).setNumber(seam.key, _heldShare),
    );
  }

  Widget _grip(PaneSeam seam, double share, double width) => _Grip(
    onGrab: () => _seamGrabbed(seam, share),
    onMove: (moved) => _seamMoved(moved, width),
    onDrop: _seamDropped,
  );

  Widget _split(double share) {
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: constraints.maxWidth * share - _Grip.width / 2,
            child: _sidebar(),
          ),
          _grip(PaneSeam.beside, share, constraints.maxWidth),
          Expanded(child: _editor(wide: true)),
        ],
      ),
    );
  }

  Widget _stacked(double share) {
    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        fit: StackFit.expand,
        children: [
          _editor(wide: false),
          if (_drawer) ...[
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _drawer = false),
              child: ColoredBox(color: context.tokens.scrim),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: share,
                heightFactor: 1,
                // The drawer's own right edge is its seam, so the grip rides
                // inside the width it moves rather than out over the scrim,
                // where a touch means close and not drag.
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _sidebar()),
                    _grip(PaneSeam.over, share, constraints.maxWidth),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sidebar() {
    final changes = _changes;
    return Panel(
      title: 'FILES',
      affordance: PanelAffordance(
        'REFRESH',
        icon: DazzleIcons.sync,
        onTap: _refresh,
      ),
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

  /// The tree from the root down through every open directory, with the
  /// checkout's word on each row: a letter on a changed file, a count on a
  /// directory with changes under it, and a row for a file that was deleted
  /// and so is not in any listing at all.
  Widget _treeRows(Map<String, WorkspaceChange> changes) {
    if (!_listings.containsKey('')) {
      return Padding(
        padding: const EdgeInsets.all(Spacing.panelPadding),
        child: EmptyState(
          _failed.contains('')
              ? 'could not read it'
              : widget.controller.phase == WorkspacePhase.ready
              ? 'reading…'
              : 'connecting…',
        ),
      );
    }
    final rows = <Widget>[];
    _walk('', 0, changes, rows);
    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(Spacing.panelPadding),
        child: EmptyState('empty'),
      );
    }
    return Padding(
      padding: panelRowsPadding,
      child: ListRowGroup(children: rows),
    );
  }

  void _walk(
    String directory,
    int depth,
    Map<String, WorkspaceChange> changes,
    List<Widget> rows,
  ) {
    final entries = _listings[directory];
    if (entries == null) {
      if (depth > 0) {
        rows.add(
          _note(
            _failed.contains(directory) ? 'could not read it' : 'reading…',
            depth,
          ),
        );
      }
      return;
    }
    for (final entry in entries) {
      final path = directory.isEmpty ? entry.name : '$directory/${entry.name}';
      if (entry.isDirectory) {
        final open = _expanded.contains(path);
        final under = changes.keys.where((p) => p.startsWith('$path/')).length;
        rows.add(
          ListRow(
            title: entry.name,
            leading: Align(
              alignment: Alignment.centerRight,
              child: FileIcon.directory(open: open),
            ),
            leadingWidth: _indent(depth) + IconSizes.glyph,
            node: !open,
            value: under == 0 ? null : '$under',
            valueColor: context.tokens.warning,
            onTap: () => _toggle(path),
          ),
        );
        if (open) _walk(path, depth + 1, changes, rows);
        continue;
      }
      final change = changes[path];
      rows.add(
        ListRow(
          title: entry.name,
          leading: Align(
            alignment: Alignment.centerRight,
            child: FileIcon.file(languageOf(path)),
          ),
          leadingWidth: _indent(depth) + IconSizes.glyph,
          value: change == null ? _sizeWord(entry.size) : _letter(change.kind),
          valueColor: change == null ? null : _badgeColor(change.kind),
          titleColor: path == _tab?.path ? context.tokens.accent : null,
          onTap: () => _read(path),
        ),
      );
    }
    for (final change in changes.values) {
      if (change.kind != WorkspaceChangeKind.deleted ||
          _parentOf(change.path) != directory) {
        continue;
      }
      rows.add(
        ListRow(
          title: change.path.split('/').last,
          leading: Align(
            alignment: Alignment.centerRight,
            child: FileIcon.file(languageOf(change.path)),
          ),
          leadingWidth: _indent(depth) + IconSizes.glyph,
          value: _letter(change.kind),
          valueColor: _badgeColor(change.kind),
          titleColor: context.tokens.textMuted,
          onTap: () {
            final file = _changedFile(change.path);
            if (file != null) {
              showDiffSheet(context, widget.controller, file: file);
            }
          },
        ),
      );
    }
  }

  /// A word where a directory's entries would be, while they are coming or
  /// when they never came.
  Widget _note(String word, int depth) => ListRow(
    title: word,
    leading: const SizedBox.shrink(),
    leadingWidth: _indent(depth) + IconSizes.glyph,
    titleColor: context.tokens.textMuted,
  );

  /// One step further in per level, taken out of the row's glyph slot so the
  /// rule under the row still runs the panel's width.
  static double _indent(int depth) => depth * Spacing.xl;

  /// Every changed file in the checkout, flat, with the counts the workspace
  /// screen shows. A tap opens the file, or the diff for a file that is not
  /// there to open any more.
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
              subtitle: file.binary ? null : '+${file.added} −${file.removed}',
              leading: FileIcon.file(languageOf(file.path)),
              value: _letter(file.kind),
              valueColor: _badgeColor(file.kind),
              titleColor: file.path == _tab?.path
                  ? context.tokens.accent
                  : null,
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

  Color _badgeColor(WorkspaceChangeKind kind) => switch (kind) {
    WorkspaceChangeKind.modified ||
    WorkspaceChangeKind.renamed => context.tokens.warning,
    WorkspaceChangeKind.added ||
    WorkspaceChangeKind.untracked => context.tokens.accent,
    WorkspaceChangeKind.deleted ||
    WorkspaceChangeKind.conflicted => context.tokens.danger,
  };

  Widget _editor({required bool wide}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _tabRow(wide: wide),
        const SizedBox(height: Spacing.md),
        Expanded(child: _viewer()),
      ],
    );
  }

  /// The open files, one cell each, and folded the word that opens the
  /// drawer at the head of them.
  Widget _tabRow({required bool wide}) {
    final changes = _changes;
    return SizedBox(
      height: TapTargets.minHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: context.tokens.borderNormal,
              width: Borders.hairline,
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!wide)
              _TabCell(
                label: 'FILES',
                active: _drawer,
                onTap: () => setState(() => _drawer = !_drawer),
              ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final tab in _tabs)
                      _TabCell(
                        key: tab.key,
                        label: tab.name,
                        badge: changes[tab.path]?.kind,
                        badgeColor: switch (changes[tab.path]?.kind) {
                          null => null,
                          final kind => _badgeColor(kind),
                        },
                        active: tab == _tab,
                        onTap: () => _read(tab.path),
                        onClose: () => _closeTab(tab),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The line under the tabs on a changed file: what kind of change it is,
  /// how many places, and the three marks that walk them.
  Widget _strip(_Tab tab, WorkspaceFile file) {
    final marks = tab.marks;
    final blocks = marks == null ? const <int>[] : markBlocks(marks);
    final word = file.untracked
        ? 'UNTRACKED'
        : marks == null
        ? 'CHANGED'
        : blocks.isEmpty
        ? 'NO MARKS'
        : '${blocks.length} ${blocks.length == 1 ? 'CHANGE' : 'CHANGES'}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.panelPadding),
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
          if (blocks.isNotEmpty) ...[
            _verb(DazzleIcons.arrowUp, 'PREV', () => _step(tab, blocks, -1)),
            _verb(DazzleIcons.arrowDown, 'NEXT', () => _step(tab, blocks, 1)),
          ],
          _verb(
            DazzleIcons.diff,
            'DIFF',
            () => showDiffSheet(context, widget.controller, file: file),
          ),
        ],
      ),
    );
  }

  /// A mark, with the word it stands for on its node for a screen reader.
  Widget _verb(DazzleIcons icon, String label, VoidCallback onTap) => Semantics(
    container: true,
    button: true,
    label: label,
    onTap: onTap,
    excludeSemantics: true,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: TapTargets.minHeight,
        height: RowMetrics.minHeight,
        child: Center(
          child: DazzleIcon(
            icon,
            size: IconSizes.sm,
            color: context.tokens.textSecondary,
          ),
        ),
      ),
    ),
  );

  /// One block along, wrapping at either end, and scrolled to by its head.
  void _step(_Tab tab, List<int> blocks, int by) {
    setState(() => tab.visit = (tab.visit + by) % blocks.length);
    final target = tab.markKeys[blocks[tab.visit]]?.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      alignment: 0.2,
      duration: const Duration(milliseconds: 200),
    );
  }

  Widget _viewer() {
    final tab = _tab;
    if (tab == null) {
      return const Panel(title: 'EDITOR', child: EmptyState('open a file'));
    }
    final changed = _changedFile(tab.path);
    return Panel(
      title: tab.path,
      literalTitle: true,
      bodyPadding: EdgeInsets.zero,
      bodyFlexible: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (changed != null) _strip(tab, changed),
          Expanded(
            child: switch ((tab.text, tab.failed)) {
              (null, false) => const Padding(
                padding: EdgeInsets.all(Spacing.panelPadding),
                child: EmptyState('reading…'),
              ),
              (null, true) => const Padding(
                padding: EdgeInsets.all(Spacing.panelPadding),
                child: EmptyState('could not read it'),
              ),
              (final text?, _) => _FileBody(
                key: ValueKey(tab.path),
                text: text,
                spans: tab.spans,
                marks: tab.marks,
                keys: tab.markKeys,
              ),
            },
          ),
        ],
      ),
    );
  }
}

/// The checkout's one-letter word on a file.
String _letter(WorkspaceChangeKind kind) => switch (kind) {
  WorkspaceChangeKind.modified => 'M',
  WorkspaceChangeKind.added => 'A',
  WorkspaceChangeKind.deleted => 'D',
  WorkspaceChangeKind.renamed => 'R',
  WorkspaceChangeKind.untracked => '?',
  WorkspaceChangeKind.conflicted => '!',
};

/// One cell on the tab row: the file's name, the checkout's letter when it
/// has one, and the cross that closes it. The underline is the whole of what
/// marks the tab on screen beyond its ink, the way the shell's tabs do it.
/// The seam between the two panes, as something a finger can take.
///
/// The bar down the middle is what says so; the box around it is wider than
/// the bar because a hairline is not a touch target. It is `opaque` so that the
/// drag begins on the gap itself and not only on the mark drawn in it.
class _Grip extends StatelessWidget {
  const _Grip({
    required this.onGrab,
    required this.onMove,
    required this.onDrop,
  });

  /// Wide enough for a finger, and the gap between the panes at the same time.
  static const width = Spacing.lg * 2;

  static const _barWidth = 2.0;
  static const _barHeight = Spacing.xl * 2;

  final VoidCallback onGrab;
  final void Function(double moved) onMove;
  final VoidCallback onDrop;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) => onGrab(),
      onHorizontalDragUpdate: (details) => onMove(details.delta.dx),
      onHorizontalDragEnd: (_) => onDrop(),
      child: SizedBox(
        width: width,
        child: Center(
          child: Container(
            width: _barWidth,
            height: _barHeight,
            decoration: BoxDecoration(
              color: context.tokens.borderNormal,
              borderRadius: BorderRadius.circular(_barWidth),
            ),
          ),
        ),
      ),
    );
  }
}

class _TabCell extends StatelessWidget {
  const _TabCell({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
    this.badge,
    this.badgeColor,
    this.onClose,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final WorkspaceChangeKind? badge;
  final Color? badgeColor;
  final VoidCallback? onClose;

  static const cross = '×';

  @override
  Widget build(BuildContext context) {
    final tint = active ? context.tokens.accent : context.tokens.textMuted;
    final badge = this.badge;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minWidth: TapTargets.minHeight),
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(
            bottom: active
                ? BorderSide(
                    color: context.tokens.accent,
                    width: Borders.hairline * 2,
                  )
                : BorderSide.none,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: context.tokens.panelHeader.copyWith(color: tint),
              maxLines: 1,
            ),
            if (badge != null) ...[
              const SizedBox(width: Spacing.sm),
              Text(
                _letter(badge),
                style: context.tokens.panelHeader.copyWith(color: badgeColor),
              ),
            ],
            if (onClose != null) ...[
              const SizedBox(width: Spacing.md),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onClose,
                child: Text(
                  cross,
                  style: context.tokens.panelHeader.copyWith(
                    color: context.tokens.textMuted,
                  ),
                ),
              ),
            ],
          ],
        ),
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
    super.key,
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

/// Bytes as one short word. Sizes here are a hint about what a tap will cost,
/// not an accounting, so one decimal is one more than anybody needs.
String _sizeWord(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} K';
  return '${(bytes / (1024 * 1024)).round()} M';
}
