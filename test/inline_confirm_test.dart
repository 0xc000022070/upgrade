import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/design/colors.dart';
import 'package:hotline/design/components/inline_confirm.dart';

/// Delete confirms in place. What matters is that a single tap
/// never commits and that the armed window closes on its own — the block is the
/// only guard between a stray tap and a deleted project.
void main() {
  Future<void> pump(WidgetTester tester, VoidCallback onConfirmed) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InlineConfirmBlock(
            label: 'DELETE PROJECT',
            confirmLabel: 'CONFIRM DELETE',
            onConfirmed: onConfirmed,
          ),
        ),
      ),
    );
  }

  Color toneOf(WidgetTester tester) {
    final container = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(InlineConfirmBlock),
            matching: find.byType(Container),
          )
          .first,
    );
    return (container.decoration! as BoxDecoration).color!;
  }

  testWidgets('one tap arms, it does not commit', (tester) async {
    var confirmed = 0;
    await pump(tester, () => confirmed++);

    expect(find.text('DELETE PROJECT'), findsOneWidget);
    expect(toneOf(tester), HotlineColors.warning);

    await tester.tap(find.byType(InlineConfirmBlock));
    await tester.pump();

    expect(confirmed, 0);
    expect(find.text('CONFIRM DELETE'), findsOneWidget);
    expect(find.text('DELETE PROJECT'), findsNothing);
    // The commit is the only thing that wears danger.
    expect(toneOf(tester), HotlineColors.danger);
  });

  testWidgets('the second tap inside the window commits once', (tester) async {
    var confirmed = 0;
    await pump(tester, () => confirmed++);

    await tester.tap(find.byType(InlineConfirmBlock));
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.byType(InlineConfirmBlock));
    await tester.pump();

    expect(confirmed, 1);
    // Disarmed by the commit, so a third tap re-arms rather than deleting again.
    expect(find.text('DELETE PROJECT'), findsOneWidget);

    await tester.tap(find.byType(InlineConfirmBlock));
    await tester.pump();
    expect(confirmed, 1);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('letting the window lapse is the cancel', (tester) async {
    var confirmed = 0;
    await pump(tester, () => confirmed++);

    await tester.tap(find.byType(InlineConfirmBlock));
    await tester.pump(const Duration(seconds: 3, milliseconds: 1));

    expect(find.text('DELETE PROJECT'), findsOneWidget);
    expect(toneOf(tester), HotlineColors.warning);

    await tester.tap(find.byType(InlineConfirmBlock));
    await tester.pump();

    // The lapsed window means this tap arms again instead of committing.
    expect(confirmed, 0);
    await tester.pump(const Duration(seconds: 4));
  });
}
