import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import 'package:upgrade/platform/ssh/host_failure.dart';
import 'package:upgrade/platform/ssh/exec_tracker.dart';
import 'package:upgrade/platform/ssh/host_links.dart';
import 'package:upgrade/platform/ssh/ssh_settle.dart';

class WorkspaceReply {
  const WorkspaceReply({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int? exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;
}

abstract interface class WorkspaceRunner {
  Future<WorkspaceReply> run(String command);

  Future<void> close();
}

/// Held, not reopened: a handshake is the expensive part of asking a machine anything,
/// and every tap on this screen is one command on a connection that already exists.
class WorkspaceSsh implements WorkspaceRunner {
  WorkspaceSsh.borrowed(this._lease, {this._again});

  static const timeout = Duration(seconds: 10);
  static const answer = Duration(seconds: 30);

  HostLease _lease;
  final Future<HostLease> Function()? _again;
  Future<HostLease>? _leasing;
  final _execs = ExecTracker('workspace closed');

  Future<HostLease> _held() {
    if (!_lease.closed) return Future.value(_lease);
    final again = _again;
    if (again == null) throw const HostFailure.unreachable('workspace closed');
    return _leasing ??= () async {
      try {
        _lease.release();
        final lease = await again();
        if (_execs.closed) {
          lease.release();
          throw const HostFailure.unreachable('workspace closed');
        }
        return _lease = lease;
      } finally {
        _leasing = null;
      }
    }();
  }

  @override
  Future<WorkspaceReply> run(String command) async {
    _execs.ensureOpen();
    final lease = await _held();
    final SSHSession session;
    try {
      session = await _execs.open(
        () => openWithin(lease.execute(command), timeout, endExec),
      );
    } catch (error) {
      throw _failure(error);
    }
    try {
      final (:stdout, :stderr) = await drainExec(session).timeout(answer);
      _execs.ensureOpen();
      return WorkspaceReply(
        exitCode: session.exitCode,
        stdout: utf8.decode(stdout, allowMalformed: true),
        stderr: utf8.decode(stderr, allowMalformed: true),
      );
    } catch (error) {
      throw _failure(error);
    } finally {
      _execs.end(session);
    }
  }

  static Object _failure(Object error) => asHostFailure(error) ?? error;

  @override
  Future<void> close() async {
    if (_execs.closed) return;
    _execs.endAll();
    _lease.release();
  }
}
