import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:striked_luau/striked_luau.dart';

import 'package:striked/platform/plugins/plugin_check.dart';
import 'package:striked/platform/plugins/plugin_sdk.dart';
import 'package:striked/platform/plugins/plugin_template.dart';

const _usage = '''
striked-plugin: author tools for Striked Luau plugins

  init <dir> [--id <id>] [--name <name>]  copy the phone-only card template
  docs [--out <file>]                     print the pinned SDK and UI schema as JSON
  check <dir> [--json]                    run manifest, Luau, fixtures and UI checks
  preview <dir> [--json] [--wait <s>]     read the phone's preview of this revision

Exit status: 0 ok, 1 diagnostics, 2 usage, 3 preview pending.''';

final _repo = File.fromUri(Platform.script).parent.parent;

Future<void> main(List<String> args) async {
  if (args.isEmpty) _fail(_usage);
  final command = args.first;
  final rest = args.skip(1).toList();
  final json = rest.remove('--json');
  String? option(String name) {
    final at = rest.indexOf(name);
    if (at < 0) return null;
    if (at + 1 >= rest.length) _fail('$name needs a value');
    final value = rest[at + 1];
    rest.removeRange(at, at + 2);
    return value;
  }

  switch (command) {
    case 'init':
      final id = option('--id');
      final name = option('--name');
      if (rest.length != 1) _fail(_usage);
      _init(Directory(rest.single), id: id, name: name);
    case 'docs':
      final out = option('--out');
      final text = const JsonEncoder.withIndent('  ')
          .convert(pluginSdkInventory());
      if (out == null) {
        stdout.writeln(text);
      } else {
        File(out).writeAsStringSync('$text\n');
        stderr.writeln('wrote $out');
      }
    case 'check':
      if (rest.length != 1) _fail(_usage);
      exit(await _check(Directory(rest.single), json: json));
    case 'preview':
      final wait = int.tryParse(option('--wait') ?? '0') ?? 0;
      if (rest.length != 1) _fail(_usage);
      exit(await _preview(Directory(rest.single), json: json, wait: wait));
    default:
      _fail(_usage);
  }
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(2);
}

void _init(Directory target, {String? id, String? name}) {
  if (target.existsSync() && target.listSync().isNotEmpty) {
    _fail('${target.path} is not empty');
  }
  final template = '${_repo.path}/$pluginTemplateDir';
  final files = pluginWorkspaceFiles(
    {
      for (final path in pluginTemplateFiles.keys)
        path: File('$template/$path').readAsStringSync(),
    },
    id: id,
    name: name,
  );
  for (final MapEntry(key: path, value: text) in files.entries) {
    final file = File('${target.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
    if (path.endsWith('.sh')) Process.runSync('chmod', ['+x', file.path]);
  }
  stdout.writeln('created ${target.path}');
  stdout.writeln('next: edit lib/card.luau, then check ${target.path}');
}

Map<String, String> _workspace(Directory root) {
  if (!root.existsSync()) _fail('${root.path} does not exist');
  final found = <String, File>{};
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final relative = p.relative(entity.path, from: root.path);
    if (!isPluginWorkspaceFile(relative)) continue;
    if ((entity.lengthSync() + 1023) ~/ 1024 >= maxWorkspaceFileKib) continue;
    found[relative] = entity;
  }
  return {
    for (final path in (found.keys.toList()..sort()).take(
      maxWorkspaceFiles + 1,
    ))
      path: utf8.decode(found[path]!.readAsBytesSync(), allowMalformed: true),
  };
}

Future<int> _check(Directory root, {required bool json}) async {
  final worker = LuauWorker();
  try {
    final check = await checkPluginWorkspace(
      _workspace(root),
      invoke:
          ({
            required key,
            required source,
            required action,
            required input,
          }) async => (await worker.invoke(
            key: key,
            source: source,
            action: action,
            input: input,
          )).value,
    );
    final envelope = check.envelope(
      command: 'check',
      context: {'workspace': root.absolute.path, 'runtime': 'dart-vm'},
    );
    if (json) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(envelope));
    } else {
      _human(envelope);
    }
    return check.ok ? 0 : 1;
  } finally {
    await worker.close();
  }
}

Future<int> _preview(
  Directory root, {
  required bool json,
  required int wait,
}) async {
  final revision = workspaceRevision(_workspace(root));
  final file = File('${root.path}/$pluginPreviewResult');
  final deadline = DateTime.now().add(Duration(seconds: wait));
  Map<String, Object?>? result;
  while (true) {
    if (file.existsSync()) {
      final read = jsonDecode(file.readAsStringSync());
      if (read is Map<String, Object?> &&
          (read['artifacts'] as Map<String, Object?>?)?['revision'] ==
              revision) {
        result = read;
        break;
      }
    }
    if (DateTime.now().isAfter(deadline)) break;
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  final envelope =
      result ??
      {
        'schema_version': pluginToolSchemaVersion,
        'command': 'preview',
        'ok': false,
        'diagnostics': [
          PluginDiagnostic(
            code: 'PREVIEW_PENDING',
            message: 'The phone has not rendered revision $revision',
            source: const PluginSource(path: pluginPreviewResult),
            expected: revision,
            actual: file.existsSync() ? 'an older revision' : 'no result',
            nextAction:
                'Open TOOLS > DEVELOP PLUGIN on the phone with this workspace. '
                'If the phone reads a copy of it, copy $pluginPreviewResult back '
                '(`just plugin-sync` does), then run preview again.',
          ).toJson(),
        ],
        'artifacts': {'revision': revision},
        'context': {'workspace': root.absolute.path},
      };
  if (json) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(envelope));
  } else {
    _human(envelope);
  }
  if (result == null) return 3;
  return envelope['ok'] == true ? 0 : 1;
}

void _human(Map<String, Object?> envelope) {
  final artifacts = envelope['artifacts']! as Map<String, Object?>;
  for (final raw in envelope['diagnostics']! as List<Object?>) {
    final d = PluginDiagnostic.fromJson(raw! as Map<String, Object?>);
    final at = d.source == null
        ? ''
        : '${d.source!.path}${d.source!.line == null ? '' : ':${d.source!.line}'}';
    final message = at.isNotEmpty && d.message.startsWith('$at: ')
        ? d.message.substring(at.length + 2)
        : d.message;
    stdout.writeln(
      '${d.severity.name} ${d.code}${at.isEmpty ? '' : ' $at'}: $message',
    );
    if (d.node != null) stdout.writeln('  node: ${d.node}');
    if (d.operation != null) stdout.writeln('  during: ${d.operation}');
    if (d.expected != null) stdout.writeln('  expected: ${d.expected}');
    if (d.actual != null) stdout.writeln('  actual: ${d.actual}');
    stdout.writeln('  next: ${d.nextAction}');
  }
  for (final raw in artifacts['renders'] as List<Object?>? ?? const []) {
    final render = raw! as Map<String, Object?>;
    stdout.writeln(
      'rendered ${render['fixture']} · ${render['widget']} · ${render['size']} · '
      '${render['nodes']} nodes',
    );
  }
  if (artifacts['shown_revision'] case final String shown
      when shown != artifacts['revision']) {
    stdout.writeln('phone keeps last good revision $shown');
  }
  stdout.writeln(
    '${envelope['command']} ${envelope['ok'] == true ? 'ok' : 'failed'} · '
    'revision ${artifacts['revision']}',
  );
}
