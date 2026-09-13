import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/projects/projects_screen.dart';
import '../../platform/plugins/module.dart';
import '../../application/drop_selection.dart';
import '../../application/fresh_drops.dart';

const projectsPlugin = NativePluginModule(
  id: 'dazzle.projects',
  directory: 'lib/plugins/projects',
  surfaces: {'navigation.page': _projects},
  deactivate: _deactivate,
);

Widget _projects(BuildContext context) => const ProjectsScreen();

void _deactivate(Ref ref) {
  ref.read(dropSelectionProvider.notifier).clear();
  ref.read(freshDropsProvider.notifier).clear();
}
