import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/app/legible_scale.dart';

void main() {
  Future<(MediaQueryData, Rect)> render(
    WidgetTester tester, {
    required Size physical,
    required double ratio,
  }) async {
    tester.view.physicalSize = physical;
    tester.view.devicePixelRatio = ratio;
    addTearDown(tester.view.reset);
    late MediaQueryData seen;
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => LegibleScale(child: child!),
        home: Builder(
          builder: (context) {
            seen = MediaQuery.of(context);
            return SizedBox.expand(key: key);
          },
        ),
      ),
    );
    return (seen, tester.getRect(find.byKey(key)));
  }

  testWidgets('a monitor at under one pixel per point is laid out smaller and '
      'drawn across the whole window', (tester) async {
    final (media, drawn) = await render(
      tester,
      physical: const Size(1920, 1200),
      ratio: 0.75,
    );
    expect(media.size, const Size(1280, 800));
    expect(media.devicePixelRatio, LegibleScale.minRatio);
    expect(drawn, const Rect.fromLTWH(0, 0, 2560, 1600));
  });

  testWidgets('a phone screen is left as the platform gives it', (
    tester,
  ) async {
    final (media, drawn) = await render(
      tester,
      physical: const Size(2076, 2152),
      ratio: 2.4375,
    );
    expect(media.devicePixelRatio, 2.4375);
    expect(media.size, drawn.size);
  });
}
