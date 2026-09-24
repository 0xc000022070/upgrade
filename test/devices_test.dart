import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/application/agents.dart';
import 'package:dazzle/application/providers.dart';
import 'package:dazzle/data/repositories/host_repository.dart';
import 'package:dazzle/features/devices/device_controllers.dart';
import 'package:dazzle/features/devices/devices_screen.dart';
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

Future<void> _pump(WidgetTester tester, DeviceLinkOpener open) async {
  stubDeviceChannels();
  final store = MemoryPrivateKeyStore();
  await store.write(_rose.keyId, 'PRIVATE');
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        privateKeyStoreProvider.overrideWithValue(store),
        staticEnabledProvider.overrideWith((ref) => Stream.value(false)),
      ],
      child: MaterialApp(
        theme: testTheme,
        home: DevicesScreen(host: _rose, open: open),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 60)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
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
    expect(deviceSubtitle(devices[1]), 'IOS · 0A1B2C3D');
    expect(deviceSubtitle(devices[0]), 'ANDROID · emulator-5554');
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

  testWidgets('each booted device is a row, and none reads NO DEVICES BOOTED', (
    tester,
  ) async {
    final link = FakeDeviceLink(const [_pixel, _iphone]);
    await _pump(tester, _opener(link));

    expect(find.text('pixel_7-api36'), findsOneWidget);
    expect(find.text('ANDROID · emulator-5554'), findsOneWidget);
    expect(find.text('iPhone 17 Pro'), findsOneWidget);
    expect(find.text('IOS · 0A1B2C3D'), findsOneWidget);

    link.devices = const [];
    await tester.tap(find.text('REFRESH'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('NO DEVICES BOOTED'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    expect(link.closed, isTrue);
  });

  testWidgets('a connection that fails says why and offers RETRY', (
    tester,
  ) async {
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
    expect(find.text('rose unreachable'), findsOneWidget);

    await tester.tap(find.text('RETRY'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('pixel_7-api36'), findsOneWidget);
  });

  testWidgets('a tap on the picture lands in device pixels', (tester) async {
    tester.view.physicalSize = const Size(540, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final link = FakeDeviceLink(const [_pixel]);
    await _pump(tester, _opener(link));
    await tester.tap(find.text('pixel_7-api36'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    link.frameStreams.single.add(_frame());
    await _settle(tester);
    expect(find.text('BACK'), findsOneWidget);
    expect(find.text('VIEW ONLY'), findsNothing);

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
    expect(link.frameStreams.last.hasListener, isFalse);
  });

  testWidgets('a simulator is only watched', (tester) async {
    final link = FakeDeviceLink(const [_iphone]);
    await _pump(tester, _opener(link));
    await tester.tap(find.text('iPhone 17 Pro'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    link.frameStreams.single.add(_frame(width: 1206, height: 2622));
    await _settle(tester);

    expect(find.text('VIEW ONLY'), findsOneWidget);
    expect(find.text('BACK'), findsNothing);
    await tester.tapAt(tester.getCenter(find.byType(RawImage)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(link.commands, isEmpty);
  });
}
