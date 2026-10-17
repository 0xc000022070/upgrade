import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/app/keyboard_release.dart';

import '../support/platform_channels.dart';
import '../support/themed_app.dart';

/// The window comes back with the keyboard's inset still standing and no keyboard under
/// it, and no amount of navigating clears it — the number belongs to the view, not to the
/// tree.
void main() {
  setUp(stubDeviceChannels);

  /// `paused` arrives behind `inactive` and `hidden`, exactly as a screen going off
  /// delivers them.
  Future<void> lifecycle(WidgetTester tester, AppLifecycleState state) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'flutter/lifecycle',
          const StringCodec().encodeMessage(state.toString()),
          (_) {},
        );
    await tester.pump();
  }

  Future<FocusNode> field(WidgetTester tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme,
        home: KeyboardRelease(
          child: Scaffold(body: TextField(focusNode: node)),
        ),
      ),
    );
    node.requestFocus();
    await tester.pump();
    expect(node.hasFocus, isTrue);
    return node;
  }

  testWidgets('a window that stops takes the keyboard down with it', (
    tester,
  ) async {
    final node = await field(tester);
    final calls = recordTextInput();

    await lifecycle(tester, AppLifecycleState.paused);

    expect(node.hasFocus, isFalse);
    expect(calls, contains('TextInput.hide'));
  });

  testWidgets('the notification shade leaves the caret where it was', (
    tester,
  ) async {
    final node = await field(tester);
    final calls = recordTextInput();

    // Pulling the shade or answering a permission dialog raises `inactive` and stops there.
    await lifecycle(tester, AppLifecycleState.inactive);

    expect(node.hasFocus, isTrue);
    expect(calls, isNot(contains('TextInput.hide')));
  });

  testWidgets('an inset nothing is asking for is refused on the way back', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await field(tester);
    await lifecycle(tester, AppLifecycleState.paused);

    tester.view.viewInsets = const FakeViewPadding(bottom: 400);
    final calls = recordTextInput();

    await lifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();

    expect(calls, contains('TextInput.hide'));
  });

  testWidgets('a keyboard something is asking for is left alone', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final node = await field(tester);
    await lifecycle(tester, AppLifecycleState.paused);

    tester.view.viewInsets = const FakeViewPadding(bottom: 400);
    final calls = recordTextInput();

    node.requestFocus();
    await lifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();

    expect(node.hasFocus, isTrue);
    expect(calls, isNot(contains('TextInput.hide')));
  });

  testWidgets('a resume with no inset asks the platform for nothing', (
    tester,
  ) async {
    await field(tester);
    await lifecycle(tester, AppLifecycleState.paused);
    final calls = recordTextInput();

    await lifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();

    expect(calls, isEmpty);
  });
}
