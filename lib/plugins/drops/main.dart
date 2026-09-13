import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/home/drops_home_surface.dart';
import '../../platform/plugins/module.dart';
import '../../application/drop_selection.dart';
import '../../application/fresh_drops.dart';

const dropsPlugin = NativePluginModule(
  id: 'dazzle.drops',
  directory: 'lib/plugins/drops',
  surfaces: {'home.layout': _home},
  deactivate: _deactivate,
);

Widget _home(BuildContext context) => const DropsHomeSurface();

void _deactivate(Ref ref) {
  ref.read(dropSelectionProvider.notifier).clear();
  ref.read(freshDropsProvider.notifier).clear();
}
