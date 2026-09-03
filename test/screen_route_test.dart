/// SPEC.md §39.32's regression list, at the route: `CONNECTING` to `LIVE`, a
/// reason line with `RETRY`, the `KEYS` strip's key events, and disposing the
/// route closing the channel and the client.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/application/agents.dart';
import 'package:hotline/data/repositories/host_repository.dart';
import 'package:hotline/features/screen/framebuffer_view.dart';
import 'package:hotline/features/screen/host_screen.dart';
import 'package:hotline/platform/keys.dart';
import 'package:hotline/platform/vnc/keysyms.dart';
import 'package:hotline/platform/vnc/rfb_client.dart';
import 'package:hotline/platform/vnc/rfb_messages.dart';
import 'package:hotline/platform/vnc/vnc_failure.dart';
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

/// A screen carried by scripted bytes instead of an ssh channel.
///
/// The [RfbClient] inside is the real one: only the transport is faked, which
/// is what makes "closes channel and client" a thing to assert rather than to
/// read.
class FakeVncConnection implements VncConnection {
  FakeVncConnection._(this.channel, this.rfb, this.serverInit);

  static Future<FakeVncConnection> open({
    int width = 16,
    int height = 8,
  }) async {
    final channel = FakeVncChannel();
    final rfb = RfbClient(incoming: channel.stream, outgoing: channel.sink);
    channel.feed(serverHandshake(width: width, height: height));
    final init = await rfb.handshake();
    return FakeVncConnection._(channel, rfb, init);
  }

  final FakeVncChannel channel;

  @override
  final RfbClient rfb;

  @override
  final RfbServerInit serverInit;

  bool closed = false;

  /// One Raw rect over the top-left pixel, which is enough for the controller
  /// to decode an image and for the route to draw one.
  void feedFrame() {
    channel.feed([
      Rfb.serverFramebufferUpdate,
      ...updateHeader(1),
      ...rectHeader(x: 0, y: 0, width: 1, height: 1, encoding: Rfb.encodingRaw),
      0x11, 0x22, 0x33, 0xFF,
    ]);
  }

  @override
  Future<void> close() async {
    closed = true;
    await rfb.close();
    await channel.dispose();
  }
}

/// The route under test, with the transport and the keystore stubbed and
/// nothing else.
Future<void> pumpRoute(
  WidgetTester tester, {
  required VncOpener open,
  String? privateKey = 'PRIVATE',
}) async {
  final store = MemoryPrivateKeyStore();
  if (privateKey != null) await store.write(_nyx.keyId, privateKey);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [privateKeyStoreProvider.overrideWithValue(store)],
      child: MaterialApp(
        home: HostScreenRoute(host: _nyx, open: open),
      ),
    ),
  );
}

/// Decoding an image and tearing a stream down are real async: the fake clock
/// a widget test runs on never advances them, so both need a turn of the real
/// one before the tree is pumped again.
Future<void> settleAsync(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 60)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the breadcrumb names the host and goes CONNECTING then LIVE', (
    tester,
  ) async {
    late FakeVncConnection connection;
    final gate = Completer<void>();
    await pumpRoute(
      tester,
      open: ({
        required String address,
        required int port,
        required String user,
        required String privateKey,
      }) async {
        await gate.future;
        connection = await FakeVncConnection.open();
        return connection;
      },
    );

    expect(find.text('/ NYX SCREEN'), findsOneWidget);
    expect(find.text('CONNECTING'), findsWidgets);
    expect(find.text('KEYS'), findsNothing, reason: 'nothing to type at yet');

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.text('LIVE'), findsOneWidget);
    expect(find.text('KEYS'), findsOneWidget);

    connection.feedFrame();
    await settleAsync(tester);

    expect(find.byType(FramebufferView), findsOneWidget);
    expect(find.text('CONNECTING'), findsNothing);
  });

  testWidgets('a refused channel is a reason line with RETRY, and RETRY reconnects', (
    tester,
  ) async {
    var attempts = 0;
    late FakeVncConnection connection;
    await pumpRoute(
      tester,
      open: ({
        required String address,
        required int port,
        required String user,
        required String privateKey,
      }) async {
        attempts++;
        if (attempts == 1) {
          throw const VncTunnelRefused('administratively prohibited');
        }
        connection = await FakeVncConnection.open();
        return connection;
      },
    );
    await tester.pumpAndSettle();

    expect(find.text('tunnel refused'), findsWidgets);
    expect(find.text('RETRY'), findsOneWidget);

    await tester.tap(find.text('RETRY'));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text('LIVE'), findsOneWidget);
    expect(find.text('tunnel refused'), findsNothing);

    connection.feedFrame();
    await settleAsync(tester);
    expect(find.byType(FramebufferView), findsOneWidget);
  });

  testWidgets('a host whose private key is gone reads as a rejected key', (
    tester,
  ) async {
    await pumpRoute(
      tester,
      privateKey: null,
      open: ({
        required String address,
        required int port,
        required String user,
        required String privateKey,
      }) async => throw StateError('never asked'),
    );
    await tester.pumpAndSettle();

    expect(find.text('key rejected'), findsWidgets);
    expect(find.text('RETRY'), findsOneWidget);
  });

  testWidgets('the KEYS strip sends a letter, ENTER, ESC and a sticky CTRL', (
    tester,
  ) async {
    late FakeVncConnection connection;
    await pumpRoute(
      tester,
      open: ({
        required String address,
        required int port,
        required String user,
        required String privateKey,
      }) async {
        connection = await FakeVncConnection.open();
        return connection;
      },
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('KEYS'));
    await tester.pumpAndSettle();
    expect(find.text('DONE'), findsOneWidget);

    final before = connection.channel.sent.length;

    // A letter comes from the IME as an edit on the hidden field.
    await tester.enterText(find.byType(EditableText), '${_sentinel}h');
    await tester.pumpAndSettle();

    await tester.tap(find.text('ENTER'));
    await tester.tap(find.text('ESC'));
    await tester.pumpAndSettle();

    // Sticky: CTRL arms, the next key goes through it, and it disarms itself.
    await tester.tap(find.text('CTRL'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ESC'));
    await tester.pumpAndSettle();

    expect(
      keyEvents(connection.channel.sent.sublist(before)),
      [
        (0x68, true),
        (0x68, false),
        (Keysyms.enter, true),
        (Keysyms.enter, false),
        (Keysyms.escape, true),
        (Keysyms.escape, false),
        (Keysyms.control, true),
        (Keysyms.escape, true),
        (Keysyms.escape, false),
        (Keysyms.control, false),
      ],
    );

    await tester.tap(find.text('DONE'));
    await tester.pumpAndSettle();
    expect(find.text('DONE'), findsNothing);
    expect(find.text('KEYS'), findsOneWidget);
  });

  testWidgets('leaving the route closes the channel and the client', (
    tester,
  ) async {
    late FakeVncConnection connection;
    final store = MemoryPrivateKeyStore();
    await store.write(_nyx.keyId, 'PRIVATE');
    Future<VncConnection> open({
      required String address,
      required int port,
      required String user,
      required String privateKey,
    }) async {
      connection = await FakeVncConnection.open();
      return connection;
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [privateKeyStoreProvider.overrideWithValue(store)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => HostScreenRoute(host: _nyx, open: open),
                ),
              ),
              child: const Text('GO'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('GO'));
    await tester.pumpAndSettle();
    expect(find.text('LIVE'), findsOneWidget);
    expect(connection.closed, isFalse);

    // §39.32's way out: the breadcrumb pops the route.
    await tester.tap(find.text('/ NYX SCREEN'));
    await tester.pumpAndSettle();
    await settleAsync(tester);

    expect(connection.closed, isTrue);
    expect(
      () => connection.rfb.framebuffer,
      returnsNormally,
      reason: 'closing must not throw on the way out',
    );
    // A pointer event after the close writes nothing: the sink is gone.
    connection.rfb.sendPointer(x: 0, y: 0, buttonMask: RfbButtons.left);
  });
}

/// The strip's hidden field starts on a run of zero-width spaces so a backspace
/// with nothing typed is still an edit.
const _sentinel = '​​​​​​​​';

List<(int, bool)> keyEvents(Uint8List written) {
  final data = ByteData.sublistView(written);
  final out = <(int, bool)>[];
  for (var at = 0; at + 8 <= written.length; at += 8) {
    if (data.getUint8(at) != Rfb.messageKeyEvent) continue;
    out.add((data.getUint32(at + 4), data.getUint8(at + 1) == 1));
  }
  return out;
}
