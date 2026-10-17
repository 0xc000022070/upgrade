import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/agents/send.dart';
import 'package:striked/application/agents/send_queue.dart';
import 'package:striked/application/launcher/launcher_sends.dart';
import 'package:striked/application/prompt/prompt_target.dart';
import 'package:striked/application/providers.dart';
import 'package:striked/design/components/panel_sheet.dart';
import 'package:striked/features/tasks/send_steps.dart';

String promptTitle(String text) => text.trim().split('\n').first.trim();

Future<SendChoice?> choosePromptTarget(
  BuildContext context,
  WidgetRef ref, {
  required String action,
}) async {
  final initial = ref.read(promptChoiceProvider);
  final settings = ref.read(settingsRepositoryProvider);
  final picked = await showPanelSheet<SendChoice>(
    context,
    title: 'SEND TO',
    builder: (context) => SendSteps(
      initial: initial,
      multiplexerOnly: true,
      action: action,
      onChosen: (choice) => Navigator.of(context).pop(choice),
      onExit: () => Navigator.of(context).pop(),
    ),
  );
  if (picked != null) await savePromptTarget(settings, picked);
  return picked;
}

String startPromptSend(
  WidgetRef ref,
  String text,
  SendChoice choice, {
  void Function()? onDismissed,
}) {
  final title = promptTitle(text);
  final sender = ref.read(senderProvider);
  final SendChoice(:target, :kind, :model) = choice;
  unawaited(savePromptTarget(ref.read(settingsRepositoryProvider), choice));
  return ref
      .read(sendQueueProvider.notifier)
      .start(
        title: title,
        target: target,
        kind: kind,
        run: launcherRun(
          (id) => sender(
            sendId: id,
            target: target,
            kind: kind,
            model: model,
            title: title,
            links: const [],
            message: text,
          ),
        ),
        onDismissed: onDismissed,
      );
}
