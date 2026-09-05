import 'package:dartssh2/dartssh2.dart';

import '../host_keys.dart';
import 'rfb_client.dart';
import 'rfb_messages.dart';
import 'vnc_failure.dart';

/// The transport: an RFB stream on a `direct-tcpip` channel inside
/// the host's own ssh connection.
///
/// Nothing here opens a port. `forwardLocal` asks the server to connect to
/// [display] on its own loopback and hands back the two ends of that channel,
/// so wayvnc keeps listening on `127.0.0.1` and the phone never needs a route
/// to it.
class VncTunnel {
  const VncTunnel({
    this.timeout = const Duration(seconds: 10),
    this.keepAlive = const Duration(seconds: 15),
  });

  /// Fixed to the host's own `127.0.0.1:5900` in this section. A
  /// display field waits for the user's word.
  static const displayHost = '127.0.0.1';
  static const displayPort = 5900;

  final Duration timeout;
  final Duration keepAlive;

  /// Opens the ssh connection, then the channel, then completes the RFB
  /// handshake.
  ///
  /// The failure mapping is the agent poll's, one line at a time: a name that
  /// did not
  /// resolve, a machine that did not answer, a key the host would not take,
  /// and — this section's own — a channel the host refused.
  ///
  /// [password] is the host row's VNC password, offered only to a server
  /// whose list has no `None`.
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
      // Half-open is worse than none: an ssh connection left behind counts
      // against the host until its own timeout, and there is no reconnect
      // loop to come back and reuse it.
      await rfb?.close();
      channel?.destroy();
      client.close();
      socket.close();
      rethrow;
    }
  }
}

/// One live screen, whatever is carrying it.
///
/// An interface because the ssh half is the one part that cannot be
/// exercised without a host: a test drives a real [RfbClient] over scripted
/// bytes through its own implementation, which is what makes "disposing the
/// route closes channel and client" a thing that can be asserted.
abstract interface class VncConnection {
  RfbClient get rfb;
  RfbServerInit get serverInit;
  Future<void> close();
}

/// The real one: the ssh connection, the channel inside it, and the RFB client
/// on top. All three close together when the route goes.
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

/// What the controller needs of the transport: open one, get a live screen.
/// The real one is [VncTunnel.open].
typedef VncOpener = Future<VncConnection> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  String? password,
  HostKeyVerifier? verifier,
});
