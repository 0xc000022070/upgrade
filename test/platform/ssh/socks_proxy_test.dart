import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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

void main() {
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

  test('a connect becomes a forward the host resolves, and bytes flow', () async {
    peer.add(_greeting);
    expect(await _read(answers, 2), _greeted);
    peer.add(_connect('localhost', 3000));
    expect(await _read(answers, 10), _granted);
    expect(client.forwardTargets, [('localhost', 3000)]);

    peer.add('GET / HTTP/1.1\r\n'.codeUnits);
    await pumpEventQueue();
    expect(String.fromCharCodes(client.forwards.single.wire.sent), 'GET / HTTP/1.1\r\n');

    client.forwards.single.wire.feed('HTTP/1.1 200 OK\r\n'.codeUnits);
    expect(String.fromCharCodes(await _read(answers, 17)), 'HTTP/1.1 200 OK\r\n');
  });

  test('a forward the host refuses is a refusal, and the peer is let go', () async {
    client.forwardError = const SocketException('refused');
    peer.add([..._greeting, ..._connect('db.lan', 5432)]);
    expect(await _read(answers, 12), [..._greeted, 5, 5, 0, 1, 0, 0, 0, 0, 0, 0]);
    expect(await answers.moveNext(), isFalse);
  });

  test('a peer that offers no method the proxy speaks is turned away', () async {
    peer.add([5, 1, 2]);
    expect(await _read(answers, 2), [5, 0xff]);
    expect(await answers.moveNext(), isFalse);
    expect(client.forwardTargets, isEmpty);
  });
}
