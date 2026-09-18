import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/design/colors.dart';
import 'package:dazzle/design/components/list_row.dart';
import 'package:dazzle/design/icons/dazzle_icon.dart';
import 'package:dazzle/design/icons/dazzle_icons.dart';
import 'package:dazzle/design/spacing.dart';

import 'support/themed_app.dart';

void main() {
  testWidgets('the glyph on a row sits on the line it marks', (tester) async {
    /// Both are box positions rather than ink, so the fallback face a test renders with
    /// cannot move them.
    Future<double> drift() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme,
          home: Scaffold(
            body: ListRow(
              leading: DazzleIcon(
                DazzleIcons.progressMarker,
                size: IconSizes.glyph,
                color: DazzleColors.textDisabled,
              ),
              title: 'lib/main.dart',
              subtitle: 'modified',
            ),
          ),
        ),
      );
      final glyph = tester.getRect(find.byType(DazzleIcon));
      final title = tester.getRect(find.text('lib/main.dart'));
      return glyph.center.dy - title.center.dy;
    }

    // Half a pixel, not none: a paragraph's box is rounded up to a whole pixel and the slot
    // beside it is not.
    expect(await drift(), closeTo(0, 0.5));

    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    expect(await drift(), closeTo(0, 0.5));
  });
}
