import 'package:flutter/widgets.dart';

import 'package:upgrade/data/pinned_host_key.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/meta.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/brand.dart';

/// [hold] is released once the sheet answers, so the session store does not sweep the
/// dial that is waiting on it.
Future<bool> askHostKeyHeld(
  BuildContext context, {
  required VoidCallback Function() hold,
  required Host host,
  required HostKeyOffer offer,
  PinnedHostKey? pinned,
}) async {
  final release = hold();
  try {
    return await askHostKey(context, host: host, offer: offer, pinned: pinned);
  } finally {
    release();
  }
}

Future<bool> askHostKey(
  BuildContext context, {
  required Host host,
  required HostKeyOffer offer,
  PinnedHostKey? pinned,
}) async {
  final changed = pinned != null;
  final title = changed ? 'HOST KEY CHANGED' : 'NEW HOST KEY';
  final answer = await showPanelSheet<bool>(
    context,
    title: title,
    builder: (context) => PanelSheetBody(
      title: title,
      children: [
        Text(host.name.toUpperCase(), style: context.tokens.panelHeader),
        const SizedBox(height: Spacing.sm),
        Meta('${host.address}:${host.port}'),
        const SheetRule(),
        if (changed) ...[
          Text('STORED KEY', style: context.tokens.label),
          const SizedBox(height: Spacing.sm),
          Meta(pinned.type.toUpperCase()),
          const SizedBox(height: Spacing.sm),
          Meta(pinned.fingerprint, maxLines: 3),
          const SizedBox(height: Spacing.md),
          Text('OFFERED KEY', style: context.tokens.label),
          const SizedBox(height: Spacing.sm),
          Meta(offer.type.toUpperCase()),
          const SizedBox(height: Spacing.sm),
          Meta(offer.fingerprint, strong: true, maxLines: 3),
          const SizedBox(height: Spacing.md),
          Text(
            'VERIFY THE OFFERED FINGERPRINT OUTSIDE $appNameCaps BEFORE REPLACING.',
            style: context.tokens.label.copyWith(color: context.tokens.warning),
          ),
        ] else ...[
          Text('KEY TYPE', style: context.tokens.label),
          const SizedBox(height: Spacing.sm),
          Meta(offer.type.toUpperCase()),
          const SizedBox(height: Spacing.md),
          Text('FINGERPRINT', style: context.tokens.label),
          const SizedBox(height: Spacing.sm),
          Meta(offer.fingerprint, strong: true, maxLines: 3),
        ],
        const SheetRule(),
        Row(
          children: [
            Expanded(
              child: ActionBlock(
                label: changed ? 'KEEP OLD' : 'REJECT',
                onTap: () => Navigator.of(context).pop(false),
              ),
            ),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: ActionBlock(
                label: changed ? 'REPLACE' : 'TRUST',
                tone: changed ? context.tokens.warning : context.tokens.accent,
                filled: true,
                onTap: () => Navigator.of(context).pop(true),
              ),
            ),
          ],
        ),
      ],
    ),
  );
  return answer ?? false;
}
