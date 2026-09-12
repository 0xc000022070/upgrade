import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../application/alerts.dart';
import '../../design/colors.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';
import '../../platform/herdr_client.dart';

/// What the app is while it is a tile in the corner of something else.
///
/// The window is a few hundred pixels of a screen the user is using for
/// something else, so it carries one line to be read at a glance and the rows
/// behind that line for whoever looks twice. Nothing here is tappable: a tap on
/// the window is the system's gesture for opening the app back up, and a target
/// under it would take that gesture away from the user.
class PipPanel extends ConsumerWidget {
  const PipPanel({super.key});

  /// How many agents fit before the window is a list nobody can read. The rest
  /// are counted on the line under them.
  static const _rows = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agents = ref.watch(agentsFeedProvider).valueOrNull;
    final outcomes = agents?.outcomes ?? const <HostOutcome>[];
    // The same sentence the shade's ongoing line carries, from the same
    // function: the window and the notification are two drawings of one answer,
    // and a second way of saying it would be a second thing to keep true.
    final headline = agents == null || agents.noHost
        ? AgentPanelState.blockedLine
        : watcherNotificationText(outcomes);
    final listed = _listed(outcomes);
    return ColoredBox(
      color: SpectacleColors.backgroundPrimary,
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        // The system decides how big the window is and the user can make it
        // smaller than these lines. Scrolling is off — a tile in the corner is
        // read, not operated — but a scroller clips what does not fit, where a
        // column paints the framework's overflow stripes over it.
        child: SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                headline,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SpectacleText.heroName.copyWith(
                  color: _headlineColour(outcomes),
                ),
              ),
              const SizedBox(height: Spacing.sm),
              for (final row in listed.take(_rows)) _AgentLine(row: row),
              if (listed.length > _rows)
                Padding(
                  padding: const EdgeInsets.only(top: Spacing.xs),
                  child: Text(
                    '+${listed.length - _rows} MORE',
                    style: SpectacleText.label,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Accent for an agent stopped at a question, which is the only state on this
  /// window that is about to cost the user something; danger for a host the
  /// watcher cannot reach, because the line is then about the app and not the
  /// work. Otherwise the colour of a line that is merely true.
  Color _headlineColour(List<HostOutcome> outcomes) {
    if (outcomes.any((outcome) => !outcome.ok)) return SpectacleColors.danger;
    final blocked = outcomes.any(
      (outcome) => outcome.agents.any((agent) => agent.state.blocked),
    );
    return blocked ? SpectacleColors.accent : SpectacleColors.textPrimary;
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

class _Row {
  const _Row(this.host, this.agent);

  final String host;
  final AgentSnapshot agent;
}

class _AgentLine extends StatelessWidget {
  const _AgentLine({required this.row});

  final _Row row;

  @override
  Widget build(BuildContext context) {
    final blocked = row.agent.state.blocked;
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${row.agent.agent.toUpperCase()} · ${row.host}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SpectacleText.valueStrong,
            ),
          ),
          const SizedBox(width: Spacing.md),
          Text(
            row.agent.state.label,
            style: SpectacleText.value.copyWith(
              color: blocked
                  ? SpectacleColors.accent
                  : SpectacleColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}
