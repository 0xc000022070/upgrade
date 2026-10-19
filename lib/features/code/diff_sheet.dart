import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/agents/agents.dart';
import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/data/repositories/path_repository.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/design/components/action_block.dart';
import 'package:striked/design/components/list_row.dart';
import 'package:striked/design/components/panel.dart';
import 'package:striked/design/components/panel_sheet.dart';
import 'package:striked/design/components/section.dart';
import 'package:striked/design/components/status_tag.dart';
import 'package:striked/design/layout.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/platform/workspace/workspace_model.dart';

import 'package:striked/features/code/diff_jump.dart';
import 'package:striked/features/code/diff_map.dart';
import 'package:striked/features/code/hunk_pin.dart';
import 'package:striked/features/code/intraline.dart';
import 'package:striked/features/code/structural.dart';
import 'package:striked/features/code/syntax.dart';
import 'package:striked/features/code/syntax_style.dart';
import 'package:striked/features/code/workspace_controller.dart';

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

Future<void> showDiffSheetFinding(
  BuildContext context,
  Host host,
  Future<String?> directory, {
  required String label,
  List<({String directory, String label})> targets = const [],
}) {
  return _sheet(
    context,
    label,
    (_) => _Finding(
      host: host,
      directory: directory,
      label: label,
      targets: targets,
    ),
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

class _Finding extends StatefulWidget {
  const _Finding({
    required this.host,
    required this.directory,
    required this.label,
    required this.targets,
  });

  final Host host;
  final Future<String?> directory;
  final String label;
  final List<({String directory, String label})> targets;

  @override
  State<_Finding> createState() => _FindingState();
}

class _FindingState extends State<_Finding> {
  bool _answered = false;
  String? _directory;

  @override
  void initState() {
    super.initState();
    unawaited(_find());
  }

  Future<void> _find() async {
    String? directory;
    try {
      directory = await widget.directory;
    } finally {
      if (mounted) {
        setState(() {
          _answered = true;
          _directory = directory;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final directory = _directory;
    if (directory != null) {
      return DiffSheet(host: widget.host, directory: directory);
    }
    if (!_answered) {
      return Panel(
        title: '${widget.label.toUpperCase()} / WORKING TREE',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('loading…', style: context.tokens.rowTitleLead),
            const SizedBox(height: Spacing.sm),
            Text('finding the checkout', style: context.tokens.rowSubtitle),
          ],
        ),
      );
    }
    if (widget.targets.isEmpty) {
      return const Panel(title: 'DIFF', child: EmptyState('not a checkout'));
    }
    return Panel(
      title: 'DIFF',
      bodyPadding: EdgeInsets.zero,
      child: ListRowGroup(
        children: [
          for (final target in widget.targets)
            ListRow(
              key: ValueKey('shell-diff-${target.directory}'),
              title: target.label.toUpperCase(),
              subtitle: shortPathLabel(target.directory),
              onTap: () => setState(() => _directory = target.directory),
            ),
        ],
      ),
    );
  }
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

  final _reading = <String>{};

  Map<String, FileTexts>? _texts;

  List<WorkspaceFile>? _textsOf;

  final Map<String, _Read?> _reads = {};

  Set<int> _opened = {};

  bool? _split;

  _Doc? _doc;
  Object? _docKey;

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
    final files = _files;
    if (_source == null && files != null && !identical(files, _textsOf)) {
      _textsOf = files;
      unawaited(_loadTexts(_walk, files, _controller.texts(files)));
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
    final file = _file;
    final lines = file == null ? null : _bundled(files, file);
    setState(() {
      _bundle = files;
      _bundling = null;
      if (lines != null) _lines = lines;
    });
  }

  Future<void> _loadTexts(
    int walk,
    List<WorkspaceFile> files,
    Future<Map<String, FileTexts>?> answer,
  ) async {
    final texts = await answer;
    if (!mounted || walk != _walk || !identical(files, _textsOf)) return;
    setState(() {
      _texts = texts ?? const {};
      _reads.clear();
    });
    final file = _file;
    if (file == null) return;
    await _study(file);
    if (!mounted ||
        walk != _walk ||
        !identical(files, _textsOf) ||
        _file?.path != file.path) {
      return;
    }
    if (_lines == null &&
        _reads[file.path] == null &&
        !_reading.contains(file.path)) {
      unawaited(_read(file));
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
      _bundle = null;
      _bundling = null;
      _reading.clear();
      _texts = null;
      _textsOf = null;
      _reads.clear();
      _autoPicked = false;
      if (_historyOpen) {
        _historyOpen = false;
        _changesOpen = true;
      }
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
    if (files != null) {
      _textsOf = files;
      unawaited(
        _loadTexts(walk, files, _controller.texts(files, sha: commit.sha)),
      );
    }
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
      } else if (!_historyOpen) {
        setState(() => _changesOpen = true);
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
      _held = null;
      _opened = {};
    });
    if (_hunkScroll.hasClients) _hunkScroll.jumpTo(0);
    _jumps.forget();
    if (cached == null &&
        _reads[file.path] == null &&
        !_reading.contains(file.path)) {
      unawaited(_read(file));
    }
    unawaited(_study(file));
  }

  /// The fallback: a file the bundle does not carry because the answer was cut at the byte
  /// cap, or because it is untracked and `diff` never names it.
  Future<void> _read(WorkspaceFile file) async {
    final walk = _walk;
    final source = _source;
    _reading.add(file.path);
    List<DiffLine>? lines;
    try {
      // The one command may still be in flight, in which case it is the answer and asking
      // for the file beside it would be the round trip this is for.
      final bundle = await _bundling;
      lines = _bundled(bundle, file);
      lines ??= source == null
          ? await _controller.diff(file)
          : await _controller.commitDiff(source.sha, file.path);
    } finally {
      if (walk == _walk) _reading.remove(file.path);
    }
    if (!mounted || walk != _walk || _file?.path != file.path) return;
    setState(() {
      _lines = lines;
      _diffFailed = lines == null;
    });
  }

  Future<void> _study(WorkspaceFile file) async {
    final texts = _texts?[file.path];
    if (texts == null || _reads.containsKey(file.path)) return;
    final walk = _walk;
    final read = texts.readable ? await _readTexts(texts) : null;
    if (!mounted || walk != _walk || !identical(_texts?[file.path], texts)) {
      return;
    }
    setState(() => _reads[file.path] = read);
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

  DiffLine? _held;

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
    final rows = _doc?.rows;
    if (rows == null || !_hunkScroll.hasClients) return;
    final at = (_hunkScroll.offset / _DiffBody.rowHeight(context)).round();
    bool hunk(SplitRow row) => row.across?.line.kind == DiffLineKind.hunk;
    var found = -1;
    for (var i = at + 1; i < rows.length; i++) {
      if (hunk(rows[i])) {
        found = i;
        break;
      }
    }
    if (found < 0) found = rows.indexWhere(hunk);
    if (found < 0) return;
    _jumps.to(found * _DiffBody.rowHeight(context));
  }

  void _close() {
    setState(() {
      _file = null;
      _lines = null;
      _held = null;
      _changesOpen = true;
      _historyOpen = false;
    });
  }

  void _back() {
    if (_file != null && !_fileAuto) {
      _close();
      return;
    }
    Navigator.of(context).pop();
  }

  void _unfold({required bool changes}) {
    setState(() {
      if (changes) {
        _changesOpen = !_changesOpen;
        _historyOpen = false;
      } else {
        _historyOpen = !_historyOpen;
        _changesOpen = false;
      }
    });
  }

  void _fold(int key) {
    setState(() => _opened = {..._opened, key});
  }

  int? _heldAt(List<SplitRow> rows) {
    final held = _held;
    if (held == null) return null;
    final at = rows.indexWhere((row) {
      final line = _rowLine(row);
      return line.kind == held.kind &&
          line.text == held.text &&
          line.oldLine == held.oldLine &&
          line.newLine == held.newLine;
    });
    return at < 0 ? null : at;
  }

  DiffLine _rowLine(SplitRow row) =>
      (row.across ?? row.right ?? row.left)!.line;

  @override
  Widget build(BuildContext context) {
    final list = _changesOpen
        ? _changes()
        : _historyOpen
        ? _history()
        : null;
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
          if (list != null || _file != null) ...[
            const SizedBox(height: Spacing.panelGap),
            Flexible(
              fit: _paneShown(list) ? FlexFit.tight : FlexFit.loose,
              child: _panes(list),
            ),
          ],
        ],
      ),
    );
  }

  Widget _headline() {
    final source = _source;
    final status = _controller.overview?.status;
    final files = _files;
    // The sheet is up before the host has answered, so it says which of the two it is: a
    // checkout with nothing changed reads the same as a checkout that has not been read yet.
    final loading = _controller.phase == WorkspacePhase.connecting;
    var added = 0;
    var removed = 0;
    for (final file in files ?? const <WorkspaceFile>[]) {
      added += file.added ?? 0;
      removed += file.removed ?? 0;
    }
    final line = loading
        ? 'reading the checkout'
        : source != null
        ? source.subject
        : [
            status?.branch ?? 'detached',
            if (status != null && !status.clean)
              '${status.changes.length} changed',
          ].join('  ·  ');
    return Panel(
      title:
          '${_controller.label.toUpperCase()} / '
          '${source == null ? 'WORKING TREE' : source.short}',
      literalTitle: source != null,
      affordance: loading || files == null
          ? null
          : _Stat(added: added, removed: removed, files: files.length),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            line,
            style: source != null && !loading
                ? context.tokens.rowTitleLead
                : context.tokens.rowSubtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (source != null && !loading)
            Text(
              '${source.author}  ·  ${source.age}',
              style: context.tokens.rowSubtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          const SizedBox(height: Spacing.md),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: _Switch(
                  key: const ValueKey('diff-changes'),
                  label: 'CHANGES',
                  count: _countWord(files?.length, _filesFailed),
                  open: _changesOpen,
                  onTap: () => _unfold(changes: true),
                ),
              ),
              const SizedBox(width: Spacing.md),
              Flexible(
                child: _Switch(
                  key: const ValueKey('diff-commits'),
                  label: 'COMMITS',
                  count: _countWord(
                    _commits?.length,
                    _controller.phase == WorkspacePhase.failed,
                  ),
                  open: _historyOpen,
                  onTap: () => _unfold(changes: false),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  bool _paneShown(Widget? list) =>
      _file != null &&
      (list == null || MediaQuery.sizeOf(context).width >= Layout.columnMax);

  Widget _panes(Widget? list) {
    final file = _file;
    if (file == null) return list!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final wide = width >= Layout.columnMax;
        if (!wide && list != null) return list;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wide && list != null) ...[
              SizedBox(
                width: width * _listShare - Spacing.panelGap / 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [Flexible(child: list)],
                ),
              ),
              const SizedBox(width: Spacing.panelGap),
            ],
            Expanded(
              key: const ValueKey('diff-pane'),
              child: _pane(file, wide: wide),
            ),
          ],
        );
      },
    );
  }

  static const _listShare = 0.42;

  String _countWord(int? count, bool failed) {
    if (count != null) return '$count';
    return failed ? 'FAILED' : 'LOADING';
  }

  Widget _changes() {
    final files = _files;
    return Panel(
      bodyPadding: EdgeInsets.zero,
      bodyFlexible: true,
      child: switch ((files, _filesFailed)) {
        (final rows?, _) when rows.isNotEmpty => ListView.separated(
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
        (final rows, final failed) => SingleChildScrollView(
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
      bodyPadding: EdgeInsets.zero,
      bodyFlexible: true,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
        child: Padding(
          padding: panelRowsPadding,
          child: ListRowGroup(
            children: [
              ListRow(
                key: const ValueKey('diff-source-tree'),
                title: 'WORKING TREE',
                titleColor: _source == null ? context.tokens.accent : null,
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

  Widget _walkBar(WorkspaceFile file) {
    final held = _held;
    final rows = _doc?.rows;
    if (held != null && rows != null && _heldAt(rows) != null) {
      return _pickedBar(held);
    }
    final files = _files ?? const <WorkspaceFile>[];
    final at = files.indexWhere((row) => row.path == file.path);
    final before = _neighbour(-1);
    final after = _neighbour(1);
    final hunks = (rows ?? const <SplitRow>[])
        .where((row) => row.across?.line.kind == DiffLineKind.hunk)
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
          Text('FILE ${at + 1} / ${files.length}', style: context.tokens.value),
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
            if (mounted) setState(() => _held = null);
          },
        ),
        ActionBlock(
          key: const ValueKey('diff-drop-line'),
          label: 'LET GO',
          onTap: () => setState(() => _held = null),
        ),
        if (number != null)
          Text(
            // A removed line's number is in the file before the change, and the line that replaced
            // it carries the same number in the file after. Held one after the other, the two rows
            // would read the same.
            line.kind == DiffLineKind.removed
                ? 'WAS LINE $number'
                : 'LINE $number',
            style: context.tokens.value,
          ),
      ],
    );
  }

  List<DiffLine>? _plainOf(WorkspaceFile file, List<DiffLine> lines) {
    if (identical(lines, _plainFrom)) return _plain;
    _plainFrom = lines;
    return _plain = plainFile(file, lines);
  }

  _Doc? _document(WorkspaceFile file, {required bool split}) {
    final read = _reads[file.path];
    final lines = _lines;
    final key = (read ?? lines, _opened, split);
    final known = _doc;
    if (known != null && _docKey == key) return known;
    _Doc? doc;
    if (read != null) {
      doc = read.document(_opened, split: split);
    } else if (lines != null) {
      final plain = _plainOf(file, lines);
      final shown = _hunkRows(plain ?? lines);
      doc = _Doc(
        rows: plain == null && split
            ? splitRows(shown)
            : [for (final row in shown) SplitRow(across: row)],
        reader: DiffReader.lines,
        split: plain == null && split,
        single: plain != null,
      );
    }
    _doc = doc;
    _docKey = key;
    return doc;
  }

  Widget _pane(WorkspaceFile file, {required bool wide}) {
    final read = _reads[file.path];
    final lines = _lines;
    final single = read != null
        ? read.single
        : lines != null && _plainOf(file, lines) != null;
    final tag = !single
        ? null
        : file.kind == WorkspaceChangeKind.deleted
        ? StatusTag('DELETED', color: context.tokens.warning)
        : StatusTag('NEW FILE', color: context.tokens.accent);
    return LayoutBuilder(
      builder: (context, constraints) {
        final fits = !single && _splitFits(context, constraints.maxWidth);
        final split = fits && (_split ?? true);
        final doc = _document(file, split: split);
        return Panel(
          // The path and not its last segment: two files of the same name in two directories are
          // the ordinary case in a repository.
          title: file.path,
          literalTitle: true,
          leading: tag,
          affordance: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (doc != null && !single)
                Text(
                  switch (doc.reader) {
                    DiffReader.syntax => 'SYNTAX',
                    DiffReader.tokens => 'TOKENS',
                    DiffReader.lines => 'LINES',
                  },
                  key: const ValueKey('diff-reader'),
                  style: context.tokens.panelHeader.copyWith(
                    color: context.tokens.textDisabled,
                  ),
                ),
              if (fits) ...[
                const SizedBox(width: Spacing.lg),
                PanelAffordance(
                  split ? 'UNIFIED' : 'SPLIT',
                  key: const ValueKey('diff-split'),
                  showIcon: false,
                  onTap: () => setState(() {
                    _split = !split;
                    _held = null;
                  }),
                ),
              ],
              const SizedBox(width: Spacing.lg),
              if (wide)
                if (!file.binary)
                  _Stat(added: file.added!, removed: file.removed!)
                else
                  const SizedBox.shrink()
              else
                PanelAffordance(
                  'CLOSE',
                  key: const ValueKey('diff-close-file'),
                  showIcon: false,
                  onTap: _close,
                ),
            ],
          ),
          bodyPadding: EdgeInsets.zero,
          bodyFlexible: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _paneBody(file, doc, read)),
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
      },
    );
  }

  Widget _paneBody(WorkspaceFile file, _Doc? doc, _Read? read) {
    String? empty;
    if (doc == null) {
      empty = _diffFailed ? 'could not read it' : 'loading…';
    } else if (read?.whitespace ?? false) {
      empty = 'only whitespace changed';
    } else if (doc.rows.isEmpty && (read?.single ?? false)) {
      empty = 'empty file';
    } else if (doc.rows.isEmpty || (read?.unchanged ?? false)) {
      empty = 'no textual change';
    }
    if (empty != null) {
      return Padding(
        padding: const EdgeInsets.all(Spacing.panelPadding),
        child: EmptyState(empty),
      );
    }
    return _DiffBody(
      path: file.path,
      doc: doc!,
      language: languageOf(file.path),
      jumps: _jumps,
      picked: _heldAt(doc.rows),
      onPick: (row) => setState(() => _held = _rowLine(doc.rows[row])),
      onFold: _fold,
    );
  }

  bool _splitFits(BuildContext context, double width) {
    final advance = _charAdvance(context);
    final lead = _DiffRow.lead(
      _gutterWidth(9999, advance),
      advance,
      single: true,
    );
    return width - DiffMap.width >= 2 * (lead + 80 * advance);
  }
}

List<ShownRow> _hunkRows(List<DiffLine> lines) {
  final changed = intralineChanges(lines);
  return [
    for (var at = 0; at < lines.length; at++)
      ShownRow(
        lines[at],
        runs: [?changed[at]],
        fromOld: lines[at].kind == DiffLineKind.removed,
      ),
  ];
}

const _isolateAbove = 65536;

Future<_Read?> _readTexts(FileTexts texts) async {
  final language = languageOf(texts.path);
  final reader = texts.changedOld != null || texts.changedNew != null
      ? DiffReader.syntax
      : DiffReader.tokens;
  final old = texts.old;
  final now = texts.now;
  final oldSpans = old == null || language == null
      ? null
      : await highlightFile(old, language);
  final newSpans = now == null || language == null
      ? null
      : await highlightFile(now, language);
  if (old == null || now == null) {
    final lines = splitLines(old ?? now);
    return _Read(
      reader: reader,
      oldSpans: oldSpans,
      newSpans: newSpans,
      plain: [
        for (var at = 0; at < lines.length; at++)
          ShownRow(
            DiffLine(
              DiffLineKind.context,
              lines[at],
              oldLine: old == null ? null : at + 1,
              newLine: now == null ? null : at + 1,
            ),
            fromOld: now == null,
          ),
      ],
    );
  }
  StructuralFile? read() =>
      structuralFile(texts, language, oldSpans: oldSpans, newSpans: newSpans);
  final file = old.length + now.length > _isolateAbove
      ? await Isolate.run(read)
      : read();
  if (file == null) return null;
  return _Read(
    reader: reader,
    structural: file,
    oldSpans: oldSpans,
    newSpans: newSpans,
    whitespace:
        old != now &&
        file.rows.every((row) => row.kind == DiffLineKind.context),
  );
}

class _Read {
  const _Read({
    required this.reader,
    this.structural,
    this.plain,
    this.oldSpans,
    this.newSpans,
    this.whitespace = false,
  });

  final DiffReader reader;
  final StructuralFile? structural;

  final List<ShownRow>? plain;
  final List<List<SyntaxSpan>>? oldSpans;
  final List<List<SyntaxSpan>>? newSpans;

  final bool whitespace;

  bool get single => plain != null;

  bool get unchanged =>
      structural?.rows.every((row) => row.kind == DiffLineKind.context) ??
      false;

  _Doc document(Set<int> opened, {required bool split}) {
    final plain = this.plain;
    if (plain != null) {
      return _Doc(
        rows: [for (final row in plain) SplitRow(across: row)],
        reader: reader,
        single: true,
        oldSpans: oldSpans,
        newSpans: newSpans,
      );
    }
    final shown = presentFile(structural!, opened);
    return _Doc(
      rows: split
          ? splitRows(shown)
          : [for (final row in shown) SplitRow(across: row)],
      reader: reader,
      split: split,
      oldSpans: oldSpans,
      newSpans: newSpans,
    );
  }
}

class _Doc {
  const _Doc({
    required this.rows,
    required this.reader,
    this.split = false,
    this.single = false,
    this.oldSpans,
    this.newSpans,
  });

  final List<SplitRow> rows;
  final DiffReader reader;
  final bool split;
  final bool single;
  final List<List<SyntaxSpan>>? oldSpans;
  final List<List<SyntaxSpan>>? newSpans;

  List<SyntaxSpan>? spansOf(ShownRow row) {
    final line = row.line;
    final (spans, number) = switch (line.kind) {
      DiffLineKind.fold => (newSpans, row.fold?.headLine),
      _ when row.fromOld => (oldSpans, line.oldLine),
      _ => (newSpans, line.newLine),
    };
    if (spans == null || number == null || number > spans.length) return null;
    return spans[number - 1];
  }
}

class _Switch extends StatelessWidget {
  const _Switch({
    super.key,
    required this.label,
    required this.count,
    required this.open,
    required this.onTap,
  });

  final String label;
  final String count;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tone = open ? context.tokens.accent : context.tokens.textSecondary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: TapTargets.minHeight),
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
        decoration: BoxDecoration(
          border: Border.all(
            color: open ? context.tokens.accent : context.tokens.borderNormal,
            width: Borders.hairline,
          ),
          borderRadius: BorderRadius.circular(Radii.sharp),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: context.tokens.panelHeader.copyWith(color: tone),
            ),
            const SizedBox(width: Spacing.sm),
            Flexible(
              child: Text(
                count,
                style: context.tokens.panelHeader.copyWith(
                  color: context.tokens.textMuted,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
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
            style: context.tokens.panelHeader,
          ),
          const SizedBox(width: Spacing.lg),
        ],
        Text.rich(
          _countSpan('+$added', context.tokens.accent, added),
          style: context.tokens.panelHeader,
        ),
        const SizedBox(width: Spacing.md),
        Text.rich(
          _countSpan('−$removed', context.tokens.warning, removed),
          style: context.tokens.panelHeader,
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
    required this.path,
    required this.doc,
    required this.jumps,
    required this.picked,
    required this.onPick,
    required this.onFold,
    this.language,
  });

  final String path;

  final _Doc doc;

  final DiffJumps jumps;

  final SyntaxLanguage? language;

  final int? picked;

  final ValueChanged<int> onPick;

  final ValueChanged<int> onFold;

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

class _DiffBodyState extends State<_DiffBody>
    with SingleTickerProviderStateMixin {
  /// How far left the text is pushed, in pixels. The numbers and the marker are not pushed
  /// with it. A notifier and not `setState`: a drag repaints the text of the rows on screen
  /// and nothing else — not the list, not the sheet around it.
  final ValueNotifier<double> _shift = ValueNotifier(0);

  /// The text carried on after the finger lets go, the way the vertical list is.
  late final AnimationController _glide = AnimationController.unbounded(
    vsync: this,
  )..addListener(_glided);

  double _travel = 0;

  void _glided() {
    final at = _glide.value.clamp(0.0, _travel);
    _shift.value = at;
    if (at != _glide.value) _glide.stop();
  }

  void _fling(DragEndDetails end) {
    final velocity = -(end.primaryVelocity ?? 0);
    if (velocity == 0) return;
    _glide
      ..value = _shift.value
      ..animateWith(
        ClampingScrollSimulation(position: _shift.value, velocity: velocity),
      );
  }

  /// A hunk header has no number of its own, so the search runs on to the first line under
  /// it that has one.
  int? _lineAt(double offset) {
    final rows = widget.doc.rows;
    for (
      var row = (offset / _DiffBody.rowHeight(context)).floor();
      row < rows.length;
      row++
    ) {
      if (row < 0) continue;
      final line = rows[row].line;
      final number = line.newLine ?? line.oldLine;
      if (number != null) return number;
    }
    return null;
  }

  /// Every row's text as drawn, its tabs opened out and its runs and colours moved to
  /// match, so the width and the mark offsets count the characters on screen.
  final Map<ShownRow, _Cell> _cells = Map.identity();

  List<DiffStreak> _streaks = const [];

  List<int> _hunks = const [];

  int _widest = 0;
  int _highest = 0;

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
    if (old.path != widget.path) {
      _glide.stop();
      _shift.value = 0;
    }
    if (!identical(old.doc, widget.doc)) _read();
  }

  void _read() {
    _cells.clear();
    _widest = 0;
    _highest = 0;
    final lines = <DiffLine>[];
    for (final row in widget.doc.rows) {
      for (final side in [row.across, row.left, row.right]) {
        if (side == null) continue;
        final cell = _cells[side] ??= _cell(side);
        if (cell.text.length > _widest) _widest = cell.text.length;
        final old = side.line.oldLine ?? 0;
        final now = side.line.newLine ?? 0;
        if (old > _highest) _highest = old;
        if (now > _highest) _highest = now;
      }
      lines.add(row.line);
    }
    _streaks = diffStreaks(lines);
    _hunks = hunkRows(lines);
  }

  _Cell _cell(ShownRow row) {
    final line = row.line;
    final text = switch (line.kind) {
      DiffLineKind.hunk => hunkHeadline(line.text),
      DiffLineKind.fold => row.fold?.head ?? '',
      _ => line.text,
    };
    return _Cell.open(
      text,
      row.moved ? const [] : row.runs,
      widget.doc.spansOf(row),
    );
  }

  @override
  void dispose() {
    _glide.dispose();
    _shift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.doc;
    final advance = _charAdvance(context);
    final row = _DiffBody.rowHeight(context);
    final gutter = _gutterWidth(_highest, advance);
    final halves = doc.split;
    final lead = _DiffRow.lead(gutter, advance, single: doc.single || halves);
    final text = _widest * advance + Spacing.panelPadding;
    return LayoutBuilder(
      builder: (context, constraints) {
        final mapped =
            _streaks.isNotEmpty &&
            doc.rows.length * row > constraints.maxHeight;
        final width = constraints.maxWidth - (mapped ? DiffMap.width : 0);
        final room = math.max(
          0.0,
          (halves ? (width - Borders.hairline) / 2 : width) - lead,
        );
        final travel = math.max(0.0, text - room);
        _travel = travel;
        Widget side(ShownRow? shown, {required bool old}) {
          if (shown == null) return const SizedBox.shrink();
          final line = shown.line;
          return _DiffRow(
            line: DiffLine(
              line.kind,
              line.text,
              oldLine: old ? line.oldLine : null,
              newLine: old ? null : line.newLine,
            ),
            cell: _cells[shown]!,
            moved: shown.moved,
            gutter: gutter,
            single: true,
            language: widget.language,
            shift: _shift,
            travel: travel,
          );
        }

        Widget rowAt(int index) {
          final at = doc.rows[index];
          final across = at.across;
          if (across != null) {
            final fold = across.fold;
            if (fold != null) {
              return _FoldLine(
                fold: fold,
                cell: _cells[across]!,
                lead: lead,
                language: widget.language,
                shift: _shift,
                travel: travel,
                onTap: () => widget.onFold(fold.key),
              );
            }
            return _DiffRow(
              line: across.line,
              cell: _cells[across]!,
              moved: across.moved,
              gutter: gutter,
              single: doc.single,
              language: widget.language,
              shift: _shift,
              travel: travel,
              picked: widget.picked == index,
            );
          }
          final pair = Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: side(at.left, old: true)),
              Container(
                width: Borders.hairline,
                color: context.tokens.borderNormal,
              ),
              Expanded(child: side(at.right, old: false)),
            ],
          );
          return widget.picked == index ? _Picked(child: pair) : pair;
        }

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
                          onHorizontalDragDown: travel == 0
                              ? null
                              : (_) => _glide.stop(),
                          onHorizontalDragUpdate: travel == 0
                              ? null
                              : (drag) => _shift.value =
                                    (_shift.value - drag.delta.dx).clamp(
                                      0.0,
                                      travel,
                                    ),
                          onHorizontalDragEnd: travel == 0 ? null : _fling,
                          child: ListView.builder(
                            controller: widget.jumps.scroll,
                            padding: EdgeInsets.zero,
                            itemExtent: row,
                            itemCount: doc.rows.length,
                            itemBuilder: (context, index) {
                              final line = doc.rows[index].line;
                              return GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                // The row that says where a cut file stops is this app's
                                // sentence about the file rather than anything the file
                                // has, so there is nothing in it to take.
                                onLongPress:
                                    line.kind == DiffLineKind.capped ||
                                        line.kind == DiffLineKind.fold
                                    ? null
                                    : () => widget.onPick(index),
                                child: rowAt(index),
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
                            rowAt: rowAt,
                          ),
                        ),
                        DiffReturn(jumps: widget.jumps, lineAt: _lineAt),
                      ],
                    ),
                  ),
                  if (mapped)
                    DiffMap(
                      streaks: _streaks,
                      rows: doc.rows.length,
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
}

class _Cell {
  const _Cell(this.text, this.runs, this.spans);

  /// A tab opened out to the next eight-column stop. The face draws a tab as one advance
  /// and the pane was measuring it as eight, so a file indented with tabs came out both
  /// mismeasured and flattened. Eight is git's own stop and the one the width arithmetic
  /// already assumed.
  factory _Cell.open(
    String text,
    List<IntralineSpan> runs,
    List<SyntaxSpan>? spans,
  ) {
    spans = spans == null ? null : _cut(spans, text.length);
    if (!text.contains('\t')) return _Cell(text, runs, spans);
    final at = List<int>.filled(text.length + 1, 0);
    final open = StringBuffer();
    var column = 0;
    for (var i = 0; i < text.length; i++) {
      at[i] = column;
      if (text.codeUnitAt(i) == 0x09) {
        final stop = _tabStop - column % _tabStop;
        open.write(' ' * stop);
        column += stop;
      } else {
        open.writeCharCode(text.codeUnitAt(i));
        column++;
      }
    }
    at[text.length] = column;
    final opened = open.toString();
    var from = 0;
    return _Cell(
      opened,
      [for (final run in runs) (start: at[run.start], end: at[run.end])],
      spans == null
          ? null
          : [
              for (final span in spans)
                (
                  text: opened.substring(
                    at[from],
                    at[from += span.text.length],
                  ),
                  token: span.token,
                ),
            ],
    );
  }

  final String text;
  final List<IntralineSpan> runs;
  final List<SyntaxSpan>? spans;

  static List<SyntaxSpan> _cut(List<SyntaxSpan> spans, int length) {
    final cut = <SyntaxSpan>[];
    var at = 0;
    for (final span in spans) {
      if (at >= length) break;
      final end = math.min(at + span.text.length, length);
      cut.add((text: span.text.substring(0, end - at), token: span.token));
      at = end;
    }
    return cut;
  }
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

class _Picked extends StatelessWidget {
  const _Picked({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: child),
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
}

class _FoldLine extends StatelessWidget {
  const _FoldLine({
    required this.fold,
    required this.cell,
    required this.lead,
    required this.onTap,
    required this.shift,
    required this.travel,
    this.language,
  });

  final FoldRow fold;
  final _Cell cell;
  final double lead;
  final VoidCallback onTap;
  final SyntaxLanguage? language;

  final ValueListenable<double> shift;
  final double travel;

  @override
  Widget build(BuildContext context) {
    final muted = context.tokens.noteBody.copyWith(
      color: context.tokens.textMuted,
    );
    final head = fold.head;
    final lines = fold.count == 1 ? 'line' : 'lines';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        color: context.tokens.surfacePrimary,
        padding: const EdgeInsets.only(
          top: _DiffBody._linePadding,
          bottom: _DiffBody._linePadding,
          right: Spacing.panelPadding,
        ),
        child: Row(
          children: [
            SizedBox(
              width: lead,
              child: head == null
                  ? null
                  : Padding(
                      padding: const EdgeInsets.only(right: Spacing.md),
                      child: FittedBox(
                        alignment: Alignment.centerRight,
                        fit: BoxFit.scaleDown,
                        child: Text('⋯ ${fold.count}', style: muted),
                      ),
                    ),
            ),
            Expanded(
              child: head == null
                  ? Text(
                      '⋯ ${fold.count} unchanged $lines',
                      style: muted,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                    )
                  : ClipRect(
                      child: ValueListenableBuilder<double>(
                        valueListenable: shift,
                        builder: (context, at, painted) => Transform.translate(
                          offset: Offset(-math.min(at, travel), 0),
                          child: painted,
                        ),
                        child: OverflowBox(
                          alignment: Alignment.centerLeft,
                          maxWidth: double.infinity,
                          child: Text.rich(
                            _codeSpan(
                              context,
                              cell,
                              language,
                              DiffLineKind.context,
                            ),
                            style: context.tokens.noteBody.copyWith(
                              color: context.tokens.textSecondary,
                            ),
                            maxLines: 1,
                            softWrap: false,
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiffRow extends StatelessWidget {
  const _DiffRow({
    required this.line,
    required this.cell,
    required this.gutter,
    required this.shift,
    required this.travel,
    this.language,
    this.moved = false,
    this.picked = false,
    this.single = false,
  });

  final DiffLine line;
  final _Cell cell;
  final double gutter;
  final bool single;
  final SyntaxLanguage? language;

  final bool moved;

  final ValueListenable<double> shift;

  /// How far the text can go before its longest line ends. Read here as well as in the drag
  /// so a pane that just got narrower draws clamped instead of writing to the notifier in
  /// the middle of a build.
  final double travel;

  final bool picked;

  static double lead(double gutter, double advance, {bool single = false}) =>
      (single ? gutter + Spacing.md * 2 : gutter * 2 + Spacing.md * 3) +
      Borders.hairline +
      advance +
      Spacing.sm;

  @override
  Widget build(BuildContext context) {
    var (marker, text, mark, ground) = switch (line.kind) {
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
      DiffLineKind.meta || DiffLineKind.fold => (
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
    if (moved) {
      text = context.tokens.textSecondary;
      mark = context.tokens.textDisabled;
      ground = null;
    }
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
                // Laid out once at its full width and painted once into its own
                // layer: a drag moves the layer, it does not paint the line again.
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  maxWidth: double.infinity,
                  child: RepaintBoundary(
                    child: Padding(
                      padding: const EdgeInsets.only(
                        right: Spacing.panelPadding,
                      ),
                      child: Text.rich(
                        _codeSpan(context, cell, language, line.kind),
                        style: context.tokens.noteBody.copyWith(color: text),
                        maxLines: 1,
                        softWrap: false,
                      ),
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
    return _Picked(child: row);
  }
}

InlineSpan _codeSpan(
  BuildContext context,
  _Cell cell,
  SyntaxLanguage? language,
  DiffLineKind kind,
) {
  final text = cell.text;
  final words =
      kind == DiffLineKind.hunk ||
      kind == DiffLineKind.meta ||
      kind == DiffLineKind.capped;
  final spans = words
      ? [(text: text, token: SyntaxToken.plain)]
      : cell.spans ??
            (language == null
                ? [(text: text, token: SyntaxToken.plain)]
                : highlight(text, language));
  final ground = switch (kind) {
    DiffLineKind.added => context.tokens.diffAddedRun,
    DiffLineKind.removed => context.tokens.diffRemovedRun,
    _ => null,
  };
  final runs = ground == null ? const <IntralineSpan>[] : cell.runs;
  final children = <TextSpan>[];
  var at = 0;
  var next = 0;
  void piece(int from, int to, TextStyle? style) {
    while (from < to) {
      while (next < runs.length && runs[next].end <= from) {
        next++;
      }
      final lit = next < runs.length && runs[next].start <= from;
      final end = lit
          ? math.min(to, runs[next].end)
          : next < runs.length
          ? math.min(to, runs[next].start)
          : to;
      children.add(
        TextSpan(
          text: text.substring(from, end),
          style: lit
              ? (style ?? const TextStyle()).copyWith(backgroundColor: ground)
              : style,
        ),
      );
      from = end;
    }
  }

  for (final span in spans) {
    final end = math.min(at + span.text.length, text.length);
    piece(at, end, syntaxStyle(context, span.token));
    at = end;
  }
  if (at < text.length) piece(at, text.length, null);
  return TextSpan(children: children);
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
