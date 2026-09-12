import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/design/colors.dart';
import 'package:spectacle/design/components/list_row.dart';
import 'package:spectacle/design/icons/spectacle_icon.dart';
import 'package:spectacle/design/icons/spectacle_icons.dart';
import 'package:spectacle/design/spacing.dart';

void main() {
  testWidgets('the glyph on a row sits on the line it marks', (tester) async {
    /// How far the glyph's centre is from the centre of the title beside it.
    /// Both are box positions rather than ink, so the fallback face a test
    /// renders with cannot move them.
    Future<double> drift() async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ListRow(
              leading: SpectacleIcon(
                SpectacleIcons.progressMarker,
                size: IconSizes.glyph,
                color: SpectacleColors.textDisabled,
              ),
              title: 'lib/main.dart',
              subtitle: 'modified',
            ),
          ),
        ),
      );
      final glyph = tester.getRect(find.byType(SpectacleIcon));
      final title = tester.getRect(find.text('lib/main.dart'));
      return glyph.center.dy - title.center.dy;
    }

    // Half a pixel, not none: a paragraph's box is rounded up to a whole
    // pixel and the slot beside it is not.
    expect(await drift(), closeTo(0, 0.5));

    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    // The glyph marks one line of a stack rather than the row, so the slot
    // holding it is measured at the size that line is painted. Held at the
    // size it was designed at, the glyph stayed where a smaller title used to
    // be and the row read as two things.
    expect(await drift(), closeTo(0, 0.5));
  });
}
