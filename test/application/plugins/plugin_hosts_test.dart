import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/plugins/plugin_hosts.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../plugins/agent_schedules_plugin_test.dart' show schedulePackage;

void main() {
  late Directory root;
  late SchedulerBindings bindings;
  late ProviderContainer container;
  late InstalledPlugin plugin;
  late PluginHostRegistry registry;
  final calls = <String>[];
  var offline = false;
  var active = true;
  var configured = false;
  Completer<void>? blocked;
  setUp(() async {
    calls.clear();
    offline = false;
    active = true;
    configured = false;
    blocked = null;
    root = await Directory.systemTemp.createTemp('upgrade-plugin-hosts-');
    bindings = SchedulerBindings(
      () async => File('${root.path}/bindings.json'),
    );
    final package = schedulePackage();
    plugin = InstalledPlugin(package, package.manifest.permissions);
    final hosts = InMemoryHostRepository();
    await hosts.save(
      const Host(
        id: 'host1',
        name: 'Development',
        address: 'localhost',
        port: 2222,
        user: 'test',
        keyId: 'test',
      ),
    );
    container = ProviderContainer(
      overrides: [
        hostRepositoryProvider.overrideWithValue(hosts),
        schedulerBindingsProvider.overrideWithValue(bindings),
        schedulerTransportProvider.overrideWithValue((
          host,
          owner,
          operation,
          args,
        ) async {
          calls.add(operation);
          if (offline) throw const SocketException('Offline');
          if (operation == 'save') await blocked?.future;
          if (operation == 'setup') configured = true;
          return {'installed': configured, 'owner': owner};
        }),
      ],
    );
    registry = container.read(pluginHostRegistryProvider);
  });
  tearDown(() async {
    container.dispose();
    await root.delete(recursive: true);
  });
  void check() {
    if (!active) throw const PluginException('Disabled');
  }

  Future<Object?> invoke(String operation, {bool allow = true}) =>
      registry.invoke(
        plugin,
        {
          'capability': 'scheduler',
          'operation': operation,
          'args': {'host': 'host1'},
        },
        (_, _, _) async => allow,
        check,
      );

  test(
    'host access needs a grant and user approval; probing is not installation',
    () async {
      await expectLater(
        invoke('inspect', allow: false),
        throwsA(isA<PluginException>()),
      );
      expect(calls, isEmpty);
      await invoke('inspect');
      await registry.deactivate(plugin);
      expect(calls, ['inspect']);
      expect(
        (await bindings.read())[pluginHostOwner(plugin)]!['host1']!.configured,
        isFalse,
      );
      plugin = InstalledPlugin(
        plugin.package,
        plugin.grants
            .where((grant) => grant.id != 'host.scheduler.inspect')
            .toSet(),
        enabled: false,
      );
      await expectLater(invoke('inspect'), throwsA(isA<PluginException>()));
      expect(calls, ['inspect']);
    },
  );

  test(
    'disable persists pending pauses and retries without deleting ownership',
    () async {
      await invoke('setup');
      offline = true;
      await registry.deactivate(plugin);
      final owner = pluginHostOwner(plugin);
      expect((await bindings.read())[owner]!['host1']!.pending, isTrue);
      offline = false;
      await registry.deactivate(plugin);
      expect((await bindings.read())[owner]!['host1']!.pending, isFalse);
      expect((await bindings.read())[owner]!['host1']!.configured, isTrue);
      expect(calls, ['setup', 'pause_scope', 'pause_scope']);
    },
  );

  test('disable queues the host pause after an in-flight write and rejects its stale result', () async {
    await invoke('setup');
    blocked = Completer<void>();
    final running = invoke('save');
    final rejected = expectLater(running, throwsA(isA<PluginException>()));
    while (!calls.contains('save')) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    active = false;
    final pausing = registry.deactivate(plugin);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(calls, ['setup', 'save']);
    blocked!.complete();
    await rejected;
    await pausing;
    expect(calls, ['setup', 'save', 'pause_scope']);
  });

  test('pending pause is acknowledged before another operation', () async {
    await invoke('setup');
    await bindings.set(
      pluginHostOwner(plugin),
      'host1',
      const SchedulerBinding(configured: true, pending: true),
    );
    await invoke('list');
    expect(calls, ['setup', 'pause_scope', 'list']);
  });

  test('unsupported or corrupt binding formats are retained', () async {
    final file = await bindings.file();
    for (final contents in ['{"version":2,"owners":{}}', '{']) {
      await file.writeAsString(contents);
      await expectLater(bindings.read(), throwsA(isA<PluginException>()));
      await expectLater(
        bindings.set(
          pluginHostOwner(plugin),
          'host1',
          const SchedulerBinding(),
        ),
        throwsA(isA<PluginException>()),
      );
      expect(await file.readAsString(), contents);
    }
  });

  test('whole numbers reach the engine spelled as counts', () {
    // Everything a plugin writes crosses as a float64, so a revision of 0 and a
    // timeout of 900 arrive here as doubles and would be sent as `0.0` and
    // `900.0`. The engine reads those fields as counts and refuses a fraction.
    final request = wholeNumbers({
      'schedule': {
        'revision': 0.0,
        'timeout': 900.0,
        'title': 'Nightly sweep',
        'weights': <Object?>[1.0, 2.5],
      },
    });
    expect(
      jsonEncode(request),
      '{"schedule":{"revision":0,"timeout":900,'
      '"title":"Nightly sweep","weights":[1,2.5]}}',
    );
  });
}
