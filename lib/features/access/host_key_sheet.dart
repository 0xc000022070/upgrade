import 'package:flutter/widgets.dart';

import '../../data/repositories/host_repository.dart';
import '../../design/colors.dart';
import '../../design/components/action_block.dart';
import '../../design/components/meta.dart';
import '../../design/components/panel_sheet.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../../platform/host_keys.dart';

/// What the user is asked the first time a machine answers: this is the key it
/// presented, do you accept it as this host's.
///
/// The sheet is the confirm sheet's shape with the fingerprint between the
/// header and the two blocks, because the fingerprint is the whole of what
/// there is to decide on.
Future<bool> askHostKey(
  BuildContext context, {
  required Host host,
  required HostKeyOffer offer,
}) async {
  final answer = await showPanelSheet<bool>(
    context,
    title: 'NEW HOST KEY',
    builder: (context) => PanelSheetBody(
      title: 'NEW HOST KEY',
      children: [
        Text(host.name.toUpperCase(), style: HotlineText.panelHeader),
        const SizedBox(height: Spacing.sm),
        Meta('${host.address}:${host.port}'),
        const SheetRule(),
        Text('KEY TYPE', style: HotlineText.label),
        const SizedBox(height: Spacing.sm),
        Meta(offer.type.toUpperCase()),
        const SizedBox(height: Spacing.md),
        Text('FINGERPRINT', style: HotlineText.label),
        const SizedBox(height: Spacing.sm),
        // Three lines rather than one: a fingerprint is fifty characters and
        // the half an ellipsis would drop is the half that tells one machine
        // from another.
        Meta(offer.fingerprint, strong: true, maxLines: 3),
        const SheetRule(),
        Row(
          children: [
            Expanded(
              child: ActionBlock(
                label: 'REJECT',
                onTap: () => Navigator.of(context).pop(false),
              ),
            ),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: ActionBlock(
                label: 'TRUST',
                tone: HotlineColors.accent,
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
