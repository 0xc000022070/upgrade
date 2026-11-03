import '../../support/native_plugins.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/alerts/alerts.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/repositories/settings_repository.dart';
import 'package:upgrade/design/colors.dart';
import 'package:upgrade/features/settings/alerts_block.dart';
import 'package:upgrade/application/providers.dart';

import '../../support/platform_channels.dart';
import '../../support/themed_app.dart';

const nyx = Host(
  id: 'host-1',
  name: 'nyx',
  address: '100.64.0.1',
  port: 22,
  user: 'luisnquin',
  keyId: 'key-1',
);

void main() {
  late AppDatabase db;
  late InMemoryHostRepository hosts;

  setUp(() {
    stubDeviceChannels();
    db = AppDatabase(NativeDatabase.memory());
    hosts = InMemoryHostRepository();
  });

  tearDown(() => db.close());

  Future<void> withHerdrHost() async {
    await hosts.save(nyx);
    await hosts.setIntegration(nyx.id, IntegrationKind.herdr, true);
  }

  Widget shell({Future<bool> Function()? permission}) => ProviderScope(
    retry: noRetry,
    overrides: [
      ...featureTestOverrides(db),
      hostRepositoryProvider.overrideWithValue(hosts),
    ],
    child: MaterialApp(
      theme: testTheme,
      home: Material(child: AlertsSettingsBlock(requestPermission: permission)),
    ),
  );

  /// The grain and the panel's own entry run off tickers that never settle, so
  /// `pumpAndSettle` would spin until the test timed out.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<bool> flag([AlertKind kind = AlertKind.blocked]) =>
      SettingsRepository(db).flag(kind.settingsKey, orElse: false);

  testWidgets('with no HERDR host both rows are dim and do nothing', (
    tester,
  ) async {
    await tester.pumpWidget(shell(permission: () async => true));
    await settle(tester);

    expect(find.text('NO HOST'), findsNWidgets(2));
    for (final kind in AlertKind.values) {
      expect(
        tester.widget<Text>(find.text(kind.label)).style?.color,
        UpgradeColors.textMuted,
      );
      await tester.tap(find.text(kind.label));
      await settle(tester);
      expect(await flag(kind), isFalse);
    }
    await unmount(tester);
  });

  testWidgets('the two rows are one panel, blocked above finished', (
    tester,
  ) async {
    await withHerdrHost();
    await tester.pumpWidget(shell(permission: () async => true));
    await settle(tester);

    expect(
      tester.getTopLeft(find.text('BLOCKED AGENTS')).dy,
      lessThan(tester.getTopLeft(find.text('FINISHED AGENTS')).dy),
    );
    await unmount(tester);
  });

  testWidgets('each row carries its own setting', (tester) async {
    await withHerdrHost();
    await tester.pumpWidget(shell(permission: () async => true));
    await settle(tester);

    await tester.tap(find.text('FINISHED AGENTS'));
    await settle(tester);

    expect(await flag(AlertKind.done), isTrue);
    expect(await flag(AlertKind.blocked), isFalse);
    await unmount(tester);
  });

  testWidgets('granted, the toggle turns on and persists', (tester) async {
    await withHerdrHost();
    await tester.pumpWidget(shell(permission: () async => true));
    await settle(tester);

    expect(find.text('NO HOST'), findsNothing);
    expect(
      tester.widget<Text>(find.text('BLOCKED AGENTS')).style?.color,
      isNot(UpgradeColors.textMuted),
    );
    await tester.tap(find.text('BLOCKED AGENTS'));
    await settle(tester);

    expect(await flag(), isTrue);
    expect(find.text('NOTIFICATIONS DENIED'), findsNothing);
    await unmount(tester);
  });

  testWidgets('refused, the toggle stays off and the row says so', (
    tester,
  ) async {
    await withHerdrHost();
    await tester.pumpWidget(shell(permission: () async => false));
    await settle(tester);

    await tester.tap(find.text('BLOCKED AGENTS'));
    await settle(tester);

    expect(await flag(), isFalse);
    expect(find.text('NOTIFICATIONS DENIED'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('on, tapping again turns it off without asking the OS', (
    tester,
  ) async {
    await withHerdrHost();
    await SettingsRepository(db)
        .setFlag(SettingsRepository.alertsBlockedAgents, true);
    var asked = false;
    await tester.pumpWidget(
      shell(
        permission: () async {
          asked = true;
          return true;
        },
      ),
    );
    await settle(tester);

    await tester.tap(find.text('BLOCKED AGENTS'));
    await settle(tester);

    expect(await flag(), isFalse);
    expect(asked, isFalse);
    await unmount(tester);
  });
}
