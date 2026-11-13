import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/platform/ssh/socks_proxy.dart';

import '../../support/host_links.dart';

const _greeting = [5, 1, 0];
const _greeted = [5, 0];
const _granted = [5, 0, 0, 1, 0, 0, 0, 0, 0, 0];

List<int> _connect(String host, int port) => [
  5,
  1,
  0,
  3,
  host.length,
  ...host.codeUnits,
  port >> 8,
  port & 0xff,
];

Future<List<int>> _read(StreamIterator<Uint8List> peer, int count) async {
  final out = <int>[];
  while (out.length < count) {
    if (!await peer.moveNext()) break;
    out.addAll(peer.current);
  }
  return out;
}

final class _Files implements SftpClient {
  static const tree = {'/lab/index.html': '<p>hi</p>', '/lab/a.css': 'p{}'};

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    if (path == '/lab' || path == '/lab/') {
      return SftpFileAttrs(mode: const SftpFileMode.value(0x41ed));
    }
    final body = tree[path];
    if (body == null) throw SftpStatusError(2, 'no such file');
    return SftpFileAttrs(size: body.length);
  }

  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async => _File(tree[path]!);

  @override
  Future<void> close() async {}

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _File implements SftpFile {
  _File(this.body);

  final String body;

  @override
  Stream<Uint8List> read({
    int? length,
    int offset = 0,
    void Function(int bytesRead)? onProgress,
    int chunkSize = 0,
    int maxPendingRequests = 0,
  }) => Stream.value(Uint8List.fromList(body.codeUnits));

  @override
  Future<void> close() async {}

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<String> _get(String path) async {
  final proxy = await SocksProxy.bind(FakeLinkClient()..files = _Files());
  final peer = await Socket.connect(InternetAddress.loopbackIPv4, proxy.port);
  peer.add([
    ..._greeting,
    ..._connect(hostFiles, 80),
    ...'GET $path HTTP/1.1\r\nHost: x\r\n\r\n'.codeUnits,
  ]);
  final bytes = await peer.expand((chunk) => chunk).toList();
  await proxy.close();
  return String.fromCharCodes(bytes.skip(12));
}

void main() {
  test('the host\'s files are served over sftp under their own name', () async {
    final page = await _get('/lab/');
    expect(page, startsWith('HTTP/1.1 200'));
    expect(page, contains('Content-Type: text/html'));
    expect(page, endsWith('\r\n\r\n<p>hi</p>'));
    expect(await _get('/lab/a.css'), contains('text/css'));
    expect(await _get('/lab'), contains('Location: /lab/'));
    expect(await _get('/lab/gone.js'), startsWith('HTTP/1.1 404'));
  });

  late FakeLinkClient client;
  late SocksProxy proxy;
  late Socket peer;
  late StreamIterator<Uint8List> answers;

  setUp(() async {
    client = FakeLinkClient();
    proxy = await SocksProxy.bind(client);
    peer = await Socket.connect(InternetAddress.loopbackIPv4, proxy.port);
    answers = StreamIterator(peer);
  });

  tearDown(() async {
    peer.destroy();
    await proxy.close();
  });

  test(
    'a connect becomes a forward the host resolves, and bytes flow',
    () async {
      peer.add(_greeting);
      expect(await _read(answers, 2), _greeted);
      peer.add(_connect('localhost', 3000));
      expect(await _read(answers, 10), _granted);
      expect(client.forwardTargets, [('localhost', 3000)]);

      peer.add('GET / HTTP/1.1\r\n'.codeUnits);
      await pumpEventQueue();
      expect(
        String.fromCharCodes(client.forwards.single.wire.sent),
        'GET / HTTP/1.1\r\n',
      );

      client.forwards.single.wire.feed('HTTP/1.1 200 OK\r\n'.codeUnits);
      expect(
        String.fromCharCodes(await _read(answers, 17)),
        'HTTP/1.1 200 OK\r\n',
      );
    },
  );

  test(
    'a forward the host refuses is a refusal, and the peer is let go',
    () async {
      client.forwardError = const SocketException('refused');
      peer.add([..._greeting, ..._connect('db.lan', 5432)]);
      expect(await _read(answers, 12), [
        ..._greeted,
        5,
        5,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        0,
      ]);
      expect(await answers.moveNext(), isFalse);
    },
  );

  test(
    'a peer that offers no method the proxy speaks is turned away',
    () async {
      peer.add([5, 1, 2]);
      expect(await _read(answers, 2), [5, 0xff]);
      expect(await answers.moveNext(), isFalse);
      expect(client.forwardTargets, isEmpty);
    },
  );
}
