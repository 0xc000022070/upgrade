import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../application/reason_lines.dart';

/// A host key the user accepted, kept as its fingerprint alone. Comparing keys and showing
/// one to the user both need only the fingerprint, and the host sends the full key on every
/// handshake anyway.
class PinnedHostKey {
  const PinnedHostKey({
    required this.type,
    required this.fingerprint,
    required this.pinnedAt,
  });

  final String type;

  /// `SHA256:<base64>`, the form OpenSSH prints and the form dartssh2 hands the verify
  /// callback.
  final String fingerprint;

  final DateTime pinnedAt;

  bool matches(String type, String fingerprint) =>
      this.type == type && this.fingerprint == fingerprint;
}

enum HostKeyRefusal { unverified, changed }

class HostKeyOffer {
  const HostKeyOffer({required this.type, required this.fingerprint});

  final String type;
  final String fingerprint;
}

/// Asks the user about a host key. Null wherever nobody can be asked, such as the agent
/// poll, the alert watcher or a reconnect; those refuse an unpinned host instead.
typedef HostKeyPrompt = Future<bool> Function(
  HostKeyOffer offer,
  PinnedHostKey? pinned,
);

typedef HostKeyPin = Future<void> Function(PinnedHostKey key);

/// Build one per connection, because it carries the answer out: the transport's callback can
/// only say yes or no, so why it said no is read from [refusal] afterwards.
class HostKeyVerifier {
  HostKeyVerifier({this.pinned, this.prompt, this.pin});

  final PinnedHostKey? pinned;

  final HostKeyPrompt? prompt;
  final HostKeyPin? pin;

  factory HostKeyVerifier.pinnedOnly(PinnedHostKey? pinned) =>
      HostKeyVerifier(pinned: pinned);

  HostKeyRefusal? _refusal;
  PinnedHostKey? _verified;
  final _offered = Completer<void>();
  final _answered = Completer<void>();

  Future<void> get offered => _offered.future;

  Future<void> get answered => _answered.future;

  HostKeyRefusal? get refusal => _refusal;

  PinnedHostKey? get verified => _verified;

  /// [fingerprint] arrives as the UTF-8 bytes of `SHA256:<base64>`; it is decoded here so
  /// nothing above this file has to know that.
  Future<bool> verify(String type, Uint8List fingerprint) =>
      verifyFingerprint(type, utf8.decode(fingerprint, allowMalformed: true));

  Future<bool> verifyFingerprint(String type, String fingerprint) async {
    if (!_offered.isCompleted) _offered.complete();
    try {
      return await _decide(type, fingerprint);
    } finally {
      if (!_answered.isCompleted) _answered.complete();
    }
  }

  Future<bool> _decide(String type, String fingerprint) async {
    final known = pinned;
    if (known != null) {
      if (known.matches(type, fingerprint)) {
        _verified = known;
        return true;
      }
      final ask = prompt;
      if (ask == null ||
          !await ask(
            HostKeyOffer(type: type, fingerprint: fingerprint),
            known,
          )) {
        _refusal = HostKeyRefusal.changed;
        return false;
      }
      return _accept(type, fingerprint);
    }
    final ask = prompt;
    if (ask == null) {
      _refusal = HostKeyRefusal.unverified;
      return false;
    }
    final approved = await ask(
      HostKeyOffer(type: type, fingerprint: fingerprint),
      null,
    );
    if (!approved) {
      _refusal = HostKeyRefusal.unverified;
      return false;
    }
    return _accept(type, fingerprint);
  }

  Future<bool> _accept(String type, String fingerprint) async {
    final accepted = PinnedHostKey(
      type: type,
      fingerprint: fingerprint,
      pinnedAt: DateTime.now(),
    );
    await pin?.call(accepted);
    _verified = accepted;
    return true;
  }
}

Future<void> authenticatedWithin(
  Future<void> authenticated,
  HostKeyVerifier verifier,
  Duration timeout,
) async {
  await Future.any([authenticated, verifier.offered]).timeout(timeout);
  await Future.any([authenticated, verifier.answered]);
  await authenticated.timeout(timeout);
}

extension HostKeyRefusalLine on HostKeyRefusal {
  ReasonLine get line => switch (this) {
    HostKeyRefusal.unverified => ReasonLine.hostKeyUnverified,
    HostKeyRefusal.changed => ReasonLine.hostKeyChanged,
  };
}
