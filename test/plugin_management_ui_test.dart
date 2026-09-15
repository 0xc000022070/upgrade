import 'package:dazzle/data/database.dart';
import 'package:dazzle/design/components/list_row.dart';
import 'package:dazzle/features/plugins/plugin_management_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native_plugins.dart';
import 'support/platform_channels.dart';

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late AppDatabase db;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  testWidgets('catalog and plugin sheet fit 320dp at 1.6 text scale', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: featureTestOverrides(db),
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: const PluginManagementScreen(),
        ),
      ),
    );
    await _drain(tester);

    expect(find.text('[ INSTALLED ]'), findsOneWidget);
    expect(find.byType(ListRow), findsNWidgets(2));
    expect(
      find.text('Capture, review, and file unstructured work.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Drops'));
    await _drain(tester);

    expect(find.text('[ YOUR LAYOUT ]'), findsOneWidget);
    expect(find.text('[ STATUS ]'), findsOneWidget);
    expect(find.text('SHOW TECHNICAL DIAGNOSTICS'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final captureLayout = find.byKey(
      const ValueKey('layout-dazzle.drops:widget:capture'),
    );
    await tester.ensureVisible(captureLayout);
    await tester.pump();
    await tester.tap(captureLayout);
    await _drain(tester);
    final remove = find.text('REMOVE FROM INPUT BAR');
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await _drain(tester);
    expect(find.textContaining('CAPTURE · NOT PLACED'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
