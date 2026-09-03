import 'dart:async';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/app/nav_shell.dart';
import 'package:hotline/application/navigation.dart';
import 'package:hotline/application/providers.dart';
import 'package:hotline/data/database.dart';
import 'package:hotline/design/components/panel.dart';
import 'package:hotline/design/components/panel_sheet.dart';
import 'package:hotline/design/effects/glitch.dart';
import 'package:hotline/design/layout.dart';
import 'package:hotline/application/drop_selection.dart';
import 'package:hotline/features/home/capture_bar.dart';
import 'package:hotline/features/tasks/selection_bar.dart';
import 'package:hotline/features/home/home_screen.dart';
import 'package:hotline/features/screen_scaffold.dart';

import 'support/platform_channels.dart';

/// faraday folds mid-session, and the two halves of the requirement pull in
/// opposite directions: the layout has to change with the width, and nothing
/// the user was holding may change with it.
Future<void> _drain(
  WidgetTester tester, {
  Duration step = Duration.zero,
}) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
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

  /// Logical pixels: the tests are written in dp, which is what the spec is
  /// written in.
  void resize(WidgetTester tester, double width, [double height = 800]) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = ui.Size(width, height);
    addTearDown(tester.view.reset);
  }

  Widget host(Widget child) => ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: MaterialApp(home: child),
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
    // The 600 is the column including its screen edge, which is how the same
    // measurement reads on a 360 phone: 328 of panel inside 360 of column.
    expect(panel.width, Layout.columnMax - 2 * 16);
    expect(panel.center.dx, 450, reason: 'centred, not left-aligned');

    // The scroll view keeps the full width: the margins the cap creates are
    // most of a near-square display, and a drag started in them has to scroll.
    expect(tester.getRect(find.byType(Scrollable)).width, 900);
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
    // The cap is horizontal only. Measured on device: an [Align] that also
    // fills vertically makes the bar as tall as the screen and leaves the body
    // nothing, and the screen comes up empty but for two tabs.
    expect(bar.height, lessThan(120));
    expect(bar.bottom, 800);
    // The tabs distribute inside the cap rather than across the 900: the
    // first opens no further left than 150, the last closes no further right
    // than 750, and the row they make is still centred on the screen.
    final first = tester.getRect(find.text('HOME'));
    final last = tester.getRect(find.text('ACCESS'));
    expect(first.left, greaterThanOrEqualTo(150));
    expect(last.right, lessThanOrEqualTo(750));
    expect((first.center.dx + last.center.dx) / 2, closeTo(450, 1));
    await unmount(tester);
  });

  testWidgets('the selection bar takes the cap the capture bar takes', (
    tester,
  ) async {
    resize(tester, 900);
    await tester.pumpWidget(
      host(const Scaffold(body: SelectionBar(scope: DropSelection.homeScope))),
    );
    await _ready(tester);

    // The bar stands in the capture bar's slot, so it has to take the same cap
    // the capture bar does or the mode would widen the screen it is a mode of.
    // The nav bar above is the one chrome that still runs the full width.
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
        // A field rather than the real sheet: the resize question is whether
        // the route's [State] is carried through one, and a controller holding
        // text is the smallest thing that can answer it.
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
    // Every panel strip is a row tall now, and the capture bar is a panel:
    // the bar is 9px taller than it was and still a bar, not a band.
    expect(narrow.height, lessThan(220), reason: 'the bar is a bar');

    resize(tester, 900);
    await tester.pump();
    await _ready(tester);

    // The field is the same [State], not a rebuilt one: the cap is a
    // constraint rather than a branch, so there is no widget for the resize to
    // insert or remove.
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
