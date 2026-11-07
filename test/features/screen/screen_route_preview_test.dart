import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/features/screen/host_screen.dart';
import 'package:upgrade/features/screen/screen_controller.dart';
import 'package:upgrade/features/screen/screen_preview.dart';
import 'package:upgrade/platform/ssh/keys.dart';
import 'package:upgrade/platform/vnc/rfb_client.dart';
import 'package:upgrade/platform/vnc/rfb_messages.dart';
import 'package:upgrade/platform/vnc/vnc_tunnel.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/application/providers.dart';

import '../../support/vnc_channel.dart';
import '../../support/themed_app.dart';

const _oak = Host(
  id: 'h1',
  name: 'oak',
  address: '10.0.2.2',
  port: 357,
  user: 'developer',
  keyId: 'k1',
);

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

  @override
  Future<int> run(String command) async => 0;

  /// One Raw pixel, which is all the controller needs to build an image.
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
      String? vncUsername,
      String? password,
      HostKeyVerifier? verifier,
    }) async => connection;

/// Decoding is real async, which the fake clock a widget test runs on never advances.
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
        host: _oak,
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
    final root = Directory.systemTemp.createTempSync('upgrade-screen');
    addTearDown(() => root.deleteSync(recursive: true));
    final previews = ScreenPreviews(Directory('${root.path}/screens'));
    addTearDown(previews.dispose);
    final written = <String>[];
    final changes = previews.changes.listen(written.add);
    addTearDown(changes.cancel);
    final keys = MemoryPrivateKeyStore();
    await keys.write(_oak.keyId, 'PRIVATE');

    late _FakeConnection connection;
    await tester.runAsync(() async {
      connection = await _FakeConnection.open(width: 640, height: 360);
    });

    await tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        overrides: [
          privateKeyStoreProvider.overrideWithValue(keys),
          screenPreviewsProvider.overrideWith((ref) async => previews),
        ],
        child: MaterialApp(
          theme: testTheme,
          home: HostScreenRoute(host: _oak, open: _opener(connection)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      previews.fileFor(_oak.id).existsSync(),
      isFalse,
      reason: 'a route that never painted has nothing to store',
    );

    connection.feedPixel(0, 0, const [0x11, 0x22, 0x33, 0x00]);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));

    // The write is real file IO started from dispose, so it needs both clocks: the real one
    // to deliver the completion and the test's own to let the continuation through.
    for (var i = 0; i < 400 && written.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(written, <String>[_oak.id]);

    final stored = previews.read(_oak.id);
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

  testWidgets('no preview is stored while the app is hidden', (tester) async {
    final root = Directory.systemTemp.createTempSync('upgrade-screen');
    addTearDown(() => root.deleteSync(recursive: true));
    final previews = ScreenPreviews(Directory('${root.path}/screens'));
    addTearDown(previews.dispose);
    final written = <String>[];
    final changes = previews.changes.listen(written.add);
    addTearDown(changes.cancel);
    final keys = MemoryPrivateKeyStore();
    await keys.write(_oak.keyId, 'PRIVATE');

    late _FakeConnection connection;
    await tester.runAsync(() async {
      connection = await _FakeConnection.open(width: 640, height: 360);
    });

    await tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        overrides: [
          privateKeyStoreProvider.overrideWithValue(keys),
          screenPreviewsProvider.overrideWith((ref) async => previews),
        ],
        child: MaterialApp(
          theme: testTheme,
          home: HostScreenRoute(host: _oak, open: _opener(connection)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> paint(int x) async {
      connection.feedPixel(x, 0, const [0x11, 0x22, 0x33, 0x00]);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pump();
    }

    Future<void> settleWrites({int? until}) async {
      for (var i = 0; i < (until == null ? 40 : 400); i++) {
        if (until != null && written.length >= until) return;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
    }

    await paint(0);
    await tester.pump(previewInterval);
    await settleWrites(until: 1);
    expect(written, <String>[_oak.id]);

    tester.binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
      ..handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await paint(1);
    await tester.pump(previewInterval * 3);
    await settleWrites();
    expect(written, <String>[_oak.id]);

    tester.binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
      ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    ProviderScope.containerOf(tester.element(find.byType(HostScreenRoute)))
        .read(agentsWakeProvider.notifier)
        .state++;
    await tester.pump(previewInterval);
    await settleWrites(until: 2);
    expect(written, <String>[_oak.id, _oak.id]);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
