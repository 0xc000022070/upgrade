import 'package:flutter/material.dart';
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
}
