import 'package:flutter/widgets.dart';

import 'package:upgrade/features/chat/chat_screen.dart';
import 'package:upgrade/platform/plugins/module.dart';

const chatPlugin = NativePluginModule(
  id: 'upgrade.chat',
  directory: 'lib/builtin_plugins/chat',
  surfaces: {'navigation.page': _chat},
  arrives: BuiltinArrival.off,
);

Widget _chat(BuildContext context) => const ChatScreen();
