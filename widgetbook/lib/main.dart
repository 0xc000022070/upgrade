import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade_widgetbook/catalog.dart';
import 'package:upgrade_widgetbook/platform_stubs.dart';

void main() {
  answerDeviceChannels();
  runApp(ProviderScope(retry: (_, _) => null, child: const UpgradeCatalog()));
}
