import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/design/components/action_block.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_sheet.dart';
import 'package:upgrade/design/components/progress_bar.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/features/files/transfer_queue.dart';
import 'package:upgrade/features/files/transfers.dart';
import 'package:upgrade/platform/herdr/agent_watcher.dart' show AgentWatcher;

const transferBarHeight = 36.0;

String _settled(Transfers transfers) {
  final failed = transfers.jobs
      .where((job) => job.ended && job.failed)
      .expand((job) => job.items)
      .where((item) => item.stage == AttachStage.failed)
      .length;
  if (failed > 0) return '$failed FAILED';
  if (transfers.jobs.any((job) => job.stop.stopped)) return 'STOPPED';
  return 'DONE';
}

String jobWord(TransferJob job) {
  if (!job.ended) return job.stop.stopped ? 'STOPPING' : 'MOVING';
  final failed = job.items
      .where((item) => item.stage == AttachStage.failed)
      .length;
  if (failed > 0) return '$failed FAILED';
  return job.stop.stopped ? 'STOPPED' : 'DONE';
}

class TransferBar extends ConsumerWidget {
  const TransferBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transfers = ref.watch(transfersProvider);
    if (transfers.jobs.isEmpty) return const SizedBox.shrink();
    final tokens = context.tokens;
    final tally = transfers.tally;
    final moving = transfers.active;
    final settled = moving ? '' : _settled(transfers);
    final failed = settled.endsWith('FAILED');
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
                  moving ? tally.counts : settled,
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

class TransferBadge extends ConsumerWidget {
  const TransferBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transfers = ref.watch(transfersProvider);
    if (transfers.jobs.isEmpty) return const SizedBox.shrink();
    final tokens = context.tokens;
    final tally = transfers.tally;
    final moving = transfers.active;
    final settled = moving ? '' : _settled(transfers);
    final failed = settled.endsWith('FAILED');
    return GestureDetector(
      key: const ValueKey('transfer-badge'),
      behavior: HitTestBehavior.opaque,
      onTap: () => showTransfers(context),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surfacePrimary,
          border: Border.all(
            color: failed ? tokens.danger : tokens.borderNormal,
            width: Borders.hairline,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm,
            vertical: Spacing.xs,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                moving ? '${tally.counts} · ${tally.percent}%' : settled,
                key: const ValueKey('transfer-badge-text'),
                style: tokens.label.copyWith(
                  color: failed ? tokens.danger : tokens.accent,
                ),
              ),
              if (moving) ...[
                const SizedBox(height: Spacing.xs),
                SizedBox(
                  width: 96,
                  child: ProgressBar(value: tally.percent / 100),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showTransfers(BuildContext context) async {
  final transfers = ProviderScope.containerOf(context).read(transfersProvider);
  await showPanelSheet<void>(
    context,
    title: 'TRANSFERS',
    builder: (_) => const TransfersSheet(),
  );
  transfers.seeAll();
}

class TransfersSheet extends ConsumerStatefulWidget {
  const TransfersSheet({super.key});

  @override
  ConsumerState<TransfersSheet> createState() => _TransfersSheetState();
}

class _TransfersSheetState extends ConsumerState<TransfersSheet> {
  bool _notifying = true;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    final bool allowed;
    try {
      allowed = await AgentWatcher.hasPermission();
    } catch (_) {
      // ignored: a phone that cannot say has nothing to offer the user
      return;
    }
    if (mounted && !allowed) setState(() => _notifying = false);
  }

  Future<void> _allow() async {
    final bool allowed;
    try {
      allowed = await AgentWatcher.requestPermission();
    } catch (_) {
      // ignored: the line stays, and the bar in the app still shows progress
      return;
    }
    if (mounted) setState(() => _notifying = allowed);
  }

  @override
  Widget build(BuildContext context) {
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
        if (!_notifying) ...[
          const SizedBox(height: Spacing.sm),
          Row(
            children: [
              Expanded(
                child: Text(
                  'no progress in the status bar',
                  style: tokens.label.copyWith(color: tokens.textSecondary),
                ),
              ),
              ActionBlock(
                key: const ValueKey('transfers-allow'),
                label: 'ALLOW',
                onTap: () => unawaited(_allow()),
              ),
            ],
          ),
        ],
        for (final (i, job) in transfers.jobs.indexed) ...[
          const SheetRule(),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${job.verb} · ${job.host} · ${jobWord(job)}',
                  key: ValueKey('transfers-job-$i'),
                  style: tokens.label,
                ),
              ),
              if (!job.ended && !job.stop.stopped)
                ActionBlock(
                  key: ValueKey('transfers-stop-$i'),
                  label: 'STOP',
                  tone: tokens.danger,
                  onTap: () => setState(job.stop.stop),
                ),
            ],
          ),
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
