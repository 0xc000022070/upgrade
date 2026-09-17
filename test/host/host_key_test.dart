@Tags(['host'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/platform/host_keys.dart';
import 'package:dazzle/platform/shell/shell_connection.dart';
import 'package:dazzle/platform/shell/shell_tunnel.dart';

import 'fixture.dart';

/// Host key policy against a machine that has one.
///
/// A fake verifier proves the branches; it cannot prove that the fingerprint
/// dartssh2 hands the callback is the shape the pin is written and compared
/// in. That is one string format shared by the transport, the database and the
/// sheet the user reads, and it is only ever checked here.
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

  /// Trusts whatever the guest presents and keeps it, which is what the sheet
  /// does when the user taps TRUST.
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

  test('a first dial asks, and TRUST writes the key the guest presented', () async {
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
    // The shape is the contract: OpenSSH's own SHA256 form, unpadded, which is
    // what the user compares against `ssh-keygen -lf` and what `matches`
    // compares string-wise on every later dial.
    expect(
      offers.single.fingerprint,
      matches(RegExp(r'^SHA256:[A-Za-z0-9+/]{43}$')),
    );
    expect(offers.single.type, startsWith('ssh-'));
    expect(written, isNotNull);
    expect(written!.fingerprint, offers.single.fingerprint);
    expect(verifier.refusal, isNull);
  });

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
      // No prompt, which is what every unattended dial in the app carries: the
      // poll, the watcher and the send refuse a host they cannot vouch for
      // rather than ask a question nobody is there to answer.
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
