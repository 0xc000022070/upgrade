import 'dart:math' as math;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:upgrade/data/database.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/layout.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/features/home/home_screen.dart';
import 'package:upgrade/features/home/agents_panel.dart';
import 'package:upgrade/features/tasks/drops_panel.dart';
import 'package:upgrade/features/settings/settings_screen.dart';

import 'support/native_plugins.dart';
import 'support/platform_channels.dart';
import 'support/variants.dart';

Set<Color> _chrome(UpgradeTokens tokens) => {
  tokens.backgroundPrimary,
  tokens.backgroundSecondary,
  tokens.surfacePrimary,
  tokens.surfaceSecondary,
  tokens.accent,
  tokens.accentMuted,
};

/// Deliberately the house's under every palette. Subtracted so a screen that draws one is
/// not read as a screen that leaked the house.
Set<Color> _shared(UpgradeTokens tokens) => {
  tokens.scrim,
  tokens.mediaBackdrop,
  tokens.diffMapWindow,
  tokens.diffAddedGround,
  tokens.diffRemovedGround,
  tokens.diffCappedGround,
};

/// A rendered pixel in this set is a widget that reached for the house instead of
/// `context.tokens`, which is invisible while the house is the palette under test.
Set<Color> _houseOnly(Palette palette) =>
    _chrome(UpgradeTokens.house)
        .difference(_chrome(palette.tokens).union(_shared(palette.tokens)));

Iterable<Color> _painted(WidgetTester tester) sync* {
  for (final widget in tester.allWidgets) {
    switch (widget) {
      case Container():
        final color = widget.color;
        if (color != null) yield color;
        final decoration = widget.decoration;
        if (decoration is BoxDecoration) {
          final fill = decoration.color;
          if (fill != null) yield fill;
        }
      case ColoredBox():
        yield widget.color;
      case DecoratedBox(decoration: final BoxDecoration decoration):
        final fill = decoration.color;
        if (fill != null) yield fill;
      case Text():
        final color = widget.style?.color;
        if (color != null) yield color;
      default:
        break;
    }
  }
}

void main() {
  late AppDatabase db;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Widget host(Widget child, {ThemeData? theme}) => ProviderScope(
    overrides: [...featureTestOverrides(db)],
    child: MaterialApp(theme: theme ?? Palette.house.theme, home: child),
  );

  /// The screens run timers of their own, and the binding fails the test on any that
  /// outlive it.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  /// Assertions are on the outermost panel: panels nest, and an inner one says nothing
  /// about the column.
  Rect widestPanel(WidgetTester tester) {
    final boxes = tester
        .widgetList<Panel>(find.byType(Panel))
        .map((panel) => tester.getRect(find.byWidget(panel)))
        .toList();
    expect(boxes, isNotEmpty, reason: 'the screen drew no panel');
    boxes.sort((a, b) => b.width.compareTo(a.width));
    return boxes.first;
  }

  void expectCappedAndCentred(WidgetTester tester, Surface surface) {
    final panel = widestPanel(tester);
    // Exact, not a ceiling: a column that collapsed to a third of the width also satisfies a
    // cap.
    final column =
        math.min(surface.width, Layout.columnMax) - 2 * Spacing.screenEdge;
    expect(
      panel.width,
      moreOrLessEquals(column, epsilon: 0.5),
      reason: 'the content column is not $column wide on $surface',
    );
    expect(
      panel.left,
      moreOrLessEquals(surface.width - panel.right, epsilon: 0.5),
      reason: 'the column is off centre on $surface',
    );
  }

  testWidgets('HOME lays out on every surface', (tester) async {
    final surface = surfaces.currentValue!;
    useSurface(tester, surface);

    await tester.pumpWidget(host(const Scaffold(body: HomeScreen())));
    await settle(tester);

    expect(find.bySemanticsLabel('SETTINGS'), findsOneWidget);
    final agents = tester.getRect(find.byType(AgentsPanel));
    final drops = tester.getRect(find.byType(DropsPanel));
    if (surface.width >= 792) {
      expect(drops.left, greaterThan(agents.right));
      expect(drops.top, agents.top);
    } else {
      expect(drops.top, greaterThan(agents.bottom));
      expect(drops.width, surface.width - 2 * Spacing.screenEdge);
    }
    expect(tester.takeException(), isNull);
    await unmount(tester);
  }, variant: surfaces);

  testWidgets('SETTINGS lays out on every surface', (tester) async {
    final surface = surfaces.currentValue!;
    useSurface(tester, surface);

    await tester.pumpWidget(host(const SettingsScreen()));
    await settle(tester);

    expect(find.text('[ APPEARANCE ]'), findsOneWidget);
    expect(find.text('[ BUILD ]'), findsOneWidget);
    expectCappedAndCentred(tester, surface);
    await unmount(tester);
  }, variant: surfaces);

  testWidgets('HOME wears every palette', (tester) async {
    final palette = palettes.currentValue!;
    useSurface(tester, Surface.phone);

    await tester.pumpWidget(
      host(const Scaffold(body: HomeScreen()), theme: palette.theme),
    );
    await settle(tester);

    final leaked = _painted(tester).toSet().intersection(_houseOnly(palette));
    expect(leaked, isEmpty, reason: 'HOME painted the house under $palette');
    await unmount(tester);
  }, variant: palettes);

  testWidgets('SETTINGS wears every palette', (tester) async {
    final palette = palettes.currentValue!;
    useSurface(tester, Surface.phone);

    await tester.pumpWidget(host(const SettingsScreen(), theme: palette.theme));
    await settle(tester);

    final leaked = _painted(tester).toSet().intersection(_houseOnly(palette));
    expect(
      leaked,
      isEmpty,
      reason: 'SETTINGS painted the house under $palette',
    );
    await unmount(tester);
  }, variant: palettes);
}
