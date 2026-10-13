import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'package:upgrade/platform/herdr/herdr_client.dart';
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
  final _execs = <SSHSession>{};
  var _closed = false;

  Future<HostLease> _held() {
    if (!_lease.closed) return Future.value(_lease);
    final again = _again;
    if (again == null) throw const HerdrUnreachable('workspace closed');
    return _leasing ??= () async {
      try {
        _lease.release();
        final lease = await again();
        if (_closed) {
          lease.release();
          throw const HerdrUnreachable('workspace closed');
        }
        return _lease = lease;
      } finally {
        _leasing = null;
      }
    }();
  }

  @override
  Future<WorkspaceReply> run(String command) async {
    if (_closed) throw const HerdrUnreachable('workspace closed');
    final lease = await _held();
    final SSHSession session;
    try {
      session = await openWithin(lease.execute(command), timeout, endExec);
    } on SSHChannelOpenError catch (error) {
      throw HerdrBusy('$error');
    } catch (error) {
      throw _failure(error);
    }
    if (_closed) {
      endExec(session);
      throw const HerdrUnreachable('workspace closed');
    }
    _execs.add(session);
    try {
      final out = BytesBuilder(copy: false);
      final err = BytesBuilder(copy: false);
      await Future.wait([
        session.stdout.cast<List<int>>().forEach(out.add),
        session.stderr.cast<List<int>>().forEach(err.add),
        session.stdin.close(),
        session.done,
      ]).timeout(answer);
      if (_closed) throw const HerdrUnreachable('workspace closed');
      return WorkspaceReply(
        exitCode: session.exitCode,
        stdout: utf8.decode(out.takeBytes(), allowMalformed: true),
        stderr: utf8.decode(err.takeBytes(), allowMalformed: true),
      );
    } catch (error) {
      throw _failure(error);
    } finally {
      _execs.remove(session);
      endExec(session);
    }
  }

  static Object _failure(Object error) => asHerdrFailure(error) ?? error;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final exec in [..._execs]) {
      endExec(exec);
    }
    _execs.clear();
    _lease.release();
  }
}
