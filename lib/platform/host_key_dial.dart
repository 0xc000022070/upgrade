import 'package:dartssh2/dartssh2.dart';

import 'host_keys.dart';

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

Future<void> dialHostKey({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  required HostKeyVerifier verifier,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final socket = await SSHSocket.connect(address, port, timeout: timeout);
  final client = SSHClient(
    socket,
    username: user,
    identities: SSHKeyPair.fromPem(privateKey),
    handshakeTimeout: timeout,
    authTimeout: timeout,
    onVerifyHostKey: verifier.verify,
  );
  try {
    await client.authenticated;
  } finally {
    client.close();
    socket.close();
  }
}
