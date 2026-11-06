import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:upgrade/data/repositories/settings_repository.dart';
import 'package:upgrade/platform/workspace/workspace_commands.dart';
import 'package:upgrade/platform/workspace/workspace_model.dart';

import 'package:upgrade/features/code/diff_outline.dart';
import 'package:upgrade/features/code/diff_patch.dart';
import 'package:upgrade/features/code/diff_read.dart';
import 'package:upgrade/features/code/workspace_controller.dart';

enum HunkWrite { stage, unstage, discard }

class DiffSession extends ChangeNotifier {
  DiffSession(this.controller, {this.settings}) {
    controller.addListener(_onWorkspace);
    unawaited(_loadViewed());
  }

  final WorkspaceController controller;
  final SettingsRepository? settings;

  List<Commit>? commits;

  Commit? source;

  DiffAgainst against = DiffAgainst.head;

  List<WorkspaceFile>? files;
  bool filesFailed = false;

  WorkspaceFile? file;
  List<DiffLine>? lines;
  bool diffFailed = false;

  Map<String, List<DiffLine>>? bundle;

  Future<Map<String, List<DiffLine>>?>? _bundling;

  final _reading = <String>{};
  final _studying = <String, int>{};

  final Map<String, List<DiffLine>> _fetched = {};

  Map<String, FileTexts>? texts;
  List<WorkspaceFile>? _textsOf;

  final Map<String, DiffRead?> reads = {};

  final Map<String, List<SymbolChange>> _outlines = {};

  WorkspaceOverview? _overviewOf;

  int _walk = 0;

  bool writing = false;

  String? said;

  final Map<String, List<WorkspaceFile>?> _commitFiles = {};

  Map<String, String> _viewed = {};

  late String _directoryOf = controller.directory;

  bool _disposed = false;

  void start({WorkspaceFile? file}) {
    _onWorkspace();
    if (file != null) pick(file);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _onWorkspace() {
    if (_disposed) return;
    if (controller.directory != _directoryOf) {
      _directoryOf = controller.directory;
      commits = null;
      _commitFiles.clear();
      _viewed = {};
      unawaited(_loadViewed());
      if (source != null) {
        unawaited(select(null));
        return;
      }
    }
    final overview = controller.overview;
    if (source == null) {
      final fresh = !identical(overview, _overviewOf);
      _overviewOf = overview;
      if (fresh) {
        files = overview == null ? null : _visible(overview.files);
        if (fresh && overview != null) _reload();
      }
      filesFailed = controller.phase == WorkspacePhase.failed;
    }
    _notify();
    if (controller.phase != WorkspacePhase.ready) return;
    if (commits == null) unawaited(_loadCommits());
    final shown = files;
    if (source == null && shown != null && !identical(shown, _textsOf)) {
      _textsOf = shown;
      unawaited(
        _loadTexts(_walk, shown, controller.texts(shown, against: against)),
      );
    }
  }

  void _reload() {
    final walk = ++_walk;
    bundle = null;
    _reading.clear();
    _fetched.clear();
    _outlines.clear();
    final picked = file;
    if (picked != null) {
      final still = files?.where((row) => row.path == picked.path);
      file = still == null || still.isEmpty ? null : still.first;
      if (file == null) lines = null;
    }
    unawaited(_loadBundle(walk, controller.sourceDiffs(against: against)));
  }

  List<WorkspaceFile> _visible(List<WorkspaceFile> all) => switch (against) {
    DiffAgainst.head => all,
    DiffAgainst.unstaged => [
      for (final file in all)
        if (file.hasUnstaged) file,
    ],
    DiffAgainst.staged => [
      for (final file in all)
        if (file.hasStaged) file,
    ],
  };

  Future<void> refresh() async {
    if (source != null) {
      commits = null;
      _notify();
      await _loadCommits();
      return;
    }
    await controller.refresh();
  }

  void readAgainst(DiffAgainst value) {
    if (value == against || source != null) return;
    against = value;
    _overviewOf = null;
    _textsOf = null;
    texts = null;
    reads.clear();
    _onWorkspace();
  }

  Future<void> _loadBundle(
    int walk,
    Future<Map<String, List<DiffLine>>?> answer,
  ) async {
    _bundling = answer;
    final files = await answer;
    if (_disposed || walk != _walk) return;
    bundle = files;
    _bundling = null;
    _outlines.clear();
    final file = this.file;
    final known = file == null ? null : bundled(file);
    if (known != null) lines = known;
    if (file != null && known == null && !_reading.contains(file.path)) {
      unawaited(_read(file));
    }
    _notify();
  }

  Future<void> _loadTexts(
    int walk,
    List<WorkspaceFile> files,
    Future<Map<String, FileTexts>?> answer,
  ) async {
    final texts = await answer;
    if (_disposed || walk != _walk || !identical(files, _textsOf)) return;
    this.texts = texts ?? const {};
    reads.clear();
    _outlines.clear();
    _notify();
    final file = this.file;
    if (file == null) return;
    await study(file);
  }

  Future<void> _loadCommits() async {
    final directory = controller.directory;
    final commits = await controller.commits();
    if (_disposed || commits == null || directory != _directoryOf) return;
    this.commits = commits;
    _notify();
  }

  Future<void> select(Commit? commit) async {
    if (commit?.sha == source?.sha) return;
    final walk = ++_walk;
    source = commit;
    files = null;
    filesFailed = false;
    file = null;
    lines = null;
    bundle = null;
    _bundling = null;
    _reading.clear();
    _fetched.clear();
    texts = null;
    _textsOf = null;
    reads.clear();
    _outlines.clear();
    _overviewOf = null;
    if (commit == null) {
      _onWorkspace();
      return;
    }
    _notify();
    unawaited(_loadBundle(walk, controller.commitDiffs(commit.sha)));
    final listed = await commitFiles(commit);
    if (_disposed || walk != _walk) return;
    files = listed;
    filesFailed = listed == null;
    _notify();
    if (listed != null) {
      _textsOf = listed;
      unawaited(
        _loadTexts(walk, listed, controller.texts(listed, sha: commit.sha)),
      );
    }
  }

  Future<List<WorkspaceFile>?> commitFiles(Commit commit) async {
    if (_commitFiles.containsKey(commit.sha)) return _commitFiles[commit.sha];
    final files = await controller.commitFiles(commit.sha);
    if (files != null) _commitFiles[commit.sha] = files;
    _notify();
    return files;
  }

  List<WorkspaceFile>? knownCommitFiles(Commit commit) =>
      _commitFiles[commit.sha];

  void pick(WorkspaceFile file) {
    this.file = file;
    lines = bundled(file);
    diffFailed = false;
    _notify();
    peek(file);
  }

  void peek(WorkspaceFile file) {
    if (bundled(file) == null &&
        reads[file.path] == null &&
        !_reading.contains(file.path)) {
      unawaited(_read(file));
    }
    unawaited(study(file));
  }

  void close() {
    file = null;
    lines = null;
    _notify();
  }

  Future<void> _read(WorkspaceFile file) async {
    final walk = _walk;
    final source = this.source;
    _reading.add(file.path);
    List<DiffLine>? lines;
    try {
      await _bundling;
      if (walk != _walk) return;
      lines = bundled(file);
      lines ??= source == null
          ? await controller.diff(file, against: against)
          : await controller.commitDiff(source.sha, file.path);
    } finally {
      if (walk == _walk) _reading.remove(file.path);
    }
    if (_disposed || walk != _walk) return;
    if (lines != null) _fetched[file.path] = lines;
    if (this.file?.path != file.path) {
      _notify();
      return;
    }
    this.lines = lines;
    diffFailed = lines == null;
    _notify();
  }

  Future<void> study(WorkspaceFile file) async {
    var texts = this.texts?[file.path];
    if (texts == null || reads.containsKey(file.path)) return;
    final walk = _walk;
    if (_studying[file.path] == walk) return;
    _studying[file.path] = walk;
    try {
      if (texts.budgeted) texts = await _alone(file, walk) ?? texts;
      if (_disposed || walk != _walk) return;
      final cached = _readCache[_cacheKey(texts)];
      final read =
          cached ??
          (texts.readable || texts.images != null
              ? await readTexts(texts)
              : null);
      if (_disposed || walk != _walk || this.texts?[file.path] == null) return;
      reads[file.path] = read;
      _outlines.remove(file.path);
      final key = _cacheKey(texts);
      if (key != null && read != null) _remember(key, read);
      _notify();
    } finally {
      if (_studying[file.path] == walk) _studying.remove(file.path);
    }
  }

  Future<FileTexts?> _alone(WorkspaceFile file, int walk) async {
    final answer = await controller.texts(
      [file],
      sha: source?.sha,
      against: against,
    );
    final texts = answer?[file.path];
    if (texts == null || _disposed || walk != _walk) return null;
    this.texts = {...?this.texts, file.path: texts};
    return texts;
  }

  List<DiffLine>? bundled(WorkspaceFile file) {
    final lines = bundle?[file.path] ?? _fetched[file.path];
    final before = file.origin == null ? null : bundle?[file.origin];
    if (lines == null || before == null) return lines;
    if (files?.any((row) => row.path == file.origin) ?? true) return lines;
    return [...before, ...lines];
  }

  List<SymbolChange> outline(WorkspaceFile file) {
    final known = _outlines[file.path];
    if (known != null) return known;
    final read = reads[file.path];
    final texts = this.texts?[file.path];
    final structural = read?.structural;
    final outline = structural != null
        ? symbolChanges(structural)
        : texts != null && texts.readable && texts.scopesNew.isNotEmpty
        ? textsOutline(texts)
        : hunkOutline(bundled(file) ?? const []);
    return _outlines[file.path] = outline;
  }

  Future<String?> stage(List<WorkspaceFile> files) =>
      _wrote(controller.stage([for (final file in files) file.path]));

  Future<String?> unstage(List<WorkspaceFile> files) =>
      _wrote(controller.unstage([for (final file in files) file.path]));

  Future<String?> discard(List<WorkspaceFile> files) async {
    final untracked = [
      for (final file in files)
        if (file.untracked) file.path,
    ];
    final tracked = [
      for (final file in files)
        if (!file.untracked) file.path,
    ];
    String? failed;
    if (untracked.isNotEmpty) {
      failed = await _wrote(controller.discard(untracked, untracked: true));
    }
    if (tracked.isNotEmpty && failed == null) {
      failed = await _wrote(controller.discard(tracked, untracked: false));
    }
    return failed;
  }

  Future<String?> writeHunk(
    WorkspaceFile file,
    HunkWrite write,
    int newLine, {
    DiffLine? only,
    DiffLine? held,
  }) => _wrote(_hunk(file, write, newLine, only: only, held: held));

  Future<String?> _hunk(
    WorkspaceFile file,
    HunkWrite write,
    int newLine, {
    DiffLine? only,
    DiffLine? held,
  }) async {
    final side = write == HunkWrite.unstage
        ? DiffAgainst.staged
        : DiffAgainst.unstaged;
    final lines = await controller.diff(file, against: side);
    if (lines == null) return 'could not read it';
    final span = hunkHolding(lines, newLine);
    if (span == null) {
      return write == HunkWrite.unstage ? 'not in the index' : 'nothing here';
    }
    if (held != null && !_holds(lines, span, held)) {
      return write == HunkWrite.unstage
          ? 'not in the index'
          : 'already in the index';
    }
    final twin = only == null ? null : _twin(lines, span, only);
    bool keep(DiffLine line) =>
        line.kind == only!.kind &&
        line.text == only.text &&
        (line.kind != DiffLineKind.added || line.newLine == only.newLine) &&
        (line.kind != DiffLineKind.removed || identical(line, twin));
    final filter = only == null ? null : keep;
    if (!patchChanges(lines, span, filter)) return 'nothing to write';
    if (write == HunkWrite.discard && file.untracked && only == null) {
      return controller.discard([file.path], untracked: true);
    }
    final created = switch (write) {
      HunkWrite.stage => file.untracked,
      HunkWrite.unstage => file.staged == 'A' && only == null,
      HunkWrite.discard => false,
    };
    final patch = hunkPatch(
      file.path,
      lines,
      span,
      keep: filter,
      reverse: write != HunkWrite.stage,
      created: created,
    );
    return controller.apply(
      patch,
      cached: write != HunkWrite.discard,
      reverse: write != HunkWrite.stage,
    );
  }

  bool _holds(List<DiffLine> lines, HunkSpan span, DiffLine held) {
    if (held.kind != DiffLineKind.added && held.kind != DiffLineKind.removed) {
      return true;
    }
    return lines
        .sublist(span.start + 1, span.end)
        .any((line) => line.kind == held.kind && line.text == held.text);
  }

  DiffLine? _twin(List<DiffLine> lines, HunkSpan span, DiffLine held) {
    final copies = [
      for (final line in lines.sublist(span.start + 1, span.end))
        if (line.kind == DiffLineKind.removed && line.text == held.text) line,
    ];
    if (copies.isEmpty) return null;
    return copies.firstWhere(
      (line) => line.oldLine == held.oldLine,
      orElse: () => copies.first,
    );
  }

  Future<String?> _wrote(Future<String?> write) async {
    writing = true;
    said = null;
    _notify();
    final failed = await write;
    writing = false;
    said = failed;
    _notify();
    return failed;
  }

  Future<List<Commit>?> fileLog(String path) => controller.fileLog(path);

  String get _viewedKey =>
      'diff_viewed:${controller.host.id}:${controller.directory}';

  Future<void> _loadViewed() async {
    final settings = this.settings;
    if (settings == null) return;
    final key = _viewedKey;
    final raw = await settings.text(key, orElse: '{}');
    if (_disposed || key != _viewedKey) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        _viewed = {
          for (final MapEntry(:key, :value) in decoded.entries)
            if (value is String) key: value,
        };
        _notify();
      }
    } on FormatException {
      // ignored: an unreadable record is the same as no marks.
    }
  }

  String _mark(WorkspaceFile file) {
    final texts = this.texts?[file.path];
    final blobs = texts?.oldOid != null || texts?.newOid != null;
    return blobs ? '${texts!.oldOid}..${texts.newOid}' : _counted(file);
  }

  String _counted(WorkspaceFile file) =>
      '${file.kind.name} ${file.added}/${file.removed}';

  bool viewed(WorkspaceFile file) {
    if (source != null) return false;
    final kept = _viewed[file.path];
    return kept != null && (kept == _mark(file) || kept == _counted(file));
  }

  int get viewedCount =>
      (files ?? const <WorkspaceFile>[]).where(viewed).length;

  void markViewed(WorkspaceFile file, bool value) {
    if (source != null) return;
    if (value) {
      _viewed[file.path] = _mark(file);
    } else {
      _viewed.remove(file.path);
    }
    _notify();
    unawaited(settings?.setText(_viewedKey, jsonEncode(_viewed)));
  }

  @override
  void dispose() {
    _disposed = true;
    controller.removeListener(_onWorkspace);
    super.dispose();
  }
}

final _readCache = <String, DiffRead>{};

const _readsKept = 48;

String? _cacheKey(FileTexts texts) {
  if (texts.oldOid == null && texts.newOid == null) return null;
  return '${texts.path}|${texts.oldOid}|${texts.newOid}';
}

void _remember(String key, DiffRead read) {
  _readCache
    ..remove(key)
    ..[key] = read;
  while (_readCache.length > _readsKept) {
    _readCache.remove(_readCache.keys.first);
  }
}
