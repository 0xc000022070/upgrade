import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/platform/herdr_client.dart';
import 'package:spectacle/platform/host_keys.dart';
import 'package:spectacle/platform/shell/shell_connection.dart';
import 'package:spectacle/platform/shell/shell_tunnel.dart';
import 'package:spectacle/platform/vnc/vnc_failure.dart';

const _type = 'ssh-ed25519';
const _fingerprint = 'SHA256:1qF0mVZjnJ4tvJq2VbT8Kk9Yo0oRr3Q5nWZs1eJqk2A';
const _other = 'SHA256:0000000000000000000000000000000000000000000';

PinnedHostKey _pin(String fingerprint) => PinnedHostKey(
  type: _type,
  fingerprint: fingerprint,
  pinnedAt: DateTime.utc(2026, 9, 3),
);

Uint8List _bytes(String fingerprint) =>
    Uint8List.fromList(utf8.encode(fingerprint));

void main() {
  test('an unpinned host is asked about once and pinned on TRUST', () async {
    final asked = <HostKeyOffer>[];
    final written = <PinnedHostKey>[];
    final verifier = HostKeyVerifier(
      prompt: (offer) async {
        asked.add(offer);
        return true;
      },
      pin: (key) async => written.add(key),
    );

    expect(await verifier.verify(_type, _bytes(_fingerprint)), isTrue);

    expect(asked.single.type, _type);
    expect(asked.single.fingerprint, _fingerprint);
    expect(written.single.fingerprint, _fingerprint);
    expect(written.single.type, _type);
    expect(verifier.refusal, isNull);
  });

  test('REJECT fails the dial as unverified and writes nothing', () async {
    final written = <PinnedHostKey>[];
    final verifier = HostKeyVerifier(
      prompt: (_) async => false,
      pin: (key) async => written.add(key),
    );

    expect(await verifier.verify(_type, _bytes(_fingerprint)), isFalse);
    expect(verifier.refusal, HostKeyRefusal.unverified);
    expect(written, isEmpty);
  });

  test('a pinned host that matches is not asked about at all', () async {
    var asked = false;
    final verifier = HostKeyVerifier(
      pinned: _pin(_fingerprint),
      prompt: (_) async {
        asked = true;
        return true;
      },
    );

    expect(await verifier.verify(_type, _bytes(_fingerprint)), isTrue);
    expect(asked, isFalse);
    expect(verifier.refusal, isNull);
  });

  test(
    'a fingerprint that differs from the pin is refused, never asked about',
    () async {
      var asked = false;
      final verifier = HostKeyVerifier(
        pinned: _pin(_fingerprint),
        prompt: (_) async {
          asked = true;
          return true;
        },
      );

      expect(await verifier.verify(_type, _bytes(_other)), isFalse);
      expect(asked, isFalse);
      expect(verifier.refusal, HostKeyRefusal.changed);
    },
  );

  test(
    'a key type that differs is a changed key, fingerprint or not',
    () async {
      final verifier = HostKeyVerifier(pinned: _pin(_fingerprint));

      expect(
        await verifier.verify('rsa-sha2-512', _bytes(_fingerprint)),
        isFalse,
      );
      expect(verifier.refusal, HostKeyRefusal.changed);
    },
  );

  test('an unattended dial refuses an unpinned host without asking', () async {
    final verifier = HostKeyVerifier.pinnedOnly(null);

    expect(await verifier.verify(_type, _bytes(_fingerprint)), isFalse);
    expect(verifier.refusal, HostKeyRefusal.unverified);
  });

  test('the three transports word both refusals the same way', () {
    final error = SSHStateError('connection closed');

    expect(
      shellFailureFor(error, HostKeyRefusal.unverified)?.kind,
      ShellFailureKind.hostKeyUnverified,
    );
    expect(
      shellFailureFor(error, HostKeyRefusal.changed)?.kind,
      ShellFailureKind.hostKeyChanged,
    );
    expect(
      asVncFailure(error, HostKeyRefusal.unverified),
      isA<VncHostKeyUnverified>(),
    );
    expect(
      asVncFailure(error, HostKeyRefusal.changed),
      isA<VncHostKeyChanged>(),
    );
    expect(
      asHerdrFailure(error, HostKeyRefusal.unverified),
      isA<HerdrHostKeyUnverified>(),
    );
    expect(
      asHerdrFailure(error, HostKeyRefusal.changed),
      isA<HerdrHostKeyChanged>(),
    );
  });

  test('a key swapped mid-session is a changed key wherever it surfaces', () {
    final error = SSHHostkeyError('host key changed');

    expect(shellFailureFor(error)?.kind, ShellFailureKind.hostKeyChanged);
    expect(asVncFailure(error), isA<VncHostKeyChanged>());
    expect(asHerdrFailure(error), isA<HerdrHostKeyChanged>());
  });

  test('both refusals read as one sentence each', () {
    expect(HostKeyRefusal.unverified.line.words, 'host key unverified');
    expect(HostKeyRefusal.changed.line.words, 'host key changed');
    // The screen route asks the failure for its line; the host's name is not
    // in either of these two, which is the point of them being one sentence.
    expect(
      VncHostKeyChanged('x').reason('nyx'),
      HostKeyRefusal.changed.line.words,
    );
    expect(
      VncHostKeyUnverified('x').reason('nyx'),
      HostKeyRefusal.unverified.line.words,
    );
  });
}
