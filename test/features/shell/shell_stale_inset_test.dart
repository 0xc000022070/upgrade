import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/app/keyboard_release.dart';
import 'package:upgrade/features/shell/shell_bar.dart';
import 'package:upgrade/platform/channels.dart';

import '../../support/fake_shell.dart';
import '../../support/platform_channels.dart';
import '../../support/shell_route.dart';

void main() {
  late bool imeUp;

  setUp(() {
    stubDeviceChannels();
    imeUp = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(Channels.device),
          (call) async => call.method == 'ime' ? imeUp : null,
        );
    recordTextInput();
  });

  Future<void> lifecycle(WidgetTester tester, AppLifecycleState state) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'flutter/lifecycle',
          const StringCodec().encodeMessage(state.toString()),
          (_) {},
        );
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  double barBottom(WidgetTester tester) =>
      tester.getBottomLeft(find.byType(ShellBar)).dy;

  double screenBottom(WidgetTester tester) =>
      tester.view.physicalSize.height / tester.view.devicePixelRatio;

  Future<void> open(WidgetTester tester) async {
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      app(
        fakeShellSessions(FakeShellTransport()),
        builder: (context, child) => KeyboardRelease(child: child!),
      ),
    );
    await ready(tester);
    expect(barBottom(tester), screenBottom(tester));
  }

  Future<void> keyboardUp(WidgetTester tester) async {
    imeUp = true;
    tester.view.viewInsets = const FakeViewPadding(bottom: 900);
    await settle(tester);
    expect(barBottom(tester), screenBottom(tester) - 300);
  }

  testWidgets('an inset the window disowns after a stop is laid out as none', (
    tester,
  ) async {
    await open(tester);
    await keyboardUp(tester);

    await lifecycle(tester, AppLifecycleState.inactive);
    await lifecycle(tester, AppLifecycleState.hidden);
    await lifecycle(tester, AppLifecycleState.paused);
    imeUp = false;
    await lifecycle(tester, AppLifecycleState.hidden);
    await lifecycle(tester, AppLifecycleState.inactive);
    await lifecycle(tester, AppLifecycleState.resumed);
    await settle(tester);

    expect(barBottom(tester), screenBottom(tester));
    expect(tester.widget<ShellBar>(find.byType(ShellBar)).keyboardOpen, false);

    tester.view.viewInsets = FakeViewPadding.zero;
    await settle(tester);
    await keyboardUp(tester);

    await unmount(tester);
  });

  testWidgets('an inset left standing across an unfold is laid out as none', (
    tester,
  ) async {
    await open(tester);
    await keyboardUp(tester);

    imeUp = false;
    tester.view.physicalSize = const Size(2232, 2310);
    await settle(tester);

    expect(barBottom(tester), screenBottom(tester));

    await unmount(tester);
  });

  testWidgets('a keyboard the window has up keeps the row above it', (
    tester,
  ) async {
    await open(tester);
    await keyboardUp(tester);

    await tester.pump(const Duration(seconds: 1));

    expect(barBottom(tester), screenBottom(tester) - 300);

    await unmount(tester);
  });
}
