import 'package:flutter/widgets.dart';

import 'package:upgrade/features/home/agents_card.dart';
import 'package:upgrade/platform/plugins/module.dart';

const agentsPlugin = NativePluginModule(
  id: 'upgrade.agents',
  directory: 'lib/builtin_plugins/agents',
  surfaces: {'home.agents': _agents},
  arrives: BuiltinArrival.on,
);

Widget _agents(BuildContext context) => const AgentsCard();
