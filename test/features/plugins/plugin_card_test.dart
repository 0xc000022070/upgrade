import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:striked/application/plugins/native_plugins.dart';
import 'package:striked/application/plugins/plugins.dart';
import 'package:striked/features/plugins/plugin_card.dart';
import 'package:striked/platform/plugins/manifest.dart';
import 'package:striked/platform/plugins/store.dart';
import 'package:striked_luau/striked_luau.dart';

import '../../support/themed_app.dart';

const _manifest = '''
manifest_version = 4
id = "test.card"
name = "Card test"
version = "1.0.0"
striked_api = "^2.1.0"
ui_api = 1
[runtime]
kind = "luau"
entry = "main.luau"
[permissions]
ui = ["widget"]
[contributes]
[[contributes.widgets]]
id = "status"
title = "Status"
locations = ["home.card"]
default_location = "home.card"
default_size = "auto"
refresh_minutes = 15
sizes = [{ id = "auto", title = "Automatic", min_width = 280, max_width = 720 }]
[[contributes.widgets]]
id = "other"
title = "Other"
locations = ["home.card"]
default_location = "home.card"
default_size = "auto"
sizes = [{ id = "auto", title = "Automatic", min_width = 280, max_width = 720 }]
''';

class _CardPlugins extends Plugins {
  _CardPlugins(this.catalog);
  final List<InstalledPlugin> catalog;
  final events = <Map<String, Object?>>[];

  @override
  Future<List<InstalledPlugin>> build() async => catalog;

  @override
  Future<LuauResult> card(
    String id,
    String widget,
    Map<String, Object?> input,
  ) async {
    events.add({...input['event']! as Map<String, Object?>, 'card': widget});
    return LuauResult(
      loadMicros: 0,
      runMicros: 0,
      memoryBytes: 0,
      peakBytes: 0,
      cold: false,
      value: {
        'state': <String, Object?>{},
        'view': {
          'kind': 'panel',
          'props': {'key': 'card', 'title': '$widget ${events.length}'},
          'children': [
            {
              'kind': 'button',
              'props': {'key': 'go', 'text': 'GO', 'onPress': 'go'},
            },
          ],
        },
        'effects': const <Object?>[],
      },
    );
  }
}

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<(ProviderContainer, _CardPlugins)> _setUp() async {
  final package = PluginPackage(
    manifest: PluginManifest.parse(_manifest),
    source: 'return {}',
    origin: 'https://github.com/test/card',
    revision: '1.0.0',
  );
  final plugin = InstalledPlugin(
    package,
    package.manifest.permissions,
    enabled: true,
  );
  final plugins = _CardPlugins([plugin]);
  final container = ProviderContainer(
    overrides: [
      pluginBootCatalogProvider.overrideWithValue([plugin]),
      pluginsProvider.overrideWith(() => plugins),
    ],
  );
  addTearDown(container.dispose);
  return (container, plugins);
}

Widget _host(ProviderContainer container, Widget card) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: testTheme,
        home: Scaffold(body: card),
      ),
    );

void main() {
  testWidgets('a card frames on mount and again on a tap', (tester) async {
    final (container, plugins) = await _setUp();
    final registration = container
        .read(pluginContributionCatalogProvider)
        .widgets
        .first;
    expect(registration.luau, isTrue);
    expect(registration.enabled, isTrue);
    await tester.pumpWidget(
      _host(container, PluginCard(registration: registration)),
    );
    await _drain(tester);
    expect(find.textContaining('STATUS 1'), findsOneWidget);
    expect(plugins.events.single['type'], 'mount');
    expect(plugins.events.single['widget'], 'status');
    await tester.tap(find.text('GO'));
    await _drain(tester);
    expect(find.textContaining('STATUS 2'), findsOneWidget);
    expect(plugins.events.last['id'], 'go');
  });

  testWidgets('a card slot handed another widget starts that widget fresh', (
    tester,
  ) async {
    final (container, plugins) = await _setUp();
    final [status, other] = container
        .read(pluginContributionCatalogProvider)
        .widgets;
    await tester.pumpWidget(_host(container, PluginCard(registration: status)));
    await _drain(tester);
    await tester.pumpWidget(_host(container, PluginCard(registration: other)));
    await _drain(tester);
    expect(find.textContaining('OTHER 2'), findsOneWidget);
    expect(plugins.events.last, containsPair('type', 'mount'));
    expect(plugins.events.last, containsPair('card', 'other'));
  });

  testWidgets('a refresh due off stage waits until Home shows again', (
    tester,
  ) async {
    final (container, plugins) = await _setUp();
    final status = container
        .read(pluginContributionCatalogProvider)
        .widgets
        .first;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final stage = ValueNotifier(true);
    await tester.pumpWidget(
      _host(
        container,
        ValueListenableBuilder(
          valueListenable: stage,
          builder: (_, shown, child) =>
              TickerMode(enabled: shown, child: child!),
          child: PluginCard(registration: status),
        ),
      ),
    );
    await _drain(tester);
    stage.value = false;
    await tester.pump();
    await tester.pump(const Duration(minutes: 16));
    await _drain(tester);
    expect(plugins.events.map((event) => event['type']), ['mount']);
    stage.value = true;
    await _drain(tester);
    expect(plugins.events.map((event) => event['type']), ['mount', 'refresh']);
  });
}
