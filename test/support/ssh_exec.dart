import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/ssh_channel.dart';

final class FakeExecChannel implements SSHChannel {
  var destroyed = 0;

  @override
  void destroy() => destroyed++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class FakeExecSession implements SSHSession {
  FakeExecSession({this.gone = false});

  final bool gone;
  final signals = <SSHSignal>[];
  final out = StreamController<Uint8List>();
  final err = StreamController<Uint8List>();
  final input = StreamController<Uint8List>();
  final exited = Completer<void>();
  final _channel = FakeExecChannel();

  @override
  SSHChannel get channel => _channel;

  int get destroyed => _channel.destroyed;

  @override
  Stream<Uint8List> get stdout => out.stream;

  @override
  Stream<Uint8List> get stderr => err.stream;

  @override
  StreamSink<Uint8List> get stdin => input.sink;

  @override
  Future<void> get done => exited.future;

  @override
  int? get exitCode => null;

  @override
  SSHSessionExitSignal? get exitSignal => null;

  @override
  void kill(SSHSignal signal) {
    if (gone) throw StateError('channel is closed');
    signals.add(signal);
  }

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class FakeExecClient implements SSHClient {
  FakeExecClient(this.session);

  final FakeExecSession session;
  final opened = Completer<void>();
  var hold = Completer<void>()..complete();

  int? closedAt;

  @override
  Future<void> close() async => closedAt = session.signals.length;

  @override
  Future<SSHSession> execute(
    String command, {
    SSHPtyConfig? pty,
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async {
    opened.complete();
    await hold.future;
    return session;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class FakeExecSocket implements SSHSocket {
  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
