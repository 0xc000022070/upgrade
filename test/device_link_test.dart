import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/ssh_channel.dart';
import 'package:upgrade/platform/devices/device_link.dart';
import 'package:upgrade/platform/host_links.dart';
import 'package:upgrade/platform/ssh_settle.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/host_links.dart';
import 'support/ssh_exec.dart';

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

final class _Refusing implements SSHClient {
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
  }) async => throw StateError('channel refused');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Socket implements SSHSocket {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

Future<HostLease> _track(List<HostLease> leases, SSHClient client) async {
  final lease = await leaseOver(client);
  leases.add(lease);
  return lease;
}

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

  test(
    'a leasing link closed ends its loop and its listing, never the connection',
    () async {
      final client = FakeRunClient((_) => null);
      final uses = <HostUse>[];
      final leases = <HostLease>[];
      final link = DeviceSsh.leasing((use) async {
        uses.add(use);
        return _track(leases, client);
      });
      link.frames(_pixel).listen((_) {}, onError: (_) {});
      unawaited(link.list().then((_) {}, onError: (_) {}));
      await pumpEventQueue();
      expect(client.sessions, hasLength(2));
      expect(uses, unorderedEquals([HostUse.deviceDock, HostUse.devices]));

      await link.close();
      await link.close();

      for (final exec in client.sessions) {
        expect(exec.signals, [SSHSignal.TERM]);
        expect(exec.destroyed, 1);
      }
      expect(leases.every((lease) => lease.closed), isTrue);
      expect(client.closed, isFalse);
    },
  );

  test(
    'a listing ends its command and lets its lease go once it has answered',
    () async {
      final client = FakeRunClient(
        (_) => (exitCode: 0, stdout: 'A emulator-5554 pixel\n', stderr: ''),
      );
      final leases = <HostLease>[];
      final link = DeviceSsh.leasing((_) => _track(leases, client));
      expect(await link.list(), [_pixel]);
      expect(client.sessions.single.destroyed, 1);
      expect(leases.single.closed, isTrue);
    },
  );

  test(
    'a listing refused by the host fails without touching the link',
    () async {
      final client = _Refusing();
      final link = DeviceSsh.leasing((_) => leaseOver(client));
      await expectLater(link.list(), throwsA(anything));
      expect(client.closed, isFalse);
      expect(link.closed, isFalse);
    },
  );

  test('a read answers with its output and ends its command', () async {
    final client = FakeRunClient(
      (_) => (exitCode: 0, stdout: 'noise\nB emulator-5556\n', stderr: ''),
    );
    final link = DeviceSsh.leasing((_) => leaseOver(client));
    expect(await link.read('boot'), 'noise\nB emulator-5556\n');
    expect(client.sessions.single.destroyed, 1);
  });

  test('a read past its limit ends its command and keeps the link', () async {
    final client = FakeRunClient((_) => null);
    final link = DeviceSsh.leasing((_) => leaseOver(client));
    await expectLater(
      link.read('boot', limit: const Duration(milliseconds: 20)),
      throwsA(isA<TimeoutException>()),
    );
    expect(client.sessions.single.signals, [SSHSignal.TERM]);
    expect(client.sessions.single.destroyed, 1);
    expect(client.closed, isFalse);
    expect(link.closed, isFalse);
  });

  test('a loop that already exited is still torn down, quietly', () {
    final session = _Session(gone: true);
    expect(() => endExec(session), returnsNormally);
    expect(session.destroyed, 1);
  });
}
