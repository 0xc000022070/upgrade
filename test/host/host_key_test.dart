@Tags(['host'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/platform/host_keys.dart';
import 'package:dazzle/platform/shell/shell_connection.dart';
import 'package:dazzle/platform/shell/shell_tunnel.dart';

import 'fixture.dart';

void main() {
  const tunnel = ShellTunnel();

  late String key;

  setUpAll(() => key = hostVmPrivateKey());

  Future<ShellConnection> open(HostKeyVerifier verifier) => tunnel.open(
    address: hostVm.address,
    port: hostVm.port,
    user: hostVm.user,
    privateKey: key,
    columns: 80,
    rows: 24,
    command: 'true',
    verifier: verifier,
  );

  Future<PinnedHostKey> trustOnFirstDial() async {
    PinnedHostKey? written;
    final verifier = HostKeyVerifier(
      prompt: (_, _) async => true,
      pin: (pinned) async => written = pinned,
    );
    final connection = await open(verifier);
    await connection.close();
    return written!;
  }

  test(
    'a first dial asks, and TRUST writes the key the guest presented',
    () async {
      final offers = <HostKeyOffer>[];
      PinnedHostKey? written;
      final verifier = HostKeyVerifier(
        prompt: (offer, pinned) async {
          offers.add(offer);
          expect(pinned, isNull);
          return true;
        },
        pin: (pinned) async => written = pinned,
      );

      final connection = await open(verifier);
      addTearDown(connection.close);

      expect(offers, hasLength(1));
      // OpenSSH's own SHA256 form, unpadded, which is what the user compares against
      // `ssh-keygen -lf` and what `matches` compares string-wise on every later dial.
      expect(
        offers.single.fingerprint,
        matches(RegExp(r'^SHA256:[A-Za-z0-9+/]{43}$')),
      );
      expect(offers.single.type, startsWith('ssh-'));
      expect(written, isNotNull);
      expect(written!.fingerprint, offers.single.fingerprint);
      expect(verifier.refusal, isNull);
    },
  );

  test(
    'the key written on the first dial opens the second without asking',
    () async {
      final pinned = await trustOnFirstDial();

      var asked = false;
      final verifier = HostKeyVerifier(
        pinned: pinned,
        prompt: (_, _) async {
          asked = true;
          return true;
        },
      );
      final connection = await open(verifier);
      addTearDown(connection.close);

      expect(asked, isFalse);
      expect(verifier.verified?.fingerprint, pinned.fingerprint);
    },
  );

  test(
    'an unpinned host nobody can be asked about is host key unverified',
    () async {
      final verifier = HostKeyVerifier.pinnedOnly(null);

      await expectLater(
        open(verifier),
        throwsA(
          isA<ShellFailure>().having(
            (failure) => failure.kind,
            'kind',
            ShellFailureKind.hostKeyUnverified,
          ),
        ),
      );
      expect(verifier.refusal, HostKeyRefusal.unverified);
    },
  );

  test(
    'a pin that is not the key the guest presents is host key changed',
    () async {
      final real = await trustOnFirstDial();
      final wrong = PinnedHostKey(
        type: real.type,
        fingerprint: 'SHA256:${'A' * 43}',
        pinnedAt: DateTime.utc(2026),
      );
      final verifier = HostKeyVerifier.pinnedOnly(wrong);

      await expectLater(
        open(verifier),
        throwsA(
          isA<ShellFailure>().having(
            (failure) => failure.kind,
            'kind',
            ShellFailureKind.hostKeyChanged,
          ),
        ),
      );
      expect(verifier.refusal, HostKeyRefusal.changed);
      expect(verifier.verified, isNull);
    },
  );
}
