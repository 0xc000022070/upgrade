import 'package:dartssh2/dartssh2.dart';

import '../host_keys.dart';
import 'rfb_client.dart';
import 'rfb_messages.dart';
import 'vnc_failure.dart';

/// Nothing here opens a port. `forwardLocal` asks the server to connect to [display] on
/// its own loopback, so wayvnc keeps listening on `127.0.0.1` and the phone never needs
/// a route to it.
class VncTunnel {
  const VncTunnel({
    this.timeout = const Duration(seconds: 10),
    this.keepAlive = const Duration(seconds: 15),
  });

  static const displayHost = '127.0.0.1';
  static const displayPort = 5900;

  final Duration timeout;
  final Duration keepAlive;

  Future<VncConnection> open({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    String? password,
    HostKeyVerifier? verifier,
  }) async {
    final socket = await guardVnc(
      () => SSHSocket.connect(address, port, timeout: timeout),
      verifier,
    );
    final client = SSHClient(
      socket,
      username: user,
      identities: SSHKeyPair.fromPem(privateKey),
      handshakeTimeout: timeout,
      authTimeout: timeout,
      keepAliveInterval: keepAlive,
      onVerifyHostKey: verifier?.verify,
    );
    SSHForwardChannel? channel;
    RfbClient? rfb;
    try {
      await guardVnc(() => client.authenticated, verifier);
      final opened = await guardVnc(
        () => client.forwardLocal(displayHost, displayPort),
        verifier,
      );
      channel = opened;
      rfb = RfbClient(
        incoming: opened.stream,
        outgoing: opened.sink,
        password: password,
      );
      final init = await guardVnc(rfb.handshake, verifier);
      return SshVncConnection._(socket, client, opened, rfb, init);
    } catch (_) {
      // Half-open is worse than none: an ssh connection left behind counts against the host
      // until its own timeout.
      await rfb?.close();
      channel?.destroy();
      client.close();
      socket.close();
      rethrow;
    }
  }
}

abstract interface class VncConnection {
  RfbClient get rfb;
  RfbServerInit get serverInit;
  Future<void> close();
}

class SshVncConnection implements VncConnection {
  SshVncConnection._(
    this._socket,
    this._client,
    this._channel,
    this.rfb,
    this.serverInit,
  );

  final SSHSocket _socket;
  final SSHClient _client;
  final SSHForwardChannel _channel;

  @override
  final RfbClient rfb;

  @override
  final RfbServerInit serverInit;

  @override
  Future<void> close() async {
    await rfb.close();
    _channel.destroy();
    _client.close();
    _socket.close();
  }
}

typedef VncOpener = Future<VncConnection> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  String? password,
  HostKeyVerifier? verifier,
});
