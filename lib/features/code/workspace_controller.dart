import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/repositories/host_repository.dart';
import '../../platform/herdr_client.dart';
import '../../platform/host_keys.dart';
import '../../platform/workspace/workspace_client.dart';
import '../../platform/workspace/workspace_commands.dart';
import '../../platform/workspace/workspace_model.dart';

/// How a workspace opens: connect, then ask. Both states are on screen —
/// [WorkspacePhase.connecting] is the handshake, and everything after it is
/// one command on a connection that is already up.
enum WorkspacePhase { connecting, ready, failed }

/// The transport seam, the same shape the vnc and shell
/// openers have.
typedef WorkspaceOpener = Future<WorkspaceRunner> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  HostKeyVerifier? verifier,
});

/// One directory on one host, read over a connection held for the route's
/// lifetime.
///
/// A [ChangeNotifier] for the reason `HostScreenController` is one: the
/// connection is exactly as long-lived as the screen, and a provider that
/// outlived the widget would leave an ssh session open on the host.
///
/// The connection is held rather than reopened per command because on a phone
/// the cost of asking a machine anything is the round trip: the handshake is
/// paid once, and a tap on a file after that is a single `sh -c`.
class WorkspaceController extends ChangeNotifier {
  WorkspaceController({
    required this.host,
    required String directory,
    required this.readPrivateKey,
    WorkspaceOpener? open,
  }) : _directory = directory,
       _root = directory,
       _open = open ?? WorkspaceSsh.open;

  final Host host;
  final Future<String?> Function(String keyId) readPrivateKey;
  final WorkspaceOpener _open;

  /// The directory the screen is reading. Not final: a worktree is opened by
  /// pointing the screen at it, on the same connection and without a route
  /// push, because it is the same machine and the same repository.
  String _directory;

  /// Where the screen started, which is the registered row. Kept so the
  /// worktree list can say which one is the one that was registered.
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

  /// The last segment, which is what the title shows.
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
      debugPrint('spectacle.workspace ${host.name}: ${error.detail ?? error}');
      if (_disposed || attempt != _attempt) return;
      _fail(error.reason(host.name));
    }
  }

  /// Asks again on the connection already open. The handshake is not repeated:
  /// this is the one command the screen was drawn from.
  Future<void> refresh() async {
    if (_runner == null) return connect();
    await _load(_attempt);
  }

  /// Points the screen at a sibling checkout. Same connection, same repository,
  /// no route: the screen is a view of a directory and the directory changed.
  Future<void> openWorktree(String directory) async {
    if (directory == _directory) return;
    _directory = directory;
    _overview = null;
    notifyListeners();
    await refresh();
  }

  /// One file's hunks. Null when the command failed, which the sheet words as
  /// its own empty line rather than tearing down the screen behind it.
  Future<List<DiffLine>?> diff(WorkspaceFile file) async {
    final command = file.untracked
        ? WorkspaceCommands.newFileDiff(_directory, file.path)
        : WorkspaceCommands.fileDiff(_directory, file.path);
    final reply = await _run(command);
    if (reply == null || !reply.ok) return null;
    return parseDiff(reply.stdout);
  }

  /// The history behind the directory, newest first. Read once per screen and
  /// held by the caller: a list of a hundred subjects does not change while a
  /// diff is being read.
  Future<List<Commit>?> commits() async {
    final reply = await _run(WorkspaceCommands.commits(_directory));
    if (reply == null || !reply.ok) return null;
    return parseCommits(reply.stdout);
  }

  /// What one commit touched, counts and kinds together.
  Future<List<WorkspaceFile>?> commitFiles(String sha) async {
    final reply = await _run(WorkspaceCommands.commitFiles(_directory, sha));
    if (reply == null || !reply.ok) return null;
    return parseCommitFiles(reply.stdout);
  }

  /// One file's hunks inside one commit.
  Future<List<DiffLine>?> commitDiff(String sha, String path) async {
    final reply = await _run(
      WorkspaceCommands.commitDiff(_directory, sha, path),
    );
    if (reply == null || !reply.ok) return null;
    return parseDiff(reply.stdout);
  }

  /// One directory's entries, [path] relative to [directory] and empty for the
  /// root itself.
  Future<List<DirEntry>?> list(String path) async {
    final reply = await _run(WorkspaceCommands.listing(_directory, path));
    if (reply == null || !reply.ok) return null;
    return parseListing(reply.stdout);
  }

  /// One file's text, already capped by the command.
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

  /// Null when the connection is gone. The reason is put on the screen on the
  /// way past, so a tap that meets a dropped connection says so instead of
  /// answering with nothing.
  Future<WorkspaceReply?> _run(String command) async {
    final runner = _runner;
    if (runner == null) return null;
    try {
      return await runner.run(command);
    } on HerdrFailure catch (error) {
      debugPrint('spectacle.workspace ${host.name}: ${error.detail ?? error}');
      if (_disposed) return null;
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
