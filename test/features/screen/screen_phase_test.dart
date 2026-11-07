import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/features/screen/screen_controller.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/vnc/vnc_failure.dart';
import 'package:upgrade/platform/vnc/vnc_tunnel.dart';

import '../../support/vnc_channel.dart';

const _oak = Host(
  id: 'oak',
  name: 'OAK',
  address: '198.51.100.77',
  port: 22,
  user: 'luisnquin',
  keyId: 'k1',
);

Future<VncConnection> _unreachable({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  String? vncUsername,
  String? password,
  HostKeyVerifier? verifier,
}) async => throw const VncUnreachable();

void main() {
  test(
    'a dial that has not answered yet is connecting, and carries no reason',
    () {
      final controller = HostScreenController(
        host: _oak,
        readPrivateKey: (_) async => 'PRIVATE',
        open: _unreachable,
      );
      addTearDown(controller.dispose);

      expect(controller.phase, isA<ScreenConnecting>());
    },
  );

  test('a failure puts its worded line on the phase itself', () async {
    final controller = HostScreenController(
      host: _oak,
      readPrivateKey: (_) async => null,
      open: _unreachable,
    );
    addTearDown(controller.dispose);

    await controller.connect();

    final phase = controller.phase;
    expect(phase, isA<ScreenFailed>());
    expect((phase as ScreenFailed).reason, 'key rejected');
  });

  test('a retry goes back to connecting and drops the line with it', () async {
    final controller = HostScreenController(
      host: _oak,
      readPrivateKey: (_) async => null,
      open: _unreachable,
    );
    addTearDown(controller.dispose);

    await controller.connect();
    expect(controller.phase, isA<ScreenFailed>());

    final dialling = controller.connect();
    expect(controller.phase, isA<ScreenConnecting>());
    await dialling;
  });

  testWidgets(
    'a dial still in flight when the app parks is closed on landing',
    (tester) async {
      final dials = <Completer<VncConnection>>[];
      final controller = HostScreenController(
        host: _oak,
        readPrivateKey: (_) async => 'PRIVATE',
        open:
            ({
              required address,
              required port,
              required user,
              required privateKey,
              vncUsername,
              password,
              required verifier,
            }) {
              dials.add(Completer());
              return dials.last.future;
            },
      );
      addTearDown(controller.dispose);
      unawaited(controller.connect());
      await tester.pump();
      controller.setAway(true);
      await tester.pump(HostScreenController.parkAfter);

      final landed = await tester.runAsync(FakeVncConnection.open);
      dials.single.complete(landed);
      await tester.pump();
      expect(landed!.closed, isTrue);
      expect(controller.phase, isA<ScreenConnecting>());

      controller.setAway(false);
      await tester.pump();
      expect(dials, hasLength(2));
    },
  );

  testWidgets('a dial waiting on the host-key sheet is not parked', (
    tester,
  ) async {
    final asked = <Completer<bool>>[];
    var dials = 0;
    final controller = HostScreenController(
      host: _oak,
      readPrivateKey: (_) async => 'PRIVATE',
      prompt: (offer, pinned) {
        asked.add(Completer());
        return asked.last.future;
      },
      open:
          ({
            required address,
            required port,
            required user,
            required privateKey,
            vncUsername,
            password,
            required verifier,
          }) async {
            dials++;
            await verifier.prompt!(
              const HostKeyOffer(type: 'ssh-ed25519', fingerprint: 'SHA256:x'),
              null,
            );
            throw const VncUnreachable();
          },
    );
    addTearDown(controller.dispose);
    unawaited(controller.connect());
    await tester.pump();
    controller.setAway(true);
    await tester.pump(HostScreenController.parkAfter);
    controller.setAway(false);
    await tester.pump();

    expect(dials, 1);
    expect(asked, hasLength(1));
    asked.single.complete(false);
    await tester.pump();
  });
}
