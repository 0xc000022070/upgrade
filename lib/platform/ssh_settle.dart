import 'dart:async';

import 'package:dartssh2/dartssh2.dart';

const sshLoginGrace = Duration(minutes: 2);

/// A client nobody is waiting for any more still finishes authenticating and is closed
/// after: sshd counts a client that leaves mid-userauth as a failed login against the phone.
Future<void> closeSettled(SSHClient client, SSHSocket socket) async {
  await client.authenticated
      .then((_) {}, onError: (Object _) {})
      .timeout(sshLoginGrace, onTimeout: () {});
  await closeSsh(client, socket);
}

Future<void> closeSsh(SSHClient client, SSHSocket socket) async {
  client.close();
  await socket.close().catchError((Object _) {});
}
