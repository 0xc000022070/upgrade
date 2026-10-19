import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

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
        child: LayoutBuilder(
          builder: (context, constraints) {
            final paired =
                constraints.maxWidth >= usageColumn * 2 + Spacing.xxl;
            final width = paired
                ? (constraints.maxWidth - Spacing.xxl) / 2
                : constraints.maxWidth;
            return Wrap(
              spacing: Spacing.xxl,
              runSpacing: Spacing.lg,
              children: [
                for (final entry in usages)
                  SizedBox(
                    width: width,
                    child: _Account(entry, now: at),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

const usageColumn = 240.0;

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
          Padding(
            padding: const EdgeInsets.only(top: Spacing.md),
            child: Row(
              children: [
                UsageRing(limit, now: now),
                const SizedBox(width: Spacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final window in limit.windows.take(ringCount))
                        _Window(window, limit: limit, now: now),
                    ],
                  ),
                ),
              ],
            ),
          ),
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
  const _Window(this.window, {required this.limit, required this.now});

  final UsageWindow window;
  final UsageLimit limit;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final resetsAt = window.resetsAt;
    return Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(windowLabel(window.minutes), style: tokens.value),
        ),
        SizedBox(
          width: 40,
          child: Text(
            '${window.usedPercent.round()}%',
            style: tokens.valueStrong.copyWith(
              color: windowColor(tokens, limit, window, now),
            ),
            textAlign: TextAlign.right,
          ),
        ),
        Expanded(
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

const ringCount = 3;

class UsageRing extends StatelessWidget {
  const UsageRing(this.limit, {required this.now, super.key});

  static const side = 72.0;

  final UsageLimit limit;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final windows = limit.windows.take(ringCount).toList();
    final tightest = windows.fold<UsageWindow?>(
      null,
      (most, each) =>
          most == null || each.usedPercent > most.usedPercent ? each : most,
    );
    return SizedBox.square(
      dimension: side,
      child: CustomPaint(
        painter: _Rings(
          [
            for (final window in windows)
              (
                used: (window.usedPercent / 100).clamp(0.0, 1.0),
                pace: windowPace(window, now),
                fill: windowColor(tokens, limit, window, now),
              ),
          ],
          track: tokens.borderSubtle,
          tick: tokens.textSecondary,
        ),
        child: Center(
          child: tightest == null
              ? null
              : Text(
                  '${tightest.usedPercent.round()}%',
                  textScaler: TextScaler.noScaling,
                  style: tokens.heroPercent.copyWith(
                    fontSize: 20,
                    color: windowColor(tokens, limit, tightest, now),
                  ),
                ),
        ),
      ),
    );
  }
}

typedef _Ring = ({double used, double? pace, Color fill});

class _Rings extends CustomPainter {
  const _Rings(this.rings, {required this.track, required this.tick});

  static const stroke = 6.0;
  static const gap = 3.0;

  final List<_Ring> rings;
  final Color track;
  final Color tick;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    var radius = size.shortestSide / 2 - stroke / 2;
    for (final ring in rings) {
      final bounds = Rect.fromCircle(center: centre, radius: radius);
      final line = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke;
      canvas
        ..drawCircle(centre, radius, line..color = track)
        ..drawArc(
          bounds,
          -math.pi / 2,
          math.pi * 2 * ring.used,
          false,
          line..color = ring.fill,
        );
      if (ring.pace case final pace?) {
        final angle = -math.pi / 2 + math.pi * 2 * pace;
        final along = Offset(math.cos(angle), math.sin(angle));
        canvas.drawLine(
          centre + along * (radius - stroke / 2 - 1),
          centre + along * (radius + stroke / 2 + 1),
          Paint()
            ..color = tick
            ..strokeWidth = 2,
        );
      }
      radius -= stroke + gap;
    }
  }

  @override
  bool shouldRepaint(_Rings old) =>
      !listEquals(old.rings, rings) || old.track != track || old.tick != tick;
}

Color windowColor(
  StrikedTokens tokens,
  UsageLimit limit,
  UsageWindow window,
  DateTime now,
) {
  final pace = windowPace(window, now);
  if (limitHit(limit, window) || window.usedPercent.round() >= 90) {
    return tokens.danger;
  }
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
