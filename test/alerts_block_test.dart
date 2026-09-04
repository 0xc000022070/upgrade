import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/application/agents.dart';
import 'package:hotline/application/providers.dart';
import 'package:hotline/data/database.dart';
import 'package:hotline/data/enums.dart';
import 'package:hotline/data/repositories/host_repository.dart';
import 'package:hotline/data/repositories/settings_repository.dart';
import 'package:hotline/design/colors.dart';
import 'package:hotline/features/settings/alerts_block.dart';

import 'support/platform_channels.dart';

/// The `[ ALERTS ]` row.

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
    overrides: [
      databaseProvider.overrideWithValue(db),
      hostRepositoryProvider.overrideWithValue(hosts),
    ],
    child: MaterialApp(
      home: Material(child: AlertsSettingsBlock(requestPermission: permission)),
    ),
  );

  /// The background grain and the panel's own entry both run off tickers that
  /// never settle, so `pumpAndSettle` here would spin until the test timed out.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<bool> flag() =>
      SettingsRepository(db)
          .flag(SettingsRepository.alertsBlockedAgents, orElse: false);

  testWidgets('with no HERDR host the row is dim and does nothing', (
    tester,
  ) async {
    await tester.pumpWidget(shell(permission: () async => true));
    await settle(tester);

    expect(find.text('NO HOST'), findsOneWidget);
    // "the row is dim".
    expect(
      tester.widget<Text>(find.text('BLOCKED AGENTS')).style?.color,
      HotlineColors.textMuted,
    );
    await tester.tap(find.text('BLOCKED AGENTS'));
    await settle(tester);

    expect(await flag(), isFalse);
    await unmount(tester);
  });

  testWidgets('granted, the toggle turns on and persists', (tester) async {
    await withHerdrHost();
    await tester.pumpWidget(shell(permission: () async => true));
    await settle(tester);

    expect(find.text('NO HOST'), findsNothing);
    expect(
      tester.widget<Text>(find.text('BLOCKED AGENTS')).style?.color,
      isNot(HotlineColors.textMuted),
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
