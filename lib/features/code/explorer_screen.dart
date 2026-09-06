import 'package:flutter/material.dart';

import '../../design/colors.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/section.dart';
import '../../design/layout.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../../platform/workspace/workspace_model.dart';
import '../screen_scaffold.dart';
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
      _fileFailed = false;
    });
    final text = await widget.controller.read(path);
    if (!mounted || _file != path) return;
    setState(() {
      _text = text;
      _fileFailed = text == null;
    });
  }

  String _join(String name) => _directory.isEmpty ? name : '$_directory/$name';

  /// One step back up the tree, or out of the file, or off the screen — in
  /// that order, which is the order the user walked in.
  void _back() {
    if (_file != null) {
      setState(() {
        _file = null;
        _text = null;
      });
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
        color: SpectacleColors.backgroundPrimary,
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
                child: const Padding(
                  padding: EdgeInsets.only(left: Spacing.md),
                  child: Text('BACK', style: SpectacleText.panelHeader),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.md),
        Container(
          height: Borders.hairline,
          color: SpectacleColors.borderNormal,
        ),
      ],
    );
  }

  List<String> get _walked =>
      _directory.isEmpty ? const [] : _directory.split('/');

  Widget _panes() {
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
    return Panel(
      title: 'FILES',
      affordance: entries == null
          ? null
          : PanelAffordance('${entries.length}', showIcon: false),
      bodyPadding: EdgeInsets.zero,
      bodyFlexible: true,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
        child: switch ((entries, _listFailed)) {
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
            child: EmptyState('empty'),
          ),
          (final rows?, _) => Padding(
            padding: panelRowsPadding,
            child: ListRowGroup(
              children: [
                for (final entry in rows)
                  ListRow(
                    title: entry.name,
                    node: entry.isDirectory,
                    value: entry.isDirectory ? null : _sizeWord(entry.size),
                    titleColor: _join(entry.name) == _file
                        ? SpectacleColors.accent
                        : null,
                    onTap: entry.isDirectory
                        ? () => _open(_join(entry.name))
                        : () => _read(_join(entry.name)),
                  ),
              ],
            ),
          ),
        },
      ),
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
    return Panel(
      title: file,
      affordance: wide
          ? null
          : PanelAffordance(
              'CLOSE',
              showIcon: false,
              onTap: () => setState(() {
                _file = null;
                _text = null;
              }),
            ),
      bodyPadding: EdgeInsets.zero,
      bodyFlexible: true,
      child: switch ((_text, _fileFailed)) {
        (null, false) => const Padding(
          padding: EdgeInsets.all(Spacing.panelPadding),
          child: EmptyState('reading…'),
        ),
        (null, true) => const Padding(
          padding: EdgeInsets.all(Spacing.panelPadding),
          child: EmptyState('could not read it'),
        ),
        (final text?, _) => _FileBody(text: text),
      },
    );
  }
}

/// The file, unwrapped and scrolling both ways, in the same mono the diff uses
/// and with no colouring of any kind: this is a file being read, not a file
/// being edited.
class _FileBody extends StatelessWidget {
  const _FileBody({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final lines = text.split('\n');
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
              for (final line in lines)
                Text(
                  line,
                  style: SpectacleText.noteBody,
                  maxLines: 1,
                  softWrap: false,
                ),
            ],
          ),
        ),
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
          const Text('/ ', style: SpectacleText.breadcrumb),
          for (var i = 0; i < segments.length; i++) ...[
            if (i > 0) const Text(' / ', style: SpectacleText.breadcrumb),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: segments[i].onTap,
              child: Text(segments[i].label, style: SpectacleText.breadcrumb),
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
