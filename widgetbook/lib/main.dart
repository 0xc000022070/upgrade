import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade_widgetbook/catalog.dart';
import 'package:upgrade_widgetbook/platform_stubs.dart';
import 'package:upgrade/application/providers.dart';

void main() {
  answerDeviceChannels();
  runApp(const ProviderScope(retry: noRetry, child: UpgradeCatalog()));
}
