import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/components/action_block.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/spacing.dart';
import '../../design/tokens.dart';
import '../../platform/engine_agents.dart';

Future<bool> showHookSheet(BuildContext context, HookStatus status) async {
  final title = '${status.agent.toUpperCase()} HOOKS';
  final answer = await showPanelSheet<bool>(
    context,
    title: title,
    builder: (context) => PanelSheetBody(
      title: title,
      children: [
        SheetField(
          label: 'FILE',
          child: SelectableText(status.configPath, style: context.tokens.value),
        ),
        const SheetRule(),
        Row(
          children: [
            Expanded(
              child: Text(
                status.writable ? 'ADDS' : 'NOT WRITABLE · ADD BY HAND',
                style: context.tokens.label,
              ),
            ),
            PanelAffordance(
              'COPY',
              showIcon: false,
              onTap: () =>
                  Clipboard.setData(ClipboardData(text: status.entries)),
            ),
          ],
        ),
        const SizedBox(height: Spacing.sm),
        SelectableText(status.entries, style: context.tokens.value),
        const SizedBox(height: Spacing.md),
        if (status.writable)
          Row(
            children: [
              Expanded(
                child: ActionBlock(
                  label: 'CANCEL',
                  onTap: () => Navigator.of(context).pop(false),
                ),
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: ActionBlock(
                  label: 'INSTALL',
                  tone: context.tokens.accent,
                  filled: true,
                  onTap: () => Navigator.of(context).pop(true),
                ),
              ),
            ],
          )
        else
          ActionBlock(
            label: 'CLOSE',
            onTap: () => Navigator.of(context).pop(false),
          ),
      ],
    ),
  );
  return answer ?? false;
}
