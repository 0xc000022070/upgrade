import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const _path = 'assets/linux/catalog.json';

Future<void> main(List<String> args) async {
  if (args.length > 1 || (args.isNotEmpty && args.single != '--check')) {
    stderr.writeln('usage: dart tool/linux_catalog.dart [--check]');
    exit(2);
  }
  final check = args.isNotEmpty;
  final file = File.fromUri(Platform.script.resolve('../$_path'));
  final original = file.readAsStringSync();
  final catalog = jsonDecode(original) as Map<String, Object?>;
  final scratch = Directory.systemTemp.createTempSync('linux-catalog-');
  final client = HttpClient()..userAgent = 'upgrade-linux-catalog';
  var text = original;
  var changed = 0;
  var broken = 0;
  try {
    for (final tool in _objects(catalog['tools'])) {
      final installer = tool['installer'];
      if (installer is! Map<String, Object?>) continue;
      final id = tool['id'] as String;
      final url = installer['url'] as String;
      final pinned = installer['sha256'] as String;
      final served = await _digest(client, url, scratch, '$id.installer');
      if (served == null) {
        broken++;
        stdout.writeln('$id installer: download failed');
      } else if (served == pinned) {
        stdout.writeln('$id installer: unchanged');
      } else {
        changed++;
        text = repin(text, url, served);
        stdout.writeln('$id installer: changed $pinned -> $served');
      }
    }
    for (final distro in _objects(catalog['distros'])) {
      final id = distro['id'] as String;
      final rootfs = distro['rootfs'] as Map<String, Object?>;
      final url = rootfs['url'] as String;
      final pinned = rootfs['sha256'] as String;
      final served = await _digest(client, url, scratch, '$id.rootfs');
      if (served == null) {
        broken++;
        stdout.writeln('$id rootfs: download failed');
      } else if (served == pinned) {
        stdout.writeln('$id rootfs: unchanged');
      } else {
        broken++;
        stdout.writeln(
          '$id rootfs: serves $served, pinned $pinned; left alone',
        );
      }
    }
  } finally {
    client.close(force: true);
    scratch.deleteSync(recursive: true);
  }
  if (changed > 0 && !check) file.writeAsStringSync(text);
  if (broken > 0 || (check && changed > 0)) exit(1);
}

String repin(String text, String url, String digest) {
  final pin = RegExp(
    '("url": "${RegExp.escape(url)}",\\s*"sha256": ")[0-9a-f]{64}(")',
  );
  final found = pin.allMatches(text).length;
  if (found != 1) throw StateError('$url is pinned $found times, not once');
  return text.replaceFirstMapped(pin, (m) => '${m[1]}$digest${m[2]}');
}

Iterable<Map<String, Object?>> _objects(Object? list) =>
    (list as List<Object?>).cast<Map<String, Object?>>();

Future<String?> _digest(
  HttpClient client,
  String url,
  Directory scratch,
  String name,
) async {
  try {
    final response = await (await client.getUrl(Uri.parse(url))).close();
    if (response.statusCode != HttpStatus.ok) {
      stderr.writeln('$url answered ${response.statusCode}');
      await response.drain<void>();
      return null;
    }
    final target = File('${scratch.path}/$name');
    await response.pipe(target.openWrite());
    return (await sha256.bind(target.openRead()).single).toString();
  } on Exception catch (failure) {
    stderr.writeln('$url: $failure');
    return null;
  }
}
