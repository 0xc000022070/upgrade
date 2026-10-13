import 'support/native_plugins.dart';

import 'dart:async';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/app/nav_shell.dart';
import 'package:upgrade/application/navigation.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/effects/glitch.dart';
import 'package:upgrade/design/layout.dart';
import 'package:upgrade/application/drops/drop_selection.dart';
import 'package:upgrade/features/home/capture_bar.dart';
import 'package:upgrade/features/tasks/selection_bar.dart';
import 'package:upgrade/features/home/home_screen.dart';
import 'package:upgrade/features/home/agents_panel.dart';
import 'package:upgrade/features/tasks/drops_panel.dart';
import 'package:upgrade/design/components/screen_scaffold.dart';

import 'support/platform_channels.dart';
import 'support/themed_app.dart';

Future<void> _drain(
  WidgetTester tester, {
  Duration step = Duration.zero,
}) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(step);
  }
}

Future<void> _ready(WidgetTester tester) =>
    _drain(tester, step: const Duration(milliseconds: 100));

void main() {
  late AppDatabase db;

  setUp(() async {
    stubDeviceChannels();
    stubClipboard(null);
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  /// Logical pixels: the tests are written in dp, which is what the spec is written in.
  void resize(WidgetTester tester, double width, [double height = 800]) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = ui.Size(width, height);
    addTearDown(tester.view.reset);
  }

  Widget host(Widget child) => ProviderScope(
    overrides: [...featureTestOverrides(db)],
    child: MaterialApp(theme: testTheme, home: child),
  );

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('below the cap the column is still the whole screen', (
    tester,
  ) async {
    resize(tester, 360);
    await tester.pumpWidget(
      host(
        const Scaffold(
          body: ScreenScaffold(
            title: 'TODAY',
            children: [Panel(title: 'NEXT ACTION', child: Text('x'))],
          ),
        ),
      ),
    );
    await _ready(tester);

    final panel = tester.getRect(find.byType(Panel));
    expect(panel.left, 16);
    expect(panel.right, 344);
  });

  testWidgets('above the cap the column stops at 600 and centres', (
    tester,
  ) async {
    resize(tester, 900);
    await tester.pumpWidget(
      host(
        const Scaffold(
          body: ScreenScaffold(
            title: 'TODAY',
            children: [Panel(title: 'NEXT ACTION', child: Text('x'))],
          ),
        ),
      ),
    );
    await _ready(tester);

    final panel = tester.getRect(find.byType(Panel));
    // The 600 is the column including its screen edge.
    expect(panel.width, Layout.columnMax - 2 * 16);
    expect(panel.center.dx, 450, reason: 'centred, not left-aligned');

    expect(tester.getRect(find.byType(Scrollable)).width, 900);
    await unmount(tester);
  });

  testWidgets('home places work beside agents on wide displays', (
    tester,
  ) async {
    resize(tester, 900);
    await tester.pumpWidget(host(const Scaffold(body: HomeScreen())));
    await _ready(tester);

    final agents = tester.getRect(find.byType(AgentsPanel));
    final drops = tester.getRect(find.byType(DropsPanel));
    expect(drops.left, greaterThan(agents.right));
    expect(drops.top, agents.top);
    expect(tester.takeException(), isNull);

    resize(tester, 360);
    await _ready(tester);
    expect(
      tester.getTopLeft(find.byType(DropsPanel)).dy,
      greaterThan(tester.getBottomLeft(find.byType(AgentsPanel)).dy),
    );
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('the nav spans the width, its tabs take the cap', (tester) async {
    resize(tester, 900);
    final glitch = List.generate(
      navDestinationCount,
      (_) => GlitchController(),
    );
    addTearDown(() {
      for (final controller in glitch) {
        controller.dispose();
      }
    });

    await tester.pumpWidget(
      host(
        Scaffold(
          bottomNavigationBar: NavBar(
            currentIndex: 0,
            onSelected: (_) {},
            glitch: glitch,
          ),
        ),
      ),
    );
    await _ready(tester);

    final bar = tester.getRect(find.byType(NavBar));
    expect(bar.width, 900);
    // The cap is horizontal only. Measured on device: an [Align] that also fills vertically
    // makes the bar as tall as the screen and leaves the body nothing.
    expect(bar.height, lessThan(120));
    expect(bar.bottom, 800);
    final first = tester.getRect(find.text('HOME'));
    final last = tester.getRect(find.text('TOOLS'));
    expect(first.left, greaterThanOrEqualTo(150));
    expect(last.right, lessThanOrEqualTo(750));
    expect((first.center.dx + last.center.dx) / 2, closeTo(450, 1));
    await unmount(tester);
  });

  testWidgets('the nav is as tall as the words in it', (tester) async {
    resize(tester, 360);
    final glitch = List.generate(
      navDestinationCount,
      (_) => GlitchController(),
    );
    addTearDown(() {
      for (final controller in glitch) {
        controller.dispose();
      }
    });

    Future<(double, double)> measure() async {
      await tester.pumpWidget(
        host(
          Scaffold(
            bottomNavigationBar: NavBar(
              currentIndex: 0,
              onSelected: (_) {},
              glitch: glitch,
            ),
          ),
        ),
      );
      await _ready(tester);
      final bar = tester.getRect(find.byType(NavBar));
      final label = tester.getRect(find.text('HOME'));
      await unmount(tester);
      return (bar.height, bar.bottom - label.bottom);
    }

    final (height, clearance) = await measure();
    expect(clearance, greaterThanOrEqualTo(0));

    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final (bigHeight, bigClearance) = await measure();

    expect(bigHeight, greaterThan(height));
    expect(bigClearance, greaterThanOrEqualTo(0));
  });

  testWidgets('the selection bar takes the cap the capture bar takes', (
    tester,
  ) async {
    resize(tester, 900);
    await tester.pumpWidget(
      host(const Scaffold(body: SelectionBar(scope: DropSelection.homeScope))),
    );
    await _ready(tester);

    final bar = tester.getRect(find.byType(Panel).first);
    expect(bar.width, Layout.columnMax - 2 * 16);
    expect(bar.center.dx, 450);
    await unmount(tester);
  });

  testWidgets('a sheet takes the cap and survives the resize', (tester) async {
    resize(tester, 900);
    await tester.pumpWidget(host(const Scaffold(body: SizedBox.shrink())));
    await _ready(tester);

    final context = tester.element(find.byType(SizedBox).first);
    unawaited(
      showPanelSheet<void>(
        context,
        title: 'ITEM',
        builder: (_) =>
            const PanelSheetBody(title: 'ITEM', children: [TextField()]),
      ),
    );
    await _ready(tester);

    await tester.enterText(find.byType(TextField), 'abierto al plegar');
    await _ready(tester);

    final wide = tester.getRect(find.byType(PanelSheetBody));
    expect(wide.width, lessThanOrEqualTo(Layout.columnMax));
    expect(wide.center.dx, 450, reason: 'a sheet, not a band across the top');

    resize(tester, 360);
    await tester.pump();
    await _ready(tester);

    expect(find.text('abierto al plegar'), findsOneWidget);
    expect(tester.getRect(find.byType(PanelSheetBody)).width, 360 - 32);
    await unmount(tester);
  });

  testWidgets('an unfold keeps what the user was holding', (tester) async {
    resize(tester, 360);
    await tester.pumpWidget(host(const Scaffold(body: HomeScreen())));
    await _ready(tester);

    await tester.enterText(find.byType(TextField), 'media escrita al plegar');
    await _ready(tester);
    final narrow = tester.getRect(find.byType(CaptureBar));
    expect(narrow.width, 360);
    expect(narrow.height, lessThan(220), reason: 'the bar is a bar');

    resize(tester, 900);
    await tester.pump();
    await _ready(tester);

    expect(find.text('media escrita al plegar'), findsOneWidget);
    expect(
      tester.getRect(find.byType(Panel).last).width,
      Layout.columnMax - 32,
    );

    resize(tester, 360);
    await tester.pump();
    await _ready(tester);

    expect(find.text('media escrita al plegar'), findsOneWidget);
    await unmount(tester);
  });
}
