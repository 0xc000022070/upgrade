import 'package:dartssh2/dartssh2.dart';

import 'package:striked/platform/ssh/host_failure.dart';
import 'package:striked/platform/ssh/ssh_settle.dart';

class ExecTracker {
  ExecTracker(this._closedDetail);

  final String _closedDetail;
  final _execs = <SSHSession, void Function()?>{};
  var _closed = false;

  bool get closed => _closed;

  void ensureOpen() {
    if (_closed) throw HerdrUnreachable(_closedDetail);
  }

  Future<SSHSession> open(
    Future<SSHSession> Function() opening, {
    void Function()? onEnd,
  }) async {
    final SSHSession session;
    try {
      session = await opening();
    } on SSHChannelOpenError catch (error) {
      throw HerdrBusy('$error');
    }
    if (_closed) {
      endExec(session);
      throw HerdrUnreachable(_closedDetail);
    }
    _execs[session] = onEnd;
    return session;
  }

  void end(SSHSession session) {
    _execs.remove(session)?.call();
    endExec(session);
  }

  void endAll() {
    _closed = true;
    for (final exec in [..._execs.keys]) {
      end(exec);
    }
  }
}
