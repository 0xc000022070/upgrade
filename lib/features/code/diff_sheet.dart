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
import '../../design/components/status_tag.dart';
import '../../design/icons/upgrade_icons.dart';
import '../../design/layout.dart';
import '../../design/spacing.dart';
import '../../platform/workspace/workspace_model.dart';

import 'diff_jump.dart';
import 'diff_map.dart';
import 'hunk_pin.dart';
import 'intraline.dart';
import 'syntax.dart';
import 'syntax_style.dart';
import 'workspace_controller.dart';

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

Future<void> _sheet(BuildContext context, String label, WidgetBuilder builder) {
  return showPanelSheet<void>(
    context,
    title: label.toUpperCase(),
    maxHeightFraction: 0.9,
    maxWidth: double.infinity,
    builder: builder,
  );
}

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

  /// The workspace's own, when the viewer was opened over it. Null when the viewer dials
  /// its own, which it then owns and closes.
  final WorkspaceController? controller;

  final Host? host;
  final String? directory;

  final WorkspaceFile? file;

  final WorkspaceOpener? open;

  @override
  ConsumerState<DiffSheet> createState() => _DiffSheetState();
}

class _DiffSheetState extends ConsumerState<DiffSheet> {
  late final WorkspaceController _controller;
  late final bool _owned;

  List<Commit>? _commits;

  Commit? _source;

  List<WorkspaceFile>? _files;
  bool _filesFailed = false;

  WorkspaceFile? _file;
  List<DiffLine>? _lines;
  bool _diffFailed = false;

  /// Every file of the source, read in one command when the source is picked. A tap on a
  /// row after that draws from here and asks the host nothing.
  Map<String, List<DiffLine>>? _bundle;

  /// The same answer while it is still in flight, so a tap that lands first waits for it
  /// instead of asking for the same file a second time.
  Future<Map<String, List<DiffLine>>?>? _bundling;

  /// Every row is one line tall and every line is the same height, so a hunk is at a known
  /// offset and jumping to it is arithmetic rather than a search.
  final ScrollController _hunkScroll = ScrollController();

  late final DiffJumps _jumps = DiffJumps(_hunkScroll);

  /// Bumped on every source change, so a slow answer that lands after the user has moved to
  /// another commit is dropped rather than drawn over it.
  int _walk = 0;

  bool _changesOpen = false;
  bool _historyOpen = false;

  bool _autoPicked = false;

  bool _fileAuto = false;

  List<DiffLine>? _plainFrom;
  List<DiffLine>? _plain;

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
          open: widget.open ?? ref.read(workspaceOpenerProvider),
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

  void _onWorkspace() {
    if (!mounted) return;
    setState(() {
      if (_source == null) {
        _files = _controller.overview?.files;
        _filesFailed = _controller.phase == WorkspacePhase.failed;
      }
    });
    _autoPick();
    if (_controller.phase != WorkspacePhase.ready) return;
    if (_commits == null) _loadCommits();
    if (_source == null && _bundling == null) {
      _loadBundle(_walk, _controller.sourceDiffs());
    }
  }

  /// One command for the whole source, kept so the file list is walked without asking the
  /// host again. A failure is not put on the screen: it costs the viewer nothing but the
  /// per-file command it was replacing.
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
      _autoPicked = false;
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
    _autoPick();
  }

  void _autoPick() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final files = _files;
      if (!mounted || _autoPicked) return;
      if (_file != null) {
        _autoPicked = true;
        return;
      }
      if (files == null || files.isEmpty) return;
      _autoPicked = true;
      final room = MediaQuery.sizeOf(context).width - Spacing.screenEdge * 2;
      if (files.length == 1 || room >= Layout.columnMax) {
        _pick(files.first, auto: true);
      }
    });
  }

  /// Not a future: the answer is usually already here, and only a file the one command did
  /// not carry costs a round trip.
  void _pick(WorkspaceFile file, {bool auto = false}) {
    final cached = _bundled(_bundle, file);
    setState(() {
      _file = file;
      _fileAuto = auto;
      _lines = cached;
      _diffFailed = false;
      _changesOpen = false;
      _historyOpen = false;
      _picked = null;
    });
    if (_hunkScroll.hasClients) _hunkScroll.jumpTo(0);
    _jumps.forget();
    if (cached == null) unawaited(_read(file));
  }

  /// The fallback: a file the bundle does not carry because the answer was cut at the byte
  /// cap, or because it is untracked and `diff` never names it.
  Future<void> _read(WorkspaceFile file) async {
    final walk = _walk;
    final source = _source;
    // The one command may still be in flight, in which case it is the answer and asking for
    // the file beside it would be the round trip this is for.
    final bundle = await _bundling;
    var lines = _bundled(bundle, file);
    lines ??= source == null
        ? await _controller.diff(file)
        : await _controller.commitDiff(source.sha, file.path);
    if (!mounted || walk != _walk || _file?.path != file.path) return;
    setState(() {
      _lines = lines;
      _diffFailed = lines == null;
    });
  }

  List<DiffLine>? _bundled(
    Map<String, List<DiffLine>>? bundle,
    WorkspaceFile file,
  ) {
    final lines = bundle?[file.path];
    final before = file.origin == null ? null : bundle?[file.origin];
    if (lines == null || before == null) return lines;
    if (_files?.any((row) => row.path == file.origin) ?? true) return lines;
    return [...before, ...lines];
  }

  int? _picked;

  WorkspaceFile? _neighbour(int step) {
    final files = _files;
    final file = _file;
    if (files == null || file == null) return null;
    final at = files.indexWhere((row) => row.path == file.path);
    final next = at + step;
    if (at < 0 || next < 0 || next >= files.length) return null;
    return files[next];
  }

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

  void _back() {
    if (_file != null && !_fileAuto) {
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
    final tall = _file != null || _changesOpen || _historyOpen;
    return PopScope(
      canPop: _file == null || _fileAuto,
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
            fit: _file != null ? FlexFit.tight : FlexFit.loose,
            child: _panes(tall: tall),
          ),
        ],
      ),
    );
  }

  Widget _headline() {
    final source = _source;
    final status = _controller.overview?.status;
    final files = _files ?? const <WorkspaceFile>[];
    // The sheet is up before the host has answered, so it says which of the two it is: a
    // checkout with nothing changed reads the same as a checkout that has not been read yet.
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

  Widget _panes({required bool tall}) {
    if (!tall) return _list();
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final wide = width >= Layout.columnMax;
        if (!wide && _file == null) return _list();
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

  static const _listShare = 0.42;

  /// Flexible and not expanded: the share is a cap on the panel and not a size handed to it.
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
        icon: _changesOpen ? UpgradeIcons.collapse : UpgradeIcons.expand,
      ),
      onHeaderTap: () => setState(() => _changesOpen = !_changesOpen),
      bodyPadding: EdgeInsets.zero,
      bodyFlexible: true,
      child: switch ((_changesOpen, files, _filesFailed)) {
        (false, _, _) => null,
        (_, final rows?, _) when rows.isNotEmpty => ListView.separated(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(
            vertical: Spacing.sm,
            horizontal: Spacing.panelPadding,
          ),
          itemCount: rows.length,
          separatorBuilder: (context, _) => Container(
            height: Borders.hairline,
            color: context.tokens.borderSubtle,
          ),
          itemBuilder: (context, index) {
            final file = rows[index];
            return ListRow(
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
            );
          },
        ),
        (_, final rows, final failed) => SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
          child: Padding(
            padding: const EdgeInsets.all(Spacing.panelPadding),
            child: EmptyState(switch ((rows, failed)) {
              (null, false) => 'loading…',
              (null, true) => _controller.reason ?? 'could not read it',
              _ => 'nothing changed',
            }),
          ),
        ),
      },
    );
  }

  Widget _history() {
    final commits = _commits;
    return Panel(
      title: 'COMMITS',
      affordance: PanelAffordance(
        _countWord(commits?.length, _controller.phase == WorkspacePhase.failed),
        icon: _historyOpen ? UpgradeIcons.collapse : UpgradeIcons.expand,
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
    return _pane(file, wide: wide);
  }

  Widget _walkBar(WorkspaceFile file) {
    final picked = _picked;
    final lines = identical(_plainFrom, _lines) ? _plain ?? _lines : _lines;
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
    return Wrap(
      spacing: Spacing.md,
      runSpacing: Spacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ActionBlock(
          key: const ValueKey('diff-prev-file'),
          label: 'PREV',
          onTap: before == null ? null : () => _pick(before),
          tone: before == null
              ? context.tokens.textDisabled
              : context.tokens.textSecondary,
        ),
        ActionBlock(
          key: const ValueKey('diff-next-file'),
          label: 'NEXT',
          onTap: after == null ? null : () => _pick(after),
          tone: after == null
              ? context.tokens.textDisabled
              : context.tokens.textSecondary,
        ),
        ActionBlock(
          key: const ValueKey('diff-next-hunk'),
          label: 'HUNK',
          onTap: hunks > 1 ? _walkHunk : null,
          tone: hunks > 1
              ? context.tokens.textSecondary
              : context.tokens.textDisabled,
        ),
        if (at >= 0)
          Text(
            'FILE ${at + 1} / ${files.length}',
            style: context.tokens.value.copyWith(
              color: context.tokens.textMuted,
            ),
          ),
      ],
    );
  }

  Widget _pickedBar(DiffLine line) {
    final number = line.newLine ?? line.oldLine;
    return Wrap(
      spacing: Spacing.md,
      runSpacing: Spacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ActionBlock(
          key: const ValueKey('diff-copy-line'),
          label: 'COPY',
          filled: true,
          tone: context.tokens.accent,
          onTap: () async {
            // The line as the file has it, not as the pane drew it: the tabs the pane opened out are
            // the file's tabs, and a hunk header is git's words in git's order once it leaves the
            // screen.
            await Clipboard.setData(ClipboardData(text: line.text));
            if (mounted) setState(() => _picked = null);
          },
        ),
        ActionBlock(
          key: const ValueKey('diff-drop-line'),
          label: 'LET GO',
          onTap: () => setState(() => _picked = null),
        ),
        if (number != null)
          Text(
            // A removed line's number is in the file before the change, and the line that replaced
            // it carries the same number in the file after. Held one after the other, the two rows
            // would read the same.
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

  List<DiffLine>? _plainOf(WorkspaceFile file, List<DiffLine> lines) {
    if (identical(lines, _plainFrom)) return _plain;
    _plainFrom = lines;
    return _plain = plainFile(file, lines);
  }

  Widget _pane(WorkspaceFile file, {required bool wide}) {
    final lines = _lines;
    final plain = lines == null ? null : _plainOf(file, lines);
    final tag = plain == null
        ? null
        : file.kind == WorkspaceChangeKind.deleted
        ? StatusTag('DELETED', color: context.tokens.warning)
        : StatusTag('NEW FILE', color: context.tokens.accent);
    return Panel(
      // The path and not its last segment: two files of the same name in two directories are
      // the ordinary case in a repository.
      title: file.path,
      literalTitle: true,
      leading: tag,
      affordance: wide
          ? file.binary
                ? null
                : _Stat(added: file.added!, removed: file.removed!)
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: switch ((lines, _diffFailed)) {
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
                lines: plain ?? rows,
                single: plain != null,
                language: languageOf(file.path),
                jumps: _jumps,
                picked: _picked,
                onPick: (row) => setState(() => _picked = row),
              ),
            },
          ),
          Container(
            height: Borders.hairline,
            color: context.tokens.borderNormal,
          ),
          Padding(
            padding: const EdgeInsets.all(Spacing.sm),
            child: _walkBar(file),
          ),
        ],
      ),
    );
  }
}

List<DiffLine>? plainFile(WorkspaceFile file, List<DiffLine> lines) {
  final side = switch (file.kind) {
    WorkspaceChangeKind.untracked ||
    WorkspaceChangeKind.added => DiffLineKind.added,
    WorkspaceChangeKind.deleted => DiffLineKind.removed,
    _ => null,
  };
  if (side == null) return null;
  final plain = <DiffLine>[];
  for (final line in lines) {
    if (line.kind == DiffLineKind.meta || line.kind == DiffLineKind.hunk) {
      continue;
    }
    if (line.kind == DiffLineKind.capped) {
      plain.add(line);
    } else if (line.kind == side) {
      plain.add(
        DiffLine(
          DiffLineKind.context,
          line.text,
          oldLine: line.oldLine,
          newLine: line.newLine,
        ),
      );
    } else {
      return null;
    }
  }
  return plain.isEmpty ? null : plain;
}

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

/// The gutter scrolls with the text rather than standing still beside it: two scrollers
/// kept in step is a second source of truth about where the view is, and the one thing
/// worse than a gutter that moves is a gutter that disagrees with the line next to it.
class _DiffBody extends StatefulWidget {
  const _DiffBody({
    required this.lines,
    required this.jumps,
    required this.picked,
    required this.onPick,
    this.language,
    this.single = false,
  });

  final List<DiffLine> lines;

  final bool single;

  final DiffJumps jumps;

  final SyntaxLanguage? language;

  final int? picked;

  final ValueChanged<int> onPick;

  /// One line's box plus the hairline of air either side of it. Every row is exactly this
  /// tall — the text never wraps — which is what lets the list build only the rows on
  /// screen and still know where row ten thousand is. Measured at the size the phone is
  /// going to paint it: a row sized for the small one cuts the top and bottom off every
  /// line and puts every jump on the wrong row.
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
  /// How far left the text is pushed, in pixels. The numbers and the marker are not pushed
  /// with it. A notifier and not `setState`: a drag repaints the text of the rows on screen
  /// and nothing else — not the list, not the sheet around it.
  final ValueNotifier<double> _shift = ValueNotifier(0);

  /// A hunk header has no number of its own, so the search runs on to the first line under
  /// it that has one.
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

  /// Worked out once for the file rather than per row: the answer for a line lives in the
  /// line beside it, which a row being built on its own cannot see.
  List<IntralineSpan?> _changed = const [];

  /// The lines as they are drawn, which is the lines git sent with their tabs opened out.
  /// Everything downstream — the width, the pairing, the offsets the marked run is given in
  /// — is then counting the same characters the reader is looking at.
  List<DiffLine> _drawn = const [];

  List<DiffStreak> _streaks = const [];

  List<int> _hunks = const [];

  @override
  void initState() {
    super.initState();
    _read();
  }

  @override
  void didUpdateWidget(covariant _DiffBody old) {
    super.didUpdateWidget(old);
    // Another file is another set of lines and another width. The reader is put back at the
    // left margin rather than dropped into the middle of a line they have not read yet.
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
    final lead = _DiffRow.lead(gutter, advance, single: widget.single);
    final text = widest * advance + Spacing.panelPadding;
    return LayoutBuilder(
      builder: (context, constraints) {
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
                          // Horizontal against the list's vertical: the arena hands the
                          // drag to whichever direction it started in. From the touch
                          // down and not from the win: the rows hold a long press now, so
                          // the drag has to outrun the slop before the arena gives it
                          // anything, and the text would otherwise arrive at the finger
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
                                // The row that says where a cut file stops is this app's
                                // sentence about the file rather than anything the file
                                // has, so there is nothing in it to take.
                                onLongPress: line.kind == DiffLineKind.capped
                                    ? null
                                    : () => widget.onPick(index),
                                child: _DiffRow(
                                  line: line,
                                  gutter: gutter,
                                  single: widget.single,
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
                            rowAt: (row) => _DiffRow(
                              line: _drawn[row],
                              gutter: gutter,
                              single: widget.single,
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

  /// By the time a line is drawn its width in characters is its length: the face is
  /// monospaced and the tabs are already gone.
  int _columns(String text) => text.length;
}

/// A tab opened out to the next eight-column stop. The face draws a tab as one advance
/// and the pane was measuring it as eight, so a file indented with tabs came out both
/// mismeasured and flattened. Eight is git's own stop and the one the width arithmetic
/// already assumed.
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

/// The advance of one character in the body's face, measured once. IBM Plex Mono is
/// monospaced, so the width of a line is its length and the width of the whole diff is
/// the longest line — arithmetic, where `IntrinsicWidth` was a second layout pass over
/// every row in the file, and arithmetic is what lets the rows be built lazily.
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

/// The painted font size [_advance] was measured at. The system text size can move while
/// the app is open, and a cache that outlived it would be the same mismeasurement it
/// exists to avoid.
double? _advanceAt;
const _ruler = '0123456789';

/// Wide enough for the highest number either side, with a floor of two digits so a short
/// file's gutter is not a hairline.
double _gutterWidth(int highest, double advance) =>
    (highest < 100 ? 2 : highest.toString().length) * advance + Spacing.md;

class _DiffRow extends StatelessWidget {
  const _DiffRow({
    required this.line,
    required this.gutter,
    required this.shift,
    required this.travel,
    this.language,
    this.changed,
    this.picked = false,
    this.single = false,
  });

  final DiffLine line;
  final double gutter;
  final bool single;
  final SyntaxLanguage? language;

  final ValueListenable<double> shift;

  /// How far the text can go before its longest line ends. Read here as well as in the drag
  /// so a pane that just got narrower draws clamped instead of writing to the notifier in
  /// the middle of a build.
  final double travel;

  final IntralineSpan? changed;

  final bool picked;

  static double lead(double gutter, double advance, {bool single = false}) =>
      (single ? gutter + Spacing.md * 2 : gutter * 2 + Spacing.md * 3) +
      Borders.hairline +
      advance +
      Spacing.sm;

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
          if (!single) ...[
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
          ],
          SizedBox(
            width: gutter,
            child: Text(
              '${(single ? line.newLine ?? line.oldLine : line.newLine) ?? ''}',
              style: numbers,
              textAlign: TextAlign.right,
              maxLines: 1,
            ),
          ),
          const SizedBox(width: Spacing.md),
          Container(
            width: Borders.hairline,
            // The row's whole inside. A fixed height was the row's inside
            // at one text size and a third of the way short of it at the
            // largest, which turned the rule into ticks.
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

  /// A hunk header, the `diff --git` preamble and the row that says where a cut file stops
  /// are words about the file rather than lines of it, so they keep the colour they have: a
  /// sentence read through a Dart lexer picks out its keywords.
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
            TextSpan(text: span.text, style: syntaxStyle(context, span.token)),
        ],
      );
    }
    // The colour runs and the changed run are two cuts of the same line made for different
    // reasons, so the line is cut at both and each piece keeps the syntax colour it had.
    final children = <TextSpan>[];
    var at = 0;
    for (final span in runs) {
      final end = at + span.text.length;
      final style = syntaxStyle(context, span.token);
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
}

List<TextSpan> fileCountSpans(BuildContext context, WorkspaceFile file) {
  if (file.binary) return [TextSpan(text: file.untracked ? 'NEW' : 'BINARY')];
  return [
    _countSpan('+${file.added}', context.tokens.accent, file.added),
    const TextSpan(text: ' '),
    _countSpan('−${file.removed}', context.tokens.warning, file.removed),
  ];
}

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
