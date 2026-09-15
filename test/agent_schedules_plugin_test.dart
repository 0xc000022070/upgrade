import 'dart:io';

import 'package:dazzle/platform/plugins/bindings.dart';
import 'package:dazzle/platform/plugins/manifest.dart';
import 'package:dazzle/platform/plugins/store.dart';
import 'package:dazzle/platform/plugins/ui.dart';
import 'package:dazzle_luau/dazzle_luau.dart';
import 'package:dazzle_luau/ui_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/themed_app.dart';

PluginPackage schedulePackage() => PluginPackage(
  manifest: PluginManifest.parse(
    File('plugins/agent-schedules/dazzle.plugin.toml').readAsStringSync(),
  ),
  source: File('plugins/agent-schedules/main.luau').readAsStringSync(),
  origin: 'bundled:dazzle.agent-schedules',
  revision: '1.0.0',
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
    root = await Directory.systemTemp.createTemp('dazzle-schedule-ui-');
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
      expect(package.manifest.uiVersion, 1);
      expect(package.manifest.datasets['preferences']!.schemaVersion, 1);
      expect(
        package.manifest.hostCapabilities['scheduler']!.operations,
        contains('setup'),
      );
      for (final replacement in ['ui_api = 2', 'ui_api = 1.0']) {
        expect(
          () => PluginManifest.parse(
            package.manifest.source.replaceFirst('ui_api = 1', replacement),
          ),
          throwsA(isA<PluginException>()),
        );
      }
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
        'list',
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
        of: find.byKey(const ValueKey('title')),
        matching: find.byType(TextField),
      );
      await tester.enterText(input, 'Native draft');
      await tester.pumpWidget(screen());
      expect(events, isEmpty);
      expect(values['title'], 'Native draft');
      final list = find.byType(Scrollable).last;
      await tester.scrollUntilVisible(
        find.text('SAVE SCHEDULE'),
        250,
        scrollable: list,
      );
      await tester.tap(find.text('SAVE SCHEDULE'));
      expect(
        (events.single['fields']! as Map<String, Object?>)['title'],
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
      expect(values['when'], '2026-09-13T09:00');
    },
  );
}
