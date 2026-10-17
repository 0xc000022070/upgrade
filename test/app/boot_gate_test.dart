import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/app/boot.dart';
import 'package:striked/design/motion.dart';

import '../support/themed_app.dart';

void main() {
  testWidgets('a long boot log rolls in the same beats as a short one', (
    tester,
  ) async {
    final steps = [for (var i = 0; i < 15; i++) BootStep('step $i', 'ok')];
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme,
        home: BootGate(steps: steps, child: const Text('HOME')),
      ),
    );
    tester.binding.platformDispatcher.onReportTimings!(const []);

    await tester.pump(Effects.bootLineStep * (Effects.bootBeats - 2));
    expect(find.text('step 14'), findsOneWidget);
    expect(find.text('HOME'), findsNothing);

    await tester.pump(
      Effects.bootLineStep * 2 +
          Effects.glitchDuration +
          const Duration(milliseconds: 16),
    );
    expect(find.text('HOME'), findsOneWidget);
    expect(
      Effects.bootLineStep * Effects.bootBeats + Effects.glitchDuration,
      lessThan(Effects.bootCap),
    );
  });
}
