import 'package:flutter/widgets.dart';

import 'package:striked/features/home/agents_card.dart';
import 'package:striked/platform/plugins/module.dart';

const agentsPlugin = NativePluginModule(
  id: 'striked.agents',
  directory: 'lib/builtin_plugins/agents',
  surfaces: {'home.agents': _agents},
  arrives: BuiltinArrival.on,
);

Widget _agents(BuildContext context) => const AgentsCard();
