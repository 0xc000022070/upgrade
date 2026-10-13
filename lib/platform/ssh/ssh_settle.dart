import 'dart:async';

import 'package:dartssh2/dartssh2.dart';

const sshLoginGrace = Duration(minutes: 2);

const sshKeepAlive = Duration(seconds: 60);

/// Lets a client nobody waits for finish authenticating, then closes it: sshd counts a client
/// that leaves mid-userauth as a failed login against the phone.
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

Future<T> openWithin<T>(
  Future<T> opening,
  Duration within,
  void Function(T opened) discard,
) => opening.timeout(
  within,
  onTimeout: () {
    opening.then(discard, onError: (Object _) {});
    throw TimeoutException('channel open', within);
  },
);

void endExec(SSHSession session) {
  try {
    session.kill(SSHSignal.TERM);
  } catch (_) {
    // ignored: a terminated channel cannot take a signal, and destroy still runs
  }
  session.channel.destroy();
}
