import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/hosts/host_providers.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/path_repository.dart';
import 'package:upgrade/data/repositories/settings_repository.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/field_panel.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/components/section.dart';
import 'package:upgrade/design/components/status_tag.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/layout.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/features/home/compose_sheet.dart';
import 'package:upgrade/features/shell/sheets/shell_sheet.dart';
import 'package:upgrade/platform/shell/remote_shell.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/platform/workspace/workspace_commands.dart';
import 'package:upgrade/platform/workspace/workspace_model.dart';

import 'package:upgrade/features/code/change_tree.dart';
import 'package:upgrade/features/code/diff_jump.dart';
import 'package:upgrade/features/code/diff_key.dart';
import 'package:upgrade/features/code/diff_lists.dart';
import 'package:upgrade/features/code/diff_map.dart';
import 'package:upgrade/features/code/diff_outline.dart';
import 'package:upgrade/features/code/diff_pane.dart';
import 'package:upgrade/features/code/diff_patch.dart';
import 'package:upgrade/features/code/diff_peek.dart';
import 'package:upgrade/features/code/diff_read.dart';
import 'package:upgrade/features/code/diff_session.dart';
import 'package:upgrade/features/code/structural.dart';
import 'package:upgrade/features/code/syntax.dart';
import 'package:upgrade/features/code/workspace_controller.dart';

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
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      builder: (context) => Scaffold(
        key: const ValueKey('diff-page'),
        backgroundColor: context.tokens.backgroundPrimary,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.screenEdge,
              Spacing.md,
              Spacing.screenEdge,
              Spacing.md,
            ),
            child: builder(context),
          ),
        ),
      ),
    ),
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

class _DiffSheetState extends ConsumerState<DiffSheet>
    with WidgetsBindingObserver {
  late final WorkspaceController _controller;
  late final bool _owned;
  late final DiffSession _session;
  SettingsRepository? _settings;

  Set<int> _opened = {};

  bool? _split;
  bool _wrap = false;
  bool _outlineAll = false;
  bool _tree = true;
  final Set<String> _closed = {};

  String? _query;
  int _hit = 0;
  final TextEditingController _search = TextEditingController();
  final TextEditingController _subject = TextEditingController();
  final TextEditingController _body = TextEditingController();

  DiffDoc? _doc;
  Object? _docKey;

  /// Every row is one line tall and every line is the same height, so a hunk is at a known
  /// offset and jumping to it is arithmetic rather than a search.
  final ScrollController _hunkScroll = ScrollController();

  late final DiffJumps _jumps = DiffJumps(_hunkScroll);

  bool _changesOpen = false;

  bool _keptBeside = false;

  bool get _beside =>
      MediaQuery.sizeOf(context).width - Spacing.screenEdge * 2 >=
      Layout.columnMax;

  bool get _changesShown => _changesOpen && (_beside || !_keptBeside);
  bool _historyOpen = false;

  bool _autoPicked = false;

  bool _fileAuto = false;

  List<Commit>? _fileLog;
  bool _logOpen = false;

  String? _shownPath;

  String? _wantPath;

  String? _treePath;

  int _hunk = -1;

  DiffLine? _held;

  List<DiffLine>? _plainFrom;
  List<DiffLine>? _plain;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    _settings = ref.read(settingsRepositoryProvider);
    _session = DiffSession(_controller, settings: _settings)
      ..addListener(_onSession);
    unawaited(_loadSettings());
    if (_owned) {
      _controller.connect();
      _session.start();
    } else {
      _session.start(file: widget.file);
      if (widget.file != null) _shownPath = widget.file!.path;
    }
  }

  Future<void> _loadSettings() async {
    final settings = _settings;
    if (settings == null) return;
    final tree = await settings.text(
      SettingsRepository.diffTree,
      orElse: 'tree',
    );
    final wrap = await settings.text(
      SettingsRepository.diffWrap,
      orElse: 'off',
    );
    if (!mounted) return;
    setState(() {
      _tree = tree != 'flat';
      _wrap = wrap == 'on';
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session
      ..removeListener(_onSession)
      ..dispose();
    _jumps.dispose();
    _hunkScroll.dispose();
    _search.dispose();
    _subject.dispose();
    _body.dispose();
    // Only the connection this screen dialled is this screen's to drop.
    if (_owned) _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _session.source == null) {
      unawaited(_session.refresh());
    }
  }

  void _onSession() {
    if (!mounted) return;
    final path = _session.file?.path;
    setState(() {
      if (path != _shownPath) {
        _shownPath = path;
        _forgetFile();
      }
    });
    _autoPick();
  }

  void _forgetFile() {
    _held = null;
    _opened = {};
    _fileLog = null;
    _logOpen = false;
    _hit = 0;
    _hunk = -1;
    if (_hunkScroll.hasClients) _hunkScroll.jumpTo(0);
    _jumps.forget();
  }

  void _autoPick() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final files = _session.files;
      if (!mounted) return;
      final want = _wantPath;
      if (want != null && files != null) {
        _wantPath = null;
        final there = files.where((file) => file.path == want);
        if (there.isNotEmpty) {
          _autoPicked = true;
          _pick(there.first);
          return;
        }
      }
      if (_autoPicked) return;
      if (_session.file != null) {
        _autoPicked = true;
        if (_beside) setState(() => _changesOpen = _keptBeside = true);
        return;
      }
      if (files == null || files.isEmpty) return;
      _autoPicked = true;
      final first = _order(files).where((file) => !file.path.endsWith('/'));
      if (first.isNotEmpty && (files.length == 1 || _beside)) {
        _pick(first.first, auto: true);
        if (_beside) setState(() => _changesOpen = _keptBeside = true);
      } else if (!_historyOpen) {
        setState(() {
          _changesOpen = true;
          _keptBeside = false;
        });
      }
    });
  }

  List<WorkspaceFile> _order(List<WorkspaceFile> files) =>
      _tree ? treeOrder(files) : files;

  void _pick(WorkspaceFile file, {bool auto = false}) {
    setState(() {
      _fileAuto = auto;
      _changesOpen = _beside && _changesOpen;
      _keptBeside = _changesOpen;
      _historyOpen = false;
      _shownPath = file.path;
      _forgetFile();
    });
    _session.pick(file);
  }

  Future<void> _select(Commit? commit) async {
    if (commit?.sha == _session.source?.sha) {
      _wantPath = null;
      setState(() {
        _historyOpen = false;
        _changesOpen = true;
        _keptBeside = false;
      });
      return;
    }
    if (_session.source == null) _treePath = _session.file?.path;
    if (commit == null) _wantPath ??= _treePath;
    setState(() {
      _autoPicked = false;
      if (_historyOpen) {
        _historyOpen = false;
        _changesOpen = true;
        _keptBeside = false;
      }
    });
    await _session.select(commit);
  }

  WorkspaceFile? _neighbour(int step) {
    final files = _session.files;
    final file = _session.file;
    if (files == null || file == null) return null;
    final order = _order(files);
    final at = order.indexWhere((row) => row.path == file.path);
    final next = at + step;
    if (at < 0 || next < 0 || next >= order.length) return null;
    return order[next];
  }

  void _close() {
    _session.close();
    setState(() {
      _held = null;
      _changesOpen = true;
      _keptBeside = false;
      _historyOpen = false;
    });
  }

  VoidCallback? get _backStep {
    final file = _session.file;
    if (_held != null) return () => setState(() => _held = null);
    if (_query != null) return _openSearch;
    if (_logOpen) return () => setState(() => _logOpen = false);
    if (_historyOpen) {
      return () => setState(() {
        _historyOpen = false;
        if (file == null) _changesOpen = true;
      });
    }
    if (file == null || _beside) return null;
    if (_changesShown) return () => setState(() => _changesOpen = false);
    return _fileAuto ? null : _close;
  }

  void _unfold({required bool changes}) {
    setState(() {
      if (changes) {
        _changesOpen = !_changesShown;
        _historyOpen = false;
      } else {
        _historyOpen = !_historyOpen;
        _changesOpen = false;
      }
      _keptBeside = false;
    });
  }

  void _fold(int key) {
    setState(() => _opened = {..._opened, key});
  }

  void _setTree(bool tree) {
    setState(() => _tree = tree);
    unawaited(
      _settings?.setText(SettingsRepository.diffTree, tree ? 'tree' : 'flat'),
    );
  }

  void _setWrap(bool wrap) {
    setState(() {
      _wrap = wrap;
      _held = null;
    });
    unawaited(
      _settings?.setText(SettingsRepository.diffWrap, wrap ? 'on' : 'off'),
    );
  }

  void _toggleViewed(WorkspaceFile file) {
    final value = !_session.viewed(file);
    _session.markViewed(file, value);
    if (!value || _session.file?.path != file.path) return;
    final files = _session.files;
    if (files == null) return;
    final order = _order(files);
    final at = order.indexWhere((row) => row.path == file.path);
    for (var i = 1; i < order.length; i++) {
      final next = order[(at + i) % order.length];
      if (!_session.viewed(next)) {
        _pick(next);
        return;
      }
    }
  }

  int? _heldAt(List<SplitRow> rows) {
    final held = _held;
    if (held == null) return null;
    bool same(ShownRow? side) {
      final line = side?.whole.line;
      return line != null &&
          line.kind == held.kind &&
          line.text == held.text &&
          line.oldLine == held.oldLine &&
          line.newLine == held.newLine;
    }

    final at = rows.indexWhere(
      (row) => same(row.across) || same(row.left) || same(row.right),
    );
    return at < 0 ? null : at;
  }

  DiffLine _rowLine(SplitRow row) =>
      (row.across ?? row.right ?? row.left)!.whole.line;

  @override
  Widget build(BuildContext context) {
    final list = _changesShown
        ? _changes()
        : _historyOpen
        ? _history()
        : null;
    final file = _session.file;
    return PopScope(
      canPop: _backStep == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _backStep?.call();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _headline(),
          if (list != null || file != null) ...[
            const SizedBox(height: Spacing.panelGap),
            Expanded(child: _panes(list)),
          ],
        ],
      ),
    );
  }

  Widget _headline() {
    final source = _session.source;
    final status = _controller.overview?.status;
    final files = _session.files;
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
            [
              status?.branch ?? 'detached',
              if (status != null && status.ahead > 0) '↑${status.ahead}',
              if (status != null && status.behind > 0) '↓${status.behind}',
            ].join(' '),
            if (status != null && !status.clean)
              '${status.changes.length} changed',
          ].join('  ·  ');
    final worktrees = _controller.overview?.worktrees.length ?? 0;
    final staged = files?.any((file) => file.hasStaged) ?? false;
    final said = _session.file == null ? _session.said : null;
    return Panel(
      leading: Semantics(
        button: true,
        label: 'BACK',
        child: GestureDetector(
          key: const ValueKey('diff-back'),
          behavior: HitTestBehavior.opaque,
          onTap: () => (_backStep ?? Navigator.of(context).pop)(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
            child: UpgradeIcon(
              UpgradeIcons.back,
              size: IconSizes.sm,
              color: context.tokens.textSecondary,
            ),
          ),
        ),
      ),
      title:
          '${_controller.label.toUpperCase()} / '
          '${source == null ? 'WORKING TREE' : source.short}',
      literalTitle: source != null,
      affordance: loading || files == null
          ? null
          : DiffStat(added: added, removed: removed, files: files.length),
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
          if (said != null)
            Text(
              said,
              style: context.tokens.rowSubtitle.copyWith(
                color: context.tokens.warning,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          const SizedBox(height: Spacing.md),
          Wrap(
            children: [
              DiffKey(
                key: const ValueKey('diff-changes'),
                says: 'CHANGES',
                icon: UpgradeIcons.diff,
                label: 'CHANGES',
                count: _countWord(files?.length, _session.filesFailed),
                on: _changesShown,
                onTap: () => _unfold(changes: true),
              ),
              DiffKey(
                key: const ValueKey('diff-commits'),
                says: 'COMMITS',
                icon: UpgradeIcons.log,
                label: 'COMMITS',
                count: _countWord(
                  _session.commits?.length,
                  _controller.phase == WorkspacePhase.failed,
                ),
                on: _historyOpen,
                onTap: () => _unfold(changes: false),
              ),
              if (worktrees > 1)
                DiffKey(
                  key: const ValueKey('diff-worktrees'),
                  says: 'WORKTREE',
                  icon: UpgradeIcons.branch,
                  label: 'WORKTREE',
                  count: '$worktrees',
                  onTap: _swapWorktree,
                ),
              if (source == null && !loading && status != null) ...[
                DiffKey(
                  key: const ValueKey('diff-commit'),
                  says: 'COMMIT',
                  icon: UpgradeIcons.submit,
                  label: 'COMMIT',
                  onTap: staged && !_session.writing ? _commit : null,
                ),
                DiffKey(
                  key: const ValueKey('diff-push'),
                  says: 'PUSH',
                  icon: UpgradeIcons.arrowUp,
                  label: 'PUSH',
                  count: status.ahead > 0 ? '${status.ahead}' : null,
                  onTap:
                      status.upstream != null &&
                          status.ahead > 0 &&
                          !_session.writing
                      ? _push
                      : null,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _commit() async {
    final staged = [
      for (final file in _session.files ?? const <WorkspaceFile>[])
        if (file.hasStaged) file,
    ];
    final letters = StatusLetters.width(context);
    final go = await showPanelSheet<bool>(
      context,
      title: 'COMMIT',
      builder: (sheet) => PanelSheetBody(
        title: 'COMMIT',
        affordance: PanelAffordance('${staged.length}', showIcon: false),
        children: [
          ListRowGroup(
            children: [
              for (final file in staged)
                ListRow(
                  title: file.path,
                  literalTitle: true,
                  leading: StatusLetters.of(file),
                  leadingWidth: letters,
                ),
            ],
          ),
          const SheetRule(),
          FieldPanel(
            label: 'SUBJECT',
            controller: _subject,
            hint: 'what this commit does',
            autofocus: true,
          ),
          const SizedBox(height: Spacing.md),
          FieldPanel(
            label: 'BODY',
            controller: _body,
            hint: 'why, when the subject is not enough',
            maxLines: 4,
            textInputAction: TextInputAction.newline,
          ),
          const SizedBox(height: Spacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              ActionBlock(
                label: 'COMMIT',
                filled: true,
                tone: context.tokens.accent,
                onTap: () {
                  if (_subject.text.trim().isEmpty) return;
                  Navigator.pop(sheet, true);
                },
              ),
            ],
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final failed = await _session.commit(
      _subject.text.trim(),
      _body.text.trim(),
    );
    if (failed == null) {
      _subject.clear();
      _body.clear();
    }
    if (mounted) setState(() {});
  }

  Future<void> _push() async {
    await _session.push();
    if (mounted) setState(() {});
  }

  Future<void> _stage(WorkspaceFile file) async {
    await (file.hasUnstaged
        ? _session.stage([file])
        : _session.unstage([file]));
    if (mounted) setState(() {});
  }

  Future<void> _swapWorktree() async {
    final overview = _controller.overview;
    if (overview == null) return;
    final worktrees = overview.worktrees;
    final chosen = await showPanelSheet<String>(
      context,
      title: 'WORKTREES',
      builder: (context) => PanelSheetBody(
        title: 'WORKTREES',
        affordance: PanelAffordance('${worktrees.length}', showIcon: false),
        children: [
          ListRowGroup(
            children: [
              for (final worktree in worktrees)
                ListRow(
                  title: worktree.label,
                  subtitle: worktree.branch ?? 'detached',
                  value: worktree.directory == _controller.directory
                      ? 'ON SCREEN'
                      : null,
                  valueColor: context.tokens.accent,
                  onTap: worktree.directory == _controller.directory
                      ? null
                      : () => Navigator.of(context).pop(worktree.directory),
                ),
            ],
          ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    _session.close();
    setState(() => _autoPicked = false);
    await _controller.openWorktree(chosen);
  }

  Widget _panes(Widget? list) {
    final file = _session.file;
    if (file == null) return list!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final wide = _beside;
        if (!wide && list != null) return list;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wide && list != null) ...[
              SizedBox(
                width: (width * _listShare).clamp(_listLeast, _listMost),
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

  static const _listShare = 0.34;
  static const _listLeast = 300.0;
  static const _listMost = 440.0;

  String _countWord(int? count, bool failed) {
    if (count != null) return '$count';
    return failed ? 'FAILED' : 'LOADING';
  }

  Widget _changes() {
    final files = _session.files;
    final working = _session.source == null;
    return Panel(
      bodyPadding: EdgeInsets.zero,
      bodyFlexible: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.panelPadding,
              Spacing.panelPadding,
              Spacing.panelPadding,
              0,
            ),
            child: _listTools(files, working: working),
          ),
          Flexible(child: _changeList(files, working: working)),
        ],
      ),
    );
  }

  Widget _listTools(List<WorkspaceFile>? files, {required bool working}) {
    final against = _session.against;
    final total = files?.length ?? 0;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (working)
          for (final (value, word) in const [
            (DiffAgainst.head, 'ALL'),
            (DiffAgainst.staged, 'STAGED'),
            (DiffAgainst.unstaged, 'UNSTAGED'),
          ])
            DiffKey(
              key: ValueKey('diff-against-${value.name}'),
              says: word,
              label: word,
              on: against == value,
              onTap: () => _session.readAgainst(value),
            ),
        DiffKey(
          key: const ValueKey('diff-tree'),
          says: 'TREE',
          icon: UpgradeIcons.files,
          on: _tree,
          onTap: () => _setTree(!_tree),
        ),
        if (working && total > 0)
          Semantics(
            label: '${_session.viewedCount} / $total VIEWED',
            excludeSemantics: true,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: Spacing.sm),
                UpgradeIcon(
                  UpgradeIcons.viewed,
                  size: IconSizes.sm,
                  color: context.tokens.textMuted,
                ),
                const SizedBox(width: Spacing.sm),
                Text(
                  '${_session.viewedCount} / $total',
                  style: context.tokens.panelHeader.copyWith(
                    color: context.tokens.textMuted,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _changeList(List<WorkspaceFile>? files, {required bool working}) {
    if (files == null || files.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(Spacing.panelPadding),
        child: EmptyState(switch ((files, _session.filesFailed)) {
          (null, false) => 'loading…',
          (null, true) => _controller.reason ?? 'could not read it',
          _ => 'nothing changed',
        }),
      );
    }
    final slivers = changeListSlivers(
      context,
      ChangeRowsData(
        files: files,
        tree: _tree,
        closed: _closed,
        picked: _session.file?.path,
        outlineOf: _session.outline,
        viewed: _session.viewed,
        working: working,
      ),
      onPick: _pick,
      onToggleViewed: _toggleViewed,
      onStage: working ? _stage : null,
      onFoldDir: (dir) => setState(() {
        if (!_closed.remove(dir.path)) _closed.add(dir.path);
      }),
      peekable: (file, row) => Peekable(
        title: file.path,
        onStart: () => _session.peek(file),
        onOpen: () => _pick(file),
        preview: (context) => ListenableBuilder(
          listenable: _session,
          builder: (context, _) => _PeekDiff(session: _session, file: file),
        ),
        child: row,
      ),
    );
    return CustomScrollView(
      shrinkWrap: true,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.symmetric(
            vertical: Spacing.sm,
            horizontal: Spacing.panelPadding,
          ),
          sliver: SliverMainAxisGroup(slivers: slivers),
        ),
      ],
    );
  }

  Widget _history() {
    final commits = _session.commits;
    final source = _session.source;
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
                titleColor: source == null ? context.tokens.accent : null,
                value: _dirtyWord(),
                onTap: () => _select(null),
              ),
              if (commits == null)
                const ListRow(title: 'loading…', value: '')
              else
                for (final commit in commits)
                  Peekable(
                    title: '${commit.short}  ${commit.subject}',
                    onStart: () => unawaited(_session.commitFiles(commit)),
                    onOpen: () => _select(commit),
                    preview: (context) => ListenableBuilder(
                      listenable: _session,
                      builder: (context, _) => _PeekCommit(
                        commit: commit,
                        files: _session.knownCommitFiles(commit),
                      ),
                    ),
                    child: ListRow(
                      key: ValueKey('diff-commit-${commit.sha}'),
                      kicker: commit.short,
                      title: commit.subject,
                      subtitle: '${commit.author} · ${commit.age}',
                      titleColor: commit.sha == source?.sha
                          ? context.tokens.accent
                          : null,
                      onTap: () => _select(commit),
                    ),
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

  List<DiffLine>? _plainOf(WorkspaceFile file, List<DiffLine> lines) {
    if (identical(lines, _plainFrom)) return _plain;
    _plainFrom = lines;
    return _plain = plainFile(file, lines);
  }

  Map<String, List<DiffLine>> _othersOf(WorkspaceFile file) => {
    for (final MapEntry(:key, :value)
        in (_session.bundle ?? const <String, List<DiffLine>>{}).entries)
      if (key != file.path) key: value,
  };

  bool Function(String text)? get _find {
    final query = _query?.toLowerCase();
    if (query == null || query.isEmpty) return null;
    return (text) => text.toLowerCase().contains(query);
  }

  DiffDoc? _document(
    WorkspaceFile file, {
    required bool split,
    required int? columns,
  }) {
    final read = _session.reads[file.path];
    final lines = _session.lines;
    final key = (
      read ?? lines,
      _opened,
      split,
      columns,
      _session.bundle,
      _query,
    );
    final known = _doc;
    if (known != null && _docKey == key) return known;
    final shape = DiffShape(
      columns: columns,
      others: _othersOf(file),
      find: _find,
    );
    final doc = diffDocOf(
      read,
      lines,
      lines == null ? null : _plainOf(file, lines),
      opened: _opened,
      split: split,
      shape: shape,
    );
    _doc = doc;
    _docKey = key;
    return doc;
  }

  int _highestOf(DiffRead? read, List<DiffLine>? lines) {
    final structural = read?.structural;
    if (structural != null) {
      return structural.oldLines.length > structural.newLines.length
          ? structural.oldLines.length
          : structural.newLines.length;
    }
    final plain = read?.plain;
    if (plain != null) return plain.length;
    var highest = 0;
    for (final line in lines ?? const <DiffLine>[]) {
      final number = (line.newLine ?? 0) > (line.oldLine ?? 0)
          ? line.newLine!
          : line.oldLine ?? 0;
      if (number > highest) highest = number;
    }
    return highest;
  }

  Widget _pane(WorkspaceFile file, {required bool wide}) {
    final read = _session.reads[file.path];
    final lines = _session.lines;
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
        final wrap = _wrap && !split;
        final columns = wrap
            ? _columns(context, constraints.maxWidth, read, lines, single)
            : null;
        final doc = _document(file, split: split, columns: columns);
        return Panel(
          // The path and not its last segment: two files of the same name in two directories are
          // the ordinary case in a repository.
          title: file.origin == null
              ? file.path
              : '${file.origin} → ${file.path}',
          literalTitle: true,
          leading: tag,
          affordance: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (doc != null && !single)
                GestureDetector(
                  onTap: _legend,
                  child: Text(
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
                ),
              const SizedBox(width: Spacing.lg),
              if (wide)
                if (!file.binary)
                  DiffStat(added: file.added!, removed: file.removed!)
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
              _tools(file, doc, fits: fits, split: split, single: single),
              if (_query != null) _searchBar(doc),
              _outlineStrip(file, doc),
              Expanded(child: _paneBody(file, doc, read, wrap: wrap)),
              Container(
                height: Borders.hairline,
                color: context.tokens.borderNormal,
              ),
              Padding(
                padding: const EdgeInsets.all(Spacing.sm),
                child: _bottomBar(file, doc),
              ),
            ],
          ),
        );
      },
    );
  }

  int _columns(
    BuildContext context,
    double width,
    DiffRead? read,
    List<DiffLine>? lines,
    bool single,
  ) {
    final advance = diffCharAdvance(context);
    final gutter = diffGutterWidth(_highestOf(read, lines), advance);
    final lead = DiffRow.lead(gutter, advance, single: single);
    final room = width - DiffMap.width - lead - Spacing.panelPadding;
    return room <= advance ? 1 : (room / advance).floor();
  }

  Widget _paneBody(
    WorkspaceFile file,
    DiffDoc? doc,
    DiffRead? read, {
    required bool wrap,
  }) {
    if (_logOpen) return _fileHistory(file);
    final images = read?.images;
    if (images != null) return DiffImages(images: images);
    String? empty;
    if (file.path.endsWith('/')) {
      empty = 'nested repository';
    } else if (doc == null) {
      empty = _session.diffFailed ? 'could not read it' : 'loading…';
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
    return DiffBody(
      path: file.path,
      doc: doc!,
      language: languageOf(file.path),
      jumps: _jumps,
      picked: _heldAt(doc.rows),
      query: _query,
      wrap: wrap,
      onPick: (row, {required old}) {
        final at = doc.rows[row];
        final side =
            at.across ?? (old ? at.left ?? at.right : at.right ?? at.left);
        setState(() => _held = side!.whole.line);
      },
      onFold: _fold,
      onGoto: _goto,
      onEdge: (step) {
        final next = _neighbour(step);
        if (next != null) _pick(next);
      },
    );
  }

  void _goto(DiffGoto goto) {
    final path = goto.path;
    if (path != null && path != _session.file?.path) {
      final files = _session.files ?? const <WorkspaceFile>[];
      final there = files.where((file) => file.path == path);
      if (there.isEmpty) return;
      _pick(there.first);
      return;
    }
    final row = _doc?.rowOf(goto.line, old: goto.old);
    if (row != null) _jumpRow(row);
  }

  void _jumpRow(int row) {
    final above = row - _jumpAbove < 0 ? 0 : row - _jumpAbove;
    _jumps.to(above * DiffBody.rowHeight(context));
  }

  static const _jumpAbove = 2;

  bool _splitFits(BuildContext context, double width) {
    final advance = diffCharAdvance(context);
    final lead = DiffRow.lead(
      diffGutterWidth(9999, advance),
      advance,
      single: true,
    );
    return width - DiffMap.width >= 2 * (lead + _splitColumns * advance);
  }

  static const _splitColumns = 80;

  Widget _tool(_Tool tool) => DiffKey(
    key: ValueKey('diff-${tool.key}'),
    says: tool.says,
    icon: tool.icon,
    label: tool.says,
    on: tool.on,
    onTap: tool.onTap,
  );

  Widget _tools(
    WorkspaceFile file,
    DiffDoc? doc, {
    required bool fits,
    required bool split,
    required bool single,
  }) {
    final working = _session.source == null;
    final folds = _foldKeys(doc);
    final viewed = _session.viewed(file);
    final tools = <_Tool>[
      (
        key: 'search',
        says: 'SEARCH',
        icon: UpgradeIcons.search,
        onTap: _openSearch,
        on: _query != null,
        spare: false,
      ),
      if (!split)
        (
          key: 'wrap',
          says: 'WRAP',
          icon: UpgradeIcons.wrap,
          onTap: () => _setWrap(!_wrap),
          on: _wrap,
          spare: false,
        ),
      if (working)
        (
          key: 'viewed',
          says: 'VIEWED',
          icon: UpgradeIcons.viewed,
          onTap: () => _toggleViewed(file),
          on: viewed,
          spare: false,
        ),
      if (fits)
        (
          key: 'split',
          says: 'SPLIT',
          icon: UpgradeIcons.split,
          onTap: () => setState(() {
            _split = !split;
            _held = null;
          }),
          on: split,
          spare: true,
        ),
      if (folds.isNotEmpty)
        (
          key: 'open-all',
          says: 'OPEN ALL',
          icon: UpgradeIcons.expand,
          onTap: () => setState(() => _opened = {..._opened, ...folds}),
          on: false,
          spare: true,
        )
      else if (_opened.isNotEmpty)
        (
          key: 'fold-all',
          says: 'FOLD ALL',
          icon: UpgradeIcons.collapse,
          onTap: () => setState(() => _opened = {}),
          on: false,
          spare: true,
        ),
      (
        key: 'history',
        says: 'LOG',
        icon: UpgradeIcons.log,
        onTap: () => _toggleLog(file),
        on: _logOpen,
        spare: true,
      ),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
      child: LayoutBuilder(
        builder: (context, box) {
          final spares = [
            for (final tool in tools)
              if (tool.spare) tool,
          ];
          final folded = spares.length > 1 && _toolsWidth(tools) > box.maxWidth;
          final _Tool more = (
            key: 'more',
            says: 'MORE',
            icon: UpgradeIcons.more,
            onTap: () => _moreTools(spares),
            on: spares.any((tool) => tool.on),
            spare: false,
          );
          final row = [
            for (final tool in tools)
              if (!folded || !tool.spare) tool,
            if (folded) more,
          ];
          return Wrap(children: [for (final tool in row) _tool(tool)]);
        },
      ),
    );
  }

  double _toolsWidth(List<_Tool> tools) => tools.fold(
    0,
    (width, tool) =>
        width + DiffKey.widthOf(context, icon: tool.icon, label: tool.says),
  );

  Future<void> _moreTools(List<_Tool> spares) {
    return showPanelSheet<void>(
      context,
      title: 'MORE',
      builder: (sheet) => PanelSheetBody(
        title: 'MORE',
        children: [
          ListRowGroup(
            children: [
              for (final tool in spares)
                ListRow(
                  key: ValueKey('diff-${tool.key}'),
                  title: tool.says,
                  titleColor: tool.onTap == null
                      ? context.tokens.textDisabled
                      : tool.on
                      ? context.tokens.accent
                      : null,
                  onTap: tool.onTap == null
                      ? null
                      : () {
                          Navigator.of(sheet).pop();
                          tool.onTap!();
                        },
                ),
            ],
          ),
        ],
      ),
    );
  }

  Set<int> _foldKeys(DiffDoc? doc) => {
    for (final row in doc?.rows ?? const <SplitRow>[])
      for (final side in [row.across, row.left, row.right])
        if (side?.fold case final fold?) fold.key,
  };

  void _openSearch() {
    setState(() {
      if (_query == null) {
        _query = '';
      } else {
        _query = null;
        _search.clear();
      }
      _hit = 0;
    });
  }

  List<int> _hitRows(DiffDoc? doc) {
    final find = _find;
    if (doc == null || find == null) return const [];
    return [
      for (var at = 0; at < doc.rows.length; at++)
        if ([doc.rows[at].across, doc.rows[at].left, doc.rows[at].right].any(
          (side) => side != null && side.fold == null && find(_drawn(side)),
        ))
          at,
    ];
  }

  String _drawn(ShownRow side) => side.drawn ?? side.line.text;

  void _stepHit(List<int> hits, int step) {
    if (hits.isEmpty) return;
    final next = (math.min(_hit, hits.length - 1) + step) % hits.length;
    setState(() => _hit = next < 0 ? next + hits.length : next);
    _jumpRow(hits[_hit]);
  }

  Widget _searchBar(DiffDoc? doc) {
    final hits = _hitRows(doc);
    final hit = hits.isEmpty ? 0 : math.min(_hit, hits.length - 1);
    final shown = hits.isEmpty ? '0 / 0' : '${hit + 1} / ${hits.length}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('diff-search-field'),
              controller: _search,
              autofocus: true,
              style: context.tokens.noteBody,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'find in this file',
              ),
              onChanged: (value) => setState(() {
                _query = value;
                _hit = 0;
              }),
              onSubmitted: (_) => _stepHit(hits, 1),
            ),
          ),
          const SizedBox(width: Spacing.md),
          Text(
            shown,
            style: context.tokens.panelHeader.copyWith(
              color: context.tokens.textMuted,
            ),
          ),
          const SizedBox(width: Spacing.sm),
          DiffKey(
            key: const ValueKey('diff-search-prev'),
            says: 'PREV MATCH',
            icon: UpgradeIcons.arrowUp,
            onTap: hits.isEmpty ? null : () => _stepHit(hits, -1),
          ),
          DiffKey(
            key: const ValueKey('diff-search-next'),
            says: 'NEXT MATCH',
            icon: UpgradeIcons.arrowDown,
            onTap: hits.isEmpty ? null : () => _stepHit(hits, 1),
          ),
          DiffKey(
            key: const ValueKey('diff-search-close'),
            says: 'CLOSE SEARCH',
            icon: UpgradeIcons.close,
            onTap: _openSearch,
          ),
        ],
      ),
    );
  }

  Widget _outlineStrip(WorkspaceFile file, DiffDoc? doc) {
    final outline = _session.outline(file);
    if (outline.isEmpty || doc == null || _logOpen) {
      return const SizedBox.shrink();
    }
    return Padding(
      key: const ValueKey('diff-outline'),
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
      child: LayoutBuilder(
        builder: (context, box) {
          final fit = _outlineFit(outline, box.maxWidth);
          final shown = _outlineAll ? outline : outline.take(fit);
          final more = outline.length - shown.length;
          return Wrap(
            children: [
              for (final (at, change) in shown.indexed)
                KeyedSubtree(
                  key: ValueKey(at),
                  child: DiffKey(
                    key: ValueKey('diff-outline-${change.name}'),
                    says: '${change.mark} ${change.label}',
                    label: '${change.mark} ${change.label}',
                    onTap: () => _jumpSymbol(doc, change),
                  ),
                ),
              if (more > 0 || _outlineAll && outline.length > fit)
                DiffKey(
                  key: const ValueKey('diff-outline-more'),
                  says: more > 0 ? '$more MORE' : 'LESS',
                  label: more > 0 ? '+$more' : 'LESS',
                  onTap: () => setState(() => _outlineAll = !_outlineAll),
                ),
            ],
          );
        },
      ),
    );
  }

  int _outlineFit(List<SymbolChange> outline, double width) {
    final cell = DiffKey.widthOf(context, label: '+${outline.length}');
    var used = 0.0;
    var fit = 0;
    for (final change in outline) {
      used += DiffKey.widthOf(context, label: '${change.mark} ${change.label}');
      final rest = fit + 1 < outline.length ? cell : 0.0;
      if (used + rest > width) break;
      fit++;
    }
    return math.max(fit, 1);
  }

  void _jumpSymbol(DiffDoc doc, SymbolChange change) {
    final line = change.newLine;
    final row = line != null
        ? doc.rowOf(line, old: false)
        : change.oldLine == null
        ? null
        : doc.rowOf(change.oldLine!, old: true);
    if (row != null) _jumpRow(row);
  }

  Future<void> _toggleLog(WorkspaceFile file) async {
    if (_logOpen) {
      setState(() => _logOpen = false);
      return;
    }
    setState(() {
      _logOpen = true;
      _held = null;
    });
    final log = await _session.fileLog(file.path);
    if (!mounted || _session.file?.path != file.path) return;
    setState(() => _fileLog = log ?? const []);
  }

  Widget _fileHistory(WorkspaceFile file) {
    final log = _fileLog;
    if (log == null || log.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(Spacing.panelPadding),
        child: EmptyState(log == null ? 'loading…' : 'no commits touch it'),
      );
    }
    return ListView(
      padding: panelRowsPadding,
      children: [
        for (final commit in log)
          ListRow(
            key: ValueKey('diff-file-commit-${commit.sha}'),
            kicker: commit.short,
            title: commit.subject,
            subtitle: '${commit.author} · ${commit.age}',
            titleColor: commit.sha == _session.source?.sha
                ? context.tokens.accent
                : null,
            onTap: () {
              _wantPath = file.path;
              unawaited(_select(commit));
            },
          ),
      ],
    );
  }

  Future<void> _legend() {
    final tokens = context.tokens;
    Widget entry(String word, String says, {Color? color}) =>
        ListRow(title: word, titleColor: color, subtitle: says);
    return showPanelSheet<void>(
      context,
      title: 'HOW IT READS',
      builder: (context) => PanelSheetBody(
        title: 'HOW IT READS',
        children: [
          ListRowGroup(
            children: [
              entry(
                'SYNTAX',
                'both sides parsed; what changed is the code, so moved and reformatted lines stay quiet and the outline names the declarations it touched',
                color: tokens.accent,
              ),
              entry(
                'TOKENS',
                'no grammar for it; the changed words of a line are lit, not the whole line',
              ),
              entry(
                'LINES',
                'too large or not read yet; git\'s own hunks, line against line',
              ),
              entry(
                '+ GREEN',
                'a line only the new side has',
                color: tokens.accent,
              ),
              entry(
                '− RED',
                'a line only the old side had',
                color: tokens.danger,
              ),
              entry(
                '· KEPT',
                'no ground: the code on this line is all still there, shifted, reformatted or added to',
              ),
              entry(
                '↕ MOVED',
                'a block that went somewhere else; tap its note to go there',
              ),
              entry('⋯ FOLD', 'unchanged lines; tap to open them'),
            ],
          ),
        ],
      ),
    );
  }

  List<int> _blockStarts(DiffDoc? doc) {
    if (doc == null) return const [];
    final rows = doc.rows;
    return [
      for (var at = 0; at < rows.length; at++)
        if (rows[at].changed && (at == 0 || !rows[at - 1].changed)) at,
    ];
  }

  int _hunkAt(List<int> blocks) {
    final stepped = math.min(_hunk, blocks.length - 1);
    final position = _hunkScroll.positions.length == 1
        ? _hunkScroll.position
        : null;
    final pixels = position != null && position.hasPixels
        ? position.pixels
        : 0.0;
    final top = pixels / DiffBody.rowHeight(context) + _jumpAbove;
    final at = blocks.lastIndexWhere((row) => row <= top + 0.5);
    final end =
        position != null &&
        position.hasContentDimensions &&
        position.extentAfter < 1;
    return end ? math.max(at, stepped) : at;
  }

  void _stepHunk(List<int> blocks, int step) {
    if (blocks.isEmpty) return;
    final hunk = _hunkAt(blocks);
    final next =
        (hunk < 0 && step < 0 ? blocks.length - 1 : hunk + step) %
        blocks.length;
    setState(() => _hunk = next < 0 ? next + blocks.length : next);
    _jumpRow(blocks[_hunk]);
  }

  Widget _block(
    String key,
    String says,
    VoidCallback? onTap, {
    UpgradeIcons? icon,
    String? word,
    bool bare = false,
    bool filled = false,
    Color? tone,
  }) => DiffKey(
    key: ValueKey('diff-$key'),
    says: says,
    icon: icon,
    label: bare ? null : word ?? says,
    onTap: onTap,
    filled: filled,
    tone: tone,
  );

  Widget _bottomBar(WorkspaceFile file, DiffDoc? doc) {
    final held = _held;
    if (held != null && doc != null && !_logOpen) {
      return _holdBar(file, doc, held);
    }
    final blocks = _blockStarts(doc);
    final files = _session.files ?? const <WorkspaceFile>[];
    final at = _order(files).indexWhere((row) => row.path == file.path);
    final before = _neighbour(-1);
    final after = _neighbour(1);
    final walks = blocks.length > 1;
    final said = _session.said;
    final muted = context.tokens.panelHeader.copyWith(
      color: context.tokens.textMuted,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (said != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Spacing.sm),
            child: Text(
              said,
              style: context.tokens.rowSubtitle.copyWith(
                color: context.tokens.warning,
              ),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: Layout.columnMax),
            child: Row(
              children: [
                _block(
                  'prev-file',
                  'PREV FILE',
                  before == null ? null : () => _pick(before),
                  icon: UpgradeIcons.arrowLeft,
                  bare: true,
                ),
                Expanded(
                  child: _count(
                    at < 0 ? 'FILE' : 'FILE ${at + 1} / ${files.length}',
                    muted,
                  ),
                ),
                _block(
                  'next-file',
                  'NEXT FILE',
                  after == null ? null : () => _pick(after),
                  icon: UpgradeIcons.arrowRight,
                  bare: true,
                ),
                const SizedBox(width: Spacing.lg),
                _block(
                  'prev-hunk',
                  'HUNK UP',
                  walks ? () => _stepHunk(blocks, -1) : null,
                  icon: UpgradeIcons.arrowUp,
                  bare: true,
                ),
                Expanded(
                  child: ListenableBuilder(
                    listenable: _hunkScroll,
                    builder: (context, _) {
                      final hunk = blocks.isEmpty ? -1 : _hunkAt(blocks);
                      return _count(
                        blocks.isEmpty
                            ? 'NO HUNKS'
                            : hunk < 0
                            ? '${blocks.length} HUNKS'
                            : 'HUNK ${hunk + 1} / ${blocks.length}',
                        muted,
                      );
                    },
                  ),
                ),
                _block(
                  'next-hunk',
                  'HUNK DOWN',
                  walks ? () => _stepHunk(blocks, 1) : null,
                  icon: UpgradeIcons.arrowDown,
                  bare: true,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _count(String text, TextStyle style) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(text, style: style, maxLines: 1),
    ),
  );

  int _anchor(DiffDoc doc, DiffLine held) {
    final own = held.newLine;
    if (own != null) return own;
    final at = _heldAt(doc.rows) ?? 0;
    for (var next = at + 1; next < doc.rows.length; next++) {
      final line = _rowLine(doc.rows[next]).newLine;
      if (line != null) return line;
    }
    for (var back = at - 1; back >= 0; back--) {
      final line = _rowLine(doc.rows[back]).newLine;
      if (line != null) return line + 1;
    }
    return 1;
  }

  void _copied(String text) {
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    setState(() => _held = null);
  }

  VoidCallback? _copyPatch(WorkspaceFile file, int anchor) {
    final lines = _session.lines ?? _session.bundled(file);
    final span = lines == null ? null : hunkHolding(lines, anchor);
    if (lines == null || span == null) return null;
    return () => _copied(hunkPatch(file.path, lines, span));
  }

  void _openEditor(UserIntent intent, int line, String path) {
    final directory = _controller.directory;
    final inner = '\${EDITOR:-vi} +$line ${shellQuote(path)}; exec \$SHELL -l';
    openHostShell(
      context,
      _controller.host,
      intent: intent,
      command: '${shellCd(directory)} && exec \$SHELL -lc ${shellQuote(inner)}',
      directory: directory,
    );
  }

  Widget _holdBar(WorkspaceFile file, DiffDoc doc, DiffLine held) {
    final number = held.newLine ?? held.oldLine;
    final anchor = _anchor(doc, held);
    final ref = '${file.path}:${number ?? anchor}';
    final working = _session.source == null;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _block(
          'copy-line',
          'COPY',
          () => _copied(held.text),
          filled: true,
          tone: context.tokens.accent,
        ),
        _block('copy-ref', 'COPY REF', () => _copied(ref), word: 'REF'),
        _block('copy-patch', 'PATCH', _copyPatch(file, anchor)),
        if (working && !file.binary)
          DiffKey(
            key: const ValueKey('diff-open-editor'),
            says: 'OPEN',
            icon: UpgradeIcons.edit,
            onTap: UserIntent.onGesture(
              (intent) =>
                  _openEditor(intent, held.newLine ?? anchor, file.path),
            ),
          ),
        _block(
          'send-line',
          'SEND',
          () => unawaited(
            showCompose(context, text: '$ref\n```\n${held.text}\n```\n'),
          ),
          icon: UpgradeIcons.submit,
          bare: true,
        ),
        _block(
          'drop-line',
          'LET GO',
          () => setState(() => _held = null),
          icon: UpgradeIcons.close,
          bare: true,
        ),
        const SizedBox(width: Spacing.sm),
        Text(
          held.newLine == null && held.oldLine != null
              ? 'WAS LINE ${held.oldLine}'
              : 'LINE ${number ?? '-'}',
          style: context.tokens.panelHeader.copyWith(
            color: context.tokens.textMuted,
          ),
        ),
      ],
    );
  }
}

typedef _Tool = ({
  String key,
  String says,
  UpgradeIcons icon,
  VoidCallback? onTap,
  bool on,
  bool spare,
});

class _PeekDiff extends StatefulWidget {
  const _PeekDiff({required this.session, required this.file});

  final DiffSession session;
  final WorkspaceFile file;

  @override
  State<_PeekDiff> createState() => _PeekDiffState();
}

class _PeekDiffState extends State<_PeekDiff> {
  final ScrollController _scroll = ScrollController();
  late final DiffJumps _jumps = DiffJumps(_scroll);

  @override
  void dispose() {
    _jumps.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final file = widget.file;
    final read = widget.session.reads[file.path];
    final images = read?.images;
    if (images != null) return DiffImages(images: images);
    final lines = widget.session.bundled(file);
    final doc = diffDocOf(
      read,
      lines,
      lines == null ? null : plainFile(file, lines),
    );
    final outline = outlineLine(widget.session.outline(file));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (outline != null)
          Padding(
            padding: const EdgeInsets.all(Spacing.panelPadding),
            child: Text(
              outline,
              style: context.tokens.noteBody.copyWith(
                color: context.tokens.textMuted,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        Flexible(
          child: doc == null || doc.rows.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(Spacing.panelPadding),
                  child: EmptyState('loading…'),
                )
              : SizedBox(
                  height: doc.rows.length * DiffBody.rowHeight(context),
                  child: DiffBody(
                    path: file.path,
                    doc: doc,
                    language: languageOf(file.path),
                    jumps: _jumps,
                    picked: null,
                    onPick: (_, {required old}) {},
                    onFold: (_) {},
                  ),
                ),
        ),
      ],
    );
  }
}

class _PeekCommit extends StatelessWidget {
  const _PeekCommit({required this.commit, required this.files});

  final Commit commit;
  final List<WorkspaceFile>? files;

  @override
  Widget build(BuildContext context) {
    final files = this.files;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(Spacing.panelPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${commit.author}  ·  ${commit.age}',
            style: context.tokens.rowSubtitle,
          ),
          const SizedBox(height: Spacing.md),
          if (files == null)
            const EmptyState('loading…')
          else
            for (final file in files)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        file.path,
                        style: context.tokens.noteBody,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: Spacing.md),
                    Text.rich(
                      TextSpan(children: fileCountSpans(context, file)),
                      style: context.tokens.noteBody,
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
