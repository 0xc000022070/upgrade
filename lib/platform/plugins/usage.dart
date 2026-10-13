import 'dart:convert';
import 'dart:io';

import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/access.dart';

class NativeUsageFile {
  NativeUsageFile(this.file);
  final File file;
  Future<void> _tail = Future.value();

  Future<Map<String, Object?>> read() async {
    if (!await file.exists()) return {};
    if (await file.length() > 1024 * 1024) {
      throw const PluginException('Plugin usage file exceeds its limit');
    }
    final value = jsonDecode(await file.readAsString());
    if (value is! Map<String, Object?> ||
        value['version'] != 1 ||
        value['plugins'] is! Map<String, Object?>) {
      throw const PluginException('Unsupported native usage format');
    }
    final usage = value['plugins']! as Map<String, Object?>;
    for (final actor in usage.values) {
      if (actor is! Map<String, Object?>) {
        throw const PluginException('Invalid native usage record');
      }
      for (final service in actor.values) {
        PluginCallUsage.decode(service);
      }
    }
    return usage;
  }

  Future<void> write(Map<String, Object?> usage) {
    final encoded = jsonEncode({'version': 1, 'plugins': usage});
    if (utf8.encode(encoded).length > 1024 * 1024) {
      throw const PluginException('Plugin usage file exceeds its limit');
    }
    final result = _tail.then((_) async {
      await file.parent.create(recursive: true);
      final next = File('${file.path}.next');
      await next.writeAsString(encoded, flush: true);
      await next.rename(file.path);
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
