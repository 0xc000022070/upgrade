import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/agents/agent_kind.dart';
import 'package:striked/application/agents/agent_usage.dart';
import 'package:striked/application/agents/agents.dart';
import 'package:striked/design/components/panel.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/features/home/agent_mark.dart';
import 'package:striked/platform/herdr/engine_agents.dart';

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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < usages.length; i++) ...[
              if (i > 0) const SizedBox(height: Spacing.lg),
              _Account(usages[i], now: at),
            ],
          ],
        ),
      ),
    );
  }
}

class _Account extends StatelessWidget {
  const _Account(this.entry, {required this.now});

  final HostUsage entry;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final usage = entry.usage;
    final known = AgentKind.lookup(usage.agent) != null;
    final captured = usage.captured;
    final plan = usage.plan;
    final named = plan == null
        ? agentMarkName(usage.agent)
        : '${agentMarkName(usage.agent)} · ${plan.toUpperCase()}';
    final error = usage.error;
    final several = usage.limits.length > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (known) ...[
              AgentMark(usage.agent),
              const SizedBox(width: Spacing.md),
            ],
            Expanded(
              child: Text(
                named,
                style: context.tokens.rowSubtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              captured == null
                  ? entry.host.name.toUpperCase()
                  : '${entry.host.name.toUpperCase()} · '
                        '${agentSnapshotAge(now, captured)}',
              style: context.tokens.value,
            ),
          ],
        ),
        if (usage.account case final account?)
          Text(
            account,
            style: context.tokens.value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        for (final limit in usage.limits) ...[
          if (several)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.md),
              child: Text(
                (limit.name ?? limit.id).toUpperCase(),
                style: context.tokens.label,
              ),
            ),
          for (final window in limit.windows)
            _Window(window, reached: limitHit(limit, window), now: now),
        ],
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: Spacing.sm),
            child: Text(
              error,
              style: context.tokens.value.copyWith(
                color: context.tokens.danger,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}

class _Window extends StatelessWidget {
  const _Window(this.window, {required this.reached, required this.now});

  final UsageWindow window;
  final bool reached;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final used = (window.usedPercent / 100).clamp(0.0, 1.0);
    final pace = windowPace(window, now);
    final tokens = context.tokens;
    final color = reached || window.usedPercent.round() >= 90
        ? tokens.danger
        : pace != null && used > pace + 0.1
        ? tokens.warning
        : tokens.accent;
    final resetsAt = window.resetsAt;
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.md),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: Text(windowLabel(window.minutes), style: tokens.value),
          ),
          Expanded(
            child: SizedBox(
              height: 8,
              child: CustomPaint(
                painter: _Bar(
                  used: used,
                  pace: pace,
                  fill: color,
                  track: tokens.borderSubtle,
                  tick: tokens.textSecondary,
                ),
              ),
            ),
          ),
          const SizedBox(width: Spacing.md),
          SizedBox(
            width: 40,
            child: Text(
              '${window.usedPercent.round()}%',
              style: tokens.valueStrong.copyWith(color: color),
              textAlign: TextAlign.right,
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(
              resetsAt == null ? '' : '↻ ${resetIn(now, resetsAt)}',
              style: tokens.value,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class _Bar extends CustomPainter {
  const _Bar({
    required this.used,
    required this.pace,
    required this.fill,
    required this.track,
    required this.tick,
  });

  final double used;
  final double? pace;
  final Color fill;
  final Color track;
  final Color tick;

  @override
  void paint(Canvas canvas, Size size) {
    final bar = Rect.fromLTWH(0, size.height / 4, size.width, size.height / 2);
    canvas
      ..drawRect(bar, Paint()..color = track)
      ..drawRect(
        Rect.fromLTWH(bar.left, bar.top, bar.width * used, bar.height),
        Paint()..color = fill,
      );
    if (pace case final pace?) {
      final x = size.width * pace;
      canvas.drawRect(
        Rect.fromLTWH(x - 1, 0, 2, size.height),
        Paint()..color = tick,
      );
    }
  }

  @override
  bool shouldRepaint(_Bar old) =>
      old.used != used ||
      old.pace != pace ||
      old.fill != fill ||
      old.track != track ||
      old.tick != tick;
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
