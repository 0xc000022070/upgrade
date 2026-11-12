import 'dart:io';

import 'package:upgrade/data/plugins/installed.dart';
import 'package:upgrade/platform/plugins/bindings.dart';
import 'package:upgrade/data/plugins/manifest.dart';
import 'package:upgrade_luau/ui_sdk.dart';
import 'package:upgrade_luau/upgrade_luau.dart';

PluginPackage bundledPlugin(String dir, {String revision = '1.0.0'}) {
  final manifest = PluginManifest.parse(
    File('plugins/$dir/upgrade.plugin.toml').readAsStringSync(),
  );
  return PluginPackage(
    manifest: manifest,
    source: File('plugins/$dir/main.luau').readAsStringSync(),
    origin: 'bundled:${manifest.id}',
    revision: revision,
  );
}

PluginPackage awsCostPackage() => bundledPlugin('aws-cost');
PluginPackage boardPackage() => bundledPlugin('board');
PluginPackage kanbanPackage() => bundledPlugin('kanban');
PluginPackage passPackage() => bundledPlugin('pass');
PluginPackage schedulePackage() =>
    bundledPlugin('agent-schedules', revision: '1.1.0');

Future<Map<String, Object?>> invokePlugin(
  LuauWorker worker,
  PluginPackage package,
  String action,
  Map<String, Object?> input,
) async {
  final plugin = InstalledPlugin(package, package.manifest.permissions);
  final result = await worker.invoke(
    key: package.digest,
    source: '$luauUiSdk\n${package.source}',
    action: action,
    input: input,
    data: bindPluginData(plugin.id, [plugin]),
  );
  return result.value! as Map<String, Object?>;
}
