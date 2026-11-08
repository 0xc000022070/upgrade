import 'package:flutter/material.dart';

import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/field_panel.dart';
import 'package:upgrade/design/components/meta_row.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/platform/notifications/pin_alerts.dart';
import 'package:upgrade/platform/ssh/connection_supervisor.dart';

typedef PinDecision = ({String? passphrase, UserIntent intent});

class PinSheet extends StatefulWidget {
  const PinSheet({super.key, required this.number, required this.request});

  final int number;
  final PinRequest request;

  @override
  State<PinSheet> createState() => _PinSheetState();
}

class _PinSheetState extends State<PinSheet> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _decide(UserIntent intent, String? passphrase) =>
      Navigator.of(context).pop((passphrase: passphrase, intent: intent));

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final wantsPin = request.mode == 'pin';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('SHELL ${widget.number}', style: context.tokens.label),
        if (request.desc.isNotEmpty) ...[
          const SizedBox(height: Spacing.sm),
          if (pinFacts(request.desc) case final parsed?) ...[
            Text(parsed.lead, style: context.tokens.prose),
            const SizedBox(height: Spacing.sm),
            for (final (label, value) in parsed.facts)
              MetaRow(label, value, maxLines: 2),
          ] else
            Text(request.desc, style: context.tokens.prose),
        ],
        if (request.error.isNotEmpty) ...[
          const SizedBox(height: Spacing.sm),
          Text(
            request.error,
            style: context.tokens.prose.copyWith(color: context.tokens.danger),
          ),
        ],
        // The host gives up on an ask after a window of its own and never says how
        // long that is, so an ask this old is drawn as one that may be over rather
        // than as one that is: it was listed open a moment ago.
        if (request.stale) ...[
          const SizedBox(height: Spacing.sm),
          Text(
            'MAY HAVE EXPIRED',
            style: context.tokens.label.copyWith(color: context.tokens.warning),
          ),
        ],
        const SizedBox(height: Spacing.md),
        if (wantsPin) ...[
          FieldPanel(
            label: request.promptLabel,
            controller: _field,
            obscureText: true,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: UserIntent.onGestureWith(_decide),
          ),
          const SizedBox(height: Spacing.md),
        ],
        Row(
          children: [
            if (request.mode != 'message') ...[
              Expanded(
                child: ActionBlock(
                  label: request.cancelLabel,
                  onTap: UserIntent.onGesture(
                    (intent) => _decide(intent, null),
                  ),
                ),
              ),
              const SizedBox(width: Spacing.md),
            ],
            Expanded(
              child: ActionBlock(
                label: request.okLabel,
                tone: context.tokens.accent,
                filled: !request.stale,
                onTap: UserIntent.onGesture(
                  (intent) => _decide(intent, wantsPin ? _field.text : 'ok'),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
