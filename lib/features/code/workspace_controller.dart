import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/agents/agents.dart';
import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/platform/herdr/herdr_client.dart';
import 'package:striked/platform/ssh/host_keys.dart';
import 'package:striked/platform/ssh/host_links.dart';
import 'package:striked/platform/workspace/workspace_client.dart';
import 'package:striked/platform/workspace/workspace_commands.dart';
import 'package:striked/platform/workspace/workspace_model.dart';

enum WorkspacePhase { connecting, ready, failed }

typedef WorkspaceOpener = Future<WorkspaceRunner> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  required HostKeyVerifier verifier,
});

final workspaceOpenerProvider = Provider<WorkspaceOpener>((ref) {
  final links = ref.read(hostLinksProvider);
  return ({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    required HostKeyVerifier verifier,
  }) async {
    Future<HostLease> lease(HostKeyVerifier verifier) => links.lease(
      address: address,
      port: port,
      user: user,
      privateKey: privateKey,
      verifier: verifier,
      use: HostUse.workspace,
    );
    final first = await lease(verifier);
    final trusted = HostKeyVerifier.pinnedOnly(
      verifier.verified ?? verifier.pinned,
    );
    return WorkspaceSsh.borrowed(first, again: () => lease(trusted));
  };
});

/// A [ChangeNotifier] for the reason `HostScreenController` is one: the connection is
/// exactly as long-lived as the screen, and a provider that outlived the widget would
/// leave an ssh session open on the host. The connection is held rather than reopened per
/// command because on a phone the cost of asking a machine anything is the round trip.
class WorkspaceController extends ChangeNotifier {
  WorkspaceController({
    required this.host,
    required String directory,
    required this.readPrivateKey,
    required this._open,
  }) : _directory = directory,
       _root = directory;

  final Host host;
  final Future<String?> Function(String keyId) readPrivateKey;
  final WorkspaceOpener _open;

  /// Not final: a worktree is opened by pointing the screen at it, on the same connection
  /// and without a route push.
  String _directory;

  /// Where the screen started, which is the registered row. Kept so the worktree list can
  /// say which one is the one that was registered.
  final String _root;

  WorkspaceRunner? _runner;
  WorkspacePhase _phase = WorkspacePhase.connecting;
  String? _reason;
  WorkspaceOverview? _overview;
  bool _disposed = false;

  /// Guards a REFRESH tapped while a previous attempt is still in flight.
  int _attempt = 0;

  String get directory => _directory;
  String get root => _root;
  WorkspacePhase get phase => _phase;
  String? get reason => _reason;
  WorkspaceOverview? get overview => _overview;

  String get label {
    final segments = _directory.split('/').where((s) => s.isNotEmpty);
    return segments.isEmpty ? _directory : segments.last;
  }

  Future<void> connect() async {
    final attempt = ++_attempt;
    _phase = WorkspacePhase.connecting;
    _reason = null;
    notifyListeners();

    final privateKey = await readPrivateKey(host.keyId);
    if (_disposed || attempt != _attempt) return;
    if (privateKey == null) {
      _fail('key rejected');
      return;
    }
    try {
      final runner = await _open(
        address: host.address,
        port: host.port,
        user: host.user,
        privateKey: privateKey,
        verifier: HostKeyVerifier.pinnedOnly(host.hostKey),
      );
      if (_disposed || attempt != _attempt) {
        await runner.close();
        return;
      }
      _runner = runner;
      await _load(attempt);
    } on HerdrFailure catch (error) {
      debugPrint('striked.workspace ${host.name}: ${error.detail ?? error}');
      if (_disposed || attempt != _attempt) return;
      _fail(error.reason(host.name));
    }
  }

  Future<void> refresh() async {
    if (_runner == null) return connect();
    await _load(_attempt);
  }

  Future<void> openWorktree(String directory) async {
    if (directory == _directory) return;
    _directory = directory;
    _overview = null;
    notifyListeners();
    await refresh();
  }

  /// The viewer walks a list of files, and on a radio the cost of each step is the round
  /// trip and not the bytes, so the whole diff is asked for once and every tap after it is
  /// already answered. A file the answer did not reach — it came back at the byte cap, or
  /// it is untracked and `diff` never names it — is simply absent, and [diff] is still
  /// there for it.
  Future<Map<String, List<DiffLine>>?> sourceDiffs({
    DiffAgainst against = DiffAgainst.head,
  }) => _diffs(WorkspaceCommands.sourceDiff(_directory, against: against));

  Future<Map<String, List<DiffLine>>?> commitDiffs(String sha) =>
      _diffs(WorkspaceCommands.commitDiffAll(_directory, sha));

  Future<Map<String, List<DiffLine>>?> _diffs(String command) async {
    final reply = await _run(command);
    if (reply == null || !reply.ok) return null;
    return parseDiffByFile(reply.stdout, complete: _whole(reply.stdout));
  }

  /// Null when the command failed, which the sheet words as its own empty line rather than
  /// tearing down the screen behind it.
  Future<List<DiffLine>?> diff(
    WorkspaceFile file, {
    DiffAgainst against = DiffAgainst.head,
  }) async {
    final command = file.untracked && against != DiffAgainst.staged
        ? WorkspaceCommands.newFileDiff(_directory, file.path)
        : WorkspaceCommands.fileDiff(_directory, file.path, against: against);
    final reply = await _run(command);
    if (reply == null || !reply.ok) return null;
    return parseDiff(reply.stdout, complete: _whole(reply.stdout));
  }

  Future<Map<String, FileTexts>?> texts(
    List<WorkspaceFile> files, {
    String? sha,
    DiffAgainst against = DiffAgainst.head,
  }) async {
    final readable = WorkspaceCommands.textsCarried([
      for (final file in files)
        if (!file.binary) (file.path, file.origin),
    ]);
    if (readable.isEmpty) return const {};
    final reply = await _run(
      WorkspaceCommands.texts(_directory, readable, sha: sha, against: against),
      quiet: true,
    );
    if (reply == null || !reply.ok) return null;
    return parseFileTexts(reply.stdout, [
      for (final (path, _) in readable) path,
    ]);
  }

  Future<List<Commit>?> commits() async {
    final reply = await _run(WorkspaceCommands.commits(_directory));
    if (reply == null || !reply.ok) return null;
    return parseCommits(reply.stdout);
  }

  Future<List<WorkspaceFile>?> commitFiles(String sha) async {
    final reply = await _run(WorkspaceCommands.commitFiles(_directory, sha));
    if (reply == null || !reply.ok) return null;
    return parseCommitFiles(reply.stdout);
  }

  Future<List<DiffLine>?> commitDiff(String sha, String path) async {
    final reply = await _run(
      WorkspaceCommands.commitDiff(_directory, sha, path),
    );
    if (reply == null || !reply.ok) return null;
    return parseDiff(reply.stdout, complete: _whole(reply.stdout));
  }

  /// `head` counted bytes, so only the encoded length can be compared with the number it
  /// was given: a cut multibyte character decodes to a replacement no shorter than the
  /// bytes it stood for, so an answer at the cap still reads as one.
  static bool _whole(String stdout) =>
      utf8.encode(stdout).length < WorkspaceCommands.diffBytes;

  /// [path] relative to [directory], empty for the root itself.
  Future<List<Commit>?> fileLog(String path) async {
    final reply = await _run(WorkspaceCommands.fileLog(_directory, path));
    if (reply == null || !reply.ok) return null;
    return parseCommits(reply.stdout);
  }

  Future<String?> stage(List<String> paths) =>
      _write(WorkspaceCommands.stage(_directory, paths));

  Future<String?> unstage(List<String> paths) =>
      _write(WorkspaceCommands.unstage(_directory, paths));

  Future<String?> discard(List<String> paths, {required bool untracked}) =>
      _write(
        WorkspaceCommands.discard(_directory, paths, untracked: untracked),
      );

  Future<String?> apply(
    String patch, {
    required bool cached,
    required bool reverse,
  }) {
    if (utf8.encode(patch).length > workspacePatchBytes) {
      return Future.value('too large to send');
    }
    return _write(
      WorkspaceCommands.apply(
        _directory,
        patch,
        cached: cached,
        reverse: reverse,
      ),
    );
  }

  Future<String?> _write(String command) async {
    final reply = await _run(command);
    if (_disposed) return null;
    if (reply == null) return 'connection lost';
    await _load(_attempt);
    if (reply.ok) return null;
    final said = reply.stderr.trim().split('\n').first;
    return said.isEmpty ? 'git said no' : said.toLowerCase();
  }

  Future<List<DirEntry>?> list(String path) async {
    final reply = await _run(WorkspaceCommands.listing(_directory, path));
    if (reply == null || !reply.ok) return null;
    return parseListing(reply.stdout);
  }

  Future<String?> read(String path) async {
    final reply = await _run(WorkspaceCommands.file(_directory, path));
    if (reply == null || !reply.ok) return null;
    return reply.stdout;
  }

  Future<void> _load(int attempt) async {
    final reply = await _run(WorkspaceCommands.overview(_directory));
    if (_disposed || attempt != _attempt) return;
    if (reply == null) return;
    if (reply.exitCode == workspaceNoDirectory) {
      _fail('directory gone');
      return;
    }
    if (reply.exitCode == workspaceNoRepository) {
      _fail('not a checkout');
      return;
    }
    if (!reply.ok) {
      _fail(reply.stderr.trim().split('\n').first.toLowerCase());
      return;
    }
    _overview = parseOverview(reply.stdout);
    _phase = WorkspacePhase.ready;
    _reason = null;
    notifyListeners();
  }

  /// Null when the connection is gone. The reason is shown on the way past, unless [quiet].
  Future<WorkspaceReply?> _run(String command, {bool quiet = false}) async {
    final runner = _runner;
    if (runner == null) return null;
    try {
      return await runner.run(command);
    } on HerdrFailure catch (error) {
      debugPrint('striked.workspace ${host.name}: ${error.detail ?? error}');
      if (_disposed || quiet) return null;
      if (error is! HerdrBusy && identical(_runner, runner)) {
        _runner = null;
        unawaited(runner.close());
      }
      _fail(error.reason(host.name));
      return null;
    }
  }

  void _fail(String reason) {
    _phase = WorkspacePhase.failed;
    _reason = reason;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // Fire and forget: the route is going and nothing is left to await it.
    final runner = _runner;
    _runner = null;
    if (runner != null) unawaited(runner.close());
    super.dispose();
  }
}
