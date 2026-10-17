import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/features/projects/projects_screen.dart';
import 'package:striked/features/home/next_action_card.dart';
import 'package:striked/platform/plugins/module.dart';
import 'package:striked/application/drops/drop_selection.dart';
import 'package:striked/application/drops/fresh_drops.dart';

const projectsPlugin = NativePluginModule(
  id: 'striked.projects',
  directory: 'lib/builtin_plugins/projects',
  surfaces: {'navigation.page': _projects, 'project.next_action': _nextAction},
  deactivate: _deactivate,
);

Widget _projects(BuildContext context) => const ProjectsScreen();

Widget _nextAction(BuildContext context) => const NextActionCard();

void _deactivate(Ref ref) {
  ref.read(dropSelectionProvider.notifier).clear();
  ref.read(freshDropsProvider.notifier).clear();
}
