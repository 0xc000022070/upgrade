import 'package:striked/platform/ssh/host_keys.dart';

/// The machine took the connection and never presented a key: a port that is not ssh, or
/// one of the tarpits that accepts a socket and then says nothing.
class HostKeySilent implements Exception {
  const HostKeySilent();

  @override
  String toString() => 'HostKeySilent';
}

typedef HostKeyDial = Future<void> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  required HostKeyVerifier verifier,
});
