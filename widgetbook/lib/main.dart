import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked_widgetbook/catalog.dart';
import 'package:striked_widgetbook/platform_stubs.dart';

void main() {
  answerDeviceChannels();
  runApp(const ProviderScope(child: StrikedCatalog()));
}
