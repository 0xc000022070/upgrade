import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/components/progress_bar.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/features/files/transfer_queue.dart';
import 'package:upgrade/features/files/transfers.dart';

const transferBarHeight = 36.0;

class TransferBar extends ConsumerWidget {
  const TransferBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transfers = ref.watch(transfersProvider);
    if (transfers.jobs.isEmpty) return const SizedBox.shrink();
    final tokens = context.tokens;
    final tally = transfers.tally;
    final moving = transfers.active;
    final failed = transfers.jobs.any(
      (job) => job.items.any((item) => item.stage == AttachStage.failed),
    );
    return GestureDetector(
      key: const ValueKey('transfer-bar'),
      behavior: HitTestBehavior.opaque,
      onTap: () => showTransfers(context),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surfacePrimary,
          border: Border(
            top: BorderSide(
              color: tokens.borderNormal,
              width: Borders.hairline,
            ),
          ),
        ),
        child: SizedBox(
          height: transferBarHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.screenEdge),
            child: Row(
              children: [
                Text(
                  moving ? tally.counts : (failed ? 'FAILED' : 'DONE'),
                  key: const ValueKey('transfer-bar-counts'),
                  style: tokens.panelHeader.copyWith(
                    color: failed ? tokens.danger : tokens.accent,
                  ),
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  child: ProgressBar(value: moving ? tally.percent / 100 : 1),
                ),
                if (moving) ...[
                  const SizedBox(width: Spacing.md),
                  Text(
                    '${tally.percent}% · ${rateWord(tally.rate)}',
                    key: const ValueKey('transfer-bar-rate'),
                    style: tokens.label,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showTransfers(BuildContext context) => showPanelSheet<void>(
  context,
  title: 'TRANSFERS',
  builder: (_) => const TransfersSheet(),
);

class TransfersSheet extends ConsumerWidget {
  const TransfersSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.tokens;
    final transfers = ref.watch(transfersProvider);
    final tally = transfers.tally;
    return PanelSheetBody(
      title: 'TRANSFERS',
      affordance: PanelAffordance(
        'CLOSE',
        showIcon: false,
        onTap: () => Navigator.of(context).pop(),
      ),
      children: [
        Text(
          transfers.active
              ? '${tally.percent}% · ${rateWord(tally.rate)}'
              : 'nothing moving',
          key: const ValueKey('transfers-rate'),
          style: tokens.label.copyWith(color: tokens.textSecondary),
        ),
        for (final (i, job) in transfers.jobs.indexed) ...[
          const SheetRule(),
          Text('${job.verb} · ${job.host}', style: tokens.label),
          const SizedBox(height: Spacing.sm),
          TransferQueue(
            files: job.files,
            items: job.items,
            keyPrefix: 'transfers-$i',
          ),
        ],
      ],
    );
  }
}
