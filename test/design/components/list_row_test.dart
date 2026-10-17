import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/design/colors.dart';
import 'package:striked/design/components/list_row.dart';
import 'package:striked/design/icons/striked_icon.dart';
import 'package:striked/design/icons/striked_icons.dart';
import 'package:striked/design/spacing.dart';

import '../../support/themed_app.dart';

void main() {
  testWidgets('multiline rows keep metadata below the full title', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme,
        home: const Scaffold(
          body: SizedBox(
            width: 300,
            child: ListRow(
              title: 'First line\nSecond line',
              titleMaxLines: 2,
              metadataBelow: true,
              mark: Text('HIGH'),
              value: '2h',
              trailing: Text('SENT'),
            ),
          ),
        ),
      ),
    );
    final title = find.text('First line\nSecond line');
    expect(title, findsOneWidget);
    for (final label in ['HIGH', '2h', 'SENT']) {
      expect(
        tester.getTopLeft(find.text(label)).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(title).dy),
      );
    }
    expect(tester.takeException(), isNull);
  });
  testWidgets('the glyph on a row sits on the line it marks', (tester) async {
    /// Both are box positions rather than ink, so the fallback face a test renders with
    /// cannot move them.
    Future<double> drift() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme,
          home: Scaffold(
            body: ListRow(
              leading: StrikedIcon(
                StrikedIcons.progressMarker,
                size: IconSizes.glyph,
                color: StrikedColors.textDisabled,
              ),
              title: 'lib/main.dart',
              subtitle: 'modified',
            ),
          ),
        ),
      );
      final glyph = tester.getRect(find.byType(StrikedIcon));
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
