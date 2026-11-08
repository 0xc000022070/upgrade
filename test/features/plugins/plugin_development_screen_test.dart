import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/data/plugins/installed.dart';
import 'package:upgrade/application/plugins/native_plugins.dart';
import 'package:upgrade/application/plugins/plugin_development.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/components/solid_action_bar.dart';
import 'package:upgrade/features/plugins/plugin_development_screen.dart';
import 'package:upgrade/data/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/plugin_check.dart';
import 'package:upgrade/application/providers.dart';

import '../../support/themed_app.dart';

const _host = Host(
  id: 'h',
  name: 'vm',
  address: '10.0.0.1',
  port: 22,
  user: 'dev',
  keyId: 'k',
);

PluginPackage _package(String origin, {String main = ''}) {
  const dir = 'plugins/templates/phone-card';
  final manifest = PluginManifest.parse(
    File('$dir/upgrade.plugin.toml').readAsStringSync(),
  );
  return PluginPackage(
    manifest: manifest,
    source: '${File('$dir/main.luau').readAsStringSync()}$main',
    origin: origin,
    revision: 'r1',
    files: {'lib/card.luau': File('$dir/lib/card.luau').readAsStringSync()},
  );
}

class _Session extends PluginDevelopment {
  _Session(this.check);
  final PluginCheck check;
  @override
  PluginDevState? build() => PluginDevState(
    host: _host,
    path: '~/hello',
    phase: PluginDevPhase.watching,
    check: check,
  );
}

void main() {
  final checked = _package('development:dev.example.hello-card');
  final check = PluginCheck(
    revision: 'r1',
    diagnostics: const [],
    manifest: checked.manifest,
    package: checked,
  );

  Future<void> pump(WidgetTester tester, List<PluginPackage> catalog) =>
      tester.pumpWidget(
        ProviderScope(
          retry: noRetry,
          overrides: [
            pluginDevelopmentProvider.overrideWith(() => _Session(check)),
            effectivePluginsProvider.overrideWithValue([
              for (final package in catalog)
                InstalledPlugin(package, package.manifest.permissions),
            ]),
          ],
          child: MaterialApp(
            theme: testTheme,
            home: const PluginDevelopmentScreen(),
          ),
        ),
      );

  Finder action(String label) => find.widgetWithText(SolidActionBar, label);

  testWidgets('the install action names what the tap will do', (tester) async {
    await pump(tester, const []);
    expect(action('INSTALL'), findsOneWidget);

    await pump(tester, [checked]);
    expect(action('INSTALLED · OPEN'), findsOneWidget);

    await pump(tester, [
      _package('development:dev.example.hello-card', main: '\n'),
    ]);
    expect(action('INSTALL THIS REVISION'), findsOneWidget);
  });

  testWidgets('an ID owned by another source blocks the install up front', (
    tester,
  ) async {
    await pump(tester, [_package('https://github.com/x/hello')]);
    expect(find.text('ID IN USE'), findsOneWidget);
    expect(find.text('HTTPS://GITHUB.COM/X/HELLO'), findsOneWidget);
    expect(action('INSTALL'), findsNothing);
  });
}
