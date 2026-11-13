import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:mime/mime.dart';

/// The name the proxy answers itself, with the host's own files read over sftp.
/// `.invalid` never resolves, so no real site is shadowed.
const hostFiles = 'files.upgrade.invalid';

/// `ssh -D` on the phone: every CONNECT becomes a `direct-tcpip` channel on [client], so
/// the name in the request is resolved by the host and `localhost` is the host's.
class SocksProxy {
  SocksProxy._(this._server, this._client);

  final ServerSocket _server;
  final SSHClient _client;
  final _peers = <Socket>{};
  Future<SftpClient>? _sftp;

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
    final sftp = _sftp;
    _sftp = null;
    try {
      await (await sftp)?.close();
    } catch (_) {
      // ignored: a subsystem that never opened has nothing to close
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
      if (host == hostFiles) {
        peer.add(_reply(0));
        while (!_ended(pending)) {
          if (pending.length > 65536 || !await chunks.moveNext()) return;
          pending = [...pending, ...chunks.current];
        }
        final line = latin1.decode(pending).split('\r\n').first.split(' ');
        await _file(
          peer,
          head: line.first == 'HEAD',
          path: Uri.decodeComponent(
            Uri.parse(line.elementAtOrNull(1) ?? '/').path,
          ),
        );
        await peer.flush();
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

  static bool _ended(List<int> bytes) {
    for (var i = 3; i < bytes.length; i++) {
      if (bytes[i - 3] == 13 &&
          bytes[i - 2] == 10 &&
          bytes[i - 1] == 13 &&
          bytes[i] == 10) {
        return true;
      }
    }
    return false;
  }

  /// One request per connection, never cached: the file is being edited while it is read.
  Future<void> _file(
    Socket peer, {
    required bool head,
    required String path,
  }) async {
    void answer(
      int code,
      Map<String, Object> fields, [
      List<int> body = const [],
    ]) {
      peer.add(
        latin1.encode(
          [
            'HTTP/1.1 $code',
            'Connection: close',
            'Cache-Control: no-store',
            if (code != 200) 'Content-Length: ${body.length}',
            for (final field in fields.entries) '${field.key}: ${field.value}',
            '\r\n',
          ].join('\r\n'),
        ),
      );
      if (!head) peer.add(body);
    }

    try {
      final sftp = await (_sftp ??= _client.sftp());
      var target = path;
      var attrs = await sftp.stat(target);
      if (attrs.isDirectory) {
        if (!target.endsWith('/')) {
          answer(301, {'Location': Uri(path: '$target/').toString()});
          return;
        }
        target = '${target}index.html';
        attrs = await sftp.stat(target);
      }
      final file = await sftp.open(target);
      try {
        answer(200, {
          'Content-Type': lookupMimeType(target) ?? 'text/plain; charset=utf-8',
          'Content-Length': ?attrs.size,
        });
        if (!head) await peer.addStream(file.read());
      } finally {
        await file.close();
      }
    } on SftpStatusError catch (error) {
      final code = switch (error.code) {
        2 => 404,
        3 => 403,
        _ => 502,
      };
      answer(code, {
        'Content-Type': 'text/plain; charset=utf-8',
      }, utf8.encode('$path: ${error.message}'));
    } catch (error) {
      _sftp = null;
      answer(502, {
        'Content-Type': 'text/plain; charset=utf-8',
      }, utf8.encode('$path: $error'));
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
