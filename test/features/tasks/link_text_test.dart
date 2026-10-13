import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/design/colors.dart';
import 'package:upgrade/features/tasks/link_text.dart';

import '../../support/platform_channels.dart';
import '../../support/themed_app.dart';

void main() {
  late List<String> opened;

  setUp(() => opened = stubUrlLauncher());

  Future<void> mount(WidgetTester tester, String text, VoidCallback onTap) =>
      tester.pumpWidget(
        MaterialApp(
          theme: testTheme,
          home: Scaffold(
            body: Center(
              child: GestureDetector(
                onTap: onTap,
                child: LinkText(
                  text,
                  style: const TextStyle(
                    fontSize: 14,
                    color: UpgradeColors.textPrimary,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  /// The mark is a style on a range rather than a widget, so the span tree is the only
  /// place to read it.
  List<(String, bool)> spans(WidgetTester tester) {
    final text = tester.widget<Text>(find.byType(Text));
    final span = text.textSpan;
    if (span == null) return [(text.data!, false)];
    final out = <(String, bool)>[];
    span.visitChildren((child) {
      final piece = child as TextSpan;
      if (piece.text != null) {
        out.add((piece.text!, piece.style?.backgroundColor != null));
      }
      return true;
    });
    return out;
  }

  testWidgets('a title with no URL in it is one plain run', (tester) async {
    await mount(tester, 'llamar al dentista', () {});

    expect(spans(tester), [('llamar al dentista', false)]);

    await tester.tap(find.byType(LinkText));
    expect(opened, isEmpty);
  });

  testWidgets('the URL is marked and the prose around it is not', (
    tester,
  ) async {
    await mount(tester, 'mirar https://min.io/docs manana', () {});

    expect(spans(tester), [
      ('mirar ', false),
      ('https://min.io/docs', true),
      (' manana', false),
    ]);
  });

  testWidgets('a tap on the URL opens it and stops there', (tester) async {
    var tapped = 0;
    await mount(tester, 'https://min.io/docs', () => tapped++);

    await tester.tap(find.byType(LinkText));
    await tester.pump();

    // The span's recognizer wins the arena, so the gesture the caller wrapped the text in
    // never sees it.
    expect(opened, ['https://min.io/docs']);
    expect(tapped, 0);
  });

  testWidgets('a tap beside the URL belongs to whatever wraps the text', (
    tester,
  ) async {
    var tapped = 0;
    await mount(tester, 'mirar https://min.io manana', () => tapped++);

    final box = tester.getRect(find.byType(LinkText));
    await tester.tapAt(Offset(box.right - 8, box.center.dy));
    await tester.pump();

    expect(opened, isEmpty);
    expect(tapped, 1);
  });
}
