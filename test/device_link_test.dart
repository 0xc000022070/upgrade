import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/ssh_channel.dart';
import 'package:dazzle/platform/devices/device_link.dart';
import 'package:dazzle/platform/ssh_settle.dart';
import 'package:flutter_test/flutter_test.dart';

const _pixel = HostDevice(
  kind: DeviceKind.android,
  id: 'emulator-5554',
  name: 'pixel_7-api36',
);

final class _Channel implements SSHChannel {
  var destroyed = 0;

  @override
  void destroy() => destroyed++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Session implements SSHSession {
  _Session({this.gone = false});

  final bool gone;
  final signals = <SSHSignal>[];
  final out = StreamController<Uint8List>();
  final _channel = _Channel();

  @override
  SSHChannel get channel => _channel;

  int get destroyed => _channel.destroyed;

  @override
  Stream<Uint8List> get stdout => out.stream;

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

final class _Client implements SSHClient {
  _Client(this.session);

  final _Session session;
  final opened = Completer<void>();
  var hold = Completer<void>()..complete();

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

final class _Socket implements SSHSocket {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'a stream let go ends the loop on the host, not only its input',
    () async {
      final session = _Session();
      final client = _Client(session);
      final link = DeviceSsh.over(_Socket(), client);
      final frames = link.frames(_pixel).listen((_) {});
      await client.opened.future;
      await _flush();
      await frames.cancel();
      expect(session.signals, [SSHSignal.TERM]);
      expect(session.destroyed, 1);
    },
  );

  test('a stream let go while it opens ends the loop once it opens', () async {
    final session = _Session();
    final client = _Client(session)..hold = Completer<void>();
    final link = DeviceSsh.over(_Socket(), client);
    final frames = link.frames(_pixel).listen((_) {});
    await client.opened.future;
    await frames.cancel();
    client.hold.complete();
    await _flush();
    expect(session.signals, [SSHSignal.TERM]);
    expect(session.destroyed, 1);
  });

  test('a loop that already exited is still torn down, quietly', () {
    final session = _Session(gone: true);
    expect(() => endExec(session), returnsNormally);
    expect(session.destroyed, 1);
  });
}
