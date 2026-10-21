import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/home/composer_focus.dart';
import 'package:striked/features/home/prompt_bar.dart';
import 'package:striked/platform/plugins/module.dart';

const promptPlugin = NativePluginModule(
  id: 'striked.prompt',
  directory: 'lib/builtin_plugins/prompt',
  surfaces: {'home.prompt': _prompt},
  deactivate: _deactivate,
  arrives: BuiltinArrival.off,
);

Widget _prompt(BuildContext context) => const PromptBar(hidable: true);

void _deactivate(Ref ref) {
  ref.read(composerSummaryProvider.notifier).withdraw();
  ref.read(promptDraftProvider).clear();
}
