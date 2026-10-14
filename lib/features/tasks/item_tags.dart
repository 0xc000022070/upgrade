import 'package:flutter/widgets.dart';

import 'package:upgrade/application/agents/send.dart';
import 'package:upgrade/application/agents/send_queue.dart';

import 'package:upgrade/design/tokens.dart';

class SentTag extends StatelessWidget {
  const SentTag({super.key});

  @override
  Widget build(BuildContext context) =>
      Text('SENT', style: context.tokens.label);
}

class PromptTag extends StatelessWidget {
  const PromptTag({super.key});

  @override
  Widget build(BuildContext context) =>
      Text('PROMPT', style: context.tokens.label);
}

class SendingTag extends StatelessWidget {
  const SendingTag({super.key, required this.failed});

  final bool failed;

  @override
  Widget build(BuildContext context) => Text(
    failed ? 'FAILED' : 'SENDING',
    style: context.tokens.label.copyWith(
      color: failed ? context.tokens.warning : null,
    ),
  );

  static SendingTag? of(List<PendingSend> sends, String itemId) {
    final mine = sends.where((send) => send.itemId == itemId);
    if (mine.isEmpty) return null;
    return SendingTag(failed: mine.every((send) => send.state is SendFailed));
  }
}
