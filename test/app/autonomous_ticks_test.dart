import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/app/autonomous_ticks.dart';

void main() {
  testWidgets('a screen kept offstage does not tick until it is back', (
    tester,
  ) async {
    var ticks = 0;
    Widget stage({required bool enabled}) => TickerMode(
      enabled: enabled,
      child: AutonomousTicks(
        onTick: () => ticks++,
        child: const SizedBox.shrink(),
      ),
    );

    await tester.pumpWidget(stage(enabled: true));
    await tester.pump(const Duration(minutes: 2));
    expect(ticks, greaterThan(0));

    await tester.pumpWidget(stage(enabled: false));
    final offstage = ticks;
    await tester.pump(const Duration(minutes: 2));
    expect(ticks, offstage);

    await tester.pumpWidget(stage(enabled: true));
    await tester.pump(const Duration(minutes: 2));
    expect(ticks, greaterThan(offstage));
  });
}
