import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/data/plugins/installed.dart';
import 'package:upgrade/application/plugins/plugin_hosts.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/data/plugins/manifest.dart';

const _head = '''
manifest_version = 5
id = "dev.local.runner"
name = "Runner"
purpose = "Run declared commands."
version = "0.1.0"
upgrade_api = "^2.1.0"
ui_api = 2

[runtime]
kind = "luau"
entry = "main.luau"

[permissions]
ui = ["page"]

[[contributes.pages]]
id = "main"
title = "Runner"
''';

String _manifest(String commands, {String service = 'run'}) =>
    '''
$_head
[host_capabilities.jobs]
api_version = 1
service = "$service"
operations = ["submit", "list", "status", "output", "cancel"]
$commands
''';

const _commands = '''
[host_capabilities.jobs.commands.test]
argv = ["just", "test", "{target}"]
cwd = "~/Projects/fixture"
timeout_seconds = 600

[host_capabilities.jobs.commands.build]
argv = ["just", "build", "{mode}"]
timeout_seconds = 60
choices = { mode = ["debug", "release"] }
''';

void main() {
  late List<(String, Map<String, Object?>)> calls;
  late List<Map<String, Object?>> jobs;
  late PluginHostService service;
  late InstalledPlugin plugin;
  late List<Set<String>> confirmed;
  late bool answer;
  late InMemoryHostRepository hosts;
  late PluginRunHosts used;
  late File file;
  late Future<Map<String, Object?>> Function(String op) reply;

  PluginHostService start() => pluginRunService(
    hosts,
    (host, name, op, args) {
      expect(name, 'run/1');
      calls.add((op, args));
      return reply(op);
    },
    used,
    random: Random(1),
  );

  setUp(() async {
    calls = [];
    jobs = [];
    confirmed = [];
    answer = true;
    reply = (op) async =>
        op == 'list' ? {'jobs': jobs} : {'id': calls.last.$2['id']};
    final state = Directory.systemTemp.createTempSync('run');
    addTearDown(() => state.deleteSync(recursive: true));
    file = File('${state.path}/run-hosts.json');
    used = PluginRunHosts(() async => file);
    hosts = InMemoryHostRepository();
    await hosts.save(
      const Host(
        id: 'host1',
        name: 'vm',
        address: 'localhost',
        port: 2222,
        user: 'dev',
        keyId: 'k',
      ),
    );
    service = start();
    final manifest = PluginManifest.parse(_manifest(_commands));
    plugin = InstalledPlugin(
      PluginPackage(
        manifest: manifest,
        source: 'return {}',
        origin: 'development:dev.local.runner',
        revision: 'r1',
      ),
      manifest.permissions,
    );
  });

  PluginHostGesture tap() => PluginHostGesture((_, _) {});

  Future<Object?> invoke(
    String operation,
    Map<String, Object?> args, {
    PluginHostGesture? gesture,
  }) => service.invoke(
    plugin,
    operation,
    {'host': 'host1', ...args},
    (_, _, operations) async {
      confirmed.add(operations);
      return answer;
    },
    () {},
    gesture,
  );

  String tag() => 'p${pluginHostOwner(plugin).substring(0, 16)}';

  test(
    'a tap runs the declared argv with each parameter as one word',
    () async {
      await invoke('submit', {
        'command': 'test',
        'params': {'target': 'unit/a.b'},
        'id': 'run1',
      }, gesture: tap());
      expect(confirmed, [
        {
          'just test {target} (any word) in ~/Projects/fixture for up to 600 s',
          'just build {mode: debug|release} for up to 60 s',
        },
      ]);
      final (op, args) = calls.last;
      expect(op, 'submit');
      expect(args, {
        'id': '${tag()}-run1',
        'argv': ['just', 'test', 'unit/a.b'],
        'cwd': '~/Projects/fixture',
        'timeout_ms': 600000,
        'tag': tag(),
      });
    },
  );

  test('submit refuses what the manifest did not spell out', () async {
    for (final args in <Map<String, Object?>>[
      {'command': 'rm', 'params': <String, Object?>{}},
      {'command': 'test', 'params': <String, Object?>{}},
      {
        'command': 'test',
        'params': {'target': 'a', 'extra': 'b'},
      },
      {
        'command': 'test',
        'params': {'target': 'a b'},
      },
      {
        'command': 'test',
        'params': {'target': '--force'},
      },
      {
        'command': 'test',
        'params': {'target': r'$(id)'},
      },
      {
        'command': 'test',
        'params': {'target': 'a=b'},
      },
      {
        'command': 'test',
        'params': {'target': 'caf\u00e9'},
      },
      {
        'command': 'build',
        'params': {'mode': 'profile'},
      },
      {
        'command': 'test',
        'params': {'target': 'a'},
        'id': 'x-y',
      },
    ]) {
      await expectLater(
        invoke('submit', args, gesture: tap()),
        throwsA(isA<PluginException>()),
        reason: '$args',
      );
    }
    expect(calls.where((call) => call.$1 == 'submit'), isEmpty);
  });

  test('submit needs a tap of its own and a free slot', () async {
    final args = {
      'command': 'test',
      'params': {'target': 'a'},
    };
    await expectLater(invoke('submit', args), throwsA(isA<PluginException>()));
    final gesture = tap();
    await invoke('submit', args, gesture: gesture);
    await expectLater(
      invoke('submit', args, gesture: gesture),
      throwsA(isA<PluginException>()),
    );
    jobs = [
      for (var i = 0; i < 4; i++) {'id': '${tag()}-$i', 'state': 'running'},
    ];
    await expectLater(
      invoke('submit', args, gesture: tap()),
      throwsA(isA<PluginException>()),
    );
    expect(calls.where((call) => call.$1 == 'submit').length, 1);
  });

  test('submits racing for the last slot get one each in turn', () async {
    final gate = Completer<void>();
    reply = (op) async {
      if (op == 'list') {
        await gate.future;
        return {'jobs': jobs};
      }
      jobs.add({'id': calls.last.$2['id'], 'state': 'running'});
      return {};
    };
    jobs = [
      for (var i = 0; i < 3; i++) {'id': '${tag()}-$i', 'state': 'running'},
    ];
    final args = {
      'command': 'build',
      'params': {'mode': 'debug'},
    };
    final first = invoke('submit', args, gesture: tap());
    final second = invoke('submit', args, gesture: tap());
    gate.complete();
    await first;
    await expectLater(second, throwsA(isA<PluginException>()));
    expect(calls.where((call) => call.$1 == 'submit').length, 1);
  });

  test('a refusal asks again only from a submit tap', () async {
    answer = false;
    await expectLater(invoke('list', {}), throwsA(isA<PluginException>()));
    await expectLater(invoke('list', {}), throwsA(isA<PluginException>()));
    expect(confirmed.length, 1);
    answer = true;
    await invoke('submit', {
      'command': 'build',
      'params': {'mode': 'release'},
    }, gesture: tap());
    expect(confirmed.length, 2);
    expect(calls.where((call) => call.$1 == 'submit').length, 1);
  });

  test('after a refusal a submit without a tap does not ask', () async {
    answer = false;
    final args = {
      'command': 'build',
      'params': {'mode': 'release'},
    };
    await expectLater(
      invoke('submit', args, gesture: tap()),
      throwsA(isA<PluginException>()),
    );
    await expectLater(invoke('submit', args), throwsA(isA<PluginException>()));
    expect(confirmed.length, 1);
  });

  test('the slot count asks the engine for live jobs only', () async {
    await invoke('submit', {
      'command': 'build',
      'params': {'mode': 'debug'},
    }, gesture: tap());
    expect(calls.firstWhere((call) => call.$1 == 'list').$2, {
      'tag': tag(),
      'live': true,
    });
  });

  test('an unreadable run host file is set aside once', () async {
    final args = {
      'command': 'build',
      'params': {'mode': 'debug'},
    };
    for (final bad in ['{not json', '{"version": 2, "owners": {}}']) {
      file.writeAsStringSync(bad);
      await expectLater(
        invoke('submit', args, gesture: tap()),
        throwsA(isA<PluginException>()),
      );
      expect(File('${file.path}.corrupt').readAsStringSync(), bad);
    }
    expect(calls.where((call) => call.$1 == 'submit'), isEmpty);
    await invoke('submit', args, gesture: tap());
    expect(await used.read(pluginHostOwner(plugin)), {'host1'});
  });

  test('reads stay on this plugin\'s jobs and within bounds', () async {
    await invoke('list', {'tag': 'other'});
    expect(calls.last.$2, {'tag': tag()});
    for (final op in ['status', 'output', 'cancel']) {
      await expectLater(
        invoke(op, {'id': 'pdeadbeefdeadbeef-x'}),
        throwsA(isA<PluginException>()),
      );
    }
    await invoke('output', {
      'id': '${tag()}-run1',
      'tail': 9000,
      'limit': 1 << 30,
      'grep': 'FAIL',
      'path': '/etc/passwd',
    });
    expect(calls.last.$2, {
      'id': '${tag()}-run1',
      'grep': 'FAIL',
      'tail': 500,
      'limit': 64 * 1024,
    });
    await expectLater(
      invoke('output', {'id': '${tag()}-run1', 'head': double.nan}),
      throwsA(isA<PluginException>()),
    );
    await invoke('output', {'id': '${tag()}-run1', 'limit': double.infinity});
    expect(calls.last.$2, {'id': '${tag()}-run1', 'limit': 32 * 1024});
    expect(confirmed.length, 1);
  });

  test('deactivate after a restart cancels the live jobs it started', () async {
    await invoke('submit', {
      'command': 'build',
      'params': {'mode': 'debug'},
    }, gesture: tap());
    jobs = [
      {'id': '${tag()}-a', 'state': 'running'},
      {'id': '${tag()}-b', 'state': 'exited'},
    ];
    calls.clear();
    await start().deactivate!(plugin);
    expect(calls.map((call) => (call.$1, call.$2['id'])), [
      ('list', null),
      ('cancel', '${tag()}-a'),
    ]);
    calls.clear();
    await start().deactivate!(plugin);
    expect(calls, isEmpty);
  });

  test('a disable that cannot read the file asks every host', () async {
    file.writeAsStringSync('{not json');
    jobs = [
      {'id': '${tag()}-a', 'state': 'running'},
    ];
    await service.deactivate!(plugin);
    expect(calls.map((call) => (call.$1, call.$2['id'])), [
      ('list', null),
      ('cancel', '${tag()}-a'),
    ]);
  });

  test('a host that cannot be reached stays for the next disable', () async {
    await invoke('submit', {
      'command': 'build',
      'params': {'mode': 'debug'},
    }, gesture: tap());
    reply = (_) async => throw const SocketException('down');
    await start().deactivate!(plugin);
    expect(await used.read(pluginHostOwner(plugin)), {'host1'});
  });

  test('a start cancels what an inactive plugin left on a host', () async {
    await invoke('submit', {
      'command': 'build',
      'params': {'mode': 'debug'},
    }, gesture: tap());
    final answered = reply;
    reply = (_) async => throw const SocketException('down');
    await start().deactivate!(plugin);
    reply = answered;
    jobs = [
      {'id': '${tag()}-a', 'state': 'running'},
    ];
    calls.clear();
    await start().reconcile!({pluginHostOwner(plugin)});
    expect(calls, isEmpty);
    await start().reconcile!({});
    expect(calls.map((call) => (call.$1, call.$2['id'])), [
      ('list', null),
      ('cancel', '${tag()}-a'),
    ]);
    expect(await used.read(pluginHostOwner(plugin)), isEmpty);
  });

  test('the manifest holds commands to literal programs', () {
    for (final commands in [
      '',
      '[host_capabilities.jobs.commands.x]\nargv = ["{program}"]\ntimeout_seconds = 5',
      '[host_capabilities.jobs.commands.x]\nargv = ["sh", "-c", "{script}"]\ntimeout_seconds = 5',
      '[host_capabilities.jobs.commands.x]\nargv = ["bash", "-lc", "{script}"]\ntimeout_seconds = 5',
      '[host_capabilities.jobs.commands.x]\nargv = ["make", "T={t}"]\ntimeout_seconds = 5',
      '[host_capabilities.jobs.commands.x]\nargv = ["make"]\ncwd = "{dir}"\ntimeout_seconds = 5',
      '[host_capabilities.jobs.commands.x]\nargv = ["make"]\ntimeout_seconds = 0',
      '[host_capabilities.jobs.commands.x]\nargv = ["make", "caf\u00e9"]\ntimeout_seconds = 5',
      '[host_capabilities.jobs.commands.x]\nargv = ["make", "{t}"]\ntimeout_seconds = 5\nchoices = { u = ["a"] }',
      '[host_capabilities.jobs.commands.x]\nargv = ["make", "{t}"]\ntimeout_seconds = 5\nchoices = { t = ["-rf"] }',
      '[host_capabilities.jobs.commands.x]\nargv = ["npm", "{verb}", "{pkg}"]\ntimeout_seconds = 5\nchoices = { verb = ["ls", "exec"] }',
      for (final argv in [
        '"bash", "-cx", "{s}"',
        '"sh", "-c", "--", "{s}"',
        '"perl", "-E", "{s}"',
        '"node", "--print", "{s}"',
        '"python3", "-m", "{s}"',
        '"/usr/bin/env", "{s}"',
        '"npx", "{s}"',
        '"npm", "exec", "{s}"',
        '"docker", "run", "{s}"',
        '"sed", "-i", "{s}", "f"',
        '"npm", "{verb}", "{pkg}"',
        '"npm", "install", "{pkg}"',
        '"php8.2", "{s}"',
        '"docker", "compose", "run", "{s}"',
        '"npm", "--prefix", ".", "{verb}", "{pkg}"',
        '"NPM", "exec", "{pkg}"',
      ])
        '[host_capabilities.jobs.commands.x]\nargv = [$argv]\ntimeout_seconds = 5',
    ]) {
      expect(
        () => PluginManifest.parse(_manifest(commands)),
        throwsA(isA<PluginException>()),
        reason: commands,
      );
    }
    expect(
      () => PluginManifest.parse(_manifest(_commands, service: 'scheduler')),
      throwsA(isA<PluginException>()),
    );
    final submit = PluginManifest.parse(_manifest(_commands))
        .hostCapabilities['jobs']!
        .permission('submit');
    expect(submit.description, contains('just test {target} (any word)'));
    for (final argv in [
      '"git", "log", "-p", "{ref}"',
      '"grep", "-e", "{pattern}", "log"',
      '"cargo", "test", "-p", "{crate}"',
      '"mkdir", "-p", "{dir}"',
      '"just", "{recipe}"',
      '"docker", "compose", "up", "-d", "{service}"',
      '"kubectl", "-n", "dev", "logs", "{pod}"',
      '"make", "{target}"',
      '"go", "test", "{pkg}"',
      '"pytest", "{file}"',
    ]) {
      expect(
        PluginManifest.parse(
          _manifest(
            '[host_capabilities.jobs.commands.x]\nargv = [$argv]\ntimeout_seconds = 5',
          ),
        ).hostCapabilities,
        isNotEmpty,
        reason: argv,
      );
    }
    final quoted = PluginManifest.parse(
      _manifest(
        '[host_capabilities.jobs.commands.x]\nargv = ["echo", "a\' \'b", "c d"]\ntimeout_seconds = 5\n'
        '[host_capabilities.jobs.commands.y]\nargv = ["sh", "-c", "make", "{t}"]\ntimeout_seconds = 5\nchoices = { t = ["a"] }',
      ),
    ).hostCapabilities['jobs']!.commands;
    expect(quoted['x']!.shown, "echo 'a'\\'' '\\''b' 'c d' for up to 5 s");
    expect(quoted['y']!.resolve({'t': 'a'}).last, 'a');
    expect(
      () => PluginManifest.parse(
        '${_manifest(_commands)}\n[host_capabilities.more]\napi_version = 1\nservice = "run"\noperations = ["submit"]\n[host_capabilities.more.commands.test]\nargv = ["rm"]\ntimeout_seconds = 5\n',
      ),
      throwsA(isA<PluginException>()),
    );
  });
}
