import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/data/plugins/installed.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/plugins/native_plugins.dart';
import 'package:upgrade/application/plugins/plugins.dart';
import 'package:upgrade/features/plugins/plugin_card.dart';
import 'package:upgrade/data/plugins/manifest.dart';
import 'package:upgrade_luau/upgrade_luau.dart';
import 'package:upgrade/application/providers.dart';

import '../../support/themed_app.dart';

const _manifest = '''
manifest_version = 4
id = "test.card"
name = "Card test"
version = "1.0.0"
upgrade_api = "^2.1.0"
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
  Completer<void>? changes;

  @override
  Future<List<InstalledPlugin>> build() async => catalog;

  @override
  Future<LuauResult> card(
    String id,
    String widget,
    Map<String, Object?> input,
  ) async {
    final event = input['event']! as Map<String, Object?>;
    events.add({...event, 'card': widget});
    if (event['type'] == 'changed') await changes?.future;
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

const _agents = '''
[host_capabilities.agents]
api_version = 1
service = "agents"
operations = ["list"]
''';

Future<(ProviderContainer, _CardPlugins)> _setUp({
  String extra = '',
  List<Override> overrides = const [],
}) async {
  final package = PluginPackage(
    manifest: PluginManifest.parse('$_manifest$extra'),
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
    retry: noRetry,
    overrides: [
      pluginBootCatalogProvider.overrideWithValue([plugin]),
      pluginsProvider.overrideWith(() => plugins),
      ...overrides,
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

  testWidgets('an agent change reaches a shown card once, quietly', (
    tester,
  ) async {
    final feed = StreamController<AgentPanelState>.broadcast();
    addTearDown(feed.close);
    final (container, plugins) = await _setUp(
      extra: _agents,
      overrides: [agentsFeedProvider.overrideWith((ref) => feed.stream)],
    );
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
    expect(container.read(pluginAgentsHeldProvider), 1);
    feed.add(AgentPanelState.linked(const []));
    await _drain(tester);
    expect(plugins.events.map((event) => event['type']), ['mount', 'changed']);
    expect(plugins.events.last['capability'], 'agents');
    expect(find.text('CONNECTING'), findsNothing);

    stage.value = false;
    await _drain(tester);
    expect(container.read(pluginAgentsHeldProvider), 0);
    feed.add(AgentPanelState.linked(const []));
    feed.add(AgentPanelState.linked(const []));
    await tester.pump(const Duration(seconds: 2));
    await _drain(tester);
    expect(plugins.events, hasLength(2));
    stage.value = true;
    await _drain(tester);
    await tester.pump(const Duration(seconds: 2));
    await _drain(tester);
    expect(plugins.events.map((event) => event['type']), [
      'mount',
      'changed',
      'changed',
    ]);
  });

  testWidgets('a tap under a quiet change waits for it and still runs', (
    tester,
  ) async {
    final feed = StreamController<AgentPanelState>.broadcast();
    addTearDown(feed.close);
    final (container, plugins) = await _setUp(
      extra: _agents,
      overrides: [agentsFeedProvider.overrideWith((ref) => feed.stream)],
    );
    final status = container
        .read(pluginContributionCatalogProvider)
        .widgets
        .first;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(_host(container, PluginCard(registration: status)));
    await _drain(tester);
    plugins.changes = Completer();
    feed.add(AgentPanelState.linked(const []));
    await _drain(tester);
    expect(plugins.events.last['type'], 'changed');

    await tester.tap(find.text('GO'));
    await _drain(tester);
    expect(plugins.events, hasLength(2));
    plugins.changes!.complete();
    await _drain(tester);
    expect(plugins.events.map((event) => event['type'] ?? event['id']), [
      'mount',
      'changed',
      'action',
    ]);
    expect(plugins.events.last['id'], 'go');
  });
}
