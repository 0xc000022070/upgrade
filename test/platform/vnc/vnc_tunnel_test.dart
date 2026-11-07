import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/host_links.dart';
import 'package:upgrade/platform/ssh/keys.dart';
import 'package:upgrade/platform/vnc/vnc_failure.dart';
import 'package:upgrade/platform/vnc/vnc_tunnel.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/host_links.dart';
import '../../support/tarpit.dart';
import '../../support/vnc_channel.dart';

final _pin = PinnedHostKey(
  type: 'ssh-ed25519',
  fingerprint: 'SHA256:vm',
  pinnedAt: DateTime(2026),
);

Future<VncConnection> _open(VncTunnel tunnel) => tunnel.open(
  address: '10.0.0.2',
  port: 22,
  user: 'dev',
  privateKey: 'key',
  verifier: HostKeyVerifier.pinnedOnly(_pin),
);

Future<VncConnection> _served(VncTunnel tunnel, FakeDial dial) async {
  final opening = _open(tunnel);
  await pumpEventQueue();
  dial.clients.last.forwards.last.wire.feed(serverHandshake());
  return opening;
}

void main() {
  test('a dial that ran out of time does not hang up mid-handshake', () async {
    final keys = Ed25519Keys(MemoryPrivateKeyStore());
    await keys.generate(id: 'k1', name: 'test');
    final privateKey = (await keys.privateKey('k1'))!;
    final tarpit = await openTarpit();
    final links = HostLinks(timeout: const Duration(milliseconds: 300));

    await expectLater(
      VncTunnel(links).open(
        address: tarpit.address,
        port: tarpit.port,
        user: 'luis',
        privateKey: privateKey,
        verifier: HostKeyVerifier.pinnedOnly(null),
      ),
      throwsA(isA<VncUnreachable>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(tarpit.closedByPeer.isCompleted, isFalse);
    links.close();
  });

  test('a refused dial reads as unreachable', () async {
    final links = HostLinks(dial: FakeDial(refuse: true).call);

    await expectLater(_open(VncTunnel(links)), throwsA(isA<VncUnreachable>()));
    links.close();
  });

  test('the screen forwards over the shared link and leaves it up', () async {
    final dial = FakeDial();
    final links = HostLinks(dial: dial.call);
    final held = await links.lease(
      address: '10.0.0.2',
      port: 22,
      user: 'dev',
      privateKey: 'key',
      verifier: HostKeyVerifier.pinnedOnly(_pin),
      use: HostUse.vnc,
    );

    final connection = await _served(VncTunnel(links), dial);
    final client = dial.clients.single;
    expect(dial.dials, 1);
    expect(connection.serverInit.name, 'nyx');

    await connection.close();
    await connection.close();
    expect(client.forwards.single.destroyed, 1);
    expect(client.closes, 0);

    held.release();
    await links.lease(
      address: '10.0.0.2',
      port: 22,
      user: 'dev',
      privateKey: 'key',
      verifier: HostKeyVerifier.pinnedOnly(_pin),
      use: HostUse.vnc,
    );
    expect(dial.dials, 1);
    links.close();
  });

  test(
    'a command on the host answers its exit code until the screen closes',
    () async {
      final dial = FakeDial();
      final links = HostLinks(dial: dial.call);
      final connection = await _served(VncTunnel(links), dial);
      dial.clients.single.reply = (command) =>
          (exitCode: 3, stdout: '', stderr: 'no');

      expect(await connection.run('wayvncctl output-cycle'), 3);
      expect(dial.clients.single.commands, ['wayvncctl output-cycle']);

      await connection.close();
      await expectLater(connection.run('true'), throwsA(anything));
      links.close();
    },
  );

  test('a failed handshake destroys the forward and keeps the link', () async {
    final dial = FakeDial();
    final links = HostLinks(dial: dial.call);
    final opening = _open(VncTunnel(links));
    await pumpEventQueue();
    final client = dial.clients.single;
    unawaited(client.forwards.single.wire.endStream());

    await expectLater(opening, throwsA(isA<VncFailure>()));
    expect(client.forwards.single.destroyed, 1);
    expect(client.closes, 0);
    links.close();
  });

  testWidgets(
    'a forward that never opens fails once, and RETRY after the screen linger redials',
    (tester) async {
      final dial = FakeDial()
        ..prepare = (client) => client.forwardGate = Completer();
      final links = HostLinks(dial: dial.call);
      final tunnel = VncTunnel(links, timeout: const Duration(seconds: 1));
      Object? failure;
      unawaited(
        _open(tunnel).then((_) {}, onError: (Object error) => failure = error),
      );
      await tester.pump();
      final client = dial.clients.single;
      dial.prepare = null;
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      expect(failure, isA<VncUnreachable>());
      expect(client.pings, 0);
      expect(client.isClosed, isFalse);
      await tester.pump(links.screenLinger);
      expect(client.isClosed, isTrue);

      unawaited(_open(tunnel).then((_) {}, onError: (Object _) {}));
      await tester.pump();
      expect(dial.dials, 2);
      expect(dial.clients.last.forwards, hasLength(1));
      links.close();
      await tester.pump(const Duration(seconds: 3));
    },
  );

  test(
    'a forward the host refuses is refused, and nothing is pinged',
    () async {
      final dial = FakeDial()
        ..prepare = (client) => client.forwardError = SSHChannelOpenError(
          1,
          'administratively prohibited',
        );
      final links = HostLinks(dial: dial.call);

      await expectLater(
        _open(VncTunnel(links)),
        throwsA(isA<VncTunnelRefused>()),
      );
      expect(dial.clients.single.pings, 0);
      expect(dial.clients.single.closes, 0);
      links.close();
    },
  );

  test('a forward that lands after its timeout is destroyed', () async {
    final gate = Completer<void>();
    final dial = FakeDial()..prepare = (client) => client.forwardGate = gate;
    final links = HostLinks(dial: dial.call);
    final tunnel = VncTunnel(links, timeout: const Duration(milliseconds: 50));

    await expectLater(_open(tunnel), throwsA(isA<VncUnreachable>()));
    final client = dial.clients.single;
    expect(client.forwards, isEmpty);
    gate.complete();
    await pumpEventQueue();
    expect(client.forwards.single.destroyed, 1);
    expect(client.closes, 0);
    links.close();
  });

  test('host failures keep their own reason on the screen', () {
    expect(asVncFailure(const HerdrUnresolved('x')), isA<VncUnresolved>());
    expect(asVncFailure(const HerdrKeyRejected('x')), isA<VncKeyRejected>());
    expect(
      asVncFailure(const HerdrHostKeyUnverified('x')),
      isA<VncHostKeyUnverified>(),
    );
    expect(
      asVncFailure(const HerdrHostKeyChanged('x')),
      isA<VncHostKeyChanged>(),
    );
    expect(asVncFailure(const HerdrBusy('x')), isA<VncUnreachable>());
    expect(asVncFailure(const HerdrUnreachable('x'))?.detail, 'x');
  });
}
