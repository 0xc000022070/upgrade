import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/plugins/native_plugins.dart';
import 'package:upgrade/application/plugins/plugins.dart';
import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/store.dart';

void main() {
  test('a card frame asked before the catalog loads waits for it', () async {
    final root = await Directory.systemTemp.createTemp('upgrade-catalog-');
    addTearDown(() => root.delete(recursive: true));
    final store = Completer<PluginStore>();
    final container = ProviderContainer(
      overrides: [pluginStoreProvider.overrideWith((ref) => store.future)],
    );
    addTearDown(() async {
      await container.read(pluginAuthorityProvider).close();
      container.dispose();
    });
    container.listen(pluginsProvider, (_, _) {});
    final frame = container
        .read(pluginsProvider.notifier)
        .card('test.missing', 'status', const {});
    store.complete(PluginStore(root));
    await expectLater(
      frame,
      throwsA(
        isA<PluginException>().having(
          (error) => error.message,
          'message',
          'Plugin is disabled or removed',
        ),
      ),
    );
  });
}
