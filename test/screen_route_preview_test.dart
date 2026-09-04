/// What the screen route leaves behind: the controller holding on to the last
/// frame that became an image, and the route storing it for the host's tile on
/// the way out.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/application/agents.dart';
import 'package:hotline/data/repositories/host_repository.dart';
import 'package:hotline/features/screen/host_screen.dart';
import 'package:hotline/features/screen/screen_controller.dart';
import 'package:hotline/features/screen/screen_preview.dart';
import 'package:hotline/platform/keys.dart';
import 'package:hotline/platform/vnc/rfb_client.dart';
import 'package:hotline/platform/vnc/rfb_messages.dart';
import 'package:hotline/platform/vnc/vnc_tunnel.dart';

import 'support/vnc_channel.dart';

const _nyx = Host(
  id: 'h1',
  name: 'nyx',
  address: '10.0.2.2',
  port: 357,
  user: 'luisnquin',
  keyId: 'k1',
);

/// A screen carried by scripted bytes. The client is the real one; only the
/// ssh channel is faked, so the frames the controller sees are parsed rather
/// than handed over.
class _FakeConnection implements VncConnection {
  _FakeConnection._(this._channel, this.rfb, this.serverInit);

  static Future<_FakeConnection> open({int width = 16, int height = 8}) async {
    final channel = FakeVncChannel();
    final rfb = RfbClient(incoming: channel.stream, outgoing: channel.sink);
    channel.feed(serverHandshake(width: width, height: height));
    return _FakeConnection._(channel, rfb, await rfb.handshake());
  }

  final FakeVncChannel _channel;

  @override
  final RfbClient rfb;

  @override
  final RfbServerInit serverInit;

  /// One Raw pixel, which is all the controller needs to build an image and
  /// all the route needs to have something to store.
  void feedPixel(int x, int y, List<int> bgrx) {
    _channel.feed([
      Rfb.serverFramebufferUpdate,
      ...updateHeader(1),
      ...rectHeader(x: x, y: y, width: 1, height: 1, encoding: Rfb.encodingRaw),
      ...bgrx,
    ]);
  }

  @override
  Future<void> close() async {
    await rfb.close();
    await _channel.dispose();
  }
}

VncOpener _opener(_FakeConnection connection) =>
    ({
      required String address,
      required int port,
      required String user,
      required String privateKey,
    }) async => connection;

/// Decoding is real async, which the fake clock a widget test runs on never
/// advances: every wait here has to happen on the real one.
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue);
}

void main() {
  testWidgets('the controller holds the last frame it turned into an image', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final connection = await _FakeConnection.open();
      final controller = HostScreenController(
        host: _nyx,
        readPrivateKey: (_) async => 'PRIVATE',
        open: _opener(connection),
      );
      addTearDown(controller.dispose);

      await controller.connect();
      expect(
        controller.lastFramebuffer,
        isNull,
        reason: 'nothing has arrived yet',
      );

      connection.feedPixel(0, 0, const [0x11, 0x22, 0x33, 0x00]);
      await _until(() => controller.lastFramebuffer != null);

      final first = controller.lastFramebuffer!;
      expect(first.width, 16);
      expect(first.height, 8);
      expect(first.pixels.sublist(0, 3), <int>[0x11, 0x22, 0x33]);

      connection.feedPixel(1, 0, const [0x44, 0x55, 0x66, 0x00]);
      await _until(
        () => controller.lastFramebuffer!.pixels[Rfb.bytesPerPixel] == 0x44,
      );

      // The second update, with the first still under it: the route stores the
      // screen as it stood, not the rect that last changed on it.
      final second = controller.lastFramebuffer!;
      expect(second.pixels.sublist(0, 3), <int>[0x11, 0x22, 0x33]);
      expect(
        second.pixels.sublist(Rfb.bytesPerPixel, Rfb.bytesPerPixel + 3),
        <int>[0x44, 0x55, 0x66],
      );
    });
  });

  testWidgets('leaving the route stores a frame under the host id', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('hotline-screen');
    addTearDown(() => root.deleteSync(recursive: true));
    final previews = ScreenPreviews(Directory('${root.path}/screens'));
    addTearDown(previews.dispose);
    // The store announces a host when its file is closed, so this is the one
    // signal that separates a written frame from a file that merely exists.
    final written = <String>[];
    final changes = previews.changes.listen(written.add);
    addTearDown(changes.cancel);
    final keys = MemoryPrivateKeyStore();
    await keys.write(_nyx.keyId, 'PRIVATE');

    late _FakeConnection connection;
    await tester.runAsync(() async {
      connection = await _FakeConnection.open(width: 640, height: 360);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          privateKeyStoreProvider.overrideWithValue(keys),
          screenPreviewsProvider.overrideWith((ref) async => previews),
        ],
        child: MaterialApp(
          home: HostScreenRoute(host: _nyx, open: _opener(connection)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      previews.fileFor(_nyx.id).existsSync(),
      isFalse,
      reason: 'a route that never painted has nothing to store',
    );

    connection.feedPixel(0, 0, const [0x11, 0x22, 0x33, 0x00]);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pumpAndSettle();

    // Popping the route, which is the write the tile is waiting on: the 30
    // second tick has not come round once in the life of this test.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));

    // The write is real file IO started from dispose, so it needs both clocks:
    // the real one to deliver the completion and the test's own to let the
    // continuation waiting on it through.
    for (var i = 0; i < 50 && written.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(written, <String>[_nyx.id]);

    final stored = previews.read(_nyx.id);
    expect(stored, isNotNull);
    expect(stored!.width, previewWidth);
    expect(stored.height, 180);
    expect(stored.bytes.sublist(0, 8), <int>[
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
    ], reason: 'a png, by its signature');
  });
}
