import 'dart:async';

import 'package:dartssh2/dartssh2.dart';

import 'host_keys.dart';

/// The machine took the connection and never presented a key: a port that is
/// not ssh, or one of the tarpits that accepts a socket and then says nothing.
class HostKeySilent implements Exception {
  const HostKeySilent();

  @override
  String toString() => 'HostKeySilent';
}

/// Dials far enough to see the host key and no further.
///
/// `VERIFY` on ACCESS has nothing to open — no shell, no screen, no agent — so
/// this is the smallest thing that makes a machine present its key: the
/// handshake runs, the verifier answers, and the connection is dropped whether
/// authentication would have succeeded or not.
typedef HostKeyDial = Future<void> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  required HostKeyVerifier verifier,
});

/// Returns once the key has been answered for — accepted, refused or pinned;
/// the answer itself is read off the verifier. Throws [HostKeySilent] when no
/// key arrives within [timeout], and whatever the transport threw when it died
/// before offering one.
Future<void> dialHostKey({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  required HostKeyVerifier verifier,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final offered = Completer<void>();
  final decided = Completer<void>();
  final broken = Completer<void>();
  final socket = await SSHSocket.connect(address, port, timeout: timeout);
  final client = SSHClient(
    socket,
    username: user,
    identities: SSHKeyPair.fromPem(privateKey),
    // The sheet is answered inside this handshake, so dartssh2's own deadline
    // counts the time the user spends reading a fingerprint and drops the
    // connection under an open sheet. What the deadline is there for — a
    // machine that never presents a key at all — is timed below instead, and
    // stops the moment the key is on screen.
    handshakeTimeout: _openEnded,
    authTimeout: timeout,
    onVerifyHostKey: (type, fingerprint) async {
      if (!offered.isCompleted) offered.complete();
      try {
        return await verifier.verify(type, fingerprint);
      } finally {
        if (!decided.isCompleted) decided.complete();
      }
    },
  );
  // Authentication is not what this dial is for and its result is thrown away.
  // It is listened to because a transport that dies before the key surfaces
  // here and nowhere else.
  unawaited(
    client.authenticated.then(
      (_) {},
      onError: (Object error, StackTrace stack) {
        if (!broken.isCompleted) broken.completeError(error, stack);
      },
    ),
  );
  try {
    await Future.any([offered.future, broken.future])
        .timeout(timeout, onTimeout: () => throw const HostKeySilent());
    await decided.future;
    // dartssh2 sends NEWKEYS the moment the verifier answers, and closing the
    // socket in that gap throws inside its own handler, where nothing can
    // catch it. Waiting the round out costs nothing: it is already decided.
    await client.authenticated
        .timeout(timeout)
        .then((_) {}, onError: (_, _) {});
  } finally {
    client.close();
    socket.close();
  }
}

/// Long enough that dartssh2's handshake deadline never fires. The dial's own
/// deadline is the one that matters and it is armed separately.
const _openEnded = Duration(days: 1);
