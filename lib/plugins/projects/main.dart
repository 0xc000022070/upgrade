import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/features/projects/projects_screen.dart';
import 'package:upgrade/features/home/next_action_card.dart';
import 'package:upgrade/platform/plugins/module.dart';
import 'package:upgrade/application/drop_selection.dart';
import 'package:upgrade/application/fresh_drops.dart';

const projectsPlugin = NativePluginModule(
  id: 'upgrade.projects',
  directory: 'lib/plugins/projects',
  surfaces: {'navigation.page': _projects, 'project.next_action': _nextAction},
  deactivate: _deactivate,
);

Widget _projects(BuildContext context) => const ProjectsScreen();

Widget _nextAction(BuildContext context) => const NextActionCard();

void _deactivate(Ref ref) {
  ref.read(dropSelectionProvider.notifier).clear();
  ref.read(freshDropsProvider.notifier).clear();
}
