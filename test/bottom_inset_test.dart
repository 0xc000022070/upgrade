import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/features/home/capture_bar.dart';

import 'support/platform_channels.dart';

/// The capture and selection bars are the last thing above the system gesture
/// area on a screen that pins nothing under them, and on device the pill was
/// sitting on the field. [BottomBarFrame] reads the inset off the MediaQuery it
/// is given rather than being told about it, which only works because a
/// Scaffold spends the bottom padding on whichever slot sits lowest: the bar
/// gets it in the bottom slot, and reads 0 in a body with a nav bar below.
void main() {
  setUp(stubDeviceChannels);

  const inset = 48.0;

  Future<double> frameHeight(
    WidgetTester tester, {
    required double bottomPadding,
    required bool navBarBelow,
  }) async {
    final bar = BottomBarFrame(
      title: 'CAPTURE / QUICK ADD',
      child: Container(height: 40, color: const Color(0xFF000000)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(padding: EdgeInsets.only(bottom: bottomPadding)),
            child: navBarBelow
                ? Scaffold(
                    body: Column(children: [const Spacer(), bar]),
                    bottomNavigationBar: const SizedBox(height: 52),
                  )
                : Scaffold(
                    body: const SizedBox.expand(),
                    bottomNavigationBar: bar,
                  ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    return tester.getSize(find.byType(BottomBarFrame)).height;
  }

  testWidgets('the bar in the bottom slot clears the gesture area', (
    tester,
  ) async {
    final bare = await frameHeight(
      tester,
      bottomPadding: 0,
      navBarBelow: false,
    );
    final inseted = await frameHeight(
      tester,
      bottomPadding: inset,
      navBarBelow: false,
    );
    expect(inseted - bare, inset);
  });

  testWidgets('the bar over HOME\'s nav bar gains nothing', (tester) async {
    final bare = await frameHeight(tester, bottomPadding: 0, navBarBelow: true);
    final inseted = await frameHeight(
      tester,
      bottomPadding: inset,
      navBarBelow: true,
    );
    // The nav bar under it took the inset, so a bar that took it again would
    // float the capture panel half a nav bar above the ground it sits on.
    expect(inseted, bare);
  });
}
