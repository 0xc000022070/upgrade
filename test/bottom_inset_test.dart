import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/features/home/capture_bar.dart';

import 'support/platform_channels.dart';
import 'support/themed_app.dart';

/// A Scaffold spends the bottom padding on whichever slot sits lowest: the bar gets it in
/// the bottom slot, and reads 0 in a body with a nav bar below.
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
        theme: testTheme,
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
    expect(inseted, bare);
  });
}
