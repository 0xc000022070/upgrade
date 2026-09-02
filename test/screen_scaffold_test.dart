import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/design/typography.dart';
import 'package:hotline/features/screen_scaffold.dart';

import 'support/platform_channels.dart';

/// Orchestrator ruling, 2026-09-02: the crumb never wraps, and a screen that
/// carries a verb on the crumb line gives up the root segment to fit.
void main() {
  setUp(stubDeviceChannels);

  test('a trailing affordance costs the crumb its root segment', () {
    expect(
      ScreenScaffold.crumbFor(
        '/ PERSONAL CONTROL PLANE / PROJECTS',
        hasTrailing: true,
      ),
      '/ PROJECTS',
    );
    expect(
      ScreenScaffold.crumbFor(
        '/ PERSONAL CONTROL PLANE / PROJECTS',
        hasTrailing: false,
      ),
      '/ PERSONAL CONTROL PLANE / PROJECTS',
    );
    // Never down to nothing: one segment is already as short as a path goes.
    expect(
      ScreenScaffold.crumbFor('/ PERSONAL CONTROL PLANE', hasTrailing: true),
      '/ PERSONAL CONTROL PLANE',
    );
    expect(
      ScreenScaffold.crumbFor('/ A / B / C', hasTrailing: true),
      '/ B / C',
    );
  });

  testWidgets('the rendered crumb is one line and drops the root beside EDIT', (
    tester,
  ) async {
    Widget host({Widget? trailing}) => ProviderScope(
      child: MaterialApp(
        home: ScreenScaffold(
          title: 'INFRA PERSONAL',
          breadcrumb: '/ PERSONAL CONTROL PLANE / PROJECTS',
          breadcrumbTrailing: trailing,
          children: const [],
        ),
      ),
    );

    await tester.pumpWidget(host(trailing: const Text('EDIT')));
    await tester.pump(const Duration(milliseconds: 100));

    final crumb = tester.widget<Text>(find.text('/ PROJECTS'));
    expect(crumb.maxLines, 1);
    expect(crumb.style, HotlineText.breadcrumb);
    expect(find.text('/ PERSONAL CONTROL PLANE / PROJECTS'), findsNothing);

    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      tester
          .widget<Text>(find.text('/ PERSONAL CONTROL PLANE / PROJECTS'))
          .maxLines,
      1,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  group('SPEC.md §39.18 segmented crumb', () {
    /// Width in dp, so the collapse can be driven the way the phone drives it.
    Future<void> sized(WidgetTester tester, double width) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.reset);
    }

    final tapped = <String>[];

    // Inside a [Scaffold], so the trailing verb is sized by the app's own text
    // style rather than by WidgetsApp's oversized error style — otherwise the
    // verb eats the width the collapse is supposed to be measured against.
    Widget host(List<String> path, {Widget? trailing}) => ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: ScreenScaffold(
            title: 'NETWORKING',
            breadcrumbSegments: [
              for (final label in path)
                CrumbSegment(label, onTap: () => tapped.add(label)),
            ],
            breadcrumbTrailing: trailing,
            children: const [],
          ),
        ),
      ),
    );

    setUp(tapped.clear);

    testWidgets('a path that fits keeps every ancestor', (tester) async {
      await sized(tester, 800);
      await tester.pumpWidget(host(['PROJECTS', 'INFRA', 'HOMELAB']));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('PROJECTS'), findsOneWidget);
      expect(find.text('INFRA'), findsOneWidget);
      expect(find.text('HOMELAB'), findsOneWidget);
      expect(
        find.text(
          '…'
          ' / ',
        ),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('leading segments collapse but the parent stays', (
      tester,
    ) async {
      await sized(tester, 260);
      await tester.pumpWidget(
        host([
          'PROJECTS',
          'PERSONAL INFRASTRUCTURE',
          'HOMELAB',
        ], trailing: const Text('EDIT')),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.text(
          '…'
          ' / ',
        ),
        findsOneWidget,
      );
      // The immediate parent is the floor of the collapse, and the verbs it
      // made room for are still on the line.
      expect(find.text('HOMELAB'), findsOneWidget);
      expect(find.text('PROJECTS'), findsNothing);
      expect(find.text('EDIT'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('a segment that fits is not ellipsized by its neighbours', (
      tester,
    ) async {
      const path = ['PROJECTS', 'INFRA PERSONAL', 'HOMELAB'];
      await sized(tester, 1200);
      await tester.pumpWidget(host(path, trailing: const Text('EDIT')));
      await tester.pump(const Duration(milliseconds: 100));

      // The width is found rather than written down: the test font is not the
      // app's, so a dp figure taken off the phone means nothing here. Narrowing
      // until the collapse is one step away lands on the tightest row that
      // still holds the whole path, which is where a Flexible per segment used
      // to cut `INFRA PERSONAL` short with space left beside `HOMELAB`.
      for (var width = 1200.0; width > 200; width -= 4) {
        tester.view.physicalSize = Size(width, 900);
        await tester.pump(const Duration(milliseconds: 16));
        if (find.text(path.first).evaluate().isEmpty) {
          tester.view.physicalSize = Size(width + 4, 900);
          await tester.pump(const Duration(milliseconds: 16));
          break;
        }
      }

      for (final label in path) {
        expect(find.text(label), findsOneWidget, reason: '$label was dropped');
        expect(
          tester
              .renderObject<RenderParagraph>(find.text(label))
              .didExceedMaxLines,
          isFalse,
          reason: '$label was clipped',
        );
      }
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('every visible segment is its own tap target', (tester) async {
      await sized(tester, 800);
      await tester.pumpWidget(host(['PROJECTS', 'INFRA', 'HOMELAB']));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('INFRA'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('PROJECTS'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(tapped, ['INFRA', 'PROJECTS']);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });
  });
}
