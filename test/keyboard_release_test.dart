import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/app/keyboard_release.dart';

import 'support/platform_channels.dart';

/// The bug this is here for: the screen goes off with the keyboard up, and the
/// window comes back with the keyboard's inset still standing and no keyboard
/// under it. Every screen then lays out one keyboard short of the display, and
/// no amount of navigating clears it — the number belongs to the view, not to
/// the tree. The keyboard is taken down on the way out so the system has
/// nothing to leave behind, and an inset nobody claims is refused on the way
/// back in.
void main() {
  setUp(stubDeviceChannels);

  /// The lifecycle as the platform sends it, which fills in the states between
  /// this one and the last: `paused` arrives behind `inactive` and `hidden`,
  /// exactly as a screen going off delivers them.
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

    // Pulling the shade or answering a permission dialog raises `inactive` and
    // stops there. The window never stopped, so the keyboard is still the
    // user's and taking it away would cost them the word they were typing.
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

    // The state the device comes back in: the keyboard was let go on the way
    // out, and the inset it left behind is still standing.
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

    // A field that takes the focus back as the app comes up is asking for the
    // keyboard the inset reports, and this must not be the thing that takes it
    // away from them.
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
