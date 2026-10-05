import 'dart:io';

import 'package:upgrade/platform/plugins/bindings.dart';
import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/store.dart';
import 'package:upgrade/platform/plugins/ui.dart';
import 'package:upgrade_luau/upgrade_luau.dart';
import 'package:upgrade_luau/ui_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/themed_app.dart';

PluginPackage schedulePackage() => PluginPackage(
  manifest: PluginManifest.parse(
    File('plugins/agent-schedules/upgrade.plugin.toml').readAsStringSync(),
  ),
  source: File('plugins/agent-schedules/main.luau').readAsStringSync(),
  origin: 'bundled:upgrade.agent-schedules',
  revision: '1.1.0',
);

class ScheduleHarness {
  ScheduleHarness(this.worker, this.package);
  final LuauWorker worker;
  final PluginPackage package;
  Map<String, Object?>? state;
  late PluginUiNode view;
  List<Object?> effects = [];
  Future<void> send(Map<String, Object?> event) async {
    final plugin = InstalledPlugin(package, package.manifest.permissions);
    final result = await worker.invoke(
      key: package.digest,
      source: '$luauUiSdk\n${package.source}',
      action: 'frame',
      input: {
        'state': state,
        'event': {'token': 'new-job', 'now': '2026-09-13T12:00:00', ...event},
      },
      data: bindPluginData(plugin.id, [plugin]),
    );
    final response = result.value! as Map<String, Object?>;
    state = response['state']! as Map<String, Object?>;
    view = PluginUiNode.parse(response['view'], allowCanvas: true);
    effects = uiList(response['effects']);
  }

  Future<void> action(String id, [Map<String, Object?> args = const {}]) =>
      send({'type': 'action', 'id': id, ...args});
  Future<void> answer(String id, Map<String, Object?> value) =>
      send({'type': 'result', 'id': id, 'ok': true, 'value': value});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LuauWorker worker;
  late ScheduleHarness app;
  const info = <String, Object?>{
    'installed': true,
    'timer_active': true,
    'supported': true,
    'agents': ['codex', 'claude'],
    'timezone': 'America/Lima',
    'features': ['queue', 'cancel', 'summary'],
  };
  const row = <String, Object?>{
    'id': 'job1',
    'title': 'Review',
    'enabled': true,
    'next_label': '2026-09-14T09:00',
    'agent': 'codex',
    'repeat': 'daily',
  };
  const run = <String, Object?>{
    'id': 'run1',
    'title': 'Review',
    'status': 'completed',
    'started_label': '2026-09-13T09:00',
  };
  setUp(() async {
    root = await Directory.systemTemp.createTemp('upgrade-schedule-ui-');
    worker = LuauWorker(dataDirectory: root.path);
    app = ScheduleHarness(worker, schedulePackage());
  });
  tearDown(() async {
    await worker.close();
    await root.delete(recursive: true);
  });
  Future<void> ready() async {
    await app.send({'type': 'mount'});
    await app.answer('hosts', {
      'items': [
        {'id': 'host1', 'name': 'Development'},
      ],
    });
    await app.action('choose_host', {'value': 'host1'});
    await app.answer('inspect', info);
    await app.answer('rows', {
      'items': [row],
      'offset': 0,
      'more': false,
      'paused': false,
    });
  }

  test(
    'bundled release has separate manifest, UI, host API and data versions',
    () async {
      final package = app.package;
      expect(package.manifest.formatVersion, 4);
      expect(package.manifest.uiVersion, 2);
      expect(package.manifest.datasets['preferences']!.schemaVersion, 1);
      expect(
        package.manifest.hostCapabilities['scheduler']!.operations,
        contains('setup'),
      );
      for (final replacement in ['ui_api = 3', 'ui_api = 1.0']) {
        expect(
          () => PluginManifest.parse(
            package.manifest.source.replaceFirst('ui_api = 2', replacement),
          ),
          throwsA(isA<PluginException>()),
        );
      }
      expect(
        PluginManifest.parse(
          package.manifest.source.replaceFirst('ui_api = 2', 'ui_api = 1'),
        ).uiVersion,
        1,
      );
      final store = PluginStore(root);
      expect(
        (await store.synchronizeBuiltins([
          package,
        ], adoptEnabled: true)).single.enabled,
        isFalse,
      );
      await store.setEnabled(package.manifest.id, true);
      await expectLater(
        store.remove(package.manifest.id),
        throwsA(isA<PluginException>()),
      );
    },
  );

  test(
    'real Lua composes empty, unsupported, setup and host-ready screens',
    () async {
      await app.send({'type': 'mount'});
      await app.answer('hosts', {'items': []});
      expect(app.state!['host'], '');
      await ready();
      await app.answer('inspect', {
        ...info,
        'installed': false,
        'supported': false,
        'reason': 'Linger required',
      });
      await app.action('inspect');
      expect(
        (app.effects.single! as Map<String, Object?>)['operation'],
        'inspect',
      );
      await app.answer('inspect', {...info, 'installed': false});
      await app.action('setup');
      expect(
        (app.effects.single! as Map<String, Object?>)['operation'],
        'setup',
      );
      await app.answer('setup', info);
      expect(
        (app.effects.single! as Map<String, Object?>)['operation'],
        'history',
      );
    },
  );

  test(
    'create, edit, save, history, output and back all return valid UI',
    () async {
      await ready();
      await app.action('new');
      await app.action('frequency', {
        'value': 'once',
        'fields': {'title': 'Kept draft', 'prompt': 'Keep prompt'},
      });
      expect(
        (app.state!['edit']! as Map<String, Object?>)['title'],
        'Kept draft',
      );
      await app.action('save', {
        'fields': {'directory': '/srv/repo', 'when': '2026-09-14T09:30'},
      });
      final save = app.effects.single! as Map<String, Object?>;
      final job =
          (save['args']! as Map<String, Object?>)['schedule']!
              as Map<String, Object?>;
      expect(job['date'], '2026-09-14');
      expect(job['time'], '09:30');
      expect(job['prompt'], 'Keep prompt');
      await app.answer('saved', {'id': 'new-job', 'revision': 1});
      await app.answer('rows', {
        'items': [row],
      });
      await app.action('edit', {
        'args': {'id': 'job1'},
      });
      await app.answer('edit', {...job, 'id': 'job1', 'revision': 1});
      await app.action('back');
      await app.answer('rows', {
        'items': [row],
      });
      await app.action('history');
      await app.answer('rows', {
        'items': [run],
      });
      await app.action('output', {
        'args': {'id': 'run1'},
      });
      await app.answer('output', {'status': 'completed', 'text': 'é' * 32768});
      await app.action('back');
      await app.answer('rows', {
        'items': [run],
      });
      await app.action('back');
      await app.answer('rows', {
        'items': [row],
      });
      await app.action('run', {
        'args': {'id': 'job1'},
      });
      await app.answer('ran', {'id': 'run1'});
      expect(app.state!['mode'], 'history');
    },
  );

  test('permission failures preserve drafts and host preferences survive VM release', () async {
    await ready();
    await app.action('new');
    await app.action('save', {
      'fields': {'title': 'Retained draft'},
    });
    await app.send({
      'type': 'result',
      'id': 'saved',
      'ok': false,
      'error': 'Connection lost',
    });
    expect(app.state!['mode'], 'edit');
    expect(
      (app.state!['edit']! as Map<String, Object?>)['title'],
      'Retained draft',
    );
    await worker.release();
    app.state = null;
    await app.send({'type': 'mount'});
    expect(app.state!['host'], 'host1');
  });

  testWidgets(
    'native editor keeps offscreen fields without Lua on each keystroke',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2160);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(ready);
      await tester.runAsync(() => app.action('new'));
      final values = <String, Object?>{};
      final events = <Map<String, Object?>>[];
      Widget screen() => MaterialApp(
        theme: testTheme,
        home: Scaffold(
          body: PluginUi(node: app.view, values: values, onEvent: events.add),
        ),
      );
      await tester.pumpWidget(screen());
      expect(tester.takeException(), isNull);
      final input = find.descendant(
        of: find.byKey(const ValueKey('prompt')),
        matching: find.byType(TextField),
      );
      await tester.enterText(input, 'Native draft');
      await tester.pumpWidget(screen());
      expect(events, isEmpty);
      expect(values['prompt'], 'Native draft');
      await tester.tap(find.text('START TASK'));
      expect(
        (events.single['fields']! as Map<String, Object?>)['prompt'],
        'Native draft',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'Lua changes update offscreen defaults without erasing native drafts',
    () async {
      await ready();
      await app.action('new');
      await app.action('frequency', {'value': 'daily'});
      final previous = app.view;
      final values = <String, Object?>{};
      synchronizePluginFields(values, null, previous);
      values['title'] = 'Typed locally';
      values['when'] = '14:00';
      synchronizePluginFields(values, previous, previous);
      expect(values['title'], 'Typed locally');
      expect(values['when'], '14:00');
      await app.action('frequency', {'value': 'once', 'fields': values});
      synchronizePluginFields(values, previous, app.view);
      expect(values['title'], 'Typed locally');
      expect(values['when'], '');
    },
  );

  test('now is a one-shot task, options retain drafts, and workspace is remembered', () async {
    await ready();
    await app.action('new');
    expect((app.state!['edit']! as Map<String, Object?>)['repeat'], 'now');
    await app.action('save', {
      'fields': {'prompt': 'Verify tests', 'directory': '/srv/repo'},
    });
    final effect = app.effects.single! as Map<String, Object?>;
    final job =
        (effect['args']! as Map<String, Object?>)['schedule']!
            as Map<String, Object?>;
    expect(job['repeat'], 'now');
    expect(job['title'], 'Verify tests');
    expect(job['timeout'], 14400);
    await app.answer('saved', {'id': 'new-job', 'revision': 1});
    expect(app.state!['mode'], 'history');
    await app.action('new');
    expect(
      (app.state!['edit']! as Map<String, Object?>)['directory'],
      '/srv/repo',
    );
    await app.action('back', {
      'fields': {'prompt': 'Keep this draft'},
    });
    await app.action('new');
    expect(
      (app.state!['edit']! as Map<String, Object?>)['prompt'],
      'Keep this draft',
    );
  });

  testWidgets(
    'disclosure keeps input drafts and native picker returns selection',
    (tester) async {
      await tester.runAsync(ready);
      await tester.runAsync(() => app.action('new'));
      final values = <String, Object?>{};
      synchronizePluginFields(values, null, app.view);
      final options = app.view.children.firstWhere(
        (node) => node.key == 'options',
      );
      final compact = PluginUiNode(
        'column',
        const {'key': 'test_options'},
        [
          PluginUiNode(
            'disclosure',
            options.props,
            options.children
                .where((node) => node.key == 'title' || node.key == 'agent')
                .toList(),
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme,
          home: Scaffold(
            body: PluginUi(node: compact, values: values, onEvent: (_) {}),
          ),
        ),
      );
      await tester.tap(find.text('Agent and options'));
      await tester.pump();
      final field = find.descendant(
        of: find.byKey(const ValueKey('title')),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, 'Kept locally');
      expect(values['title'], 'Kept locally');
      tester.testTextInput.hide();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Agent and options'));
      await tester.pump();
      expect(values['title'], 'Kept locally');
      await tester.ensureVisible(find.text('Agent and options'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Agent and options'));
      await tester.pump();
      await tester.ensureVisible(find.text('Agent').last);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Agent').last);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('CLAUDE'), findsOneWidget);
      await tester.tap(find.text('CLAUDE'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(values['agent'], 'claude');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final scale in [1.0, 1.6, 2.0]) {
    testWidgets('composer fits 320dp at text scale $scale with keyboard', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(960, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(ready);
      await tester.runAsync(() => app.action('new'));
      final values = <String, Object?>{};
      synchronizePluginFields(values, null, app.view);
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme,
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(320, 800),
              textScaler: TextScaler.linear(scale),
              viewInsets: const EdgeInsets.only(bottom: 280),
            ),
            child: Scaffold(
              body: PluginUi(node: app.view, values: values, onEvent: (_) {}),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      expect(find.text('START TASK').hitTestable(), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
