import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/providers.dart';
import 'package:upgrade/application/agents/send.dart';
import 'package:upgrade/application/agents/send_queue.dart';
import 'package:upgrade/data/database.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/upgrade_field.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/features/tasks/send_steps.dart';
import 'package:upgrade/application/drops/attachment_files.dart';

class SendFlow extends ConsumerStatefulWidget {
  const SendFlow({
    super.key,
    required this.taskId,
    required this.projectId,
    required this.onExit,
  });

  final String taskId;

  final String? projectId;

  final VoidCallback onExit;

  @override
  ConsumerState<SendFlow> createState() => _SendFlowState();
}

class _SendFlowState extends ConsumerState<SendFlow> {
  final _message = TextEditingController();
  bool _messageReady = false;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  void _send(SendChoice choice) {
    final task = ref.read(taskProvider(widget.taskId)).value;
    if (task == null || !_messageReady || _message.text.trim().isEmpty) return;
    // Read once here: a send is one message, and re-reading it inside the transport would
    // let an edit land halfway through.
    final attachments =
        ref.read(itemAttachmentsProvider(widget.taskId)).value ??
        const <Attachment>[];
    final sender = ref.read(senderProvider);
    final SendChoice(:target, :kind, :model) = choice;
    final message = _message.text;
    final links = [
      for (final attachment in attachments)
        if (attachment.kind == AttachmentKind.url) attachment.value,
    ];
    // An image row holds a path relative to app support; the file is what goes up.
    final imagePaths = [
      for (final attachment in attachments)
        if (attachment.kind == AttachmentKind.image)
          ?ref.read(attachmentFilesProvider).absolute(attachment.value),
    ];
    ref
        .read(sendQueueProvider.notifier)
        .start(
          itemId: widget.taskId,
          title: task.title,
          target: target,
          kind: kind,
          run: (id) => sender(
            sendId: id,
            target: target,
            kind: kind,
            model: model,
            itemId: widget.taskId,
            title: task.title,
            prompt: task.prompt,
            message: message,
            links: links,
            imagePaths: imagePaths,
          ),
        );
    FocusScope.of(context).unfocus();
    widget.onExit();
    // Not maybePop: this flow's own scope refuses a pop until its back has run.
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final task = ref.watch(taskProvider(widget.taskId)).value;
    final attachmentState = ref.watch(itemAttachmentsProvider(widget.taskId));
    final attachments = attachmentState.value;
    if (!_messageReady && task != null && attachments != null) {
      _message.text = sendPrompt(
        title: task.title,
        prompt: task.prompt,
        links: [
          for (final attachment in attachments)
            if (attachment.kind == AttachmentKind.url) attachment.value,
        ],
      );
      _messageReady = true;
    }
    final imageCount =
        attachments
            ?.where((attachment) => attachment.kind == AttachmentKind.image)
            .length ??
        0;
    return SendSteps(
      projectId: widget.projectId,
      ready: _messageReady && _message.text.trim().isNotEmpty,
      onChosen: _send,
      onExit: widget.onExit,
      message: [
        SheetField(
          label: 'MESSAGE',
          child: UpgradeField(
            key: const ValueKey('send-message'),
            semanticLabel: 'Message to agent',
            controller: _message,
            enabled: _messageReady,
            minLines: 3,
            maxLines: 6,
            hint: attachmentState.hasError
                ? 'Could not load attachments. Go back and retry.'
                : 'Loading message…',
            onChanged: (_) => setState(() {}),
          ),
        ),
        if (imageCount > 0)
          Text(
            '$imageCount image${imageCount == 1 ? '' : 's'} will be uploaded. Remote paths are added to the message.',
            style: context.tokens.rowSubtitle,
          ),
      ],
    );
  }
}
