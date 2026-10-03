import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/application/agents.dart';
import 'package:dazzle/application/navigation.dart';
import 'package:dazzle/application/providers.dart';
import 'package:dazzle/data/repositories/host_repository.dart';
import 'package:dazzle/design/dynamic_tokens.dart';
import 'package:dazzle/design/effects/glitch.dart';
import 'package:dazzle/design/icons/dazzle_icon.dart';
import 'package:dazzle/design/theme.dart';
import 'package:dazzle/design/tokens.dart';
import 'package:dazzle/features/devices/device_controllers.dart';
import 'package:dazzle/features/devices/device_dock.dart';
import 'package:dazzle/features/devices/device_float.dart';
import 'package:dazzle/features/screen/screen_preview.dart';
import 'package:dazzle/platform/devices/device_link.dart';
import 'package:dazzle/platform/herdr_client.dart';
import 'package:dazzle/platform/host_keys.dart';
import 'package:dazzle/platform/keys.dart';

import 'support/platform_channels.dart';
import 'support/themed_app.dart';

const _rose = Host(
  id: 'h1',
  name: 'rose',
  address: '10.0.2.2',
  port: 22,
  user: 'luisnquin',
  keyId: 'k1',
);

const _nyx = Host(
  id: 'h2',
  name: 'nyx',
  address: '10.0.2.3',
  port: 22,
  user: 'luisnquin',
  keyId: 'k1',
);

const _pixel = HostDevice(
  kind: DeviceKind.android,
  id: 'emulator-5554',
  name: 'pixel_7-api36',
);

const _iphone = HostDevice(
  kind: DeviceKind.simulator,
  id: '0A1B2C3D-0000-1111-2222-333344445555',
  name: 'iPhone 17 Pro',
);

class FakeDeviceLink implements DeviceLink {
  FakeDeviceLink(this.devices);

  List<HostDevice> devices;
  final commands = <String>[];
  final frameStreams = <StreamController<DeviceFrame>>[];
  bool closed = false;

  @override
  Future<List<HostDevice>> list() async => devices;

  @override
  Stream<DeviceFrame> frames(HostDevice device) {
    final controller = StreamController<DeviceFrame>();
    frameStreams.add(controller);
    return controller.stream;
  }

  @override
  Future<void> run(String command) async => commands.add(command);

  @override
  Future<void> close() async => closed = true;
}

DeviceLinkOpener _opener(FakeDeviceLink link) =>
    ({
      required String address,
      required int port,
      required String user,
      required String privateKey,
      HostKeyVerifier? verifier,
    }) async => link;

List<int> _header(String line) => latin1.encode('$line\n');

const _floatKey = ValueKey('device-float');
const _overlayKey = ValueKey('device-float-overlay');
const _barKey = ValueKey('device-list');
const _bubbleKey = ValueKey('device-float-bubble');

Future<void> _pump(
  WidgetTester tester,
  DeviceLinkOpener open, {
  List<Host> hosts = const [_rose],
  ThemeData? theme,
}) async {
  stubDeviceChannels();
  final store = MemoryPrivateKeyStore();
  await store.write(_rose.keyId, 'PRIVATE');
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        privateKeyStoreProvider.overrideWithValue(store),
        staticEnabledProvider.overrideWith((ref) => Stream.value(false)),
        deviceLinkOpenerProvider.overrideWithValue(open),
        deviceHostsProvider.overrideWith((ref) => Stream.value(hosts)),
      ],
      child: MaterialApp(
        theme: theme ?? testTheme,
        navigatorKey: rootNavigatorKey,
        builder: (context, child) => DeviceFloat(child: child!),
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => ref.read(deviceDockProvider).show(_rose),
                child: const Text('DEVICES'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.text('DEVICES'));
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 60)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _live(WidgetTester tester, FakeDeviceLink link) async {
  link.frameStreams.last.add(_frame());
  await _settle(tester);
}

Future<void> _tapKey(WidgetTester tester, Key key) async {
  await tester.tap(find.byKey(key));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _open(WidgetTester tester) => _tapKey(tester, _bubbleKey);

Future<void> _pick(
  WidgetTester tester,
  HostDevice device, {
  String host = 'h1',
}) async {
  if (find.byKey(_bubbleKey).evaluate().isNotEmpty) await _open(tester);
  final tab = find.byKey(ValueKey('device-tab-$host-${device.id}'));
  await tester.ensureVisible(tab);
  await tester.pump();
  await tester.tap(tab);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _fold(WidgetTester tester) async {
  await _tapKey(tester, _floatKey);
  await _tapKey(tester, const ValueKey('device-float-collapse'));
}

Future<void> _dismiss(WidgetTester tester) async {
  final scrim = tester.getRect(find.byKey(_overlayKey));
  await tester.tapAt(scrim.centerLeft + const Offset(4, 0));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _expand(WidgetTester tester) async {
  await _tapKey(tester, _floatKey);
  await _tapKey(tester, const ValueKey('device-float-expand'));
  await tester.pump(const Duration(seconds: 1));
}

void _lifecycle(WidgetTester tester, List<AppLifecycleState> states) {
  for (final state in states) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

DeviceFrame _frame({int width = 1080, int height = 2400}) {
  final png = encodePng(
    PreviewFrame(width: 9, height: 20, rgb: Uint8List(9 * 20 * 3)),
  );
  return DeviceFrame(width: width, height: height, bytes: png);
}

void main() {
  test('the list keeps names with spaces and skips what is not a device', () {
    final devices = parseDeviceList(
      'A emulator-5554 pixel_7-api36-b\n'
      'noise\n'
      'I 0A1B2C3D-0000-1111-2222-333344445555 iPhone 17 Pro\n'
      'A R5CT1234\n',
    );
    expect(devices.map((device) => device.name), [
      'pixel_7-api36-b',
      'iPhone 17 Pro',
      'R5CT1234',
    ]);
    expect(devices[1].kind, DeviceKind.simulator);
    expect(devices[1].pressable, isFalse);
  });

  test('frames survive being cut anywhere and keepalives vanish', () async {
    final body = List<int>.generate(10, (index) => index);
    final wire = [
      ..._header('K'),
      ..._header('F 1080 2400 10'),
      ...body,
      ..._header('K'),
      ..._header('F 1 2 3'),
      7,
      8,
      9,
    ];
    for (final cut in [1, 3, 7, wire.length]) {
      final chunks = [
        for (var at = 0; at < wire.length; at += cut)
          wire.sublist(at, (at + cut).clamp(0, wire.length)),
      ];
      final frames = await Stream<List<int>>.fromIterable(chunks)
          .transform(const DeviceFrameDecoder())
          .toList();
      expect(frames, hasLength(2), reason: 'cut $cut');
      expect(frames[0].width, 1080);
      expect(frames[0].height, 2400);
      expect(frames[0].bytes, body);
      expect(frames[1].bytes, [7, 8, 9]);
    }
  });

  test('a capture error reaches the listener with its message', () async {
    final result = Stream<List<int>>.fromIterable([
      _header('E error: device offline'),
    ]).transform(const DeviceFrameDecoder()).toList();
    await expectLater(
      result,
      throwsA(
        isA<DeviceCaptureFailed>().having(
          (error) => error.message,
          'message',
          'error: device offline',
        ),
      ),
    );
  });

  test('a serial is quoted wherever it reaches the shell', () {
    const odd = HostDevice(kind: DeviceKind.android, id: "a'b c", name: 'x');
    expect(
      DeviceCommands.tap(odd, 1, 2),
      "adb -s 'a'\\''b c' shell input tap 1 2",
    );
    expect(
      DeviceCommands.frames(_iphone),
      contains("xcrun simctl io '\\''${_iphone.id}'\\'' screenshot"),
    );
  });

  test('a drag is clamped into what input swipe is told', () async {
    final link = FakeDeviceLink(const []);
    final controller = DeviceScreenController(
      hostName: 'rose',
      link: link,
      device: _pixel,
    )..start();
    addTearDown(controller.dispose);
    link.frameStreams.single.add(_frame());
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(controller.phase, isA<DeviceLive>());

    controller
      ..drag(Offset.zero, const Offset(10, 20), const Duration(milliseconds: 5))
      ..drag(Offset.zero, const Offset(10, 20), const Duration(seconds: 9))
      ..press(const Offset(3, 4));
    await Future<void>.delayed(Duration.zero);
    expect(link.commands, [
      "adb -s 'emulator-5554' shell input swipe 0 0 10 20 100",
      "adb -s 'emulator-5554' shell input swipe 0 0 10 20 2000",
      "adb -s 'emulator-5554' shell input swipe 3 4 3 4 600",
    ]);
  });

  testWidgets('DEVICES opens the bar, and a tab opens the window', (
    tester,
  ) async {
    final link = FakeDeviceLink(const [_pixel, _iphone]);
    await _pump(tester, _opener(link));

    expect(find.byKey(_bubbleKey), findsOneWidget);
    expect(find.byKey(_barKey), findsNothing);
    expect(find.byKey(_floatKey), findsNothing);
    final tear = find.descendant(
      of: find.byKey(_bubbleKey),
      matching: find.byType(GlitchBlocks),
    );
    expect(tear, findsNothing);
    var tore = false;
    for (var i = 0; i < 60 && !tore; i++) {
      await tester.pump(const Duration(milliseconds: 45));
      tore = tear.evaluate().isNotEmpty;
    }
    expect(tore, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    for (var i = 0; i < 180; i++) {
      await tester.pump(const Duration(milliseconds: 45));
      expect(tear, findsNothing);
    }
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tore = false;
    for (var i = 0; i < 60 && !tore; i++) {
      await tester.pump(const Duration(milliseconds: 45));
      tore = tear.evaluate().isNotEmpty;
    }
    expect(tore, isTrue);
    await _open(tester);
    expect(find.byKey(_bubbleKey), findsNothing);
    expect(find.byKey(_barKey), findsOneWidget);
    expect(find.text('ROSE'), findsOneWidget);
    expect(find.text('pixel_\u200B7-api36'), findsOneWidget);
    expect(find.text('+  NO OTHER HOST HAS DEVICES ON'), findsOneWidget);
    expect(link.frameStreams, isEmpty);

    await _pick(tester, _pixel);
    expect(find.byKey(_barKey), findsNothing);
    expect(find.byKey(_floatKey), findsOneWidget);
    expect(link.frameStreams.single.hasListener, isTrue);

    await _fold(tester);
    expect(find.byKey(_bubbleKey), findsOneWidget);
    expect(link.frameStreams.single.hasListener, isFalse);

    await _open(tester);
    await _tapKey(tester, const ValueKey('device-list-handle'));
    expect(find.byKey(_barKey), findsNothing);
    expect(find.byKey(_bubbleKey), findsOneWidget);

    await _pick(tester, _iphone);
    expect(find.byKey(_barKey), findsNothing);
    expect(link.frameStreams, hasLength(2));
    expect(link.frameStreams.last.hasListener, isTrue);

    await _fold(tester);
    link.devices = const [];
    await _open(tester);
    await tester.tap(find.text('ROSE'));
    await _settle(tester);
    expect(find.text('NONE'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    expect(link.closed, isTrue);
  });

  testWidgets('a connection that fails says why on the bar', (tester) async {
    final link = FakeDeviceLink(const [_pixel]);
    var calls = 0;
    Future<DeviceLink> open({
      required String address,
      required int port,
      required String user,
      required String privateKey,
      HostKeyVerifier? verifier,
    }) async {
      if (calls++ == 0) throw const HerdrUnreachable('refused');
      return link;
    }

    await _pump(tester, open);
    await _open(tester);
    expect(find.text('rose unreachable'), findsOneWidget);
    expect(link.frameStreams, isEmpty);

    await tester.tap(find.text('ROSE'));
    await _settle(tester);
    expect(find.text('rose unreachable'), findsNothing);
    await _pick(tester, _pixel);
    expect(link.frameStreams.single.hasListener, isTrue);
  });

  testWidgets('+ adds a host to the bar, and its tabs move the stream', (
    tester,
  ) async {
    final rose = FakeDeviceLink(const [_pixel]);
    final nyx = FakeDeviceLink(const [_iphone]);
    Future<DeviceLink> open({
      required String address,
      required int port,
      required String user,
      required String privateKey,
      HostKeyVerifier? verifier,
    }) async => address == _nyx.address ? nyx : rose;

    await _pump(tester, open, hosts: const [_rose, _nyx]);
    await _pick(tester, _pixel);
    await _live(tester, rose);
    await _fold(tester);
    await _open(tester);

    const plus = ValueKey('device-list-plus');
    await tester.ensureVisible(find.byKey(plus));
    await tester.pump();
    await tester.tap(find.byKey(plus));
    await tester.pump();
    expect(find.text('DEVICES ON'), findsOneWidget);
    expect(find.byKey(const ValueKey('device-new-host-h1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('device-new-host-h2')));
    await _settle(tester);

    expect(find.text('NYX'), findsOneWidget);
    expect(find.byKey(plus), findsNothing);
    expect(find.text('+  NO OTHER HOST HAS DEVICES ON'), findsOneWidget);
    expect(nyx.frameStreams, isEmpty);

    await _pick(tester, _iphone, host: 'h2');
    expect(rose.frameStreams.single.hasListener, isFalse);
    expect(nyx.frameStreams.single.hasListener, isTrue);
    expect(rose.closed, isFalse);

    await _fold(tester);
    await _pick(tester, _pixel);
    expect(rose.frameStreams, hasLength(2));
    expect(rose.frameStreams.last.hasListener, isTrue);
    expect(nyx.frameStreams.single.hasListener, isFalse);
    expect(nyx.closed, isFalse);

    await tester.pumpWidget(const SizedBox());
    expect(rose.closed, isTrue);
    expect(nyx.closed, isTrue);
  });

  testWidgets('a tap on the picture lands in device pixels', (tester) async {
    tester.view.physicalSize = const Size(540, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final link = FakeDeviceLink(const [_pixel]);
    await _pump(tester, _opener(link));
    await _pick(tester, _pixel);
    await _live(tester, link);
    await _expand(tester);
    expect(find.text('BACK'), findsOneWidget);
    expect(find.text('VIEW ONLY'), findsNothing);

    link.frameStreams.single.add(_frame());
    await _settle(tester);
    final picture = tester.getRect(find.byType(RawImage));
    await tester.tapAt(picture.center);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('HOME'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(link.commands, [
      "adb -s 'emulator-5554' shell input tap 540 1200",
      "adb -s 'emulator-5554' shell input keyevent 3",
    ]);

    link.frameStreams.single.addError(const DeviceCaptureFailed('gone'));
    await _settle(tester);
    expect(find.text('stream closed'), findsOneWidget);

    await tester.tap(find.text('RETRY'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(link.frameStreams, hasLength(2));

    await tester.tap(find.text('/ ROSE PIXEL_7-API36'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('/ ROSE PIXEL_7-API36'), findsNothing);
    expect(find.byKey(_floatKey), findsOneWidget);
    expect(link.frameStreams.last.hasListener, isTrue);
  });

  testWidgets('a simulator is only watched', (tester) async {
    final link = FakeDeviceLink(const [_iphone]);
    await _pump(tester, _opener(link));
    await _pick(tester, _iphone);
    link.frameStreams.single.add(_frame(width: 1206, height: 2622));
    await _settle(tester);
    await _expand(tester);

    expect(find.text('VIEW ONLY'), findsOneWidget);
    expect(find.text('BACK'), findsNothing);
    await tester.tapAt(tester.getCenter(find.byType(RawImage)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(link.commands, isEmpty);
  });

  test('a paused stream stays paused when the app comes back', () async {
    final link = FakeDeviceLink(const []);
    final controller = DeviceScreenController(
      hostName: 'rose',
      link: link,
      device: _pixel,
    )..start();
    addTearDown(controller.dispose);

    await controller.pause();
    await controller.setAway(true);
    await controller.setAway(false);
    expect(link.frameStreams, hasLength(1));
    expect(controller.phase, isA<DevicePaused>());

    await controller.setAway(true);
    controller.resume();
    expect(link.frameStreams, hasLength(1));
    await controller.setAway(false);
    expect(link.frameStreams, hasLength(2));
    expect(link.frameStreams.last.hasListener, isTrue);
  });

  testWidgets('a float keeps its controls down until tapped', (tester) async {
    final link = FakeDeviceLink(const [_pixel, _iphone]);
    await _pump(tester, _opener(link));
    await _pick(tester, _pixel);
    await _live(tester, link);

    expect(find.byKey(_overlayKey), findsNothing);
    expect(find.text('PAUSE'), findsNothing);

    await _tapKey(tester, _floatKey);
    expect(find.byKey(_overlayKey), findsOneWidget);

    await _dismiss(tester);
    expect(find.byKey(_overlayKey), findsNothing);

    await _tapKey(tester, _floatKey);
    await tester.tap(find.text('PAUSE'));
    await tester.pump();
    expect(link.frameStreams.single.hasListener, isFalse);
    expect(find.text('RESUME'), findsOneWidget);

    await _dismiss(tester);
    expect(find.byKey(const ValueKey('device-float-paused')), findsOneWidget);

    await _tapKey(tester, _floatKey);
    await tester.tap(find.text('RESUME'));
    await tester.pump();
    expect(link.frameStreams, hasLength(2));

    await _tapKey(tester, const ValueKey('device-float-expand'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('/ ROSE PIXEL_7-API36'), findsOneWidget);
    expect(find.byKey(_floatKey), findsNothing);
    expect(link.frameStreams, hasLength(2));

    await tester.tap(find.text('/ ROSE PIXEL_7-API36'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(_floatKey), findsOneWidget);
    expect(link.frameStreams, hasLength(2));
    expect(link.frameStreams.last.hasListener, isTrue);
    expect(link.closed, isFalse);
  });

  testWidgets('collapsing folds the window into the bar, paused till picked', (
    tester,
  ) async {
    final link = FakeDeviceLink(const [_pixel]);
    await _pump(tester, _opener(link));
    await _pick(tester, _pixel);
    await _live(tester, link);

    await _fold(tester);
    expect(find.byKey(_bubbleKey), findsOneWidget);
    expect(find.byType(RawImage), findsNothing);
    expect(link.frameStreams.single.hasListener, isFalse);
    expect(link.closed, isFalse);

    await _pick(tester, _pixel);
    expect(find.byKey(_barKey), findsNothing);
    expect(find.byKey(_overlayKey), findsNothing);
    expect(link.frameStreams, hasLength(2));
    expect(link.frameStreams.last.hasListener, isTrue);

    await tester.drag(find.byKey(_floatKey), const Offset(400, 0));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(_bubbleKey), findsOneWidget);
    expect(link.frameStreams.last.hasListener, isFalse);

    await _pick(tester, _pixel);
    await _live(tester, link);
    await _tapKey(tester, _floatKey);
    await tester.tap(find.text('PAUSE'));
    await tester.pump();
    await _tapKey(tester, const ValueKey('device-float-collapse'));
    await _pick(tester, _pixel);
    expect(link.frameStreams, hasLength(3));
    expect(find.byKey(const ValueKey('device-float-paused')), findsOneWidget);
  });

  testWidgets('the window and the bar close from their glyphs or the target', (
    tester,
  ) async {
    final link = FakeDeviceLink(const [_pixel]);
    await _pump(tester, _opener(link));
    await _pick(tester, _pixel);
    await _live(tester, link);

    Future<void> dropOnTarget(Finder handle) async {
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await gesture.moveBy(const Offset(-20, 0));
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
      final target = find.byKey(const ValueKey('device-float-target'));
      expect(target, findsOneWidget);
      await gesture.moveTo(tester.getCenter(target));
      await tester.pump();
      await gesture.up();
      await tester.pump();
    }

    Future<void> reopen() async {
      link.closed = false;
      await tester.tap(find.text('DEVICES'));
      await _settle(tester);
    }

    await dropOnTarget(find.byKey(_floatKey));
    expect(find.byKey(_floatKey), findsNothing);
    expect(find.byKey(_barKey), findsNothing);
    expect(link.frameStreams.single.hasListener, isFalse);
    expect(link.closed, isTrue);

    await reopen();
    await dropOnTarget(find.byKey(_bubbleKey));
    expect(find.byKey(_bubbleKey), findsNothing);
    expect(link.closed, isTrue);

    await reopen();
    await _open(tester);
    await dropOnTarget(
      find.descendant(of: find.byKey(_barKey), matching: find.text('DEVICES')),
    );
    expect(find.byKey(_barKey), findsNothing);
    expect(link.closed, isTrue);

    await reopen();
    await _open(tester);
    await _tapKey(tester, const ValueKey('device-list-close'));
    expect(find.byKey(_barKey), findsNothing);
    expect(link.closed, isTrue);

    await reopen();
    await _pick(tester, _pixel);
    await _live(tester, link);
    await _tapKey(tester, _floatKey);
    await _tapKey(tester, const ValueKey('device-float-close'));
    expect(find.byKey(_floatKey), findsNothing);
    expect(find.byKey(_barKey), findsNothing);
    expect(link.frameStreams.last.hasListener, isFalse);
    expect(link.closed, isTrue);
  });

  testWidgets(
    'minimize is apart from END, and every control is a full target',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final link = FakeDeviceLink(const [_pixel]);
      await _pump(tester, _opener(link));
      expect(
        tester.getSemantics(find.byKey(_bubbleKey)),
        isSemantics(label: 'DEVICES', isButton: true),
      );

      await _open(tester);
      await _tapKey(tester, const ValueKey('device-list-outside'));
      expect(find.byKey(_barKey), findsNothing);
      expect(find.byKey(_bubbleKey), findsOneWidget);

      await _open(tester);
      await _tapKey(tester, const ValueKey('device-list-minimize'));
      expect(find.byKey(_bubbleKey), findsOneWidget);
      expect(link.closed, isFalse);

      await _pick(tester, _pixel);
      await _live(tester, link);
      await _tapKey(tester, _floatKey);
      for (final key in const [
        'device-float-expand',
        'device-float-collapse',
        'device-float-close',
      ]) {
        final size = tester.getSize(find.byKey(ValueKey(key)));
        expect(size.width, greaterThanOrEqualTo(44), reason: key);
        expect(size.height, greaterThanOrEqualTo(44), reason: key);
      }
      expect(find.bySemanticsLabel('MINIMIZE'), findsOneWidget);
      expect(find.bySemanticsLabel('FULL SCREEN'), findsOneWidget);
      expect(find.bySemanticsLabel('END'), findsOneWidget);

      await _tapKey(tester, const ValueKey('device-float-collapse'));
      expect(find.byKey(_bubbleKey), findsOneWidget);
      expect(link.frameStreams.single.hasListener, isFalse);
      expect(link.closed, isFalse);
      semantics.dispose();
    },
  );

  testWidgets('a pinch resizes the float within its bounds', (tester) async {
    final link = FakeDeviceLink(const [_pixel]);
    await _pump(tester, _opener(link));
    await _pick(tester, _pixel);
    await _live(tester, link);

    Future<void> pinch(double spread) async {
      final center = tester.getCenter(find.byKey(_floatKey));
      final a = await tester.startGesture(center - const Offset(40, 0));
      final b = await tester.startGesture(center + const Offset(40, 0));
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        await a.moveBy(Offset(-spread / 20, 0));
        await b.moveBy(Offset(spread / 20, 0));
        await tester.pump();
      }
      await a.up();
      await b.up();
      await tester.pump(const Duration(milliseconds: 400));
    }

    expect(tester.getSize(find.byKey(_floatKey)).width, deviceFloatWidth);
    await pinch(40);
    final grown = tester.getSize(find.byKey(_floatKey)).width;
    expect(grown, greaterThan(deviceFloatWidth));
    await pinch(4000);
    final widest = tester.getRect(find.byKey(_floatKey));
    expect(widest.width, lessThan(800 * deviceFloatMaxShare));
    expect(widest.width, greaterThan(grown));
    expect(widest.bottom, lessThan(600 - deviceFloatClearance + 1));
    await pinch(-60);
    await pinch(-60);
    expect(tester.getSize(find.byKey(_floatKey)).width, deviceFloatMinWidth);
  });

  testWidgets('PAUSE stops the loop, and so does hiding the app', (
    tester,
  ) async {
    addTearDown(() => _lifecycle(tester, const [AppLifecycleState.resumed]));
    final link = FakeDeviceLink(const [_pixel]);
    await _pump(tester, _opener(link));
    await _pick(tester, _pixel);
    await _live(tester, link);
    await _expand(tester);

    await tester.tap(find.text('PAUSE'));
    await tester.pump();
    expect(link.frameStreams.single.hasListener, isFalse);
    await tester.tap(find.text('HOME'));
    await tester.pump();
    expect(link.commands, isEmpty);

    await tester.tap(find.text('RESUME'));
    await tester.pump();
    expect(link.frameStreams, hasLength(2));
    link.frameStreams.last.add(_frame());
    await _settle(tester);
    expect(find.text('PAUSE'), findsOneWidget);

    _lifecycle(tester, const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
    ]);
    await tester.pump();
    expect(link.frameStreams.last.hasListener, isFalse);

    _lifecycle(tester, const [
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]);
    await tester.pump();
    expect(link.frameStreams, hasLength(3));
    expect(link.frameStreams.last.hasListener, isTrue);
  });

  group('under a light theme the float keeps the house ink', () {
    const house = DazzleTokens.house;
    final light = dazzleTokensFromScheme(
      ColorScheme.fromSeed(
        seedColor: Colors.indigo,
        brightness: Brightness.light,
      ),
    );
    final theme = DazzleTheme.build(light);
    final inks = {
      house.textPrimary,
      house.textMuted,
      house.accent,
      house.warning,
    };

    Color icon(WidgetTester tester, Finder under) => tester
        .widget<DazzleIcon>(
          find.descendant(of: under, matching: find.byType(DazzleIcon)),
        )
        .color;

    Color? ink(Element text) =>
        (text.renderObject! as RenderParagraph).text.style?.color;

    Future<FakeDeviceLink> window(WidgetTester tester) async {
      final link = FakeDeviceLink(const [_pixel]);
      await _pump(tester, _opener(link), theme: theme);
      await _pick(tester, _pixel);
      return link;
    }

    test('the light ink is not the house ink', () {
      expect(light.textPrimary, isNot(house.textPrimary));
      expect(light.textMuted, isNot(house.textMuted));
    });

    testWidgets('on the bubble', (tester) async {
      await _pump(
        tester,
        _opener(FakeDeviceLink(const [_pixel])),
        theme: theme,
      );
      expect(icon(tester, find.byKey(_bubbleKey)), house.textPrimary);
    });

    testWidgets('on the window before its first frame', (tester) async {
      await window(tester);
      final state = find.descendant(
        of: find.byKey(_floatKey),
        matching: find.text('CONNECTING'),
      );
      expect(inks, contains(ink(state.evaluate().single)));
    });

    testWidgets('on the overlay', (tester) async {
      final link = await window(tester);
      await _live(tester, link);
      await _tapKey(tester, _floatKey);
      final overlay = find.byKey(_overlayKey);
      final glyphs = find.descendant(
        of: overlay,
        matching: find.byType(DazzleIcon),
      );
      final words = find.descendant(
        of: overlay,
        matching: find.byType(RichText),
      );
      expect(glyphs, findsNWidgets(2));
      expect(words, findsAtLeastNWidgets(2));
      for (final glyph in tester.widgetList<DazzleIcon>(glyphs)) {
        expect(inks, contains(glyph.color));
      }
      for (final word in words.evaluate()) {
        expect(inks, contains(ink(word)));
      }
    });

    testWidgets('on the paused mark', (tester) async {
      final link = await window(tester);
      await _live(tester, link);
      await _tapKey(tester, _floatKey);
      await tester.tap(find.text('PAUSE'));
      await tester.pump();
      await _dismiss(tester);
      final bar = tester.widget<ColoredBox>(
        find
            .descendant(
              of: find.byKey(const ValueKey('device-float-paused')),
              matching: find.byType(ColoredBox),
            )
            .first,
      );
      expect(bar.color, house.textPrimary);
    });

    testWidgets('on the close target, cold and hot', (tester) async {
      final link = await window(tester);
      await _live(tester, link);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(_floatKey)),
      );
      await gesture.moveBy(const Offset(-20, 0));
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
      final target = find.byKey(const ValueKey('device-float-target'));
      expect(icon(tester, target), house.textMuted);
      await gesture.moveTo(tester.getCenter(target));
      await tester.pump();
      expect(icon(tester, target), house.accent);
      await gesture.up();
      await tester.pump();
    });
  });

  testWidgets('a long device name breaks after an underscore', (tester) async {
    const raw = 'medium_phone_API_36_with_a_long_name';
    const long = HostDevice(
      kind: DeviceKind.android,
      id: 'emulator-5556',
      name: raw,
    );
    final semantics = tester.ensureSemantics();
    await _pump(tester, _opener(FakeDeviceLink(const [long])));
    await _open(tester);
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.byKey(const ValueKey('device-tab-h1-emulator-5556')),
        matching: find.byType(RichText),
      ),
    );
    final shown = paragraph.text.toPlainText();
    final tops = {
      for (final box in paragraph.getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: shown.length),
      ))
        box.top,
    }.toList()..sort();
    expect(tops, hasLength(2));
    final second = paragraph
        .getPositionForOffset(Offset(0, tops[1] + 1))
        .offset;
    expect(shown.substring(0, second).replaceAll('\u200B', ''), endsWith('_'));
    expect(find.bySemanticsLabel(raw), findsOneWidget);
    semantics.dispose();
  });
}
