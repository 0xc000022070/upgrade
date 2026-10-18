import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/application/agents/agents.dart';
import 'package:striked/application/navigation.dart';
import 'package:striked/application/pip.dart';
import 'package:striked/app/pip_host.dart';
import 'package:striked/application/providers.dart';
import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/design/dynamic_tokens.dart';
import 'package:striked/design/effects/glitch.dart';
import 'package:striked/design/icons/striked_icon.dart';
import 'package:striked/design/theme.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/features/devices/device_controllers.dart';
import 'package:striked/features/devices/device_dock.dart';
import 'package:striked/features/devices/device_float.dart';
import 'package:striked/features/devices/screens_action.dart';
import 'package:striked/features/screen/screen_preview.dart';
import 'package:striked/platform/devices/device_link.dart';
import 'package:striked/platform/herdr/herdr_client.dart';
import 'package:striked/platform/ssh/host_keys.dart';
import 'package:striked/platform/ssh/keys.dart';
import 'package:striked/platform/vnc/vnc_tunnel.dart';

import '../../support/fake_pip.dart';
import '../../support/platform_channels.dart';
import '../../support/vnc_channel.dart';
import '../../support/themed_app.dart';

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

  final reads = <String>[];
  final answers = <String, String>{};
  final held = <String, Completer<String>>{};

  @override
  Future<String> read(String command, {Duration? limit}) async {
    reads.add(command);
    for (final MapEntry(:key, :value) in held.entries) {
      if (!command.contains(key)) continue;
      final pending = value.future;
      return limit == null ? pending : pending.timeout(limit);
    }
    for (final MapEntry(:key, :value) in answers.entries) {
      if (command.contains(key)) return value;
    }
    return 'OK\n';
  }

  int readsOf(String part) =>
      reads.where((command) => command.contains(part)).length;

  @override
  bool closed = false;

  @override
  Future<void> close() async {
    closed = true;
    for (final pending in held.values) {
      if (!pending.isCompleted) pending.completeError(StateError('ended'));
    }
  }
}

const _bootPart = '-no-window';
const _stoppedPart = 'emulator -list-avds';
const _killPart = 'emu kill';
const _avdDeletePart = 'avdmanager delete avd';

const _sims = '''
{"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
  {"udid": "SIM-1", "name": "iPhone Air", "state": "Shutdown", "isAvailable": true}
]}}''';

const _booted = HostDevice(
  kind: DeviceKind.android,
  id: 'emulator-5556',
  name: 'Pixel_9',
  avd: 'Pixel_9',
);

FakeDeviceLink _hostLink([List<HostDevice> devices = const [_pixel]]) =>
    FakeDeviceLink(devices)
      ..answers[_stoppedPart] = 'T A\nE Pixel_9\nT I\n@simctl\n$_sims\n';

Future<void> _openSheet(WidgetTester tester) async {
  if (find.byKey(_bubbleKey).evaluate().isNotEmpty) await _open(tester);
  await tester.tap(find.byKey(const ValueKey('device-group-plus-h1')));
  await _settle(tester);
}

Future<void> _longPress(WidgetTester tester, Key key) async {
  if (find.byKey(_bubbleKey).evaluate().isNotEmpty) await _open(tester);
  await tester.longPress(find.byKey(key));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

DeviceDock _dock(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(DeviceFloat)))
        .read(deviceDockProvider);

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
  List<Host> desktops = const [],
  VncOpener? vnc,
  bool show = true,
  ThemeData? theme,
  FakePip? pip,
  String? remembered,
  List<String>? remembers,
}) async {
  stubDeviceChannels();
  final saved = StreamController<String?>()..add(remembered);
  addTearDown(() => unawaited(saved.close()));
  final store = MemoryPrivateKeyStore();
  await store.write(_rose.keyId, 'PRIVATE');
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        screensHostProvider.overrideWith((ref) => saved.stream),
        rememberScreensHostProvider.overrideWithValue((hostId) async {
          remembers?.add(hostId);
          saved.add(hostId);
        }),
        privateKeyStoreProvider.overrideWithValue(store),
        staticEnabledProvider.overrideWith((ref) => Stream.value(false)),
        deviceLinkOpenerProvider.overrideWithValue(open),
        deviceHostsProvider.overrideWith((ref) => Stream.value(hosts)),
        vncHostsProvider.overrideWith((ref) => Stream.value(desktops)),
        if (vnc != null) vncOpenerProvider.overrideWithValue(vnc),
        if (pip != null) pipSurfaceProvider.overrideWithValue(pip),
      ],
      child: MaterialApp(
        theme: theme ?? testTheme,
        navigatorKey: rootNavigatorKey,
        navigatorObservers: [rootRoutes],
        builder: (context, child) => pip == null
            ? DeviceFloat(child: child!)
            : PipHost(child: DeviceFloat(child: child!)),
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: () => ref.read(deviceDockProvider).show(_rose),
                    child: const Text('DEVICES'),
                  ),
                  const ScreensAction(),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  if (!show) return _settle(tester);
  await tester.tap(find.text('DEVICES'));
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _show(
  WidgetTester tester,
  StreamController<DeviceFrame> stream, [
  DeviceFrame? frame,
]) async {
  final controller = _dock(tester).session!.controller;
  final before = controller.image;
  stream.add(frame ?? _frame());
  await tester.runAsync(() async {
    for (var i = 0; i < 2500 && identical(controller.image, before); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  });
  await _settle(tester);
}

Future<void> _live(WidgetTester tester, FakeDeviceLink link) =>
    _show(tester, link.frameStreams.last);

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
  test('a renamed host is renamed on the groups the dock holds', () async {
    final dock = DeviceDock(
      group: (host, dock) => DevicesController(
        host: host,
        dock: dock,
        readPrivateKey: (_) async => null,
        open: ({
          required address,
          required port,
          required user,
          required privateKey,
          required verifier,
        }) => Completer<DeviceLink>().future,
      ),
      desktopOf: (_) => throw UnimplementedError(),
    );
    addTearDown(dock.dispose);
    dock.attach(const [_rose, _nyx]);
    await Future<void>.delayed(Duration.zero);
    var told = 0;
    dock.addListener(() => told++);

    dock.rename(const [
      Host(
        id: 'h1',
        name: 'mark',
        address: '10.0.2.2',
        port: 22,
        user: 'luisnquin',
        keyId: 'k1',
      ),
      _nyx,
    ]);

    expect([for (final group in dock.groups) group.host.name], ['mark', 'nyx']);
    expect(told, 1);
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
    expect(find.text('SCREENS'), findsOneWidget);
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

    link.devices = const [_pixel];
    await tester.tap(find.text('NONE'));
    await _settle(tester);
    expect(find.text('NONE'), findsNothing);
    link.devices = const [];

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

    await tester.tap(find.text('rose unreachable'));
    await _settle(tester);
    expect(find.text('rose unreachable'), findsNothing);
    await _pick(tester, _pixel);
    expect(link.frameStreams.single.hasListener, isTrue);
  });

  testWidgets('every host with devices on is listed, and its tabs move the '
      'stream', (tester) async {
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
    await _open(tester);
    await _settle(tester);
    await tester.tap(find.text('ROSE'));
    await tester.pump();
    await _pick(tester, _pixel);
    await _live(tester, rose);
    await _fold(tester);
    await _open(tester);
    await _settle(tester);

    expect(find.text('NYX'), findsOneWidget);
    expect(find.byKey(ValueKey('device-tab-h2-${_iphone.id}')), findsNothing);
    expect(nyx.frameStreams, isEmpty);

    await tester.tap(find.text('NYX'));
    await tester.pump();
    await _pick(tester, _iphone, host: 'h2');
    expect(rose.frameStreams.single.hasListener, isFalse);
    expect(nyx.frameStreams.single.hasListener, isTrue);
    expect(rose.closed, isFalse);

    await _fold(tester);
    await _open(tester);
    await tester.tap(find.text('ROSE'));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('device-group-h2')),
        matching: find.text('HELD'),
      ),
      findsOneWidget,
    );
    await _pick(tester, _pixel);
    expect(rose.frameStreams, hasLength(2));
    expect(rose.frameStreams.last.hasListener, isTrue);
    expect(nyx.frameStreams.single.hasListener, isFalse);
    expect(nyx.closed, isFalse);

    await tester.pumpWidget(const SizedBox());
    expect(rose.closed, isTrue);
    expect(nyx.closed, isTrue);
  });

  testWidgets('the host last opened from is the one the list opens on', (
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
    final remembers = <String>[];

    await _pump(
      tester,
      open,
      hosts: const [_rose, _nyx],
      remembered: 'h2',
      remembers: remembers,
    );
    await _open(tester);
    await _settle(tester);
    final iphone = find.byKey(ValueKey('device-tab-h2-${_iphone.id}'));
    final pixel = find.byKey(ValueKey('device-tab-h1-${_pixel.id}'));
    expect(iphone, findsOneWidget);
    expect(pixel, findsNothing);
    expect(
      tester.getTopLeft(find.text('NYX')).dy,
      lessThan(tester.getTopLeft(find.text('ROSE')).dy),
    );

    await tester.tap(find.text('ROSE'));
    await tester.pump();
    expect(pixel, findsOneWidget);
    expect(iphone, findsNothing);
    expect(remembers, isEmpty);

    await _pick(tester, _pixel);
    expect(remembers, ['h1']);
    await _fold(tester);
    await _open(tester);
    expect(pixel, findsOneWidget);
    expect(iphone, findsNothing);
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

    await _show(tester, link.frameStreams.single);
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
    await _show(
      tester,
      link.frameStreams.single,
      _frame(width: 1206, height: 2622),
    );
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

    await tester.drag(find.byKey(_floatKey), const Offset(-400, 0));
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
    expect(find.byKey(_bubbleKey), findsOneWidget);
    expect(link.frameStreams.single.hasListener, isFalse);
    expect(link.closed, isFalse);

    await dropOnTarget(find.byKey(_bubbleKey));
    expect(find.byKey(_bubbleKey), findsNothing);
    expect(link.closed, isTrue);

    await reopen();
    await _open(tester);
    await dropOnTarget(
      find.descendant(of: find.byKey(_barKey), matching: find.text('SCREENS')),
    );
    expect(find.byKey(_barKey), findsNothing);
    expect(link.closed, isTrue);

    await reopen();
    await _pick(tester, _pixel);
    await _live(tester, link);
    await _tapKey(tester, _floatKey);
    await _tapKey(tester, const ValueKey('device-float-close'));
    expect(find.byKey(_floatKey), findsNothing);
    expect(find.byKey(_bubbleKey), findsOneWidget);
    expect(link.frameStreams.last.hasListener, isFalse);
    expect(link.closed, isFalse);
  });

  testWidgets(
    'minimize is apart from END, and every control is a full target',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final link = FakeDeviceLink(const [_pixel]);
      await _pump(tester, _opener(link));
      expect(
        tester.getSemantics(find.byKey(_bubbleKey)),
        isSemantics(label: 'SCREENS', isButton: true),
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
        'device-float-size',
        'device-float-close',
      ]) {
        final size = tester.getSize(find.byKey(ValueKey(key)));
        expect(size.width, greaterThanOrEqualTo(44), reason: key);
        expect(size.height, greaterThanOrEqualTo(44), reason: key);
      }
      expect(find.bySemanticsLabel('MINIMIZE'), findsOneWidget);
      expect(find.bySemanticsLabel('FULL SCREEN'), findsOneWidget);
      expect(find.bySemanticsLabel('END'), findsOneWidget);
      expect(find.bySemanticsLabel('SIZE'), findsOneWidget);

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

  testWidgets('SIZE steps the float through its widths on the same stream', (
    tester,
  ) async {
    final link = FakeDeviceLink(const [_pixel]);
    await _pump(tester, _opener(link));
    await _pick(tester, _pixel);
    await _live(tester, link);
    final controller = _dock(tester).session!.controller;

    Future<Rect> size() async {
      await _tapKey(tester, const ValueKey('device-float-size'));
      expect(find.byKey(_overlayKey), findsOneWidget);
      return tester.getRect(find.byKey(_floatKey));
    }

    await _tapKey(tester, _floatKey);
    final middle = await size();
    final widest = await size();
    expect(middle.width, (deviceFloatWidth + widest.width) / 2);
    expect(widest.width, lessThanOrEqualTo(800 * deviceFloatMaxShare));
    expect(widest.bottom, lessThan(600 - deviceFloatClearance + 1));
    expect(controller.decodeWidth, greaterThan(floatDecodeWidth));

    expect((await size()).width, deviceFloatWidth);
    expect(controller.decodeWidth, floatDecodeWidth);
    expect(link.frameStreams.single.hasListener, isTrue);
    expect(link.closed, isFalse);
  });

  testWidgets('a row says what it is, and what its hold is', (tester) async {
    final link = FakeDeviceLink(const [_pixel, _iphone]);
    await _pump(tester, _opener(link));
    await _open(tester);

    Finder tag(HostDevice device, String word) => find.descendant(
      of: find.byKey(ValueKey('device-tab-h1-${device.id}')),
      matching: find.text(word),
    );

    expect(tag(_pixel, 'EMULATOR'), findsOneWidget);
    expect(tag(_iphone, 'SIMULATOR'), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(_barKey), matching: find.text('DEVICES')),
      findsNothing,
    );

    await _pick(tester, _pixel);
    await _live(tester, link);
    await _open(tester);
    expect(tag(_pixel, 'LIVE'), findsOneWidget);
    expect(tag(_iphone, 'SIMULATOR'), findsOneWidget);

    await _tapKey(tester, const ValueKey('device-list-handle'));
    await _fold(tester);
    await _open(tester);
    expect(tag(_pixel, 'HELD'), findsOneWidget);
  });

  testWidgets('a window parks its own stream in picture-in-picture', (
    tester,
  ) async {
    final pip = FakePip();
    final link = FakeDeviceLink(const [_pixel]);
    await _pump(tester, _opener(link), pip: pip);
    await _pick(tester, _pixel);
    await _live(tester, link);
    await _tapKey(tester, _floatKey);
    await _tapKey(tester, const ValueKey('device-float-pip'));
    expect(pip.entries, 1);
    expect(pip.aspect, isNotNull);
    expect(pip.aspect!.isEmpty, isFalse);

    pip.modes.add(true);
    await _settle(tester);
    const window = ValueKey('screen-pip');
    expect(
      find.descendant(of: find.byKey(window), matching: find.byType(RawImage)),
      findsOneWidget,
    );
    expect(link.frameStreams.last.hasListener, isTrue);

    pip.modes.add(false);
    await _settle(tester);
    expect(find.byKey(window), findsNothing);
    expect(find.byKey(_floatKey), findsOneWidget);
    expect(link.frameStreams.last.hasListener, isTrue);
  });

  testWidgets('a float too narrow for its glyphs keeps them on its edges', (
    tester,
  ) async {
    final link = FakeDeviceLink(const [_pixel]);
    await _pump(tester, _opener(link), pip: FakePip());
    await _pick(tester, _pixel);
    await _live(tester, link);
    await _tapKey(tester, _floatKey);
    final float = tester.getRect(find.byKey(_floatKey));
    final expand = tester.getRect(
      find.byKey(const ValueKey('device-float-expand')),
    );
    final collapse = tester.getRect(
      find.byKey(const ValueKey('device-float-collapse')),
    );
    final close = tester.getRect(
      find.byKey(const ValueKey('device-float-close')),
    );
    expect(expand.top - float.top, lessThan(4));
    expect(expand.left - float.left, lessThan(4));
    expect(float.right - collapse.right, lessThan(4));
    expect(float.bottom - close.bottom, lessThan(4));
  });

  testWidgets('a window offers no picture-in-picture without one', (
    tester,
  ) async {
    final link = FakeDeviceLink(const [_pixel]);
    await _pump(tester, _opener(link), pip: FakePip(here: false));
    await _pick(tester, _pixel);
    await _live(tester, link);
    await _tapKey(tester, _floatKey);
    expect(find.byKey(const ValueKey('device-float-collapse')), findsOneWidget);
    expect(find.byKey(const ValueKey('device-float-pip')), findsNothing);
  });

  testWidgets('a short throw carries the float to the far side', (
    tester,
  ) async {
    final link = FakeDeviceLink(const [_pixel]);
    await _pump(tester, _opener(link));
    await _pick(tester, _pixel);
    await _live(tester, link);

    final from = tester.getCenter(find.byKey(_floatKey));
    expect(from.dx, lessThan(400));
    await tester.fling(find.byKey(_floatKey), const Offset(150, 0), 2000);
    await tester.pumpAndSettle();
    expect(tester.getCenter(find.byKey(_floatKey)).dx, greaterThan(400));
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
    await _show(tester, link.frameStreams.last);
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

  testWidgets('a window left by BACK streams again when the app comes back', (
    tester,
  ) async {
    addTearDown(() => _lifecycle(tester, const [AppLifecycleState.resumed]));
    final link = FakeDeviceLink(const [_pixel]);
    await _pump(tester, _opener(link));
    await _pick(tester, _pixel);
    await _live(tester, link);

    _lifecycle(tester, const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]);
    await tester.pump();
    expect(link.frameStreams.single.hasListener, isFalse);

    _lifecycle(tester, const [AppLifecycleState.resumed]);
    await tester.pump();
    expect(link.frameStreams, hasLength(2));
    expect(link.frameStreams.last.hasListener, isTrue);
  });

  group('a connection the phone dropped', () {
    late List<FakeDeviceLink> links;
    late int dials;

    Future<void> window(WidgetTester tester) async {
      links = [
        FakeDeviceLink(const [_pixel]),
        FakeDeviceLink(const [_pixel]),
      ];
      dials = 0;
      Future<DeviceLink> open({
        required String address,
        required int port,
        required String user,
        required String privateKey,
        HostKeyVerifier? verifier,
      }) async => links[dials++];

      await _pump(tester, open);
      await _pick(tester, _pixel);
      await _live(tester, links.first);
    }

    void hide(WidgetTester tester) => _lifecycle(tester, const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
    ]);

    void show(WidgetTester tester) => _lifecycle(tester, const [
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]);

    testWidgets('while the app was hidden is dialled again on return', (
      tester,
    ) async {
      addTearDown(() => show(tester));
      await window(tester);
      hide(tester);
      await tester.pump();
      links.first.closed = true;
      show(tester);
      await _settle(tester);

      expect(dials, 2);
      expect(links.first.frameStreams, hasLength(1));
      expect(links.last.frameStreams.single.hasListener, isTrue);
    });

    testWidgets('and only noticed on return is dialled again once', (
      tester,
    ) async {
      addTearDown(() => show(tester));
      await window(tester);
      hide(tester);
      await tester.pump();
      show(tester);
      await tester.pump();
      links.first.frameStreams.last.addError(const HerdrUnreachable('103'));
      await _settle(tester);

      expect(dials, 2);
      expect(links.last.frameStreams.single.hasListener, isTrue);

      links.last.frameStreams.last.addError(const HerdrUnreachable('103'));
      await _settle(tester);
      expect(dials, 2);
      expect(find.byKey(const ValueKey('device-float-failed')), findsOneWidget);
    });

    testWidgets('is marked on the frozen frame, and RETRY dials again', (
      tester,
    ) async {
      await window(tester);
      links.first.frameStreams.last.addError(const HerdrUnreachable('103'));
      await _settle(tester);
      expect(find.byKey(const ValueKey('device-float-failed')), findsOneWidget);
      expect(dials, 1);

      await _tapKey(tester, _floatKey);
      await tester.tap(find.text('RETRY'));
      await _settle(tester);

      expect(dials, 2);
      expect(links.last.frameStreams.single.hasListener, isTrue);
    });

    testWidgets('before the first frame of a new window is not redialled', (
      tester,
    ) async {
      links = [
        FakeDeviceLink(const [_pixel]),
        FakeDeviceLink(const [_pixel]),
      ];
      dials = 0;
      Future<DeviceLink> open({
        required String address,
        required int port,
        required String user,
        required String privateKey,
        HostKeyVerifier? verifier,
      }) async => links[dials++];

      await _pump(tester, open);
      await _pick(tester, _pixel);
      links.first.frameStreams.last.addError(const HerdrUnreachable('103'));
      await _settle(tester);

      expect(dials, 1);
      expect(links.first.frameStreams, hasLength(1));
    });

    testWidgets('is not what a failed capture is, so RETRY keeps the link', (
      tester,
    ) async {
      await window(tester);
      links.first.frameStreams.last.addError(const DeviceCaptureFailed('x'));
      await _settle(tester);

      await _tapKey(tester, _floatKey);
      await tester.tap(find.text('RETRY'));
      await _settle(tester);

      expect(dials, 1);
      expect(links.first.frameStreams, hasLength(2));
    });

    testWidgets('under the bubble alone is dialled again on return', (
      tester,
    ) async {
      addTearDown(() => show(tester));
      links = [
        FakeDeviceLink(const [_pixel]),
        FakeDeviceLink(const [_pixel]),
      ];
      dials = 0;
      Future<DeviceLink> open({
        required String address,
        required int port,
        required String user,
        required String privateKey,
        HostKeyVerifier? verifier,
      }) async => links[dials++];

      await _pump(tester, open);
      hide(tester);
      await tester.pump();
      links.first.closed = true;
      show(tester);
      await _settle(tester);
      await _pick(tester, _pixel);

      expect(dials, 2);
      expect(links.last.frameStreams.single.hasListener, isTrue);
    });
  });

  group('under a light theme the float keeps the house ink', () {
    const house = StrikedTokens.house;
    final light = strikedTokensFromScheme(
      ColorScheme.fromSeed(
        seedColor: Colors.indigo,
        brightness: Brightness.light,
      ),
    );
    final theme = StrikedTheme.build(light);
    final inks = {
      house.textPrimary,
      house.textMuted,
      house.accent,
      house.warning,
    };

    Color icon(WidgetTester tester, Finder under) => tester
        .widget<StrikedIcon>(
          find.descendant(of: under, matching: find.byType(StrikedIcon)),
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
        matching: find.byType(StrikedIcon),
      );
      final words = find.descendant(
        of: overlay,
        matching: find.byType(RichText),
      );
      expect(glyphs, findsNWidgets(2));
      expect(words, findsAtLeastNWidgets(2));
      for (final glyph in tester.widgetList<StrikedIcon>(glyphs)) {
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
      find
          .descendant(
            of: find.byKey(const ValueKey('device-tab-h1-emulator-5556')),
            matching: find.byType(RichText),
          )
          .first,
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
    expect(
      find.bySemanticsLabel(RegExp('^${RegExp.escape(raw)}\\n')),
      findsOneWidget,
    );
    semantics.dispose();
  });

  group('booting and removing', () {
    testWidgets('+ lists what is shut down, over a hidden bar', (tester) async {
      final link = _hostLink();
      await _pump(tester, _opener(link));
      await _openSheet(tester);

      expect(find.byKey(const ValueKey('device-sheet')), findsOneWidget);
      expect(find.text('ROSE DEVICES'), findsOneWidget);
      expect(find.byKey(_barKey), findsNothing);
      expect(
        find.byKey(const ValueKey('device-stopped-Pixel_9')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('device-stopped-SIM-1')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('device-sheet-new')), findsOneWidget);

      await tester.tapAt(const Offset(4, 4));
      await _settle(tester);
      expect(find.byKey(const ValueKey('device-sheet')), findsNothing);
      expect(find.byKey(_barKey), findsOneWidget);
    });

    testWidgets('a host with neither tool says so and offers nothing', (
      tester,
    ) async {
      final link = FakeDeviceLink(const [_pixel])..answers[_stoppedPart] = '';
      await _pump(tester, _opener(link));
      await _openSheet(tester);
      expect(find.text('no emulator or xcrun'), findsOneWidget);
      expect(find.byKey(const ValueKey('device-sheet-new')), findsNothing);
    });

    for (final cold in [false, true]) {
      testWidgets(
        '${cold ? 'COLD BOOT' : 'BOOT'} shows the row booting, then live',
        (tester) async {
          final link = _hostLink();
          final boot = link.held[_bootPart] = Completer<String>();
          await _pump(tester, _opener(link));
          await _openSheet(tester);
          await _tapKey(
            tester,
            ValueKey('device-${cold ? 'cold' : 'boot'}-Pixel_9'),
          );
          await _settle(tester);

          expect(find.byKey(const ValueKey('device-sheet')), findsNothing);
          expect(find.byKey(_barKey), findsOneWidget);
          final sent = link.reads.singleWhere((c) => c.contains(_bootPart));
          expect(sent.contains('-no-snapshot-load'), cold);
          expect(
            find.byKey(const ValueKey('device-booting-h1-Pixel_9')),
            findsOneWidget,
          );
          expect(find.text('Pixel_\u200B9  \u2026'), findsOneWidget);

          link.devices = const [_pixel, _booted];
          boot.complete('B emulator-5556\n');
          await _settle(tester);
          expect(
            find.byKey(const ValueKey('device-booting-h1-Pixel_9')),
            findsNothing,
          );
          await _pick(tester, _booted);
          expect(link.frameStreams.single.hasListener, isTrue);
        },
      );
    }

    testWidgets('a boot that fails keeps the name and says why', (
      tester,
    ) async {
      final link = _hostLink()
        ..answers[_bootPart] = 'INFO booting\nE PANIC: no engine\n';
      await _pump(tester, _opener(link));
      await _openSheet(tester);
      await _tapKey(tester, const ValueKey('device-boot-Pixel_9'));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('device-boot-failed-h1-Pixel_9')),
        findsOneWidget,
      );
      expect(find.text('PANIC: no engine'), findsOneWidget);
    });

    testWidgets('a boot past 3 min fails alone; the label clears it', (
      tester,
    ) async {
      final link = _hostLink();
      link.held[_bootPart] = Completer<String>();
      await _pump(tester, _opener(link));
      await _openSheet(tester);
      await _tapKey(tester, const ValueKey('device-boot-Pixel_9'));
      final listed = link.reads.length;
      await tester.pump(const Duration(minutes: 3));
      await _settle(tester);
      expect(find.text('not booted in 3 min'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('device-boot-failed-h1-Pixel_9')),
        findsOneWidget,
      );
      expect(link.reads, hasLength(listed));
      expect(link.readsOf(_killPart), 0);

      link.devices = const [_pixel, _booted];
      await tester.tap(find.text('ROSE'));
      await _settle(tester);
      expect(find.text('not booted in 3 min'), findsNothing);
      expect(
        find.byKey(const ValueKey('device-boot-failed-h1-Pixel_9')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('device-tab-h1-emulator-5556')),
        findsOneWidget,
      );
    });

    testWidgets(
      'a listing that finds a timed out boot running drops its reason',
      (tester) async {
        final link = _hostLink(const [_pixel, _iphone]);
        link.held[_bootPart] = Completer<String>();
        await _pump(tester, _opener(link));
        await _openSheet(tester);
        await _tapKey(tester, const ValueKey('device-boot-Pixel_9'));
        await tester.pump(const Duration(minutes: 3));
        await _settle(tester);
        expect(find.text('not booted in 3 min'), findsOneWidget);

        link.devices = const [_pixel, _booted];
        await _longPress(tester, ValueKey('device-tab-h1-${_iphone.id}'));
        await _tapKey(tester, ValueKey('device-shutdown-h1-${_iphone.id}'));
        await _settle(tester);
        expect(link.readsOf('simctl shutdown'), 1);
        expect(find.text('not booted in 3 min'), findsNothing);
        expect(
          find.byKey(const ValueKey('device-boot-failed-h1-Pixel_9')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('device-tab-h1-emulator-5556')),
          findsOneWidget,
        );
        expect(link.readsOf(_killPart), 0);
      },
    );

    testWidgets('a boot that times out while already listed fails alone', (
      tester,
    ) async {
      final link = _hostLink()
        ..answers[_stoppedPart] = 'T A\nE Pixel_9\nE Small\n'
        ..answers['Small'] = 'B emulator-5558\n';
      link.held['Pixel_9'] = Completer<String>();
      await _pump(tester, _opener(link));
      await _openSheet(tester);
      await _tapKey(tester, const ValueKey('device-boot-Pixel_9'));
      link.devices = const [
        _pixel,
        _booted,
        HostDevice(
          kind: DeviceKind.android,
          id: 'emulator-5558',
          name: 'Small',
          avd: 'Small',
        ),
      ];
      await _openSheet(tester);
      await _tapKey(tester, const ValueKey('device-boot-Small'));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('device-tab-h1-emulator-5558')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('device-tab-h1-emulator-5556')),
        findsNothing,
      );

      await tester.pump(const Duration(minutes: 3));
      await _settle(tester);
      expect(find.text('not booted in 3 min'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('device-boot-failed-h1-Pixel_9')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('device-tab-h1-emulator-5556')),
        findsNothing,
      );

      link.devices = const [_pixel, _booted];
      await _longPress(tester, const ValueKey('device-tab-h1-emulator-5558'));
      await _tapKey(tester, const ValueKey('device-shutdown-h1-emulator-5558'));
      await _settle(tester);
      expect(find.text('not booted in 3 min'), findsNothing);
      expect(
        find.byKey(const ValueKey('device-boot-failed-h1-Pixel_9')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('device-tab-h1-emulator-5556')),
        findsOneWidget,
      );
    });

    testWidgets('ending the dock ends a boot in flight and shuts nothing down', (
      tester,
    ) async {
      final link = _hostLink(const [_pixel, _booted]);
      link.held[_bootPart] = Completer<String>();
      await _pump(tester, _opener(link));
      await _openSheet(tester);
      await _tapKey(tester, const ValueKey('device-boot-Pixel_9'));
      await _settle(tester);
      _dock(tester).close();
      await _settle(tester);

      expect(link.closed, isTrue);
      expect(link.held[_bootPart]!.isCompleted, isTrue);
      expect(link.readsOf(_killPart), 0);
      expect(link.readsOf('simctl shutdown'), 0);
      expect(link.commands, isEmpty);
    });

    testWidgets('a long press offers SHUT DOWN and DELETE on what it made', (
      tester,
    ) async {
      final link = _hostLink(const [_pixel, _booted]);
      await _pump(tester, _opener(link));
      await _pick(tester, _booted);
      expect(link.frameStreams.single.hasListener, isTrue);
      await _fold(tester);

      const tab = ValueKey('device-tab-h1-emulator-5556');
      await _longPress(tester, tab);
      expect(
        find.byKey(const ValueKey('device-actions-h1-emulator-5556')),
        findsOneWidget,
      );
      await _longPress(tester, tab);
      expect(
        find.byKey(const ValueKey('device-actions-h1-emulator-5556')),
        findsNothing,
      );

      await _longPress(tester, tab);
      link.devices = const [_pixel];
      await _tapKey(tester, const ValueKey('device-shutdown-h1-emulator-5556'));
      await _settle(tester);
      expect(_dock(tester).session, isNull);
      expect(link.frameStreams.single.hasListener, isFalse);
      final kill = link.reads.singleWhere((c) => c.contains(_killPart));
      expect(kill, contains('emulator-5556'));
      expect(kill, isNot(contains(_avdDeletePart)));
      expect(find.byKey(tab), findsNothing);

      final streams = link.frameStreams.length;
      await _longPress(tester, const ValueKey('device-tab-h1-emulator-5554'));
      expect(
        find.byKey(const ValueKey('device-actions-h1-emulator-5554')),
        findsNothing,
      );
      expect(find.byKey(_barKey), findsOneWidget);
      expect(link.frameStreams, hasLength(streams));
      expect(_dock(tester).session, isNull);
    });

    testWidgets('DELETE asks once more, then stops and deletes', (
      tester,
    ) async {
      final link = _hostLink(const [_booted]);
      await _pump(tester, _opener(link));
      await _longPress(tester, const ValueKey('device-tab-h1-emulator-5556'));

      const delete = ValueKey('device-delete-h1-emulator-5556');
      await _tapKey(tester, delete);
      expect(find.text('CONFIRM DELETE'), findsOneWidget);
      expect(link.readsOf(_avdDeletePart), 0);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('CONFIRM DELETE'), findsNothing);

      await _tapKey(tester, delete);
      await _tapKey(tester, delete);
      await _settle(tester);
      final sent = link.reads.singleWhere((c) => c.contains(_avdDeletePart));
      expect(sent, contains(_killPart));
      expect(sent, contains('Pixel_9'));
    });

    testWidgets('a refused shut down says why under the row', (tester) async {
      final link = _hostLink(const [_booted])
        ..answers[_killPart] = 'E still running\n';
      await _pump(tester, _opener(link));
      await _longPress(tester, const ValueKey('device-tab-h1-emulator-5556'));
      await _tapKey(tester, const ValueKey('device-shutdown-h1-emulator-5556'));
      await _settle(tester);
      expect(find.text('still running'), findsOneWidget);
    });

    testWidgets('a long press in the sheet offers DELETE alone', (
      tester,
    ) async {
      final link = _hostLink();
      await _pump(tester, _opener(link));
      await _openSheet(tester);
      await _longPress(tester, const ValueKey('device-stopped-SIM-1'));
      expect(find.byKey(const ValueKey('device-boot-SIM-1')), findsNothing);
      expect(find.text('SHUT DOWN'), findsNothing);
      const delete = ValueKey('device-delete-SIM-1');
      await _tapKey(tester, delete);
      expect(link.readsOf('simctl delete'), 0);
      link.answers[_stoppedPart] = 'T A\nE Pixel_9\nT I\n';
      await _tapKey(tester, delete);
      await _settle(tester);
      expect(link.readsOf('simctl delete'), 1);
      expect(link.readsOf(_stoppedPart), 2);
      expect(find.byKey(const ValueKey('device-stopped-SIM-1')), findsNothing);
    });

    testWidgets('NEW makes an emulator from a profile and an image', (
      tester,
    ) async {
      final link = _hostLink()
        ..answers['avdmanager list device'] =
            'P pixel_7\nP medium_phone\nS system-images;android-36;google_apis;x86_64\n';
      await _pump(tester, _opener(link));
      await _openSheet(tester);
      await _tapKey(tester, const ValueKey('device-sheet-new'));
      await _settle(tester);

      expect(find.text('ANDROID'), findsOneWidget);
      expect(
        find.text('system-images;android-36;google_apis;x86_64'),
        findsOneWidget,
      );
      await _tapKey(tester, const ValueKey('device-new-profile'));
      await _tapKey(tester, const ValueKey('device-pick-pixel_7'));

      final name = find.descendant(
        of: find.byKey(const ValueKey('device-new-name')),
        matching: find.byType(EditableText),
      );
      await tester.enterText(name, 'bad name');
      await tester.pump();
      await _tapKey(tester, const ValueKey('device-new-create'));
      expect(link.readsOf('avdmanager create avd'), 0);

      await tester.enterText(name, 'Pixel_10');
      await tester.pump();
      await _tapKey(tester, const ValueKey('device-new-image'));
      await _tapKey(
        tester,
        const ValueKey(
          'device-pick-system-images;android-36;google_apis;x86_64',
        ),
      );
      expect(tester.widget<EditableText>(name).focusNode.hasFocus, isFalse);
      await _tapKey(tester, const ValueKey('device-new-create'));
      await _settle(tester);
      final sent = link.reads.singleWhere(
        (c) => c.contains('avdmanager create avd'),
      );
      expect(sent, contains('Pixel_10'));
      expect(sent, contains('pixel_7'));
      expect(find.byKey(const ValueKey('device-new-name')), findsNothing);
      expect(link.readsOf(_stoppedPart), 2);
    });

    testWidgets('NEW without a system image cannot create', (tester) async {
      final link = _hostLink()
        ..answers['avdmanager list device'] = 'P pixel_7\n';
      await _pump(tester, _opener(link));
      await _openSheet(tester);
      await _tapKey(tester, const ValueKey('device-sheet-new'));
      await _settle(tester);
      expect(find.text('no system image'), findsOneWidget);
      expect(find.byKey(const ValueKey('device-new-create')), findsNothing);
    });

    testWidgets('NEW on a mac offers runtimes the device type runs', (
      tester,
    ) async {
      final link = FakeDeviceLink(const [])
        ..answers[_stoppedPart] = 'T I\n@simctl\n$_sims\n'
        ..answers['list devicetypes'] =
            '@devicetypes\n{"devicetypes":['
            '{"identifier":"t1","name":"iPhone One"},'
            '{"identifier":"t2","name":"iPhone Two"},'
            '{"identifier":"t3","name":"iPhone Three"}]}\n'
            '@runtimes\n{"runtimes":['
            '{"identifier":"r1","name":"iOS 27.0","isAvailable":true,'
            '"supportedDeviceTypes":[{"identifier":"t1"},{"identifier":"t2"}]},'
            '{"identifier":"r2","name":"iOS 26.5","isAvailable":true,'
            '"supportedDeviceTypes":[{"identifier":"t2"}]}]}\n';
      await _pump(tester, _opener(link));
      await _openSheet(tester);
      await _tapKey(tester, const ValueKey('device-sheet-new'));
      await _settle(tester);
      expect(find.text('ANDROID'), findsNothing);

      await _tapKey(tester, const ValueKey('device-new-profile'));
      expect(find.byKey(const ValueKey('device-pick-t3')), findsNothing);
      await _tapKey(tester, const ValueKey('device-pick-t1'));
      expect(find.text('iOS 27.0'), findsOneWidget);
      await _tapKey(tester, const ValueKey('device-new-image'));
      expect(find.byKey(const ValueKey('device-pick-r2')), findsNothing);
      await _tapKey(tester, const ValueKey('device-pick-r1'));

      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('device-new-name')),
          matching: find.byType(EditableText),
        ),
        'My Phone',
      );
      await tester.pump();
      await _tapKey(tester, const ValueKey('device-new-create'));
      await _settle(tester);
      final sent = link.reads.singleWhere((c) => c.contains('simctl create'));
      expect(sent, contains('My Phone'));
      expect(sent, contains('t1'));
      expect(sent, contains('r1'));
    });
  });

  group('a desktop', () {
    late List<FakeVncConnection> connections;

    VncOpener vnc() {
      connections = [];
      return ({
        required String address,
        required int port,
        required String user,
        required String privateKey,
        String? vncUsername,
        String? password,
        HostKeyVerifier? verifier,
      }) async {
        final connection = await FakeVncConnection.open();
        connections.add(connection);
        return connection;
      };
    }

    const desktopKey = ValueKey('desktop-float');
    const desktopTab = ValueKey('desktop-tab-h1');

    Future<void> watchDesktop(WidgetTester tester) async {
      if (find.byKey(_bubbleKey).evaluate().isNotEmpty) await _open(tester);
      await _tapKey(tester, desktopTab);
      await _settle(tester);
      final controller = _dock(tester).desktop!.controller;
      final before = controller.frameCount;
      connections.last.feedFrame();
      await tester.runAsync(() async {
        for (var i = 0; i < 2500 && controller.frameCount == before; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
      });
      await _settle(tester);
    }

    Finder onDesktop(String text) => find.descendant(
      of: find.byKey(const ValueKey('desktop-float-overlay')),
      matching: find.text(text),
    );

    testWidgets('parks in picture-in-picture, even from a pause', (
      tester,
    ) async {
      final pip = FakePip();
      await _pump(
        tester,
        _opener(FakeDeviceLink(const [])),
        desktops: const [_rose],
        vnc: vnc(),
        pip: pip,
      );
      await watchDesktop(tester);
      await _tapKey(tester, desktopKey);
      await tester.tap(onDesktop('PAUSE'));
      await tester.pump();
      expect(onDesktop('RESUME'), findsOneWidget);
      await _tapKey(tester, const ValueKey('desktop-float-pip'));
      expect(pip.entries, 1);
      pip.modes.add(true);
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('screen-pip')),
          matching: find.byType(RawImage),
        ),
        findsOneWidget,
      );

      pip.modes.add(false);
      await _settle(tester);
      expect(find.byKey(desktopKey), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-float-paused')), findsNothing);
    });

    testWidgets('floats beside a device, each window on its own', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final link = FakeDeviceLink(const [_pixel]);
      await _pump(tester, _opener(link), desktops: const [_rose], vnc: vnc());
      await _open(tester);
      final rows = [
        for (final key in const [
          'device-group-h1',
          'desktop-tab-h1',
          'device-tab-h1-emulator-5554',
        ])
          tester.getTopLeft(find.byKey(ValueKey(key))).dy,
      ];
      expect(rows, orderedEquals([...rows]..sort()));

      await watchDesktop(tester);
      expect(find.byKey(desktopKey), findsOneWidget);
      expect(find.byKey(_bubbleKey), findsOneWidget);
      expect(connections, hasLength(1));

      await _pick(tester, _pixel);
      await _live(tester, link);
      expect(find.byKey(desktopKey), findsOneWidget);
      expect(find.byKey(_floatKey), findsOneWidget);
      expect(find.byKey(_bubbleKey), findsOneWidget);
      expect(
        tester
            .getRect(find.byKey(desktopKey))
            .overlaps(tester.getRect(find.byKey(_floatKey))),
        isFalse,
      );

      await _tapKey(tester, desktopKey);
      await tester.tap(onDesktop('PAUSE'));
      await tester.pump();
      expect(_dock(tester).desktopPaused, isTrue);
      expect(onDesktop('RESUME'), findsOneWidget);
      await tester.tapAt(
        tester.getRect(find.byKey(desktopKey)).centerLeft + const Offset(4, 0),
      );
      await tester.pump();
      expect(_dock(tester).desktopPaused, isTrue);
      expect(
        find.byKey(const ValueKey('desktop-float-paused')),
        findsOneWidget,
      );
      expect(link.frameStreams.last.hasListener, isTrue);

      await _tapKey(tester, desktopKey);
      await _tapKey(tester, const ValueKey('desktop-float-close'));
      await _settle(tester);
      expect(find.byKey(desktopKey), findsNothing);
      expect(find.byKey(_floatKey), findsOneWidget);
      expect(connections.single.closed, isTrue);
      expect(link.closed, isFalse);
    });

    testWidgets('a minimized desktop comes back from its row', (tester) async {
      await _pump(
        tester,
        _opener(FakeDeviceLink(const [_pixel])),
        desktops: const [_rose],
        vnc: vnc(),
      );
      await watchDesktop(tester);
      await _tapKey(tester, desktopKey);
      await _tapKey(tester, const ValueKey('desktop-float-collapse'));
      expect(find.byKey(desktopKey), findsNothing);
      expect(_dock(tester).desktop, isNotNull);

      await _open(tester);
      await _tapKey(tester, desktopTab);
      expect(find.byKey(desktopKey), findsOneWidget);
      expect(connections, hasLength(1));
      expect(connections.single.closed, isFalse);
    });

    testWidgets('goes full screen on the same connection and floats back', (
      tester,
    ) async {
      await _pump(
        tester,
        _opener(FakeDeviceLink(const [_pixel])),
        desktops: const [_rose],
        vnc: vnc(),
      );
      await watchDesktop(tester);
      await _tapKey(tester, desktopKey);
      await _tapKey(tester, const ValueKey('desktop-float-expand'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('/ ROSE SCREEN'), findsOneWidget);
      expect(find.byKey(desktopKey), findsNothing);
      expect(find.byKey(_bubbleKey), findsNothing);
      expect(connections, hasLength(1));

      await tester.tap(find.text('/ ROSE SCREEN'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(desktopKey), findsOneWidget);
      expect(connections.single.closed, isFalse);
    });
  });

  group('the edge', () {
    const handle = ValueKey('screens-handle');
    const screensAction = ValueKey('screens-action');

    Future<void> tuck(WidgetTester tester) async {
      await tester.drag(find.byKey(_bubbleKey), const Offset(400, 0));
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('takes the bubble and gives it back with the list open', (
      tester,
    ) async {
      final link = FakeDeviceLink(const [_pixel]);
      await _pump(tester, _opener(link));
      await _pick(tester, _pixel);
      await _live(tester, link);

      await tuck(tester);
      expect(find.byKey(_bubbleKey), findsNothing);
      expect(find.byKey(_floatKey), findsNothing);
      expect(find.byKey(handle), findsOneWidget);
      expect(link.frameStreams.last.hasListener, isFalse);
      expect(link.closed, isFalse);
      final bar = tester.widget<Container>(
        find.byKey(const ValueKey('screens-handle-bar')),
      );
      expect(
        ((bar.decoration! as BoxDecoration).border! as Border).top.color,
        testTheme.extension<StrikedTokens>()!.accent,
      );

      await _tapKey(tester, handle);
      expect(find.byKey(_barKey), findsOneWidget);
      await _pick(tester, _pixel);
      expect(find.byKey(_floatKey), findsOneWidget);
      expect(link.frameStreams.last.hasListener, isTrue);
    });

    testWidgets('keeps the side a bubble was let go past', (tester) async {
      await _pump(tester, _opener(FakeDeviceLink(const [_pixel])));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(_bubbleKey)),
      );
      for (var i = 0; i < 30; i++) {
        await gesture.moveBy(
          const Offset(-30, 0),
          timeStamp: Duration(milliseconds: i * 5),
        );
        await tester.pump(const Duration(milliseconds: 5));
      }
      for (var i = 1; i <= 3; i++) {
        await gesture.moveBy(
          const Offset(25, 0),
          timeStamp: Duration(milliseconds: 200 + i * 5),
        );
        await tester.pump(const Duration(milliseconds: 5));
      }
      await gesture.up(timeStamp: const Duration(milliseconds: 215));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(handle), findsOneWidget);
      expect(tester.getCenter(find.byKey(handle)).dx, lessThan(400));
    });

    testWidgets('is only on the tabs', (tester) async {
      await _pump(tester, _opener(FakeDeviceLink(const [_pixel])));
      await tuck(tester);
      expect(find.byKey(handle), findsOneWidget);

      rootNavigatorKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold()),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(handle), findsNothing);

      rootNavigatorKey.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(handle), findsOneWidget);
    });

    testWidgets('stays over the shell, but not over what opens on it', (
      tester,
    ) async {
      await _pump(tester, _opener(FakeDeviceLink(const [_pixel])));
      await tuck(tester);
      final navigator = rootNavigatorKey.currentState!;

      navigator.push(_ShellLikeRoute());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(handle), findsOneWidget);

      navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold()));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(handle), findsNothing);

      navigator.pop();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(handle), findsOneWidget);

      await _tapKey(tester, handle);
      expect(find.byKey(_barKey), findsOneWidget);
    });

    testWidgets('rests above the keyboard', (tester) async {
      await _pump(tester, _opener(FakeDeviceLink(const [_pixel])));
      await tuck(tester);
      rootNavigatorKey.currentState!.push(_ShellLikeRoute());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      final ratio = tester.view.devicePixelRatio;
      tester.view.viewInsets = FakeViewPadding(bottom: 300 * ratio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      final screen = tester.view.physicalSize / ratio;
      expect(
        tester.getRect(find.byKey(handle)).bottom,
        lessThanOrEqualTo(screen.height - 300),
      );
    });

    testWidgets('opens its list above the keyboard', (tester) async {
      await _pump(tester, _opener(FakeDeviceLink(const [_pixel])));
      await tuck(tester);
      rootNavigatorKey.currentState!.push(_ShellLikeRoute());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      final ratio = tester.view.devicePixelRatio;
      final screen = tester.view.physicalSize / ratio;
      final keyboard = screen.height * 0.6;
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard * ratio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      final rest = tester.getRect(find.byKey(handle));

      await _tapKey(tester, handle);
      final list = tester.getRect(find.byKey(_barKey));
      expect(list.bottom, lessThanOrEqualTo(rest.bottom));
      expect(list.height, greaterThan(rest.height * 2));
    });

    testWidgets('has a twin in the header that opens the list', (tester) async {
      await _pump(tester, _opener(FakeDeviceLink(const [_pixel])), show: false);
      expect(find.byKey(_barKey), findsNothing);
      await _tapKey(tester, screensAction);
      expect(find.byKey(_barKey), findsOneWidget);
      expect(find.byKey(handle), findsNothing);
    });

    testWidgets('is there before anything was opened', (tester) async {
      await _pump(tester, _opener(FakeDeviceLink(const [_pixel])), show: false);
      expect(find.byKey(handle), findsOneWidget);
      expect(find.byKey(_bubbleKey), findsNothing);
    });

    testWidgets('is not there without a host to show', (tester) async {
      await _pump(
        tester,
        _opener(FakeDeviceLink(const [_pixel])),
        hosts: const [],
        show: false,
      );
      expect(find.byKey(handle), findsNothing);
      expect(find.byKey(screensAction), findsNothing);
    });
  });
}

class _ShellLikeRoute extends PopupRoute<void> with KeepsScreensEdge {
  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => null;

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => const SizedBox.expand();
}
