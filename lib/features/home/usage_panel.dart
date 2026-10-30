import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/agents/agent_usage.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/features/home/agent_mark.dart';
import 'package:upgrade/platform/herdr/engine_agents.dart';

class UsagePanel extends ConsumerStatefulWidget {
  const UsagePanel({super.key, this.usages, this.now});

  final List<HostUsage>? usages;
  final DateTime? now;

  @override
  ConsumerState<UsagePanel> createState() => _UsagePanelState();
}

class _UsagePanelState extends ConsumerState<UsagePanel> {
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    if (widget.now == null) {
      _clock = Timer.periodic(usagePoll, (_) => setState(() {}));
    }
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<HostUsage> usages =
        widget.usages ?? ref.watch(usageFeedProvider);
    if (usages.isEmpty) return const SizedBox.shrink();
    final at = widget.now ?? DateTime.now();
    final accounts = usageAccounts(usages);
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.panelGap),
      child: Panel(
        title: 'USAGE',
        affordance: PanelAffordance(
          'REFRESH',
          onTap: () =>
              ref.read(usageFeedProvider.notifier).refresh(fresh: true),
        ),
        bodyPadding: const EdgeInsets.symmetric(
          horizontal: Spacing.panelPadding,
          vertical: Spacing.md,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final columns =
                constraints.maxWidth >= usageColumn * 2 + Spacing.xxl + 1
                ? 2
                : 1;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < accounts.length; i += columns)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Spacing.md),
                    child: IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var j = i; j < i + columns; j++) ...[
                            if (j > i)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: Spacing.lg,
                                ),
                                child: VerticalDivider(
                                  width: 1,
                                  thickness: 1,
                                  color: context.tokens.borderSubtle,
                                ),
                              ),
                            Expanded(
                              child: j < accounts.length
                                  ? _Account(accounts[j], now: at)
                                  : const SizedBox.shrink(),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

const usageColumn = 220.0;

class _Account extends StatelessWidget {
  const _Account(this.usage, {required this.now});

  final AgentUsage usage;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final captured = usage.captured;
    final plan = usage.plan;
    final named = plan == null
        ? agentMarkName(usage.agent)
        : '${agentMarkName(usage.agent)} · ${plan.toUpperCase()}';
    final error = usage.error;
    final several = usage.limits.length > 1;
    final days = usageDays(usage, now);
    final brand = agentBrandColor(usage.agent) ?? tokens.accent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            AgentMark(usage.agent, size: _markSide, tint: brand),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                named,
                style: tokens.rowSubtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (captured != null)
              Text(agentSnapshotAge(now, captured), style: tokens.value),
          ],
        ),
        if (usage.account case final account?)
          Text(
            account,
            style: tokens.value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        if (days.today != null || days.yesterday != null)
          Padding(
            padding: const EdgeInsets.only(top: Spacing.md),
            child: Row(
              children: [
                Expanded(child: _Day('TODAY', days.today, brand: brand)),
                const SizedBox(width: Spacing.lg),
                Expanded(
                  child: _Day('YESTERDAY', days.yesterday, brand: brand),
                ),
              ],
            ),
          ),
        for (final limit in usage.limits) ...[
          if (several)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.md),
              child: Text(
                (limit.name ?? limit.id).toUpperCase(),
                style: tokens.label,
              ),
            ),
          for (final window in limit.windows)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.sm),
              child: _Window(
                window,
                color: windowColor(tokens, usage.agent, limit, window, now),
                now: now,
              ),
            ),
        ],
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: Spacing.sm),
            child: Text(
              error,
              style: tokens.value.copyWith(color: tokens.danger),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}

const _markSide = 20.0;

const evenDay = 100 / 7;

class _Day extends StatelessWidget {
  const _Day(this.label, this.rise, {required this.brand});

  final String label;
  final double? rise;
  final Color brand;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final rise = this.rise;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(label, style: tokens.value),
            const SizedBox(width: Spacing.md),
            Text(
              rise == null ? '—' : '${rise.round()}%',
              style: tokens.valueStrong.copyWith(
                color: rise == null
                    ? tokens.textMuted
                    : rise > evenDay
                    ? tokens.warning
                    : brand,
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.xs),
        SizedBox(
          height: _cellHeight,
          child: CustomPaint(
            painter: UsageCells(
              cells: 6,
              filled: rise == null ? 0 : rise / evenDay,
              fill: brand,
              empty: tokens.borderSubtle,
            ),
          ),
        ),
      ],
    );
  }
}

const _cellHeight = 8.0;

class _Window extends StatelessWidget {
  const _Window(this.window, {required this.color, required this.now});

  final UsageWindow window;
  final Color color;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final resetsAt = window.resetsAt;
    return Row(
      children: [
        SizedBox(
          width: 40,
          child: Text(windowLabel(window.minutes), style: tokens.value),
        ),
        Expanded(
          child: SizedBox(
            height: _cellHeight,
            child: CustomPaint(
              painter: UsageCells(
                cells: 10,
                filled: window.usedPercent / 100,
                pace: windowPace(window, now),
                fill: color,
                empty: tokens.borderSubtle,
                tick: tokens.textSecondary,
              ),
            ),
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            '${window.usedPercent.round()}%',
            style: tokens.valueStrong.copyWith(color: color),
            textAlign: TextAlign.right,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            resetsAt == null ? '' : '↻ ${resetIn(now, resetsAt)}',
            style: tokens.value,
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}

class UsageCells extends CustomPainter {
  const UsageCells({
    required this.cells,
    required this.filled,
    required this.fill,
    required this.empty,
    this.pace,
    this.tick,
  });

  static const gap = 2.0;

  final int cells;
  final double filled;
  final double? pace;
  final Color fill;
  final Color empty;
  final Color? tick;

  @override
  void paint(Canvas canvas, Size size) {
    final width = (size.width - gap * (cells - 1)) / cells;
    final lit = filled.clamp(0.0, 1.0) * cells;
    for (var i = 0; i < cells; i++) {
      final cell = Rect.fromLTWH(i * (width + gap), 0, width, size.height);
      canvas.drawRect(cell, Paint()..color = empty);
      final share = (lit - i).clamp(0.0, 1.0);
      if (share > 0) {
        canvas.drawRect(
          cell,
          Paint()
            ..color = fill.withValues(alpha: fill.a * math.max(share, .35)),
        );
      }
    }
    if ((pace, tick) case (final pace?, final tick?)) {
      final x = (size.width * pace).clamp(1.0, size.width - 1);
      canvas.drawRect(
        Rect.fromLTWH(x - 1, -2, 2, size.height + 4),
        Paint()..color = tick,
      );
    }
  }

  @override
  bool shouldRepaint(UsageCells old) =>
      old.cells != cells ||
      old.filled != filled ||
      old.pace != pace ||
      old.fill != fill ||
      old.empty != empty ||
      old.tick != tick;
}

Color windowColor(
  UpgradeTokens tokens,
  String agent,
  UsageLimit limit,
  UsageWindow window,
  DateTime now,
) {
  if (limitHit(limit, window) || window.usedPercent.round() >= 90) {
    return tokens.danger;
  }
  if (agentBrandColor(agent) case final brand?) return brand;
  final pace = windowPace(window, now);
  if (pace != null && window.usedPercent / 100 > pace + 0.1) {
    return tokens.warning;
  }
  return tokens.accent;
}

bool limitHit(UsageLimit limit, UsageWindow window) {
  if (!limit.reached) return false;
  final full = limit.windows.where((each) => each.usedPercent.round() >= 100);
  return full.isEmpty || full.contains(window);
}

String windowLabel(int? minutes) {
  if (minutes == null) return '';
  if (minutes == 10080) return 'WEEK';
  if (minutes >= 1440 && minutes % 1440 == 0) return '${minutes ~/ 1440}D';
  if (minutes >= 60 && minutes % 60 == 0) return '${minutes ~/ 60}H';
  return '${minutes}M';
}

double? windowPace(UsageWindow window, DateTime now) {
  final resetsAt = window.resetsAt;
  final minutes = window.minutes;
  if (resetsAt == null || minutes == null) return null;
  final left = resetsAt.difference(now).inSeconds / (minutes * 60);
  return (1 - left).clamp(0.0, 1.0);
}

String resetIn(DateTime now, DateTime resetsAt) {
  final left = resetsAt.difference(now);
  if (left.inMinutes < 1) return 'NOW';
  if (left.inMinutes < 60) return '${left.inMinutes}M';
  if (left.inHours < 24) return '${left.inHours}H';
  return '${left.inDays}D';
}
