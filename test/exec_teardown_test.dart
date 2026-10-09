import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:upgrade/platform/herdr_client.dart';
import 'package:upgrade/platform/ssh_settle.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/host_links.dart';
import 'support/ssh_exec.dart';

void main() {
  test('a command given up on is ended on the host', () {
    final session = FakeExecSession();

    endExec(session);

    expect(session.signals, [SSHSignal.TERM]);
    expect(session.destroyed, 1);
  });

  test(
    'an engine call past its deadline ends the command it started',
    () async {
      final session = FakeExecSession();
      final herdr = HerdrSession.over(
        FakeExecSocket(),
        FakeExecClient(session),
      );

      await expectLater(
        herdr.engine(const {}, within: const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>()),
      );

      expect(session.signals, [SSHSignal.TERM]);
      expect(session.destroyed, 1);
    },
  );

  test(
    'a borrowed session closed mid-call ends its command and keeps the link',
    () async {
      final client = FakeRunClient((_) => null);
      final lease = await leaseOver(client);
      final herdr = HerdrSession.borrowed(lease);

      unawaited(herdr.paths().then((_) {}, onError: (_) {}));
      await pumpEventQueue();
      herdr
        ..close()
        ..close();

      final exec = client.sessions.single;
      expect(exec.signals, [SSHSignal.TERM]);
      expect(exec.destroyed, 1);
      expect(lease.closed, isTrue);
      expect(client.closed, isFalse);
      await expectLater(herdr.paths(), throwsA(isA<HerdrUnreachable>()));
    },
  );

  test(
    'a borrowed session closed mid-call lets its socket channel go',
    () async {
      final forward = _Forward();
      final client = _ForwardClient(forward);
      final lease = await leaseOver(client);
      final herdr = HerdrSession.borrowed(lease);

      unawaited(herdr.list().then((_) {}, onError: (_) {}));
      await pumpEventQueue();
      expect(client.forwards, 1);
      herdr.close();

      expect(forward.destroyed, 1);
      expect(lease.closed, isTrue);
      expect(client.closed, isFalse);
    },
  );
}

final class _Forward implements SSHForwardChannel {
  var destroyed = 0;
  final _incoming = StreamController<Uint8List>();
  final _outgoing = StreamController<List<int>>();

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  void destroy() => destroyed++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ForwardClient implements SSHClient {
  _ForwardClient(this.forward);

  final _Forward forward;
  final _roster = FakeRunClient(
    (_) => (
      exitCode: 0,
      stdout:
          '{"sessions":[{"name":"development","running":true,"default":true,'
          '"socket_path":"/run/herdr.sock"}]}',
      stderr: '',
    ),
  );
  var forwards = 0;
  var closed = false;

  @override
  bool get isClosed => closed;

  @override
  Future<void> get done => Completer<void>().future;

  @override
  Future<void> close() async => closed = true;

  @override
  Future<SSHSession> execute(
    String command, {
    SSHPtyConfig? pty,
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) => _roster.execute(command);

  @override
  Future<SSHForwardChannel> forwardLocalUnix(String remoteSocketPath) async {
    forwards++;
    return forward;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
