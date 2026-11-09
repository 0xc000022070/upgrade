import 'package:flutter/widgets.dart';

import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/features/home/agents_panel.dart';
import 'package:upgrade/features/home/on_stage_card.dart';
import 'package:upgrade/platform/plugins/module.dart';

const agentsPlugin = NativePluginModule(
  id: 'upgrade.agents',
  directory: 'lib/builtin_plugins/agents',
  surfaces: {'home.agents': _agents},
  arrives: BuiltinArrival.on,
);

Widget _agents(BuildContext context) =>
    OnStageCard(visible: homeAgentsVisibleProvider, child: const AgentsPanel());
