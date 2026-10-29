import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:striked/application/plugins/plugin_development.dart';
import 'package:striked/platform/plugins/manifest.dart';
import 'package:striked/platform/plugins/plugin_check.dart';
import 'package:striked/platform/plugins/plugin_template.dart';

Future<ProcessResult> _sh(String command, String home, {String? stdin}) async {
  final process = await Process.start(
    'sh',
    ['-c', command],
    environment: {'HOME': home},
  );
  if (stdin != null) process.stdin.write(stdin);
  await process.stdin.close();
  final code = await process.exitCode;
  return ProcessResult(process.pid, code, '', '');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the app bundles every template file the workspace is made of',
    () async {
      final onDisk = {
        for (final entity in Directory(
          pluginTemplateDir,
        ).listSync(recursive: true))
          if (entity is File) p.relative(entity.path, from: pluginTemplateDir),
      };
      expect(onDisk, {...pluginTemplateFiles.keys, 'README.md'});
      final template = {
        for (final file in pluginTemplateFiles.keys)
          file: await rootBundle.loadString('$pluginTemplateDir/$file'),
      };
      final files = pluginWorkspaceFiles(
        template,
        id: pluginIdFor('My Card!'),
        name: 'My Card!',
      );
      final manifest = PluginManifest.parse(files[pluginManifestFile]!);
      expect(manifest.id, 'dev.local.my-card');
      expect(manifest.name, 'My Card!');
      expect(files.keys, containsAll(['.striked/wait.sh', pluginSdkFile]));
    },
  );

  test('plugin ids from folder names stay valid', () {
    expect(pluginIdFor('hello-card'), 'dev.local.hello-card');
    expect(pluginIdFor('2nd_try--'), 'dev.local.nd-try');
    expect(pluginIdFor(''), 'dev.local.plugin');
  });

  test('a create lands whole into an empty folder or not at all', () async {
    final home = Directory.systemTemp.createTempSync('ws');
    addTearDown(() => home.deleteSync(recursive: true));
    const path = "~/a b'c\$(touch pwn)";
    final ws = "${home.path}/a b'c\$(touch pwn)";
    final files = {
      'lib/card.luau': 'return {}',
      '.striked/wait.sh': File('$pluginTemplateDir/wait.sh').readAsStringSync(),
    };
    Future<int> create(Map<String, String> files) async => (await _sh(
      pluginWorkspaceCreateCommand,
      home.path,
      stdin: pluginWorkspaceCreateScript(path, files),
    )).exitCode;

    Directory('$ws/.striked/preview').createSync(recursive: true);
    expect(await create(files), 0);
    expect(File('$ws/lib/card.luau').readAsStringSync(), 'return {}\n');
    expect(File('$ws/.striked/preview').existsSync(), isFalse);
    expect(File('${home.path}/pwn').existsSync(), isFalse);
    expect(
      File('$ws/.striked/wait.sh').statSync().modeString(),
      startsWith('rwx'),
    );
    expect(await create({'other.luau': ''}), 4);
    expect(File('$ws/other.luau').existsSync(), isFalse);
    expect(home.listSync().map((entity) => p.basename(entity.path)), [
      "a b'c\$(touch pwn)",
    ]);
  });

  test('wait.sh returns only the result that echoes its own ask', () async {
    final ws = Directory.systemTemp.createTempSync('ws');
    addTearDown(() => ws.deleteSync(recursive: true));
    Directory('${ws.path}/.striked').createSync();
    File('$pluginTemplateDir/wait.sh').copySync('${ws.path}/.striked/wait.sh');
    final result = File('${ws.path}/$pluginPreviewResult')
      ..createSync(recursive: true)
      ..writeAsStringSync('{\n  "ok": true,\n  "context": {}\n}\n');
    final waiting = Process.run('sh', ['${ws.path}/.striked/wait.sh']);
    final ask = File('${ws.path}/$pluginPreviewAsk');
    while (!ask.existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    result.writeAsStringSync(
      '{\n  "ok": false,\n  "context": {\n    "ask": "${ask.readAsStringSync().trim()}"\n  }\n}\n',
    );
    final waited = await waiting;
    expect(waited.exitCode, 1);
    expect(waited.stdout, contains('"ok": false'));
  });

  test('the poll reads the ask ahead of the files', () async {
    final ws = Directory.systemTemp.createTempSync('ws');
    addTearDown(() => ws.deleteSync(recursive: true));
    File('${ws.path}/$pluginPreviewAsk')
      ..createSync(recursive: true)
      ..writeAsStringSync('42-1\n');
    File('${ws.path}/main.luau').writeAsStringSync('return {}');
    final read = await Process.run('sh', [
      '-c',
      pluginWorkspaceCommand(ws.path),
    ], stdoutEncoding: null);
    final files = parseWorkspaceFrames(read.stdout as Uint8List)!;
    expect(files.keys.first, pluginPreviewAsk);
    expect(files, {pluginPreviewAsk: '42-1', 'main.luau': 'return {}'});
  });
}
