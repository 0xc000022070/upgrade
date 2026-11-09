import 'package:flutter/widgets.dart';

import 'package:upgrade/application/agents/agent_usage.dart';
import 'package:upgrade/features/home/on_stage_card.dart';
import 'package:upgrade/features/home/usage_panel.dart';
import 'package:upgrade/platform/plugins/module.dart';

const usagePlugin = NativePluginModule(
  id: 'upgrade.usage',
  directory: 'lib/builtin_plugins/usage',
  surfaces: {'home.usage': _usage},
  arrives: BuiltinArrival.on,
  splitFrom: 'upgrade.agents',
);

Widget _usage(BuildContext context) =>
    OnStageCard(visible: homeUsageVisibleProvider, child: const UsagePanel());
