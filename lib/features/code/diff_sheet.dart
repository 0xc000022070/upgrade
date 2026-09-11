import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/path_repository.dart';
import '../../design/colors.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/components/section.dart';
import '../../design/icons/spectacle_icons.dart';
import '../../design/layout.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../../platform/workspace/workspace_model.dart';
import 'syntax.dart';
import 'workspace_controller.dart';

/// The diff of a workspace the caller is already reading, on the connection it
/// already holds.
Future<void> showDiffSheet(
  BuildContext context,
  WorkspaceController controller, {
  WorkspaceFile? file,
}) {
  return _sheet(
    context,
    controller.label,
    (_) => DiffSheet(controller: controller, file: file),
  );
}

/// The diff of a directory nothing is reading yet — the terminal header's
/// mark, which knows a host and a checkout and nothing else.
Future<void> showDiffSheetAt(
  BuildContext context,
  Host host,
  String directory,
) {
  return _sheet(
    context,
    defaultPathLabel(directory),
    (_) => DiffSheet(host: host, directory: directory),
  );
}

/// The sheet the viewer is, at the height a diff wants: the app's modal shape
/// over the terminal that asked for it, and no route of its own. Out is the
/// scrim, so the terminal is one tap behind the diff the whole time.
Future<void> _sheet(BuildContext context, String label, WidgetBuilder builder) {
  return showPanelSheet<void>(
    context,
    title: label.toUpperCase(),
    maxHeightFraction: 0.9,
    builder: builder,
  );
}

/// What changed, and what changed before it: the working tree against `HEAD`,
/// the history behind it, and one file's hunks at a time.
///
/// Read only, like the workspace it belongs to. Reading a commit does not move
/// `HEAD` and nothing here checks anything out — the verbs are in the shell.
///
/// One viewer, two ways in. From the workspace it borrows that screen's
/// controller, which is already connected and already holds the working tree;
/// from the terminal's header it owns one, dials it and closes it on the way
/// out.
class DiffSheet extends ConsumerStatefulWidget {
  const DiffSheet({
    super.key,
    this.controller,
    this.host,
    this.directory,
    this.file,
    this.open,
  }) : assert(
         controller != null || (host != null && directory != null),
         'a borrowed controller, or the host and directory to dial one',
       );

  /// The workspace's own, when the viewer was opened over it. Null when the
  /// viewer dials its own, which it then owns and closes.
  final WorkspaceController? controller;

  final Host? host;
  final String? directory;

  /// The row that was tapped, opened as the screen comes up.
  final WorkspaceFile? file;

  /// The transport, for a test that drives the screen without a socket.
  final WorkspaceOpener? open;

  @override
  ConsumerState<DiffSheet> createState() => _DiffSheetState();
}

class _DiffSheetState extends ConsumerState<DiffSheet> {
  late final WorkspaceController _controller;
  late final bool _owned;

  List<Commit>? _commits;

  /// The commit on screen, or null for the working tree, which is what the
  /// viewer opens on.
  Commit? _source;

  List<WorkspaceFile>? _files;
  bool _filesFailed = false;

  WorkspaceFile? _file;
  List<DiffLine>? _lines;
  bool _diffFailed = false;

  /// Bumped on every source change, so a slow answer that lands after the user
  /// has moved to another commit is dropped rather than drawn over it.
  int _walk = 0;

  /// Both lists come up folded, so the sheet is the height of what is being
  /// read rather than the height of everything that could be. Which of the
  /// three is worth the screen is the user's to say, and the sheet says
  /// nothing about it until they have.
  bool _changesOpen = false;
  bool _historyOpen = false;

  @override
  void initState() {
    super.initState();
    final borrowed = widget.controller;
    _owned = borrowed == null;
    _controller =
        borrowed ??
        WorkspaceController(
          host: widget.host!,
          directory: widget.directory!,
          readPrivateKey: ref.read(ed25519KeysProvider).privateKey,
          open: widget.open,
        );
    _controller.addListener(_onWorkspace);
    if (_owned) {
      _controller.connect();
    } else {
      _onWorkspace();
      final file = widget.file;
      if (file != null) _pick(file);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onWorkspace);
    // Only the connection this screen dialled is this screen's to drop.
    if (_owned) _controller.dispose();
    super.dispose();
  }

  /// The working tree is the workspace's own answer, so the viewer takes it
  /// from there rather than asking for it a second time.
  void _onWorkspace() {
    if (!mounted) return;
    setState(() {
      if (_source == null) {
        _files = _controller.overview?.files;
        _filesFailed = _controller.phase == WorkspacePhase.failed;
      }
    });
    if (_commits == null && _controller.phase == WorkspacePhase.ready) {
      _loadCommits();
    }
  }

  Future<void> _loadCommits() async {
    final commits = await _controller.commits();
    if (!mounted || commits == null) return;
    setState(() => _commits = commits);
  }

  Future<void> _select(Commit? commit) async {
    if (commit?.sha == _source?.sha) return;
    final walk = ++_walk;
    setState(() {
      _source = commit;
      _files = null;
      _filesFailed = false;
      _file = null;
      _lines = null;
    });
    if (commit == null) {
      _onWorkspace();
      return;
    }
    final files = await _controller.commitFiles(commit.sha);
    if (!mounted || walk != _walk) return;
    setState(() {
      _files = files;
      _filesFailed = files == null;
    });
  }

  Future<void> _pick(WorkspaceFile file) async {
    final walk = _walk;
    setState(() {
      _file = file;
      _lines = null;
      _diffFailed = false;
      // The file is what the sheet is now for. On a phone the list it was
      // picked from is off screen anyway; folding it is what the sheet goes
      // back to when the file is closed.
      _changesOpen = false;
      _historyOpen = false;
    });
    final source = _source;
    final lines = source == null
        ? await _controller.diff(file)
        : await _controller.commitDiff(source.sha, file.path);
    if (!mounted || walk != _walk || _file?.path != file.path) return;
    setState(() {
      _lines = lines;
      _diffFailed = lines == null;
    });
  }

  /// Out of the file first, then out of the sheet — the order the user walked
  /// in. The scrim does the same thing in one tap, which is the way out for
  /// anyone not using the phone's own back.
  void _back() {
    if (_file != null) {
      setState(() {
        _file = null;
        _lines = null;
      });
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // Only what is unfolded asks for the screen. With both lists folded and no
    // file open the sheet is the head line and two strips, which is the whole
    // of what the user has asked to see.
    final tall = _file != null || _changesOpen || _historyOpen;
    return PopScope(
      canPop: _file == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _headline(),
          const SizedBox(height: Spacing.panelGap),
          Flexible(
            fit: tall ? FlexFit.tight : FlexFit.loose,
            child: _panes(tall: tall),
          ),
        ],
      ),
    );
  }

  /// The line the eye lands on: which checkout, what is being read in it, on
  /// what branch, and how much of it there is. It carries the repository too,
  /// because the sheet has no breadcrumb over it.
  Widget _headline() {
    final source = _source;
    final status = _controller.overview?.status;
    final files = _files ?? const <WorkspaceFile>[];
    // The sheet is up before the host has answered, so it says which of the
    // two it is: a checkout with nothing changed reads the same as a checkout
    // that has not been read yet, and only one of them is worth waiting on.
    final loading = _controller.phase == WorkspacePhase.connecting;
    var added = 0;
    var removed = 0;
    for (final file in files) {
      added += file.added ?? 0;
      removed += file.removed ?? 0;
    }
    final under = <String>[
      if (loading)
        'reading the checkout'
      else if (source == null)
        status?.branch ?? 'detached'
      else ...[
        source.short,
        source.author,
        source.age,
      ],
      if (!loading && source == null && status != null && !status.clean)
        '${status.changes.length} changed',
    ];
    return Panel(
      title:
          '${_controller.label.toUpperCase()} / '
          '${source == null ? 'WORKING TREE' : source.short.toUpperCase()}',
      affordance: loading
          ? null
          : _Stat(added: added, removed: removed, files: files.length),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            loading ? 'loading…' : source?.subject ?? 'uncommitted changes',
            style: SpectacleText.rowTitleLead,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            under.join('  ·  '),
            style: SpectacleText.rowSubtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  /// The explorer's fold, over the same two panes: folded, whichever of the
  /// list and the hunks is being read takes the screen; unfolded, both are on
  /// it. One tree at every width, so unfolding never drops the commit the user
  /// had walked to.
  Widget _panes({required bool tall}) {
    if (!tall) return _list();
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final wide = width >= Layout.columnMax;
        final listWidth = wide
            ? width * _listShare - Spacing.panelGap / 2
            : (_file == null ? width : 0.0);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: listWidth, child: _list()),
            SizedBox(width: wide ? Spacing.panelGap : 0),
            Expanded(child: _hunks(wide: wide)),
          ],
        );
      },
    );
  }

  /// The hunks are longer than a path and wider than a subject, so the pane
  /// that is read gets the width.
  static const _listShare = 0.42;

  /// A folded panel is its own height and an unfolded one takes what is left,
  /// so two folds and a file are three states of one column rather than three
  /// layouts.
  Widget _list() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_changesOpen) Expanded(flex: 3, child: _changes()) else _changes(),
        const SizedBox(height: Spacing.panelGap),
        if (_historyOpen) Expanded(flex: 2, child: _history()) else _history(),
      ],
    );
  }

  /// What a folded strip says in place of a count, which is the only thing on
  /// it while the host is still being asked.
  String _countWord(int? count, bool failed) {
    if (count != null) return '$count';
    return failed ? 'FAILED' : 'LOADING';
  }

  Widget _changes() {
    final files = _files;
    return Panel(
      title: 'CHANGES',
      affordance: PanelAffordance(
        _countWord(files?.length, _filesFailed),
        icon: _changesOpen ? SpectacleIcons.collapse : SpectacleIcons.expand,
      ),
      onHeaderTap: () => setState(() => _changesOpen = !_changesOpen),
      bodyPadding: EdgeInsets.zero,
      bodyFlexible: true,
      child: !_changesOpen
          ? null
          : SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
              child: switch ((files, _filesFailed)) {
                (null, false) => const Padding(
                  padding: EdgeInsets.all(Spacing.panelPadding),
                  child: EmptyState('loading…'),
                ),
                (null, true) => Padding(
                  padding: const EdgeInsets.all(Spacing.panelPadding),
                  child: EmptyState(_controller.reason ?? 'could not read it'),
                ),
                (final rows?, _) when rows.isEmpty => const Padding(
                  padding: EdgeInsets.all(Spacing.panelPadding),
                  child: EmptyState('nothing changed'),
                ),
                (final rows?, _) => Padding(
                  padding: panelRowsPadding,
                  child: ListRowGroup(
                    children: [
                      for (final file in rows)
                        ListRow(
                          key: ValueKey('diff-file-${file.path}'),
                          kicker: fileKindWord(file),
                          title: file.path,
                          subtitle: file.origin,
                          titleColor: file.path == _file?.path
                              ? SpectacleColors.accent
                              : null,
                          value: fileCountWord(file),
                          onTap: () => _pick(file),
                        ),
                    ],
                  ),
                ),
              },
            ),
    );
  }

  Widget _history() {
    final commits = _commits;
    return Panel(
      title: 'COMMITS',
      affordance: PanelAffordance(
        _countWord(commits?.length, _controller.phase == WorkspacePhase.failed),
        icon: _historyOpen ? SpectacleIcons.collapse : SpectacleIcons.expand,
      ),
      onHeaderTap: () => setState(() => _historyOpen = !_historyOpen),
      bodyPadding: EdgeInsets.zero,
      bodyFlexible: true,
      child: !_historyOpen
          ? null
          : SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
              child: Padding(
                padding: panelRowsPadding,
                child: ListRowGroup(
                  children: [
                    ListRow(
                      key: const ValueKey('diff-source-tree'),
                      title: 'WORKING TREE',
                      titleColor: _source == null
                          ? SpectacleColors.accent
                          : null,
                      value: _dirtyWord(),
                      onTap: () => _select(null),
                    ),
                    if (commits == null)
                      const ListRow(title: 'loading…', value: '')
                    else
                      for (final commit in commits)
                        ListRow(
                          key: ValueKey('diff-commit-${commit.sha}'),
                          kicker: commit.short,
                          title: commit.subject,
                          subtitle: '${commit.author} · ${commit.age}',
                          titleColor: commit.sha == _source?.sha
                              ? SpectacleColors.accent
                              : null,
                          onTap: () => _select(commit),
                        ),
                  ],
                ),
              ),
            ),
    );
  }

  String? _dirtyWord() {
    final status = _controller.overview?.status;
    if (status == null) return null;
    return status.clean ? 'CLEAN' : '${status.changes.length}';
  }

  Widget _hunks({required bool wide}) {
    final file = _file;
    if (file == null) {
      return wide
          ? const Panel(title: 'DIFF', child: EmptyState('pick a file'))
          : const SizedBox.shrink();
    }
    return Panel(
      // The path and not its last segment: two files of the same name in two
      // directories are the ordinary case in a repository.
      title: file.path,
      affordance: wide
          ? _Stat(added: file.added ?? 0, removed: file.removed ?? 0)
          : PanelAffordance(
              'CLOSE',
              key: const ValueKey('diff-close-file'),
              showIcon: false,
              onTap: () => setState(() {
                _file = null;
                _lines = null;
              }),
            ),
      bodyPadding: EdgeInsets.zero,
      bodyFlexible: true,
      child: switch ((_lines, _diffFailed)) {
        (null, false) => const Padding(
          padding: EdgeInsets.all(Spacing.panelPadding),
          child: EmptyState('loading…'),
        ),
        (null, true) => const Padding(
          padding: EdgeInsets.all(Spacing.panelPadding),
          child: EmptyState('could not read it'),
        ),
        (final rows?, _) when rows.isEmpty => const Padding(
          padding: EdgeInsets.all(Spacing.panelPadding),
          child: EmptyState('no textual change'),
        ),
        (final rows?, _) => _DiffBody(
          lines: rows,
          language: languageOf(file.path),
        ),
      },
    );
  }
}

/// `+n −n`, in the two colours that mean added and removed, with the file
/// count in front when it is a whole source being counted.
class _Stat extends StatelessWidget {
  const _Stat({required this.added, required this.removed, this.files});

  final int added;
  final int removed;
  final int? files;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (files case final count?) ...[
          Text(
            '$count ${count == 1 ? 'FILE' : 'FILES'}',
            style: SpectacleText.panelHeader.copyWith(
              color: SpectacleColors.textMuted,
            ),
          ),
          const SizedBox(width: Spacing.lg),
        ],
        Text(
          '+$added',
          style: SpectacleText.panelHeader.copyWith(
            color: SpectacleColors.accent,
          ),
        ),
        const SizedBox(width: Spacing.md),
        Text(
          '−$removed',
          style: SpectacleText.panelHeader.copyWith(
            color: SpectacleColors.danger,
          ),
        ),
      ],
    );
  }
}

/// The lines, scrolling both ways and never wrapping: a wrapped line stops
/// being the line that is in the file, and the column is what makes a diff a
/// diff.
///
/// The gutter scrolls with the text rather than standing still beside it. Two
/// scrollers kept in step is a second source of truth about where the view is,
/// and the one thing worse than a gutter that moves is a gutter that disagrees
/// with the line next to it.
class _DiffBody extends StatelessWidget {
  const _DiffBody({required this.lines, this.language});

  final List<DiffLine> lines;

  /// Null for a file the app cannot place, which is drawn the way every file
  /// used to be.
  final SyntaxLanguage? language;

  @override
  Widget build(BuildContext context) {
    var highest = 0;
    for (final line in lines) {
      final old = line.oldLine ?? 0;
      final now = line.newLine ?? 0;
      if (old > highest) highest = old;
      if (now > highest) highest = now;
    }
    final gutter = _gutterWidth(highest);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: IntrinsicWidth(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final line in lines)
                _DiffRow(line: line, gutter: gutter, language: language),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wide enough for the highest number either side, with a floor of two digits
/// so a short file's gutter is not a hairline.
double _gutterWidth(int highest) =>
    (highest < 100 ? 2 : highest.toString().length) * 7.0 + Spacing.md;

/// One line: the two gutters, the glyph, and the text.
///
/// The ground and the glyph are the diff's own two colours and say which side
/// of the change the line is on. Syntax colours only the text between them,
/// which is why the two can share a row without arguing.
class _DiffRow extends StatelessWidget {
  const _DiffRow({required this.line, required this.gutter, this.language});

  final DiffLine line;
  final double gutter;
  final SyntaxLanguage? language;

  /// The accent and the danger red at the weight a whole line can carry — the
  /// hue says which side the line is on, and the text stays readable over it.
  static const _addedGround = Color(0x1AB7FF2A);
  static const _removedGround = Color(0x1FB84A4A);

  @override
  Widget build(BuildContext context) {
    final (marker, text, mark, ground) = switch (line.kind) {
      DiffLineKind.added => (
        '+',
        SpectacleColors.textPrimary,
        SpectacleColors.accent,
        _addedGround,
      ),
      DiffLineKind.removed => (
        '−',
        SpectacleColors.textSecondary,
        SpectacleColors.danger,
        _removedGround,
      ),
      DiffLineKind.hunk => (
        ' ',
        SpectacleColors.textMuted,
        SpectacleColors.textDisabled,
        SpectacleColors.surfacePrimary,
      ),
      DiffLineKind.meta => (
        ' ',
        SpectacleColors.textDisabled,
        SpectacleColors.textDisabled,
        null,
      ),
      DiffLineKind.context => (
        ' ',
        SpectacleColors.textSecondary,
        SpectacleColors.textDisabled,
        null,
      ),
    };
    final numbers = SpectacleText.noteBody.copyWith(
      color: SpectacleColors.textDisabled,
    );
    return Container(
      color: ground,
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The two sides of the change, the way a file is numbered before it
          // and after it. A hunk header sits over both and is numbered by
          // neither.
          SizedBox(
            width: gutter,
            child: Text(
              '${line.oldLine ?? ''}',
              style: numbers,
              textAlign: TextAlign.right,
              maxLines: 1,
            ),
          ),
          const SizedBox(width: Spacing.md),
          SizedBox(
            width: gutter,
            child: Text(
              '${line.newLine ?? ''}',
              style: numbers,
              textAlign: TextAlign.right,
              maxLines: 1,
            ),
          ),
          const SizedBox(width: Spacing.md),
          Container(
            width: Borders.hairline,
            height: 14,
            color: SpectacleColors.borderSubtle,
          ),
          const SizedBox(width: Spacing.md),
          Text(
            marker,
            style: SpectacleText.noteBody.copyWith(color: mark),
            maxLines: 1,
          ),
          const SizedBox(width: Spacing.sm),
          Padding(
            padding: const EdgeInsets.only(right: Spacing.panelPadding),
            child: Text.rich(
              _text(),
              style: SpectacleText.noteBody.copyWith(color: text),
              maxLines: 1,
              softWrap: false,
            ),
          ),
        ],
      ),
    );
  }

  /// The line cut into runs of one colour. A hunk header and the `diff --git`
  /// preamble are git's words about the file rather than lines of it, so they
  /// are left the colour they already have — colouring them would say they
  /// were code.
  InlineSpan _text() {
    final language = this.language;
    if (language == null ||
        line.kind == DiffLineKind.hunk ||
        line.kind == DiffLineKind.meta) {
      return TextSpan(text: line.text);
    }
    return TextSpan(
      children: [
        for (final span in highlight(line.text, language))
          TextSpan(text: span.text, style: _style(span.token)),
      ],
    );
  }

  static TextStyle? _style(SyntaxToken token) => switch (token) {
    SyntaxToken.plain => null,
    SyntaxToken.punctuation => const TextStyle(
      color: SpectacleColors.textMuted,
    ),
    SyntaxToken.keyword => const TextStyle(color: SyntaxColors.keyword),
    SyntaxToken.type => const TextStyle(color: SyntaxColors.type),
    SyntaxToken.string => const TextStyle(color: SyntaxColors.string),
    SyntaxToken.number => const TextStyle(color: SyntaxColors.number),
    SyntaxToken.comment => const TextStyle(color: SyntaxColors.comment),
    SyntaxToken.annotation => const TextStyle(color: SyntaxColors.annotation),
  };
}

/// `+3 -1` on a row git could count, one word on a row it could not. Shared
/// with the workspace's own change list: the rows are the same rows.
String fileCountWord(WorkspaceFile file) {
  if (file.untracked) return 'NEW';
  if (file.binary) return 'BINARY';
  return '+${file.added} -${file.removed}';
}

String fileKindWord(WorkspaceFile file) => switch (file.kind) {
  WorkspaceChangeKind.modified => 'MODIFIED',
  WorkspaceChangeKind.added => 'ADDED',
  WorkspaceChangeKind.deleted => 'DELETED',
  WorkspaceChangeKind.renamed => 'RENAMED',
  WorkspaceChangeKind.untracked => 'UNTRACKED',
  WorkspaceChangeKind.conflicted => 'CONFLICT',
};
