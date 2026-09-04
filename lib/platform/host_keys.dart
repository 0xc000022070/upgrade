import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// The machine's own key as the app keeps it: what kind it is and the OpenSSH
/// fingerprint of it.
///
/// The key itself is not stored. A comparison needs the fingerprint and the
/// user reads the fingerprint, so the bytes would be a copy of something the
/// remote presents on every handshake anyway.
class PinnedHostKey {
  const PinnedHostKey({
    required this.type,
    required this.fingerprint,
    required this.pinnedAt,
  });

  /// `ssh-ed25519`, `rsa-sha2-512`, whatever the transport negotiated.
  final String type;

  /// `SHA256:<base64>`, the form OpenSSH prints and the form dartssh2 hands
  /// the verify callback.
  final String fingerprint;

  final DateTime pinnedAt;

  bool matches(String type, String fingerprint) =>
      this.type == type && this.fingerprint == fingerprint;
}

/// Why a dial was refused before it ever reached authentication.
enum HostKeyRefusal {
  /// Nothing is pinned and nobody could be asked — an unattended dial, or a
  /// user who said no.
  unverified,

  /// Something is pinned and this is not it. A machine reinstalled, or a
  /// machine in the middle; the app cannot tell which and refuses both.
  changed,
}

/// What the sheet is asked about, and what the caller needs to draw it.
class HostKeyOffer {
  const HostKeyOffer({required this.type, required this.fingerprint});

  final String type;
  final String fingerprint;
}

/// Asks the user whether this is the machine. Null everywhere the question
/// cannot be put on screen — the agent poll, the alert watcher, a reconnect —
/// and those refuse an unpinned host instead of asking.
typedef HostKeyPrompt = Future<bool> Function(HostKeyOffer offer);

/// Writes the pin once the user has said yes. Separate from the prompt because
/// the sheet knows nothing about the database and the repository knows nothing
/// about sheets.
typedef HostKeyPin = Future<void> Function(PinnedHostKey key);

/// One dial's worth of host key policy.
///
/// Built per connection because it carries the answer out: the transport's
/// callback can only say yes or no, so the reason it said no is read from
/// [refusal] afterwards, when `SSHHostkeyError` surfaces and has to be turned
/// into a line the user can read.
class HostKeyVerifier {
  HostKeyVerifier({this.pinned, this.prompt, this.pin});

  /// What the host row already trusts, or null for a host that has never been
  /// connected to.
  final PinnedHostKey? pinned;

  final HostKeyPrompt? prompt;
  final HostKeyPin? pin;

  /// Never asks and never pins: every unattended dial in the app.
  factory HostKeyVerifier.pinnedOnly(PinnedHostKey? pinned) =>
      HostKeyVerifier(pinned: pinned);

  HostKeyRefusal? _refusal;

  /// Why the last call to [verify] said no, or null if it never did.
  HostKeyRefusal? get refusal => _refusal;

  /// The callback dartssh2 calls with the key the server presented, before
  /// authentication and before any channel exists.
  ///
  /// [fingerprint] arrives as the UTF-8 bytes of `SHA256:<base64>`; it is
  /// decoded here so nothing above this file has to know that.
  Future<bool> verify(String type, Uint8List fingerprint) =>
      verifyFingerprint(type, utf8.decode(fingerprint, allowMalformed: true));

  /// The same decision on an already-decoded fingerprint, which is what a test
  /// and the ACCESS panel's own verify path both have.
  Future<bool> verifyFingerprint(String type, String fingerprint) async {
    final known = pinned;
    if (known != null) {
      if (known.matches(type, fingerprint)) return true;
      // No override on the connect path. The only way past a changed key is
      // forgetting the pin on the host form, where the user is looking at what
      // they are dropping.
      _refusal = HostKeyRefusal.changed;
      return false;
    }
    final ask = prompt;
    if (ask == null) {
      _refusal = HostKeyRefusal.unverified;
      return false;
    }
    final accepted = await ask(
      HostKeyOffer(type: type, fingerprint: fingerprint),
    );
    if (!accepted) {
      _refusal = HostKeyRefusal.unverified;
      return false;
    }
    await pin?.call(
      PinnedHostKey(
        type: type,
        fingerprint: fingerprint,
        pinnedAt: DateTime.now(),
      ),
    );
    return true;
  }
}

/// The two lines every transport words a host key failure as. One sentence per
/// refusal, the same in the shell's header, on the AGENTS panel and on ACCESS,
/// because it is the same fact wherever it is found.
String hostKeyReason(HostKeyRefusal refusal) => switch (refusal) {
  HostKeyRefusal.unverified => 'host key unverified',
  HostKeyRefusal.changed => 'host key changed',
};
