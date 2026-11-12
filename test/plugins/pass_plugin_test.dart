import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/features/plugins/plugin_reach.dart';
import 'package:upgrade/features/plugins/plugin_ui.dart';
import 'package:upgrade/platform/pass/pass_cli.dart';
import 'package:upgrade/platform/ssh/connection_supervisor.dart';
import 'package:upgrade_luau/upgrade_luau.dart';

import '../support/plugin_packages.dart';

Iterable<PluginUiNode> walk(PluginUiNode node) sync* {
  yield node;
  for (final child in node.children) {
    yield* walk(child);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('host scripts', () {
    late Directory root;
    late Directory store;
    late PassRun run;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('upgrade-pass-');
      store = await Directory('${root.path}/store').create();
      final bin = await Directory('${root.path}/bin').create();
      final pass = File('${bin.path}/pass');
      await pass.writeAsString(
        '#!/bin/sh\ncase "\$1 \$2 \$3" in\n'
        '"show -- "*) cat "\$PASSWORD_STORE_DIR/\$3.gpg" ;;\n'
        '"otp --help ") [ -f "\$PASSWORD_STORE_DIR/../otp" ] ;;\n'
        '"otp code -q") l=\$(sed -n 2p "\$PASSWORD_STORE_DIR/\$5.gpg")\n'
        'case \$l in otpauth*) echo "Invalid key URI (missing accountname): \$l" >&2; exit 1 ;; esac\n'
        'echo "\$l" ;;\n'
        '*) exit 9 ;;\nesac\n',
      );
      await Process.run('chmod', ['+x', pass.path]);
      for (final (name, body) in [
        ('web/github', 'hunter2\nuser: me\n'),
        ('web/otp', 'pw\n274051\n'),
        ('web/badotp', 'pw\notpauth://totp/?secret=SEEDSEED\n'),
        ("odd \$(touch ${root.path}/pwned) 'x'", 'odd\n'),
        ('.git/objects/x', 'no\n'),
      ]) {
        await File('${store.path}/$name.gpg').create(recursive: true);
        await File('${store.path}/$name.gpg').writeAsString(body);
      }
      run = (command, script) async {
        expect(command, passCommand);
        final process = await Process.start(
          'sh',
          ['-s'],
          environment: {
            'PASSWORD_STORE_DIR': store.path,
            'PATH': '${bin.path}:${Platform.environment['PATH']}',
          },
        );
        process.stdin
          ..write('echo motd\n')
          ..add(script);
        await process.stdin.close();
        final out = await process.stdout.expand((b) => b).toList();
        final err = await process.stderr.expand((b) => b).toList();
        return ExecResult(
          exitCode: await process.exitCode,
          stdout: Uint8List.fromList(out),
          stderr: Uint8List.fromList(err),
        );
      };
    });
    tearDown(() => root.delete(recursive: true));

    test('lists entries without the git directory', () async {
      expect(await passList(run), [
        "odd \$(touch ${root.path}/pwned) 'x'",
        'web/badotp',
        'web/github',
        'web/otp',
      ]);
    });

    test('copies the first line after the profile noise', () async {
      expect(await passShow(run, 'web/github'), 'hunter2');
      expect(
        await passShow(run, "odd \$(touch ${root.path}/pwned) 'x'"),
        'odd',
      );
      expect(File('${root.path}/pwned').existsSync(), isFalse);
    });

    test('refuses paths outside the store and missing entries', () async {
      for (final entry in ['../x', '/etc/passwd', '-x', 'a//b', 'a\nb', '']) {
        expect(passEntryValid(entry), isFalse, reason: entry);
      }
      await expectLater(
        passShow(run, 'web/gitlab'),
        throwsA(
          isA<PassException>().having(
            (e) => e.message,
            'message',
            startsWith('No such entry in'),
          ),
        ),
      );
    });

    test(
      'copies a pass-otp code only from a host with the extension',
      () async {
        Matcher fails(String message) => throwsA(
          isA<PassException>().having((e) => e.message, 'message', message),
        );
        await expectLater(
          passOtp(run, 'web/otp'),
          fails('This host has no pass-otp extension'),
        );
        await File('${root.path}/otp').create();
        expect(await passOtp(run, 'web/otp'), '274051');
        await expectLater(
          passOtp(run, 'web/github'),
          fails('pass otp printed no code'),
        );
        await expectLater(
          passOtp(run, 'web/badotp'),
          fails('Invalid key URI (missing accountname):'),
        );
      },
    );

    test('a host without pass says so', () async {
      Future<ExecResult> missing(String command, Uint8List script) async =>
          ExecResult(exitCode: 127, stdout: Uint8List(0), stderr: Uint8List(0));
      await expectLater(
        passList(missing),
        throwsA(
          isA<PassException>().having(
            (e) => e.message,
            'message',
            'This host has no pass on its login PATH',
          ),
        ),
      );
    });
  });

  group('plugin', () {
    late Directory root;
    late LuauWorker worker;
    final package = passPackage();
    Map<String, Object?>? state;
    late Map<String, Object?> response;
    Future<void> send(Map<String, Object?> event) async {
      response = await invokePlugin(worker, package, 'frame', {
        'state': state,
        'event': {'token': 'seed', 'now': '2026-11-11T09:30:00', ...event},
      });
      state = response['state']! as Map<String, Object?>;
    }

    List<Object?> effects() => response['effects'] as List<Object?>? ?? [];
    PluginUiNode view() =>
        PluginUiNode.parse(response['view'], allowCanvas: false);
    List<PluginUiNode> rows() =>
        walk(view()).where((n) => n.kind == 'list_row').toList();

    setUp(() async {
      state = null;
      root = await Directory.systemTemp.createTemp('upgrade-pass-plugin-');
      worker = LuauWorker(
        dataDirectory: root.path,
        dataTimeBudget: const Duration(days: 1),
      );
    });
    tearDown(() async {
      await worker.close();
      await root.delete(recursive: true);
    });

    test('review names every operation in plain words', () {
      expect(
        pluginReach(package.manifest).map((reach) => reach.line),
        containsAll([
          'LIST THE ENTRIES IN YOUR PASSWORD STORE ON THE HOST YOU CHOOSE ON THIS SHEET',
          'COPY A PASSWORD TO THE CLIPBOARD WHEN YOU TAP IT',
          'COPY A ONE-TIME CODE TO THE CLIPBOARD WHEN YOU TAP IT',
        ]),
      );
    });

    test('lists on open, narrows, copies on tap and keeps the list', () async {
      await send({'type': 'mount'});
      expect(effects().single, containsPair('operation', 'list'));
      await send({
        'type': 'result',
        'id': 'list',
        'ok': true,
        'value': {
          'entries': ['mail/work', 'web/github', 'web/gitlab'],
        },
      });
      expect(rows().map((r) => r.props['title']), hasLength(3));
      await send({'type': 'action', 'id': 'search', 'value': 'web git'});
      expect(rows().map((r) => r.props['title']), ['web/github', 'web/gitlab']);
      await send({
        'type': 'action',
        'id': 'copy',
        'args': {'entry': 'web/github'},
      });
      expect(effects().single, containsPair('args', {'entry': 'web/github'}));
      await send({
        'type': 'result',
        'id': 'copy',
        'ok': true,
        'value': {'entry': 'web/github', 'clears': 45},
      });
      expect(
        walk(view()).map((n) => n.props['text']),
        contains('COPIED web/github · CLEARS IN 45S'),
      );
      await send({'type': 'action', 'id': 'otp', 'value': true});
      await send({
        'type': 'action',
        'id': 'copy',
        'args': {'entry': 'web/github'},
      });
      expect(effects().single, containsPair('operation', 'otp'));
      await send({
        'type': 'result',
        'id': 'copy',
        'ok': true,
        'value': {'entry': 'web/github', 'clears': 45},
      });
      expect(
        walk(view()).map((n) => n.props['text']),
        contains('COPIED THE CODE FOR web/github · CLEARS IN 45S'),
      );

      state = null;
      await send({'type': 'mount'});
      expect(rows(), hasLength(3));
      await send({
        'type': 'result',
        'id': 'list',
        'ok': false,
        'error': 'No host chosen for Pass',
      });
      expect(
        walk(view()).map((n) => n.props['text']),
        contains('No host chosen for Pass'),
      );
      expect(rows(), hasLength(3));
    });
  });
}
