import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../herdr_client.dart';
import '../host_links.dart';
import '../ssh_settle.dart';

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
  WorkspaceSsh.borrowed(this._lease);

  static const timeout = Duration(seconds: 10);
  static const answer = Duration(seconds: 30);

  final HostLease _lease;
  final _execs = <SSHSession>{};
  var _closed = false;

  @override
  Future<WorkspaceReply> run(String command) async {
    if (_closed || _lease.client.isClosed) {
      throw const HerdrUnreachable('workspace closed');
    }
    final SSHSession session;
    try {
      session = await openWithin(
        _lease.client.execute(command),
        timeout,
        endExec,
      );
    } on SSHChannelOpenError catch (error) {
      throw HerdrBusy('$error');
    } catch (error) {
      throw await _doubted(error);
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
      throw await _doubted(error);
    } finally {
      _execs.remove(session);
      endExec(session);
    }
  }

  Future<Object> _doubted(Object error) async {
    if (!_closed &&
        (error is TimeoutException ||
            error is SSHError ||
            error is SocketException)) {
      await _lease.suspect();
    }
    return asHerdrFailure(error) ?? error;
  }

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
