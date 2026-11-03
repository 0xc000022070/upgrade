import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/signal_text.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/typography.dart';
import 'package:upgrade/design/components/screen_scaffold.dart';
import 'package:upgrade/application/providers.dart';

import '../../support/platform_channels.dart';
import '../../support/themed_app.dart';

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
      retry: noRetry,
      child: MaterialApp(
        theme: testTheme,
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
    expect(crumb.style, UpgradeText.breadcrumb);
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

  group('segmented crumb', () {
    Future<void> sized(WidgetTester tester, double width) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.reset);
    }

    final tapped = <String>[];

    // Inside a [Scaffold], so the trailing verb is sized by the app's own text style rather
    // than by WidgetsApp's oversized error style.
    Widget host(List<String> path, {Widget? trailing}) => ProviderScope(
      retry: noRetry,
      child: MaterialApp(
        theme: testTheme,
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

      // The width is found rather than written down: the test font is not the app's, so a dp
      // figure taken off the phone means nothing here.
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

  group('header parity', () {
    Widget host({Widget? trailing, VoidCallback? onBack}) => ProviderScope(
      retry: noRetry,
      child: MaterialApp(
        theme: testTheme,
        home: Scaffold(
          body: ScreenScaffold(
            title: 'HOSTS',
            breadcrumb: '/ PERSONAL CONTROL PLANE / HOSTS',
            breadcrumbTrailing: trailing,
            onBack: onBack,
            children: const [],
          ),
        ),
      ),
    );

    /// The [SignalText] itself rather than its glyphs: the title decodes on entry, so the
    /// characters on screen at any pump are not the title's.
    Future<(double, double)> header(WidgetTester tester, Widget widget) async {
      await tester.pumpWidget(widget);
      await tester.pump(const Duration(milliseconds: 100));
      final title = tester.getTopLeft(find.byType(SignalText)).dy;
      final row = tester
          .getRect(
            find
                .ancestor(
                  of: find.byType(SignalText),
                  matching: find.byType(Row),
                )
                .first,
          )
          .top;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      return (title, row);
    }

    testWidgets('the title sits at one offset on every kind of header', (
      tester,
    ) async {
      final withTrailing = await header(
        tester,
        host(trailing: const PanelAffordance('SYS', showIcon: false)),
      );
      final withBack = await header(tester, host(onBack: () {}));
      final bare = await header(tester, host());

      expect(withTrailing.$1, TapTargets.minHeight + Spacing.lg);
      expect(withBack, withTrailing);
      expect(bare, withTrailing);
    });
  });
}
