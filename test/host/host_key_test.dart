@Tags(['host'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/platform/ssh/host_failure.dart';
import 'package:upgrade/data/pinned_host_key.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/host_links.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/platform/shell/shell_tunnel.dart';

import '../support/reasons.dart';
import 'fixture.dart';

void main() {
  final tunnel = ShellTunnel();

  late String key;

  setUpAll(() => key = hostVmPrivateKey());

  Future<ShellConnection> open(HostKeyVerifier verifier, [ShellTunnel? over]) =>
      (over ?? tunnel).open(
        reason: UserAction(testIntent()),
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
    await connection.close(UserClosed(testIntent()));
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
      addTearDown(() => connection.close(UserClosed(testIntent())));

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
      // The first dial's link lingers filed under this pin, and reusing it verifies
      // nothing; a pool of its own makes the second open dial and meet the pin.
      final links = HostLinks();
      addTearDown(links.close);
      final connection = await open(verifier, ShellTunnel(links: links));
      addTearDown(() => connection.close(UserClosed(testIntent())));

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
          isA<HostFailure>().having(
            (failure) => failure.kind,
            'kind',
            HostFailureKind.hostKeyUnverified,
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
          isA<HostFailure>().having(
            (failure) => failure.kind,
            'kind',
            HostFailureKind.hostKeyChanged,
          ),
        ),
      );
      expect(verifier.refusal, HostKeyRefusal.changed);
      expect(verifier.verified, isNull);
    },
  );
}
