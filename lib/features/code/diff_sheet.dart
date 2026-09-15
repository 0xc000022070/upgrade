import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/path_repository.dart';
import '../../design/tokens.dart';
import '../../design/components/action_block.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/components/section.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../design/layout.dart';
import '../../design/spacing.dart';
import '../../platform/workspace/workspace_model.dart';

import 'diff_jump.dart';
import 'diff_map.dart';
import 'hunk_pin.dart';
import 'intraline.dart';
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

  /// Every file of the source, read in one command when the source is picked.
  /// A tap on a row after that draws from here and asks the host nothing.
  Map<String, List<DiffLine>>? _bundle;

  /// The same answer while it is still in flight, so a tap that lands first
  /// waits for it instead of asking for the same file a second time.
  Future<Map<String, List<DiffLine>>?>? _bundling;

  /// The hunks pane's own scroller, which is what the hunk walk moves. Every
  /// row is one line tall and every line is the same height, so a hunk is at a
  /// known offset and jumping to it is arithmetic rather than a search.
  final ScrollController _hunkScroll = ScrollController();

  /// Every movement of the pane the reader's thumb did not make, and the way
  /// back from the last of them.
  late final DiffJumps _jumps = DiffJumps(_hunkScroll);

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
    _jumps.dispose();
    _hunkScroll.dispose();
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
    if (_controller.phase != WorkspacePhase.ready) return;
    if (_commits == null) _loadCommits();
    if (_source == null && _bundling == null) {
      _loadBundle(_walk, _controller.sourceDiffs());
    }
  }

  /// One command for the whole source, kept so the file list is walked without
  /// asking the host again. A failure is not put on the screen: it costs the
  /// viewer nothing but the per-file command it was replacing.
  Future<void> _loadBundle(
    int walk,
    Future<Map<String, List<DiffLine>>?> answer,
  ) async {
    _bundling = answer;
    final files = await answer;
    if (!mounted || walk != _walk) return;
    setState(() {
      _bundle = files;
      _bundling = null;
    });
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
      _bundle = null;
      _bundling = null;
    });
    if (commit == null) {
      _onWorkspace();
      return;
    }
    unawaited(_loadBundle(walk, _controller.commitDiffs(commit.sha)));
    final files = await _controller.commitFiles(commit.sha);
    if (!mounted || walk != _walk) return;
    setState(() {
      _files = files;
      _filesFailed = files == null;
    });
  }

  /// The answer is usually already here, so this is not a future: the lines go
  /// up in the same frame the row was tapped in, and only a file the one
  /// command did not carry costs a round trip.
  void _pick(WorkspaceFile file) {
    final cached = _bundle?[file.path];
    setState(() {
      _file = file;
      _lines = cached;
      _diffFailed = false;
      // The file is what the sheet is now for. On a phone the list it was
      // picked from is off screen anyway; folding it is what the sheet goes
      // back to when the file is closed.
      _changesOpen = false;
      _historyOpen = false;
      _picked = null;
    });
    if (_hunkScroll.hasClients) _hunkScroll.jumpTo(0);
    _jumps.forget();
    if (cached == null) unawaited(_read(file));
  }

  /// The fallback: a file the bundle does not carry because the answer was cut
  /// at the byte cap, or because it is untracked and `diff` never names it.
  Future<void> _read(WorkspaceFile file) async {
    final walk = _walk;
    final source = _source;
    // The one command may still be in flight, in which case it is the answer
    // and asking for the file beside it would be the round trip this is for.
    final bundle = await _bundling;
    var lines = bundle?[file.path];
    lines ??= source == null
        ? await _controller.diff(file)
        : await _controller.commitDiff(source.sha, file.path);
    if (!mounted || walk != _walk || _file?.path != file.path) return;
    setState(() {
      _lines = lines;
      _diffFailed = lines == null;
    });
  }

  /// The row the reader has taken hold of, for the one verb a diff pane has
  /// that is not a movement. Held by the sheet and not the body: what it puts
  /// under the thumb is the bar below the lines, which is the sheet's.
  int? _picked;

  /// The file before or after the open one in the change list, which is the
  /// order the list is drawn in and so the order the eye expects.
  WorkspaceFile? _neighbour(int step) {
    final files = _files;
    final file = _file;
    if (files == null || file == null) return null;
    final at = files.indexWhere((row) => row.path == file.path);
    final next = at + step;
    if (at < 0 || next < 0 || next >= files.length) return null;
    return files[next];
  }

  /// The next hunk header below the top of the view, wrapping to the first.
  /// A diff is read hunk by hunk and a long file is mostly context between
  /// them, so this is the scroll the thumb was going to make anyway.
  void _walkHunk() {
    final lines = _lines;
    if (lines == null || !_hunkScroll.hasClients) return;
    final at = (_hunkScroll.offset / _DiffBody.rowHeight(context)).round();
    var found = -1;
    for (var i = at + 1; i < lines.length; i++) {
      if (lines[i].kind == DiffLineKind.hunk) {
        found = i;
        break;
      }
    }
    if (found < 0) {
      found = lines.indexWhere((line) => line.kind == DiffLineKind.hunk);
    }
    if (found < 0) return;
    _jumps.to(found * _DiffBody.rowHeight(context));
  }

  /// Out of the file first, then out of the sheet — the order the user walked
  /// in. The scrim does the same thing in one tap, which is the way out for
  /// anyone not using the phone's own back.
  void _back() {
    if (_file != null) {
      setState(() {
        _file = null;
        _lines = null;
        _picked = null;
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
            // Only a file asks for the whole sheet. A list unfolded over four
            // rows is four rows tall: what the screen was asked for is on it,
            // and the rest of a panel stretched to the cap is ground between
            // the reader and the terminal they opened the diff against.
            fit: _file != null ? FlexFit.tight : FlexFit.loose,
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
          '${source == null ? 'WORKING TREE' : source.short}',
      literalTitle: source != null,
      affordance: loading
          ? null
          : _Stat(added: added, removed: removed, files: files.length),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            loading ? 'loading…' : source?.subject ?? 'uncommitted changes',
            style: context.tokens.rowTitleLead,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            under.join('  ·  '),
            style: context.tokens.rowSubtitle,
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
        // One column and nothing picked: there are no hunks to stand beside,
        // so the row is the list and carrying it would only stretch the list
        // to a height the sheet does not otherwise ask for.
        if (!wide && _file == null) return _list();
        // Folded over a file, the lists are two header strips, and a column
        // holding two fifths of a wide screen to draw them is two fifths of
        // the screen not drawing the file. Folded they keep the width their
        // own words need, which is the width they would have had on a phone
        // plus nothing. They cannot go: a wide pane carries its stat where a
        // narrow one carries CLOSE, so the strips are the way back to the
        // list.
        final strips = wide && _file != null && !_changesOpen && !_historyOpen;
        final listWidth = wide
            ? width * _listShare - Spacing.panelGap / 2
            : (_file == null ? width : 0.0);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (strips)
              IntrinsicWidth(child: _list())
            else
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

  /// A folded panel is its own height and an unfolded one takes what its rows
  /// need up to what is left, so two folds and a file are three states of one
  /// column rather than three layouts. Flexible and not expanded: the share is
  /// a cap on the panel and not a size handed to it.
  Widget _list() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_changesOpen) Flexible(flex: 3, child: _changes()) else _changes(),
        const SizedBox(height: Spacing.panelGap),
        if (_historyOpen) Flexible(flex: 2, child: _history()) else _history(),
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
        icon: _changesOpen ? DazzleIcons.collapse : DazzleIcons.expand,
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
                          literalTitle: true,
                          subtitle: file.origin,
                          titleColor: file.path == _file?.path
                              ? context.tokens.accent
                              : null,
                          valueSpans: fileCountSpans(context, file),
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
        icon: _historyOpen ? DazzleIcons.collapse : DazzleIcons.expand,
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
                          ? context.tokens.accent
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
                              ? context.tokens.accent
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _pane(file, wide: wide)),
        const SizedBox(height: Spacing.panelGap),
        _walkBar(file),
      ],
    );
  }

  /// The walk, under the lines rather than on the strip over them: the file is
  /// read to its end and the way to the next one has to still be under the
  /// thumb when it gets there. The strip scrolls out of reach on a phone; this
  /// does not.
  ///
  /// It says where in the change list the open file is, because a diff of
  /// twenty files is walked and a walk needs to know how much of it is left.
  Widget _walkBar(WorkspaceFile file) {
    final picked = _picked;
    final lines = _lines;
    if (picked != null && lines != null && picked < lines.length) {
      return _pickedBar(lines[picked]);
    }
    final files = _files ?? const <WorkspaceFile>[];
    final at = files.indexWhere((row) => row.path == file.path);
    final before = _neighbour(-1);
    final after = _neighbour(1);
    final hunks = (_lines ?? const <DiffLine>[])
        .where((line) => line.kind == DiffLineKind.hunk)
        .length;
    return Row(
      children: [
        ActionBlock(
          key: const ValueKey('diff-prev-file'),
          label: 'PREV',
          onTap: before == null ? null : () => _pick(before),
          tone: before == null
              ? context.tokens.textDisabled
              : context.tokens.textSecondary,
        ),
        const SizedBox(width: Spacing.md),
        ActionBlock(
          key: const ValueKey('diff-next-file'),
          label: 'NEXT',
          onTap: after == null ? null : () => _pick(after),
          tone: after == null
              ? context.tokens.textDisabled
              : context.tokens.textSecondary,
        ),
        // Wider than the gap between the two file steps, because it is the gap
        // between two walks: the pair on the left leaves the file and the one
        // on the right moves inside it.
        const SizedBox(width: Spacing.xl),
        ActionBlock(
          key: const ValueKey('diff-next-hunk'),
          label: 'HUNK',
          onTap: hunks > 1 ? _walkHunk : null,
          tone: hunks > 1
              ? context.tokens.textSecondary
              : context.tokens.textDisabled,
        ),
        const Spacer(),
        if (at >= 0)
          Text(
            // Named, the way the held line's number is: a bare pair of numbers
            // under three verbs is a count of whichever of them the reader
            // guesses it belongs to.
            'FILE ${at + 1} / ${files.length}',
            style: context.tokens.value.copyWith(
              color: context.tokens.textMuted,
            ),
          ),
      ],
    );
  }

  /// What the bar says while a line is held: the walk is put away, because a
  /// line taken hold of is a thing to do something with and not a place in a
  /// list to move on from.
  Widget _pickedBar(DiffLine line) {
    final number = line.newLine ?? line.oldLine;
    return Row(
      children: [
        ActionBlock(
          key: const ValueKey('diff-copy-line'),
          label: 'COPY',
          filled: true,
          tone: context.tokens.accent,
          onTap: () async {
            // The line as the file has it, not as the pane drew it: the tabs
            // the pane opened out are the file's tabs, and a hunk header is
            // git's words in git's order once it leaves the screen.
            await Clipboard.setData(ClipboardData(text: line.text));
            if (mounted) setState(() => _picked = null);
          },
        ),
        const SizedBox(width: Spacing.md),
        ActionBlock(
          key: const ValueKey('diff-drop-line'),
          label: 'LET GO',
          onTap: () => setState(() => _picked = null),
        ),
        const Spacer(),
        if (number != null)
          Text(
            // A removed line's number is in the file before the change, and the
            // line that replaced it carries the same number in the file after.
            // Held one after the other, the two rows would read the same.
            line.kind == DiffLineKind.removed
                ? 'WAS LINE $number'
                : 'LINE $number',
            style: context.tokens.value.copyWith(
              color: context.tokens.textMuted,
            ),
          ),
      ],
    );
  }

  Widget _pane(WorkspaceFile file, {required bool wide}) {
    return Panel(
      // The path and not its last segment: two files of the same name in two
      // directories are the ordinary case in a repository.
      title: file.path,
      literalTitle: true,
      affordance: wide
          ? _Stat(added: file.added ?? 0, removed: file.removed ?? 0)
          : PanelAffordance(
              'CLOSE',
              key: const ValueKey('diff-close-file'),
              showIcon: false,
              onTap: () => setState(() {
                _file = null;
                _lines = null;
                _picked = null;
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
          jumps: _jumps,
          picked: _picked,
          onPick: (row) => setState(() => _picked = row),
        ),
      },
    );
  }
}

/// How much line is off the right edge, and where in it the reader is.
///
/// The pane has no scrollbar left to say it: the list scrolls down and the
/// text is moved by a transform, which is what keeps the numbers still. This
/// is the one mark that admits the line goes on, and it sits under the text
/// rather than under the whole row so its left edge is where the text's is.
class _Rail extends StatelessWidget {
  const _Rail({
    required this.shift,
    required this.travel,
    required this.room,
    required this.lead,
  });

  final ValueListenable<double> shift;
  final double travel;
  final double room;
  final double lead;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Air above and below, or the rail fuses to the last row on one side and
      // to the walk on the other and reads as the pane's border.
      padding: EdgeInsets.only(left: lead, top: Spacing.xs, bottom: Spacing.xs),
      child: SizedBox(
        height: Borders.hairline * 2,
        child: ValueListenableBuilder<double>(
          valueListenable: shift,
          builder: (context, at, _) {
            // The thumb is as much of the rail as the pane is of the line.
            final thumb = math.max(room * room / (room + travel), Spacing.xl);
            final travelled = math.min(at, travel) / travel;
            return Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(color: context.tokens.borderSubtle),
                ),
                Positioned(
                  left: travelled * (room - thumb),
                  width: thumb,
                  top: 0,
                  bottom: 0,
                  child: ColoredBox(color: context.tokens.textDisabled),
                ),
              ],
            );
          },
        ),
      ),
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
            style: context.tokens.panelHeader.copyWith(
              color: context.tokens.textMuted,
            ),
          ),
          const SizedBox(width: Spacing.lg),
        ],
        Text.rich(
          _countSpan('+$added', context.tokens.accent, added),
          style: context.tokens.panelHeader.copyWith(
            color: context.tokens.textMuted,
          ),
        ),
        const SizedBox(width: Spacing.md),
        Text.rich(
          _countSpan('−$removed', context.tokens.warning, removed),
          style: context.tokens.panelHeader.copyWith(
            color: context.tokens.textMuted,
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
class _DiffBody extends StatefulWidget {
  const _DiffBody({
    required this.lines,
    required this.jumps,
    required this.picked,
    required this.onPick,
    this.language,
  });

  final List<DiffLine> lines;

  /// The pane's scroller and its way back, held by the sheet so the hunk
  /// walk can move it.
  final DiffJumps jumps;

  /// Null for a file the app cannot place, which is drawn the way every file
  /// used to be.
  final SyntaxLanguage? language;

  /// The row held, or null while none is.
  final int? picked;

  final ValueChanged<int> onPick;

  /// One line's box plus the hairline of air either side of it. Every row is
  /// exactly this tall — the text never wraps — which is what lets the list
  /// build only the rows on screen and still know where row ten thousand is.
  ///
  /// Measured at the size the phone is going to paint it. A reader who turned
  /// the system text size up did it because the small one is hard to read, and
  /// a row sized for the small one would cut the top and bottom off every line
  /// of the file and put every jump on the wrong row.
  static double rowHeight(BuildContext context) =>
      MediaQuery.textScalerOf(context)
              .scale(context.tokens.noteBody.fontSize!) *
          context.tokens.noteBody.height! +
      _linePadding * 2;

  static const _linePadding = 1.0;

  @override
  State<_DiffBody> createState() => _DiffBodyState();
}

class _DiffBodyState extends State<_DiffBody> {
  /// How far left the text is pushed, in pixels. The numbers and the marker
  /// are not pushed with it: a phone is narrower than the lines in a source
  /// file, so reading one to its end means going right, and the two things
  /// that say which side of the change a line is on are exactly the two that
  /// used to leave the screen when it did.
  ///
  /// A notifier and not `setState`: a drag repaints the text of the rows on
  /// screen and nothing else — not the list, not the sheet around it.
  final ValueNotifier<double> _shift = ValueNotifier(0);

  /// The number the gutter carries at an offset, for the way back to name
  /// where it goes. A hunk header has no number of its own, so the search runs
  /// on to the first line under it that has one.
  int? _lineAt(double offset) {
    for (
      var row = (offset / _DiffBody.rowHeight(context)).floor();
      row < _drawn.length;
      row++
    ) {
      if (row < 0) continue;
      final line = _drawn[row];
      final number = line.newLine ?? line.oldLine;
      if (number != null) return number;
    }
    return null;
  }

  /// Where each line differs from the one it replaced, worked out once for the
  /// file rather than per row: the answer for a line lives in the line beside
  /// it, which a row being built on its own cannot see.
  List<IntralineSpan?> _changed = const [];

  /// The lines as they are drawn, which is the lines git sent with their tabs
  /// opened out. Everything downstream — the width, the pairing, the offsets
  /// the marked run is given in — is then counting the same characters the
  /// reader is looking at.
  List<DiffLine> _drawn = const [];

  /// Where the changes sit in the file, for the strip that says so. Worked out
  /// with the rest of the file rather than on every frame the pane scrolls.
  List<DiffStreak> _streaks = const [];

  /// Which rows carry a hunk header, for the one held at the top of the pane.
  List<int> _hunks = const [];

  @override
  void initState() {
    super.initState();
    _read();
  }

  @override
  void didUpdateWidget(covariant _DiffBody old) {
    super.didUpdateWidget(old);
    // Another file is another set of lines and another width. The reader is
    // put back at the left margin rather than dropped into the middle of a
    // line they have not read yet.
    if (!identical(old.lines, widget.lines)) {
      _shift.value = 0;
      _read();
    }
  }

  void _read() {
    _drawn = [
      for (final line in widget.lines)
        DiffLine(
          line.kind,
          _openTabs(
            line.kind == DiffLineKind.hunk
                ? hunkHeadline(line.text)
                : line.text,
          ),
          oldLine: line.oldLine,
          newLine: line.newLine,
        ),
    ];
    _changed = intralineChanges(_drawn);
    _streaks = diffStreaks(_drawn);
    _hunks = hunkRows(_drawn);
  }

  @override
  void dispose() {
    _shift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var highest = 0;
    var widest = 0;
    for (final line in _drawn) {
      final old = line.oldLine ?? 0;
      final now = line.newLine ?? 0;
      if (old > highest) highest = old;
      if (now > highest) highest = now;
      final columns = _columns(line.text);
      if (columns > widest) widest = columns;
    }
    final advance = _charAdvance(context);
    final row = _DiffBody.rowHeight(context);
    final gutter = _gutterWidth(highest, advance);
    final lead = _DiffRow.lead(gutter, advance);
    final text = widest * advance + Spacing.panelPadding;
    return LayoutBuilder(
      builder: (context, constraints) {
        // A file that fits on the screen has nowhere to jump to, and one with
        // nothing added or removed has nothing to point at. Either way the
        // strip would only repeat what the reader can already see, so the pane
        // keeps the width instead.
        final mapped =
            _streaks.isNotEmpty && _drawn.length * row > constraints.maxHeight;
        final room = math.max(
          0.0,
          constraints.maxWidth - lead - (mapped ? DiffMap.width : 0),
        );
        final travel = math.max(0.0, text - room);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        GestureDetector(
                          // Horizontal against the list's vertical: the arena
                          // hands the drag to whichever direction it started
                          // in, so a diff is read down and across with the
                          // same thumb.
                          //
                          // From the touch down and not from the win: the rows
                          // hold a long press now, so the drag has to outrun
                          // the slop before the arena gives it anything, and
                          // the text would otherwise arrive at the finger
                          // short by exactly that distance every time.
                          dragStartBehavior: DragStartBehavior.down,
                          onHorizontalDragUpdate: travel == 0
                              ? null
                              : (drag) => _shift.value =
                                    (_shift.value - drag.delta.dx).clamp(
                                      0.0,
                                      travel,
                                    ),
                          child: ListView.builder(
                            controller: widget.jumps.scroll,
                            padding: EdgeInsets.zero,
                            itemExtent: row,
                            itemCount: _drawn.length,
                            itemBuilder: (context, index) {
                              final line = _drawn[index];
                              return GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                // The hold takes a line out of the file and
                                // into the terminal behind the sheet. The row
                                // that says where a cut file stops is this
                                // app's sentence about the file rather than
                                // anything the file has, so there is nothing
                                // in it to take.
                                onLongPress: line.kind == DiffLineKind.capped
                                    ? null
                                    : () => widget.onPick(index),
                                child: _DiffRow(
                                  line: line,
                                  gutter: gutter,
                                  language: widget.language,
                                  shift: _shift,
                                  travel: travel,
                                  picked: widget.picked == index,
                                  changed: index < _changed.length
                                      ? _changed[index]
                                      : null,
                                ),
                              );
                            },
                          ),
                        ),
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: HunkPin(
                            rows: _hunks,
                            jumps: widget.jumps,
                            rowHeight: row,
                            // The same row the list would have drawn, so the
                            // held header and the one it stands in for are
                            // the one thing seen twice.
                            rowAt: (row) => _DiffRow(
                              line: _drawn[row],
                              gutter: gutter,
                              language: widget.language,
                              shift: _shift,
                              travel: travel,
                              picked: widget.picked == row,
                            ),
                          ),
                        ),
                        DiffReturn(jumps: widget.jumps, lineAt: _lineAt),
                      ],
                    ),
                  ),
                  if (mapped)
                    DiffMap(
                      streaks: _streaks,
                      rows: _drawn.length,
                      jumps: widget.jumps,
                    ),
                ],
              ),
            ),
            // Nothing else says how much line is off the right edge once the
            // scroller that used to say it is gone.
            if (travel > 0)
              Padding(
                // The rail measures the text, so it ends where the text ends
                // rather than running on under the strip.
                padding: EdgeInsets.only(right: mapped ? DiffMap.width : 0),
                child: _Rail(
                  shift: _shift,
                  travel: travel,
                  room: room,
                  lead: lead,
                ),
              ),
          ],
        );
      },
    );
  }

  /// How wide a line is in characters, which by the time a line is drawn is
  /// its length: the face is monospaced and the tabs are already gone.
  int _columns(String text) => text.length;
}

/// A tab opened out to the next eight-column stop.
///
/// The face draws a tab as one advance and the pane was measuring it as eight,
/// so a file indented with tabs came out both mismeasured and flattened — a Go
/// file lost the shape that says what is inside what. Eight is git's own stop
/// and the one the width arithmetic already assumed.
String _openTabs(String text) {
  if (!text.contains('\t')) return text;
  final open = StringBuffer();
  var column = 0;
  for (final unit in text.codeUnits) {
    if (unit == 0x09) {
      final stop = _tabStop - column % _tabStop;
      open.write(' ' * stop);
      column += stop;
    } else {
      open.writeCharCode(unit);
      column++;
    }
  }
  return open.toString();
}

const _tabStop = 8;

/// The advance of one character in the body's face, measured once.
///
/// IBM Plex Mono is monospaced, so the width of a line is its length and the
/// width of the whole diff is the longest line. That is arithmetic, where
/// `IntrinsicWidth` was a second layout pass over every row in the file — and
/// arithmetic is what lets the rows be built lazily, because a list cannot
/// size itself to a child it has not built.
double _charAdvance(BuildContext context) {
  final scaler = MediaQuery.textScalerOf(context);
  final size = scaler.scale(context.tokens.noteBody.fontSize!);
  final known = _advance;
  if (known != null && _advanceAt == size) return known;
  final painter = TextPainter(
    text: TextSpan(text: _ruler, style: context.tokens.noteBody),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
  )..layout();
  final advance = painter.width / _ruler.length;
  painter.dispose();
  _advanceAt = size;
  return _advance = advance;
}

double? _advance;

/// The painted font size [_advance] was measured at. The system text size can
/// move while the app is open, and a cache that outlived it would be the same
/// mismeasurement it exists to avoid.
double? _advanceAt;
const _ruler = '0123456789';

/// Wide enough for the highest number either side, with a floor of two digits
/// so a short file's gutter is not a hairline.
double _gutterWidth(int highest, double advance) =>
    (highest < 100 ? 2 : highest.toString().length) * advance + Spacing.md;

/// One line: the two gutters, the glyph, and the text.
///
/// The ground and the glyph are the diff's own two colours and say which side
/// of the change the line is on. Syntax colours only the text between them,
/// which is why the two can share a row without arguing.
class _DiffRow extends StatelessWidget {
  const _DiffRow({
    required this.line,
    required this.gutter,
    required this.shift,
    required this.travel,
    this.language,
    this.changed,
    this.picked = false,
  });

  final DiffLine line;
  final double gutter;
  final SyntaxLanguage? language;

  /// The pane's one horizontal position, listened to by the text of every row
  /// on screen and by nothing else.
  final ValueListenable<double> shift;

  /// How far the text can go before its longest line ends. Read here as well
  /// as in the drag so a pane that just got narrower draws clamped instead of
  /// writing to the notifier in the middle of a build.
  final double travel;

  /// The stretch of this line the line it replaced did not have. Null on a
  /// line that has no partner, and on a pair with nothing worth pointing at.
  final IntralineSpan? changed;

  /// Whether this is the row being held.
  final bool picked;

  /// Everything left of the text: the two number columns, the rule between
  /// them and the line's marker, with the air each of them sits in.
  static double lead(double gutter, double advance) =>
      gutter * 2 + Spacing.md * 3 + Borders.hairline + advance + Spacing.sm;

  @override
  Widget build(BuildContext context) {
    final (marker, text, mark, ground) = switch (line.kind) {
      DiffLineKind.added => (
        '+',
        context.tokens.textPrimary,
        context.tokens.accent,
        context.tokens.diffAddedGround,
      ),
      DiffLineKind.removed => (
        '−',
        context.tokens.textSecondary,
        context.tokens.danger,
        context.tokens.diffRemovedGround,
      ),
      DiffLineKind.hunk => (
        ' ',
        context.tokens.textMuted,
        context.tokens.textDisabled,
        context.tokens.surfacePrimary,
      ),
      DiffLineKind.meta => (
        ' ',
        context.tokens.textDisabled,
        context.tokens.textDisabled,
        null,
      ),
      DiffLineKind.context => (
        ' ',
        context.tokens.textSecondary,
        context.tokens.textDisabled,
        null,
      ),
      // The one row that is not the file. It says the reading stopped short,
      // so it is the colour this app spends on a state that is not wrong but
      // is not finished either, and it carries a ground so a reader who
      // arrives at the bottom cannot take it for the last line of the diff.
      DiffLineKind.capped => (
        '…',
        context.tokens.warning,
        context.tokens.warning,
        context.tokens.diffCappedGround,
      ),
    };
    final numbers = context.tokens.noteBody.copyWith(
      color: context.tokens.textDisabled,
    );
    final row = Container(
      color: ground,
      padding: const EdgeInsets.symmetric(vertical: _DiffBody._linePadding),
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
            // The row's whole inside, so the only break in the rule down the
            // pane is the air between one line and the next. A fixed height
            // was the row's inside at one text size and a third of the way
            // short of it at the largest, which turned the rule into ticks.
            height: _DiffBody.rowHeight(context) - _DiffBody._linePadding * 2,
            color: context.tokens.borderSubtle,
          ),
          const SizedBox(width: Spacing.md),
          Text(
            marker,
            style: context.tokens.noteBody.copyWith(color: mark),
            maxLines: 1,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: ClipRect(
              child: ValueListenableBuilder<double>(
                valueListenable: shift,
                builder: (context, at, painted) => Transform.translate(
                  offset: Offset(-math.min(at, travel), 0),
                  child: painted,
                ),
                // Laid out once at its full width and moved by the transform:
                // a drag repaints the line, it does not lay it out again.
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  maxWidth: double.infinity,
                  child: Padding(
                    padding: const EdgeInsets.only(right: Spacing.panelPadding),
                    child: Text.rich(
                      _text(context),
                      style: context.tokens.noteBody.copyWith(color: text),
                      maxLines: 1,
                      softWrap: false,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    if (!picked) return row;
    // The accent, at the one width the palette allows it: a held line is drawn
    // over four grounds, two of which are already the diff's own colours, so
    // the mark is put beside the line rather than on it.
    return Stack(
      children: [
        row,
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: Spacing.xs,
          child: ColoredBox(color: context.tokens.accent),
        ),
      ],
    );
  }

  /// The line cut into runs of one colour. A hunk header, the `diff --git`
  /// preamble and the row that says where a cut file stops are words about the
  /// file rather than lines of it, so they are left the colour they already
  /// have — colouring them would say they were code, and a sentence read
  /// through a Dart lexer picks out its keywords.
  InlineSpan _text(BuildContext context) {
    final language = this.language;
    final runs =
        language == null ||
            line.kind == DiffLineKind.hunk ||
            line.kind == DiffLineKind.meta ||
            line.kind == DiffLineKind.capped
        ? [(text: line.text, token: SyntaxToken.plain)]
        : highlight(line.text, language);
    final run = changed;
    final ground = switch (line.kind) {
      DiffLineKind.added => context.tokens.diffAddedRun,
      DiffLineKind.removed => context.tokens.diffRemovedRun,
      _ => null,
    };
    if (run == null || ground == null) {
      return TextSpan(
        children: [
          for (final span in runs)
            TextSpan(text: span.text, style: _style(context, span.token)),
        ],
      );
    }
    // The colour runs and the changed run are two cuts of the same line made
    // for different reasons, so the line is cut at both and each piece keeps
    // the syntax colour it had.
    final children = <TextSpan>[];
    var at = 0;
    for (final span in runs) {
      final end = at + span.text.length;
      final style = _style(context, span.token);
      final from = math.max(at, run.start);
      final to = math.min(end, run.end);
      if (from >= to) {
        children.add(TextSpan(text: span.text, style: style));
      } else {
        if (from > at) {
          children.add(
            TextSpan(text: line.text.substring(at, from), style: style),
          );
        }
        children.add(
          TextSpan(
            text: line.text.substring(from, to),
            style: (style ?? const TextStyle()).copyWith(
              backgroundColor: ground,
            ),
          ),
        );
        if (to < end) {
          children.add(
            TextSpan(text: line.text.substring(to, end), style: style),
          );
        }
      }
      at = end;
    }
    return TextSpan(children: children);
  }

  static TextStyle? _style(BuildContext context, SyntaxToken token) =>
      switch (token) {
        SyntaxToken.plain => null,
        SyntaxToken.punctuation => TextStyle(color: context.tokens.textMuted),
        SyntaxToken.keyword => TextStyle(color: context.tokens.syntax.keyword),
        SyntaxToken.type => TextStyle(color: context.tokens.syntax.type),
        SyntaxToken.string => TextStyle(color: context.tokens.syntax.string),
        SyntaxToken.number => TextStyle(color: context.tokens.syntax.number),
        SyntaxToken.comment => TextStyle(color: context.tokens.syntax.comment),
        SyntaxToken.annotation => TextStyle(
          color: context.tokens.syntax.annotation,
        ),
      };
}

/// `+3 −1` on a row git could count, one word on a row it could not. Shared
/// with the workspace's own change list: the rows are the same rows.
///
/// The two numbers mean opposite things and the row is read at a glance, so
/// they are coloured rather than left to the sign in front of them — the same
/// pair the panel's own total draws, and the same minus, because one screen
/// that spells the sign two ways reads as two screens.
List<TextSpan> fileCountSpans(BuildContext context, WorkspaceFile file) {
  if (file.untracked) return const [TextSpan(text: 'NEW')];
  if (file.binary) return const [TextSpan(text: 'BINARY')];
  return [
    _countSpan('+${file.added}', context.tokens.accent, file.added),
    const TextSpan(text: ' '),
    _countSpan('−${file.removed}', context.tokens.warning, file.removed),
  ];
}

/// The colour says how much of the file went this way, so a side nothing went
/// is not lit: a `−0` in warning reads as loud across the room as a `−49`, and
/// what it is reporting is that nothing happened.
TextSpan _countSpan(String text, Color lit, int? count) => TextSpan(
  text: text,
  style: (count ?? 0) == 0 ? null : TextStyle(color: lit),
);

String fileKindWord(WorkspaceFile file) => switch (file.kind) {
  WorkspaceChangeKind.modified => 'MODIFIED',
  WorkspaceChangeKind.added => 'ADDED',
  WorkspaceChangeKind.deleted => 'DELETED',
  WorkspaceChangeKind.renamed => 'RENAMED',
  WorkspaceChangeKind.untracked => 'UNTRACKED',
  WorkspaceChangeKind.conflicted => 'CONFLICT',
};
