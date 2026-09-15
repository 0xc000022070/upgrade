import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../application/alerts.dart';
import '../../design/colors.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../../platform/herdr_client.dart';
import '../home/agent_mark.dart';

/// The block at the head of the headline, at the size the headline is drawn at.
/// The same block the strip over the nav bar carries, for the same reason: it
/// is where the one colour on the surface goes.
const pipHeadlineMarkSize = 6.0;

/// The agent's mark against the line it sits on. The panel's own box is 24 and
/// the window's lines are 11, so the box is asked for at the line's own scale
/// instead — a hair over one and a half times the glyph, which leaves it
/// reading as a mark beside a name rather than as a tile with a name after it.
const pipMarkRatio = 1.5;

/// What the app is while it is a tile in the corner of something else.
///
/// The window is a couple of hundred points of a screen the user is using for
/// something else, so it carries one line to be read at a glance and the rows
/// behind that line for whoever looks twice. Nothing here is tappable: a tap on
/// the window is the system's gesture for opening the app back up, and a target
/// under it would take that gesture away from the user.
class PipPanel extends ConsumerWidget {
  const PipPanel({super.key});

  /// The most agents the window will list, before the rest are counted on the
  /// line under them. How many it actually lists is whatever the system gave it
  /// the height for.
  static const _maxRows = 3;

  /// The window does not grow with the reader's text size — the system decides
  /// how big it is — so past this the type stops rising and the rows start
  /// coming off instead. Below it the scale is honoured in full.
  static const _maxTextScale = 1.3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The feed keeps handing out its last state after the poll behind it stops,
    // so a count read straight off it is not evidence that anything is counting.
    // It matters more here than anywhere else in the app: the watcher can stop
    // while the window is up, and there is no way back out of
    // picture-in-picture from this side. A window that trusted the value would
    // park a frozen tally over whatever the user left to do and stay there
    // until they came back for it.
    final live = ref.watch(agentsFeedLiveProvider);
    final window = _read(live, ref.watch(agentsFeedProvider).valueOrNull);

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: _maxTextScale,
      // One node saying the whole window in a sentence, rather than six nodes
      // of shouted fragments and a separator that reads as "middle dot". It
      // names every agent, including the ones there was no height to draw.
      child: Semantics(
        container: true,
        label: window.spoken,
        excludeSemantics: true,
        child: ColoredBox(
          color: DazzleColors.backgroundPrimary,
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

  /// What the window says, given what the app can currently see.
  _Window _read(bool live, AgentPanelState? agents) {
    if (!live) {
      // The window cannot be absent the way the strip over the nav bar is:
      // nothing on this side closes it, so the choice is between a stale count
      // and saying so. It says so, and keeps the count underneath it labelled
      // as the last thing heard, which is more use than an empty tile and is
      // the one phrasing that is not a lie.
      final last = agents == null || agents.noHost ? '' : agents.tally;
      return _Window(
        headline: 'NOT WATCHING',
        tint: DazzleColors.textSecondary,
        note: last.isEmpty ? null : 'LAST SEEN $last',
      );
    }
    final outcomes = agents?.outcomes ?? const <HostOutcome>[];
    if (agents == null || agents.noHost) {
      return const _Window(
        headline: AgentPanelState.blockedLine,
        tint: DazzleColors.textSecondary,
      );
    }
    // The same sentence the shade's ongoing line carries, from the same
    // function: the window and the notification are two drawings of one answer,
    // and a second way of saying it would be a second thing to keep true.
    return _Window(
      headline: watcherNotificationText(outcomes),
      tint: _headlineTint(outcomes),
      rows: _listed(outcomes),
    );
  }

  /// Accent for an agent stopped at a question, which is the only state on this
  /// window that is about to cost the user something; danger for a host the
  /// watcher cannot reach, because the line is then about the app and not the
  /// work. Otherwise the colour of a line that is merely true.
  Color _headlineTint(List<HostOutcome> outcomes) {
    if (outcomes.any((outcome) => !outcome.ok)) return DazzleColors.danger;
    final blocked = outcomes.any(
      (outcome) => outcome.agents.any((agent) => agent.state.blocked),
    );
    return blocked ? DazzleColors.accent : DazzleColors.textPrimary;
  }

  /// The active agents, blocked first, each with the host it is on. Two hosts
  /// running the same agent are two rows for the reason the panel already keeps
  /// them apart: they are different machines.
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

  /// The window as one sentence. Built from the rows rather than from the text
  /// on them, so that what is read out is every agent the app can see and not
  /// only the ones that fitted.
  String get spoken => [
    headline.replaceAll(' · ', ', '),
    if (note != null) note!.replaceAll(' · ', ', '),
    for (final row in rows)
      '${row.agent.agent} ${row.agent.state.word} on ${row.host}',
  ].join('. ');
}

/// Everything under the padding, laid out against the height the system gave
/// the window rather than a height the app picked.
class _Body extends StatelessWidget {
  const _Body({required this.window, required this.maxRows});

  final _Window window;
  final int maxRows;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final headline = scaler.scale(DazzleText.pipHeadline.fontSize!) * 1.2;
    final meta = scaler.scale(DazzleText.pipMeta.fontSize!) * 1.25;
    final row =
        scaler.scale(DazzleText.pipAgent.fontSize!) * pipMarkRatio +
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
              // A rule under the line, so the headline reads as the head of
              // something rather than as the first of several sizes of text.
              const SizedBox(
                height: Borders.hairline,
                child: ColoredBox(color: DazzleColors.borderSubtle),
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
                  style: DazzleText.pipMeta,
                ),
              ),
            for (final row in window.rows.take(shown)) _AgentLine(row: row),
            if (hidden > 0)
              Padding(
                padding: const EdgeInsets.only(top: Spacing.sm),
                child: Text('+$hidden MORE', style: DazzleText.pipMeta),
              ),
          ],
        );
      },
    );
  }

  /// How many rows there is room for. An unbounded height is a test or a
  /// measuring pass, and takes the cap.
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
    // Everything past here leaves at least one row off, so the line that counts
    // the ones left off is paid for before the rows are.
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
    // Sized off the line it sits on rather than held at the size it was drawn
    // at: the phone's scale is a curve and gives a small size most of the rise,
    // so a block fixed at six points shrinks against its own text until it
    // reads as a speck of dust.
    final base = DazzleText.pipHeadline.fontSize!;
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
            style: DazzleText.pipHeadline.copyWith(color: window.tint),
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

  /// The mark does not take the reader's scale on its own — it is an SVG, not
  /// a glyph — so the line's scale is measured once and handed to it, and the
  /// mark rises with the name beside it instead of shrinking against it.
  double _markSize(BuildContext context) {
    final base = DazzleText.pipAgent.fontSize!;
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
                    style: DazzleText.pipMeta,
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DazzleText.pipAgent,
            ),
          ),
          const SizedBox(width: Spacing.md),
          Text(
            row.agent.state.label,
            style: DazzleText.pipState.copyWith(
              color: blocked ? DazzleColors.accent : null,
              fontWeight: blocked ? FontWeight.w500 : null,
            ),
          ),
        ],
      ),
    );
  }
}
