import 'dart:async';

import 'package:dartssh2/dartssh2.dart';

import '../host_keys.dart';
import '../host_links.dart';
import '../ssh_settle.dart';
import 'rfb_client.dart';
import 'rfb_messages.dart';
import 'vnc_failure.dart';

/// Nothing here opens a port. `forwardLocal` asks the server to connect to [display] on
/// its own loopback, so wayvnc keeps listening on `127.0.0.1` and the phone never needs
/// a route to it.
class VncTunnel {
  const VncTunnel(this.links, {this.timeout = const Duration(seconds: 10)});

  static const displayHost = '127.0.0.1';
  static const displayPort = 5900;

  final HostLinks links;
  final Duration timeout;

  Future<VncConnection> open({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    String? vncUsername,
    String? password,
    HostKeyVerifier? verifier,
  }) async {
    final lease = await guardVnc(
      () => links.lease(
        address: address,
        port: port,
        user: user,
        privateKey: privateKey,
        verifier: verifier,
        caller: 'vnc',
      ),
      verifier,
    );
    SSHForwardChannel? channel;
    RfbClient? rfb;
    try {
      final opened = await guardVnc(
        () => openWithin(
          lease.client.forwardLocal(displayHost, displayPort),
          timeout,
          (opened) => opened.destroy(),
        ),
        verifier,
      );
      channel = opened;
      final client = RfbClient(
        incoming: opened.stream,
        outgoing: opened.sink,
        username: vncUsername,
        password: password,
      );
      rfb = client;
      final init = await guardVnc(
        () => client.handshake().timeout(timeout),
        verifier,
      );
      return SshVncConnection._(lease, opened, client, init);
    } catch (error) {
      await rfb?.close();
      channel?.destroy();
      if (error is VncUnreachable || error is VncStreamClosed) {
        await lease.suspect();
      }
      lease.release();
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
  SshVncConnection._(this._lease, this._channel, this.rfb, this.serverInit);

  final HostLease _lease;
  final SSHForwardChannel _channel;
  var _closed = false;

  @override
  final RfbClient rfb;

  @override
  final RfbServerInit serverInit;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await rfb.close();
    } finally {
      _channel.destroy();
      _lease.release();
    }
  }
}

typedef VncOpener = Future<VncConnection> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  String? vncUsername,
  String? password,
  HostKeyVerifier? verifier,
});
