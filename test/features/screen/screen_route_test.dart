import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/features/screen/framebuffer_view.dart';
import 'package:upgrade/features/screen/host_screen.dart';
import 'package:upgrade/features/screen/screen_rail.dart';
import 'package:upgrade/platform/ssh/keys.dart';
import 'package:upgrade/platform/vnc/keysyms.dart';
import 'package:upgrade/platform/vnc/rfb_messages.dart';
import 'package:upgrade/platform/vnc/vnc_failure.dart';
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

/// What Android reserves at the left edge for its own back gesture. A pointer that goes
/// down inside it never reaches the app.
const gestureInset = 24.0;

Future<void> pumpRoute(
  WidgetTester tester, {
  required VncOpener open,
  String? privateKey = 'PRIVATE',
  bool edgeGesture = false,
}) async {
  final store = MemoryPrivateKeyStore();
  if (privateKey != null) await store.write(_oak.keyId, privateKey);
  await tester.pumpWidget(
    ProviderScope(
      retry: noRetry,
      overrides: [privateKeyStoreProvider.overrideWithValue(store)],
      child: MaterialApp(
        theme: testTheme,
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              systemGestureInsets: edgeGesture
                  ? const EdgeInsets.symmetric(horizontal: gestureInset)
                  : EdgeInsets.zero,
            ),
            child: HostScreenRoute(host: _oak, open: open),
          ),
        ),
      ),
    ),
  );
}

/// Decoding an image and tearing a stream down are real async: the fake clock a widget
/// test runs on never advances them.
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
            String? vncUsername,
            String? password,
            HostKeyVerifier? verifier,
          }) async {
            await gate.future;
            connection = await FakeVncConnection.open();
            return connection;
          },
    );

    expect(find.text('/ OAK SCREEN'), findsOneWidget);
    expect(find.text('CONNECTING'), findsWidgets);
    expect(
      find.byType(ScreenRail),
      findsNothing,
      reason: 'nothing to type at yet',
    );

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.text('LIVE'), findsNothing);
    expect(find.text('KEYS'), findsNothing);
    expect(find.text('/ OAK SCREEN'), findsOneWidget);
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
              String? vncUsername,
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

  testWidgets('missing VNC credentials point directly to host editing', (
    tester,
  ) async {
    await pumpRoute(
      tester,
      open: ({
        required String address,
        required int port,
        required String user,
        required String privateKey,
        String? vncUsername,
        String? password,
        HostKeyVerifier? verifier,
      }) async => throw const VncPasswordNeeded('server offers 2'),
    );
    await tester.pumpAndSettle();

    expect(find.text('VNC password missing'), findsWidgets);
    expect(find.text('EDIT HOST'), findsWidgets);
    expect(find.text('RETRY'), findsNothing);
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
        String? vncUsername,
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

    expect(find.byKey(const ValueKey('key-CTRL')), findsNothing);
    expect(keyboardUp(tester), isFalse);

    final rail = tester.getRect(find.byKey(const ValueKey('rail-keyboard')));
    expect(rail.left, lessThan(Spacing.lg));
    expect(rail.width, lessThan(TapTargets.minHeight + 1));

    await tester.tap(find.byKey(const ValueKey('rail-keys')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('key-CTRL')), findsOneWidget);
    expect(keyboardUp(tester), isFalse);

    await tester.tap(find.byKey(const ValueKey('rail-keyboard')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('key-CTRL')), findsOneWidget);
    expect(keyboardUp(tester), isTrue);

    await tester.tap(find.byKey(const ValueKey('rail-keys')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('key-CTRL')), findsNothing);
    expect(keyboardUp(tester), isTrue);

    await tester.tap(find.byKey(const ValueKey('rail-keyboard')));
    await tester.pumpAndSettle();
    expect(keyboardUp(tester), isFalse);
  });

  testWidgets('a hidden app asks for no update until it is shown again', (
    tester,
  ) async {
    late FakeVncConnection connection;
    await pumpRoute(tester, open: _liveOpen((c) => connection = c));
    await settleAsync(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    final before = connection.channel.sent.length;
    connection.feedFrame();
    await settleAsync(tester);
    expect(connection.channel.sent.length, before);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    ProviderScope.containerOf(tester.element(find.byType(HostScreenRoute)))
        .read(agentsWakeProvider.notifier)
        .state++;
    await settleAsync(tester);
    final after = connection.channel.sent.sublist(before);
    expect(after, hasLength(10));
    expect(after.first, Rfb.messageFramebufferUpdateRequest);
  });

  testWidgets('an app left by BACK asks for updates again when it returns', (
    tester,
  ) async {
    late FakeVncConnection connection;
    await pumpRoute(tester, open: _liveOpen((c) => connection = c));
    await settleAsync(tester);

    for (final state in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    final before = connection.channel.sent.length;
    connection.feedFrame();
    await settleAsync(tester);
    expect(connection.channel.sent.length, before);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    ProviderScope.containerOf(tester.element(find.byType(HostScreenRoute)))
        .read(agentsWakeProvider.notifier)
        .state++;
    await settleAsync(tester);
    final after = connection.channel.sent.sublist(before);
    expect(after, hasLength(10));
    expect(after.first, Rfb.messageFramebufferUpdateRequest);
  });

  testWidgets('a left drag hides the rail and the handle brings it back', (
    tester,
  ) async {
    late FakeVncConnection connection;
    await pumpRoute(tester, open: _liveOpen((c) => connection = c));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('rail-keys')));
    await tester.tap(find.byKey(const ValueKey('rail-keyboard')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('key-CTRL')), findsOneWidget);
    expect(keyboardUp(tester), isTrue);

    final before = connection.channel.sent.length;

    // Barely past the touch slop, which is all the room a real drag towards the left edge
    // has: the rail starts about twenty-five logical pixels from it.
    await tester.drag(
      find.byKey(const ValueKey('rail-panel')),
      const Offset(-26, 0),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rail-panel')), findsNothing);
    expect(find.byKey(const ValueKey('rail-handle')), findsOneWidget);
    expect(find.byKey(const ValueKey('key-CTRL')), findsOneWidget);
    expect(keyboardUp(tester), isTrue);

    await tester.drag(
      find.byKey(const ValueKey('rail-handle')),
      const Offset(60, 0),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rail-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('rail-handle')), findsNothing);

    await tester.drag(
      find.byKey(const ValueKey('rail-panel')),
      const Offset(-26, 0),
    );
    await tester.pumpAndSettle();
    final centred = tester.getRect(find.byKey(const ValueKey('rail-handle')));
    await tester.drag(
      find.byKey(const ValueKey('rail-handle')),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    final moved = tester.getRect(find.byKey(const ValueKey('rail-handle')));
    expect(moved.top, lessThan(centred.top - 80));
    expect(moved.left, centred.left);
    expect(find.byKey(const ValueKey('rail-panel')), findsNothing);

    await tester.drag(
      find.byKey(const ValueKey('rail-handle')),
      const Offset(60, 0),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const ValueKey('rail-keyboard'))).top,
      lessThan(centred.top),
      reason: 'the rail opens where its handle was moved to',
    );

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
    connection.feedFrame();
    await settleAsync(tester);
    expect(find.byType(FramebufferView), findsOneWidget);

    await tester.drag(
      find.byKey(const ValueKey('rail-panel')),
      const Offset(-26, 0),
    );
    await tester.pumpAndSettle();
    final footprint = tester.getRect(find.byKey(const ValueKey('rail-handle')));

    Future<void> pointerDrag(double x) async {
      final gesture = await tester.startGesture(Offset(x, footprint.center.dy));
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
    }

    final before = connection.channel.sent.length;
    await tester.tapAt(Offset(footprint.right - 4, footprint.center.dy));
    await settleAsync(tester);
    expect(find.byKey(const ValueKey('rail-handle')), findsOneWidget);
    expect(
      connection.channel.sent.length,
      greaterThan(before),
      reason: 'a tap in the patch is a click at the host, not a pull',
    );

    final afterTap = connection.channel.sent.length;
    await pointerDrag(footprint.right + 8);
    await settleAsync(tester);
    expect(
      find.byKey(const ValueKey('rail-handle')),
      findsOneWidget,
      reason: 'the rail claims nothing outside its own patch',
    );
    expect(
      connection.channel.sent.length,
      greaterThan(afterTap),
      reason: 'a pixel to the right of it, the drag is a pointer at the host',
    );
  });

  testWidgets('the strip is one row of 36, modifiers first', (tester) async {
    await pumpRoute(tester, open: _liveOpen());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rail-keys')));
    await tester.pumpAndSettle();

    Rect box(String label) =>
        tester.getRect(find.byKey(ValueKey('key-$label')));

    const order = [
      'SUPER',
      'CTRL',
      'ALT',
      'SHIFT',
      'ESC',
      'TAB',
      'LEFT',
      'UP',
      'DOWN',
      'RIGHT',
      'END',
    ];
    for (final label in order) {
      expect(box(label).top, box('SUPER').top, reason: '$label is on the row');
      expect(box(label).width, greaterThanOrEqualTo(RowMetrics.minHeight));
    }
    for (var i = 1; i < order.length; i++) {
      expect(
        box(order[i]).left,
        moreOrLessEquals(box(order[i - 1]).right),
        reason: '${order[i]} follows ${order[i - 1]}',
      );
    }
    expect(box('SUPER').height, lessThanOrEqualTo(RowMetrics.minHeight));
  });

  testWidgets('a drag down on a modifier arms it for two keys', (tester) async {
    late FakeVncConnection connection;
    await pumpRoute(tester, open: _liveOpen((c) => connection = c));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rail-keys')));
    await tester.pumpAndSettle();

    final before = connection.channel.sent.length;
    await tester.drag(
      find.byKey(const ValueKey('key-CTRL')),
      const Offset(0, 40),
    );
    await tester.pumpAndSettle();
    expect(find.text('CTRL(x2)'), findsOneWidget);

    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const ValueKey('key-TAB')));
      await tester.pumpAndSettle();
    }

    expect(keyEvents(connection.channel.sent.sublist(before)), [
      (Keysyms.control, true),
      (Keysyms.tab, true),
      (Keysyms.tab, false),
      (Keysyms.control, false),
      (Keysyms.control, true),
      (Keysyms.tab, true),
      (Keysyms.tab, false),
      (Keysyms.control, false),
      (Keysyms.tab, true),
      (Keysyms.tab, false),
    ]);
    expect(find.text('CTRL'), findsOneWidget);
  });

  testWidgets('a press latches a modifier until it is tapped off', (
    tester,
  ) async {
    late FakeVncConnection connection;
    await pumpRoute(tester, open: _liveOpen((c) => connection = c));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rail-keys')));
    await tester.pumpAndSettle();

    final before = connection.channel.sent.length;
    await tester.longPress(find.byKey(const ValueKey('key-SHIFT')));
    await tester.pumpAndSettle();
    expect(find.text('SHIFT(∞)'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('key-TAB')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), '${_sentinel}a');
    await tester.pumpAndSettle();
    expect(find.text('SHIFT(∞)'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('key-SHIFT')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('key-TAB')));
    await tester.pumpAndSettle();

    expect(keyEvents(connection.channel.sent.sublist(before)), [
      (Keysyms.shift, true),
      (Keysyms.tab, true),
      (Keysyms.tab, false),
      (Keysyms.shift, false),
      (Keysyms.shift, true),
      (0x61, true),
      (0x61, false),
      (Keysyms.shift, false),
      (Keysyms.tab, true),
      (Keysyms.tab, false),
    ]);
  });

  testWidgets('the strip survives the keyboard closing itself', (tester) async {
    await pumpRoute(tester, open: _liveOpen());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('rail-keys')));
    await tester.tap(find.byKey(const ValueKey('rail-keyboard')));
    await tester.pumpAndSettle();
    expect(keyboardUp(tester), isTrue);

    // The platform drops the input connection and [EditableText] answers that by unfocusing.
    // Nothing tells the route directly.
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
    expect(find.text('ENTER'), findsNothing);
    expect(find.text('DONE'), findsNothing);

    final before = connection.channel.sent.length;

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

    // Gboard draws ↵ rather than a checkmark because the field asks for a multiline input
    // type.
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
    // 0x0A is a C0 control with no keysym of its own; `forCharacter` would send it as
    // Unicode.
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
    await store.write(_oak.keyId, 'PRIVATE');
    Future<VncConnection> open({
      required String address,
      required int port,
      required String user,
      required String privateKey,
      String? vncUsername,
      String? password,
      HostKeyVerifier? verifier,
    }) async {
      connection = await FakeVncConnection.open();
      return connection;
    }

    await tester.pumpWidget(
      ProviderScope(
        retry: noRetry,
        overrides: [privateKeyStoreProvider.overrideWithValue(store)],
        child: MaterialApp(
          theme: testTheme,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => HostScreenRoute(host: _oak, open: open),
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

    await tester.tap(find.text('/ OAK SCREEN'));
    await tester.pumpAndSettle();
    await settleAsync(tester);

    expect(connection.closed, isTrue);
    expect(
      () => connection.rfb.framebuffer,
      returnsNormally,
      reason: 'closing must not throw on the way out',
    );
    connection.rfb.sendPointer(x: 0, y: 0, buttonMask: RfbButtons.left);
  });
}

VncOpener _liveOpen([void Function(FakeVncConnection)? keep]) =>
    ({
      required String address,
      required int port,
      required String user,
      required String privateKey,
      String? vncUsername,
      String? password,
      HostKeyVerifier? verifier,
    }) async {
      final connection = await FakeVncConnection.open();
      keep?.call(connection);
      return connection;
    };

/// A [FocusNode] outlives its widget, so a field reparented out from under the IME still
/// reads as focused while the connection behind it is gone. Both halves are asserted.
bool keyboardUp(WidgetTester tester) =>
    tester.testTextInput.hasAnyClients &&
    tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus;

/// A run of zero-width spaces, so a backspace with nothing typed is still an edit.
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
