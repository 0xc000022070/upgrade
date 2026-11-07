import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// `ssh -D` on the phone: every CONNECT becomes a `direct-tcpip` channel on [client], so
/// the name in the request is resolved by the host and `localhost` is the host's.
class SocksProxy {
  SocksProxy._(this._server, this._client);

  final ServerSocket _server;
  final SSHClient _client;
  final _peers = <Socket>{};

  int get port => _server.port;

  static Future<SocksProxy> bind(SSHClient client) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = SocksProxy._(server, client);
    server.listen(proxy._serve, onError: (Object _) {});
    return proxy;
  }

  Future<void> close() async {
    await _server.close();
    for (final peer in _peers.toList()) {
      peer.destroy();
    }
  }

  Future<void> _serve(Socket peer) async {
    _peers.add(peer);
    final chunks = StreamIterator<Uint8List>(peer);
    var pending = <int>[];
    Future<List<int>> take(int count) async {
      while (pending.length < count) {
        if (!await chunks.moveNext()) throw const SocketException('peer gone');
        pending = [...pending, ...chunks.current];
      }
      final taken = pending.sublist(0, count);
      pending = pending.sublist(count);
      return taken;
    }

    SSHForwardChannel? channel;
    try {
      final greeting = await take(2);
      final methods = await take(greeting[1]);
      if (greeting[0] != 5 || !methods.contains(0)) {
        peer.add(const [5, 0xff]);
        return;
      }
      peer.add(const [5, 0]);

      final head = await take(4);
      final host = switch (head[3]) {
        1 => (await take(4)).join('.'),
        3 => String.fromCharCodes(await take((await take(1))[0])),
        4 => _ipv6(await take(16)),
        _ => null,
      };
      final portBytes = await take(2);
      final target = (portBytes[0] << 8) | portBytes[1];
      if (head[1] != 1 || host == null) {
        peer.add(_reply(7));
        return;
      }
      try {
        channel = await _client.forwardLocal(host, target);
      } catch (_) {
        peer.add(_reply(5));
        return;
      }
      peer.add(_reply(0));

      final opened = channel;
      unawaited(
        opened.stream
            .listen(peer.add, onDone: peer.destroy, onError: (Object _) {})
            .asFuture<void>()
            // ignored: a channel that dies mid-page just ends this peer, which the finally does
            .catchError((Object _) {}),
      );
      if (pending.isNotEmpty) opened.sink.add(pending);
      while (await chunks.moveNext()) {
        opened.sink.add(chunks.current);
      }
    } catch (_) {
      // ignored: the peer hung up or wrote something that is not SOCKS; either way it is gone
    } finally {
      channel?.destroy();
      peer.destroy();
      _peers.remove(peer);
    }
  }

  static List<int> _reply(int code) => [5, code, 0, 1, 0, 0, 0, 0, 0, 0];

  static String _ipv6(List<int> bytes) {
    final groups = <String>[];
    for (var i = 0; i < 16; i += 2) {
      groups.add(((bytes[i] << 8) | bytes[i + 1]).toRadixString(16));
    }
    return groups.join(':');
  }
}
