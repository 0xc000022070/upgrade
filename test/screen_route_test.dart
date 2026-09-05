/// The regression list at the screen route: `CONNECTING` giving way to a
/// breadcrumb standing alone, a reason line with `RETRY`, the
/// strip's key events and the keyboard's Return, the rail's two independent
/// toggles, and disposing the route closing the channel and the client.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/application/agents.dart';
import 'package:spectacle/data/repositories/host_repository.dart';
import 'package:spectacle/design/spacing.dart';
import 'package:spectacle/features/screen/framebuffer_view.dart';
import 'package:spectacle/features/screen/host_screen.dart';
import 'package:spectacle/features/screen/screen_rail.dart';
import 'package:spectacle/platform/keys.dart';
import 'package:spectacle/platform/vnc/keysyms.dart';
import 'package:spectacle/platform/vnc/rfb_client.dart';
import 'package:spectacle/platform/vnc/rfb_messages.dart';
import 'package:spectacle/platform/vnc/vnc_failure.dart';
import 'package:spectacle/platform/vnc/vnc_tunnel.dart';
import 'package:spectacle/platform/host_keys.dart';

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
      0x11,
      0x22,
      0x33,
      0xFF,
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
/// What Android reserves at the left edge for its own back gesture. A pointer
/// that goes down inside it never reaches the app, which is why the rail's way
/// back has to start further in than this.
const gestureInset = 24.0;

Future<void> pumpRoute(
  WidgetTester tester, {
  required VncOpener open,
  String? privateKey = 'PRIVATE',
  bool edgeGesture = false,
}) async {
  final store = MemoryPrivateKeyStore();
  if (privateKey != null) await store.write(_nyx.keyId, privateKey);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [privateKeyStoreProvider.overrideWithValue(store)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              systemGestureInsets: edgeGesture
                  ? const EdgeInsets.symmetric(horizontal: gestureInset)
                  : EdgeInsets.zero,
            ),
            child: HostScreenRoute(host: _nyx, open: open),
          ),
        ),
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
  testWidgets('the breadcrumb stands alone once the screen is live', (
    tester,
  ) async {
    late FakeVncConnection connection;
    final gate = Completer<void>();
    await pumpRoute(
      tester,
      open:
          ({
            required String address,
            required int port,
            required String user,
            required String privateKey,
            String? password,
            HostKeyVerifier? verifier,
          }) async {
            await gate.future;
            connection = await FakeVncConnection.open();
            return connection;
          },
    );

    expect(find.text('/ NYX SCREEN'), findsOneWidget);
    expect(find.text('CONNECTING'), findsWidgets);
    expect(
      find.byType(ScreenRail),
      findsNothing,
      reason: 'nothing to type at yet',
    );

    gate.complete();
    await tester.pumpAndSettle();

    // `LIVE` is gone, and so is `KEYS`. What is left on the line is the
    // breadcrumb, and the rail is what opens the keyboard now.
    expect(find.text('LIVE'), findsNothing);
    expect(find.text('KEYS'), findsNothing);
    expect(find.text('/ NYX SCREEN'), findsOneWidget);
    expect(find.byType(ScreenRail), findsOneWidget);

    connection.feedFrame();
    await settleAsync(tester);

    expect(find.byType(FramebufferView), findsOneWidget);
    expect(find.text('CONNECTING'), findsNothing);
  });

  testWidgets(
    'a refused channel is a reason line with RETRY, and RETRY reconnects',
    (tester) async {
      var attempts = 0;
      late FakeVncConnection connection;
      await pumpRoute(
        tester,
        open:
            ({
              required String address,
              required int port,
              required String user,
              required String privateKey,
              String? password,
              HostKeyVerifier? verifier,
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
      expect(find.text('tunnel refused'), findsNothing);
      expect(find.text('RETRY'), findsNothing);

      connection.feedFrame();
      await settleAsync(tester);
      expect(find.byType(FramebufferView), findsOneWidget);
    },
  );

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
        String? password,
        HostKeyVerifier? verifier,
      }) async => throw StateError('never asked'),
    );
    await tester.pumpAndSettle();

    expect(find.text('key rejected'), findsWidgets);
    expect(find.text('RETRY'), findsOneWidget);
  });

  testWidgets('the rail toggles the strip and the keyboard apart', (
    tester,
  ) async {
    await pumpRoute(tester, open: _liveOpen());
    await tester.pumpAndSettle();

    // Neither: the rail is the only chrome over the picture.
    expect(find.byKey(const ValueKey('key-CTRL')), findsNothing);
    expect(keyboardUp(tester), isFalse);

    // The rail belongs on the left edge, and a [Panel] left unbounded
    // stretches to full width with its toggles centred over the picture.
    final rail = tester.getRect(find.byKey(const ValueKey('rail-keyboard')));
    expect(rail.left, lessThan(Spacing.lg));
    expect(rail.width, lessThan(TapTargets.minHeight + 1));

    // Strip without keyboard — the AVNC frame the user asked for.
    await tester.tap(find.byKey(const ValueKey('rail-keys')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('key-CTRL')), findsOneWidget);
    expect(keyboardUp(tester), isFalse);

    // Both.
    await tester.tap(find.byKey(const ValueKey('rail-keyboard')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('key-CTRL')), findsOneWidget);
    expect(keyboardUp(tester), isTrue);

    // Keyboard without strip.
    await tester.tap(find.byKey(const ValueKey('rail-keys')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('key-CTRL')), findsNothing);
    expect(keyboardUp(tester), isTrue);

    // And the keyboard alone goes down again, leaving neither.
    await tester.tap(find.byKey(const ValueKey('rail-keyboard')));
    await tester.pumpAndSettle();
    expect(keyboardUp(tester), isFalse);
  });

  testWidgets('a left drag hides the rail and the handle brings it back', (
    tester,
  ) async {
    late FakeVncConnection connection;
    await pumpRoute(tester, open: _liveOpen((c) => connection = c));
    await tester.pumpAndSettle();

    // Both up, so the drag can be shown not to touch either.
    await tester.tap(find.byKey(const ValueKey('rail-keys')));
    await tester.tap(find.byKey(const ValueKey('rail-keyboard')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('key-CTRL')), findsOneWidget);
    expect(keyboardUp(tester), isTrue);

    final before = connection.channel.sent.length;

    // Barely past the touch slop, which is all the room a real drag towards
    // the left edge has: the rail starts about twenty-five logical pixels from
    // it.
    await tester.drag(
      find.byKey(const ValueKey('rail-panel')),
      const Offset(-26, 0),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rail-panel')), findsNothing);
    expect(find.byKey(const ValueKey('rail-handle')), findsOneWidget);
    expect(find.byKey(const ValueKey('key-CTRL')), findsOneWidget);
    expect(keyboardUp(tester), isTrue);

    // A drag back to the right, starting on the handle.
    await tester.drag(
      find.byKey(const ValueKey('rail-handle')),
      const Offset(60, 0),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rail-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('rail-handle')), findsNothing);

    // And a tap on the handle is the same door.
    // Barely past the touch slop, which is all the room a real drag towards
    // the left edge has: the rail starts about twenty-five logical pixels from
    // it.
    await tester.drag(
      find.byKey(const ValueKey('rail-panel')),
      const Offset(-26, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rail-handle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rail-panel')), findsOneWidget);

    expect(find.byKey(const ValueKey('key-CTRL')), findsOneWidget);
    expect(keyboardUp(tester), isTrue);
    expect(
      connection.channel.sent.length,
      before,
      reason:
          'the recogniser is on the rail, never on the picture, so a drag '
          'over it is not a pointer drag at the host',
    );
  });

  testWidgets('the hidden rail answers past the edge the back gesture takes', (
    tester,
  ) async {
    late FakeVncConnection connection;
    await pumpRoute(
      tester,
      open: _liveOpen((c) => connection = c),
      edgeGesture: true,
    );
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const ValueKey('rail-panel')),
      const Offset(-26, 0),
    );
    await tester.pumpAndSettle();

    // The patch the hidden rail keeps is the footprint the shown one had, not
    // the sliver drawn in it: it starts at the edge and ends past the inset,
    // so there is room to put a finger down where the system will not take it.
    final footprint = tester.getRect(find.byKey(const ValueKey('rail-handle')));
    expect(footprint.left, 0);
    expect(footprint.right, greaterThan(gestureInset * 2));
    expect(footprint.height, TapTargets.minHeight);

    final before = connection.channel.sent.length;
    final inside = Offset(footprint.right - 4, footprint.center.dy);
    expect(inside.dx, greaterThan(gestureInset));

    await tester.dragFrom(inside, const Offset(60, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rail-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('rail-handle')), findsNothing);
    expect(
      connection.channel.sent.length,
      before,
      reason: 'a drag that starts in the patch belongs to the rail',
    );
  });

  testWidgets('a drag just outside the footprint is still the host\'s', (
    tester,
  ) async {
    late FakeVncConnection connection;
    await pumpRoute(
      tester,
      open: _liveOpen((c) => connection = c),
      edgeGesture: true,
    );
    await tester.pumpAndSettle();
    // The picture itself, not the ground under it: only a decoded frame takes
    // pointers, and decoding one is real async.
    connection.feedFrame();
    await settleAsync(tester);
    expect(find.byType(FramebufferView), findsOneWidget);

    await tester.drag(
      find.byKey(const ValueKey('rail-panel')),
      const Offset(-26, 0),
    );
    await tester.pumpAndSettle();
    final footprint = tester.getRect(find.byKey(const ValueKey('rail-handle')));

    // A pointer drag at the host is a long press and then a move: the picture
    // gives its single-finger gestures to the pointer, and a bare one-finger
    // slide over it is not one of them. Both starts are that same gesture, so
    // the only difference between them is which side of the patch they are on.
    Future<void> pointerDrag(double x) async {
      final gesture = await tester.startGesture(Offset(x, footprint.center.dy));
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
    }

    final before = connection.channel.sent.length;
    await pointerDrag(footprint.right - 4);
    await settleAsync(tester);
    expect(
      connection.channel.sent.length,
      before,
      reason: 'the patch takes the pointer, hidden or shown',
    );

    await pointerDrag(footprint.right + 8);
    await settleAsync(tester);
    expect(
      find.byKey(const ValueKey('rail-handle')),
      findsOneWidget,
      reason: 'the rail claims nothing outside its own patch',
    );
    expect(
      connection.channel.sent.length,
      greaterThan(before),
      reason: 'a pixel to the right of it, the drag is a pointer at the host',
    );
  });

  testWidgets('the strip is two rows of six with the arrows in an inverted T', (
    tester,
  ) async {
    await pumpRoute(tester, open: _liveOpen());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rail-keys')));
    await tester.pumpAndSettle();

    Rect box(String label) =>
        tester.getRect(find.byKey(ValueKey('key-$label')));

    const top = ['ESC', 'TAB', 'SHIFT', 'UP', 'END'];
    const bottom = ['SUPER', 'CTRL', 'ALT', 'LEFT', 'DOWN', 'RIGHT'];

    for (final label in top) {
      expect(
        box(label).top,
        box('ESC').top,
        reason: '$label is on the top row',
      );
    }
    for (final label in bottom) {
      expect(
        box(label).top,
        box('SUPER').top,
        reason: '$label is on the bottom row',
      );
    }
    expect(box('SUPER').top, greaterThan(box('ESC').top));

    // Six equal columns, which is what makes the arrows read as a T rather
    // than as four keys that happen to be near each other.
    for (final label in [...top, ...bottom]) {
      expect(
        box(label).width,
        moreOrLessEquals(box('ESC').width),
        reason: '\$label is one cell',
      );
    }
    expect(
      box('ESC').left + box('ESC').width * 6,
      moreOrLessEquals(box('END').right),
    );

    expect(box('UP').center.dx, moreOrLessEquals(box('DOWN').center.dx));
    expect(box('LEFT').center.dx, lessThan(box('DOWN').center.dx));
    expect(box('RIGHT').center.dx, greaterThan(box('DOWN').center.dx));
    expect(box('END').center.dx, moreOrLessEquals(box('RIGHT').center.dx));
    // The fourth cell of the top row is empty: nothing sits over the left
    // arrow.
    expect(
      top.where(
        (label) => (box(label).center.dx - box('LEFT').center.dx).abs() < 1,
      ),
      isEmpty,
    );
  });

  testWidgets('the strip survives the keyboard closing itself', (tester) async {
    await pumpRoute(tester, open: _liveOpen());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('rail-keys')));
    await tester.tap(find.byKey(const ValueKey('rail-keyboard')));
    await tester.pumpAndSettle();
    expect(keyboardUp(tester), isTrue);

    // What the system back gesture and the IME's own hide actually do: the
    // platform drops the input connection, and [EditableText] answers that by
    // unfocusing. Nothing tells the route directly.
    tester.testTextInput.closeConnection();
    await tester.pumpAndSettle();

    expect(keyboardUp(tester), isFalse);
    expect(
      find.byKey(const ValueKey('key-CTRL')),
      findsOneWidget,
      reason: 'the strip is not the keyboard and does not leave with it',
    );
  });

  testWidgets('the strip sends a letter, ESC, END and an arrow', (
    tester,
  ) async {
    late FakeVncConnection connection;
    await pumpRoute(tester, open: _liveOpen((c) => connection = c));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('rail-keys')));
    await tester.pumpAndSettle();
    // `ENTER` and `DONE` are off the strip.
    expect(find.text('ENTER'), findsNothing);
    expect(find.text('DONE'), findsNothing);

    final before = connection.channel.sent.length;

    // A letter comes from the IME as an edit on the hidden field.
    await tester.enterText(find.byType(EditableText), '${_sentinel}h');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('key-ESC')));
    await tester.tap(find.byKey(const ValueKey('key-END')));
    await tester.tap(find.byKey(const ValueKey('key-LEFT')));
    await tester.pumpAndSettle();

    expect(keyEvents(connection.channel.sent.sublist(before)), [
      (0x68, true),
      (0x68, false),
      (Keysyms.escape, true),
      (Keysyms.escape, false),
      (Keysyms.end, true),
      (Keysyms.end, false),
      (Keysyms.left, true),
      (Keysyms.left, false),
    ]);
  });

  testWidgets('SHIFT is sticky and arms exactly one key', (tester) async {
    late FakeVncConnection connection;
    await pumpRoute(tester, open: _liveOpen((c) => connection = c));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('rail-keys')));
    await tester.pumpAndSettle();

    final before = connection.channel.sent.length;

    await tester.tap(find.byKey(const ValueKey('key-SHIFT')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('key-TAB')));
    await tester.pumpAndSettle();
    // The second one is outside the chord: one key is what sticky means.
    await tester.tap(find.byKey(const ValueKey('key-TAB')));
    await tester.pumpAndSettle();

    expect(keyEvents(connection.channel.sent.sublist(before)), [
      (Keysyms.shift, true),
      (Keysyms.tab, true),
      (Keysyms.tab, false),
      (Keysyms.shift, false),
      (Keysyms.tab, true),
      (Keysyms.tab, false),
    ]);
  });

  testWidgets('a newline from the IME is Return, not a character', (
    tester,
  ) async {
    late FakeVncConnection connection;
    await pumpRoute(tester, open: _liveOpen((c) => connection = c));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('rail-keyboard')));
    await tester.pumpAndSettle();

    // Gboard draws ↵ rather than a checkmark because the field asks for a
    // multiline input type, and what the ↵ delivers is this edit.
    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.keyboardType, TextInputType.multiline);
    expect(field.textInputAction, TextInputAction.newline);

    final before = connection.channel.sent.length;
    await tester.enterText(find.byType(EditableText), '$_sentinel\n');
    await tester.pumpAndSettle();

    expect(keyEvents(connection.channel.sent.sublist(before)), [
      (Keysyms.enter, true),
      (Keysyms.enter, false),
    ]);
    // 0x0A is a C0 control with no keysym of its own; `forCharacter` would send
    // it as Unicode, and this is the assertion that it never does.
    expect(
      keyEvents(connection.channel.sent.sublist(before)),
      isNot(contains((Keysyms.forCharacter('\n'), true))),
    );
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
      String? password,
      HostKeyVerifier? verifier,
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
    expect(find.byType(ScreenRail), findsOneWidget);
    expect(connection.closed, isFalse);

    // The way out: the breadcrumb pops the route.
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

/// A live screen, with the connection handed back to the caller when it wants
/// one. Every assertion below opens the same way.
VncOpener _liveOpen([void Function(FakeVncConnection)? keep]) =>
    ({
      required String address,
      required int port,
      required String user,
      required String privateKey,
      String? password,
      HostKeyVerifier? verifier,
    }) async {
      final connection = await FakeVncConnection.open();
      keep?.call(connection);
      return connection;
    };

/// Whether the IME is attached, which on this route is the whole of what "the
/// keyboard is up" means: the hidden field is mounted either way, and only the
/// focus on it moves.
///
/// Both halves are asserted, and the platform half is the one that matters. A
/// [FocusNode] outlives its widget, so a field that was reparented out from
/// under the IME still reads as focused while the connection behind it is gone
/// — which on the emulator was the keyboard dropping when the strip was raised
/// and a test watching focus alone stayed green through it.
bool keyboardUp(WidgetTester tester) =>
    tester.testTextInput.hasAnyClients &&
    tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus;

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
