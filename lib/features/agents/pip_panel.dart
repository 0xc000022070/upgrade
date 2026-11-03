import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/alerts/alerts.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/features/home/agent_mark.dart';

const pipHeadlineMarkSize = 6.0;

/// The panel's own box is 24 and the window's lines are 11, so the box is asked for at
/// the line's own scale instead.
const pipMarkRatio = 1.5;

/// Nothing here is tappable: a tap on the window is the system's gesture for opening the
/// app back up, and a target under it would take that gesture away from the user.
class PipPanel extends ConsumerWidget {
  const PipPanel({super.key});

  static const _maxRows = 3;

  /// The window does not grow with the reader's text size — the system decides how big it
  /// is — so past this the type stops rising and the rows start coming off instead.
  static const _maxTextScale = 1.3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The feed keeps handing out its last state after the poll behind it stops. It matters
    // more here than anywhere else: the watcher can stop while the window is up, and there
    // is no way out of picture-in-picture from this side.
    final live = ref.watch(agentsFeedLiveProvider);
    final window = _read(context, live, ref.watch(agentsFeedProvider).value);

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: _maxTextScale,
      child: Semantics(
        container: true,
        label: window.spoken,
        excludeSemantics: true,
        child: ColoredBox(
          color: context.tokens.backgroundPrimary,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.lg,
              vertical: Spacing.md,
            ),
            child: _Body(window: window, maxRows: _maxRows),
          ),
        ),
      ),
    );
  }

  _Window _read(BuildContext context, bool live, AgentPanelState? agents) {
    if (!live) {
      // The window cannot be absent the way the strip over the nav bar is — nothing on this
      // side closes it — so the count stays, labelled as the last thing heard.
      final last = agents == null || agents.noHost ? '' : agents.tally;
      return _Window(
        headline: 'NOT WATCHING',
        tint: context.tokens.textSecondary,
        note: last.isEmpty ? null : 'LAST SEEN $last',
      );
    }
    final outcomes = agents?.outcomes ?? const <HostOutcome>[];
    if (agents == null || agents.noHost) {
      return _Window(
        headline: AgentPanelState.blockedLine,
        tint: context.tokens.textSecondary,
      );
    }
    // The same sentence the shade's ongoing line carries, from the same function.
    return _Window(
      headline: watcherNotificationText(outcomes),
      tint: _headlineTint(context, outcomes),
      rows: _listed(outcomes),
    );
  }

  Color _headlineTint(BuildContext context, List<HostOutcome> outcomes) {
    if (outcomes.any((outcome) => !outcome.ok)) return context.tokens.danger;
    final blocked = outcomes.any(
      (outcome) => outcome.agents.any((agent) => agent.state.blocked),
    );
    if (blocked) return context.tokens.danger;
    final working = outcomes.any(
      (outcome) => outcome.agents.any((agent) => agent.state.active),
    );
    return working ? context.tokens.warning : context.tokens.textPrimary;
  }

  List<_Row> _listed(List<HostOutcome> outcomes) {
    final rows = <_Row>[];
    for (final outcome in outcomes) {
      for (final agent in outcome.agents) {
        if (agent.state.active) rows.add(_Row(outcome.host.name, agent));
      }
    }
    rows.sort((a, b) {
      final urgency =
          (b.agent.state.blocked ? 1 : 0) - (a.agent.state.blocked ? 1 : 0);
      return urgency != 0 ? urgency : a.agent.agent.compareTo(b.agent.agent);
    });
    return rows;
  }
}

class _Window {
  const _Window({
    required this.headline,
    required this.tint,
    this.note,
    this.rows = const [],
  });

  final String headline;
  final Color tint;
  final String? note;
  final List<_Row> rows;

  String get spoken => [
    headline.replaceAll(' · ', ', '),
    if (note != null) note!.replaceAll(' · ', ', '),
    for (final row in rows)
      '${row.agent.agent} ${row.agent.state.word} on ${row.host}',
  ].join('. ');
}

class _Body extends StatelessWidget {
  const _Body({required this.window, required this.maxRows});

  final _Window window;
  final int maxRows;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final headline = scaler.scale(context.tokens.pipHeadline.fontSize!) * 1.2;
    final meta = scaler.scale(context.tokens.pipMeta.fontSize!) * 1.25;
    final row =
        scaler.scale(context.tokens.pipAgent.fontSize!) * pipMarkRatio +
        Spacing.sm;

    return LayoutBuilder(
      builder: (context, box) {
        final shown = _fit(
          box.maxHeight,
          headline: headline + Spacing.md + Borders.hairline,
          meta: meta,
          row: row,
        );
        final hidden = window.rows.length - shown;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _Headline(window: window),
            if (window.note != null || shown > 0) ...[
              const SizedBox(height: Spacing.sm),
              SizedBox(
                height: Borders.hairline,
                child: ColoredBox(color: context.tokens.borderSubtle),
              ),
              const SizedBox(height: Spacing.xs),
            ],
            if (window.note != null)
              Padding(
                padding: const EdgeInsets.only(top: Spacing.xs),
                child: Text(
                  window.note!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.tokens.pipMeta,
                ),
              ),
            for (final row in window.rows.take(shown)) _AgentLine(row: row),
            if (hidden > 0)
              Padding(
                padding: const EdgeInsets.only(top: Spacing.sm),
                child: Text('+$hidden MORE', style: context.tokens.pipMeta),
              ),
          ],
        );
      },
    );
  }

  /// An unbounded height is a test or a measuring pass, and takes the cap.
  int _fit(
    double height, {
    required double headline,
    required double meta,
    required double row,
  }) {
    final wanted = window.rows.length < maxRows ? window.rows.length : maxRows;
    if (!height.isFinite) return wanted;
    var left = height - headline;
    if (window.note != null) left -= meta + Spacing.xs;
    if (window.rows.length <= maxRows && left >= wanted * row) return wanted;
    // Everything past here leaves at least one row off, so the line that counts the ones
    // left off is paid for before the rows are.
    left -= meta + Spacing.sm;
    final fits = left <= 0 ? 0 : left ~/ row;
    return fits < wanted ? fits : wanted;
  }
}

class _Headline extends StatelessWidget {
  const _Headline({required this.window});

  final _Window window;

  @override
  Widget build(BuildContext context) {
    final base = context.tokens.pipHeadline.fontSize!;
    final scale = MediaQuery.textScalerOf(context).scale(base) / base;
    final side = pipHeadlineMarkSize * scale;
    return Row(
      children: [
        SizedBox(
          key: const ValueKey('pip-headline-mark'),
          width: side,
          height: side,
          child: ColoredBox(color: window.tint),
        ),
        const SizedBox(width: Spacing.md),
        Expanded(
          child: Text(
            window.headline,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.tokens.pipHeadline.copyWith(color: window.tint),
          ),
        ),
      ],
    );
  }
}

class _Row {
  const _Row(this.host, this.agent);

  final String host;
  final AgentSnapshot agent;
}

class _AgentLine extends StatelessWidget {
  const _AgentLine({required this.row});

  final _Row row;

  /// The mark does not take the reader's scale on its own — it is an SVG, not a glyph — so
  /// the line's scale is measured once and handed to it.
  double _markSize(BuildContext context) {
    final base = context.tokens.pipAgent.fontSize!;
    return MediaQuery.textScalerOf(context).scale(base) * pipMarkRatio;
  }

  @override
  Widget build(BuildContext context) {
    final blocked = row.agent.state.blocked;
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.sm),
      child: Row(
        children: [
          AgentMark(row.agent.agent, size: _markSize(context)),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: row.agent.agent.toUpperCase()),
                  TextSpan(
                    text: ' · ${row.host}',
                    style: context.tokens.pipMeta,
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.tokens.pipAgent,
            ),
          ),
          const SizedBox(width: Spacing.md),
          Text(
            row.agent.state.label,
            style: context.tokens.pipState.copyWith(
              color: agentStateColor(context, row.agent.state),
              fontWeight: blocked ? FontWeight.w500 : null,
            ),
          ),
        ],
      ),
    );
  }
}
