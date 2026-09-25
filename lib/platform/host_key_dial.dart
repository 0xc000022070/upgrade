import 'dart:async';

import 'package:dartssh2/dartssh2.dart';

import 'host_keys.dart';
import 'ssh_settle.dart';

/// The machine took the connection and never presented a key: a port that is not ssh, or
/// one of the tarpits that accepts a socket and then says nothing.
class HostKeySilent implements Exception {
  const HostKeySilent();

  @override
  String toString() => 'HostKeySilent';
}

/// The smallest thing that makes a machine present its key: the handshake runs, the
/// verifier answers, and the connection is dropped whether authentication would have
/// succeeded or not.
typedef HostKeyDial = Future<void> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  required HostKeyVerifier verifier,
});

/// Throws [HostKeySilent] when no key arrives within [timeout], and whatever the
/// transport threw when it died before offering one.
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
    keepAliveInterval: sshKeepAlive,
    onVerifyHostKey: (type, fingerprint) async {
      if (!offered.isCompleted) offered.complete();
      try {
        return await verifier.verify(type, fingerprint);
      } finally {
        if (!decided.isCompleted) decided.complete();
      }
    },
  );
  // Authentication is not what this dial is for and its result is thrown away. It is
  // listened to because a transport that dies before the key surfaces here and nowhere
  // else.
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
  } finally {
    unawaited(
      offered.isCompleted
          ? closeSettled(client, socket)
          : closeSsh(client, socket),
    );
  }
}
