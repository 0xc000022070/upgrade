import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../application/agent_kind.dart';
import '../../application/agent_state.dart';
import '../../design/colors.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';

/// The mark file for a kind, or null when it falls back to `?`.
///
/// The kind names its own file rather than the bundle being searched for one:
/// the asset bundle can be enumerated at runtime only by parsing
/// `AssetManifest`, which is a file read and a decode on the way to drawing a
/// 16px glyph. The files are checked against the kinds by this function's test
/// rather than at runtime — a kind whose file is missing renders an empty box,
/// which is worse than the `?` it would have fallen back to.
String? agentMarkAsset(String agent) => AgentKind.lookup(agent)?.markAsset;

/// The name as herdr reports it, uppercased, `?` when it reports none.
String agentMarkName(String agent) => agent.isEmpty ? '?' : agent.toUpperCase();

/// The colour a state is drawn in, here rather than on the state itself: what
/// a word means is the application's, what it looks like is the design's. One
/// switch, shared by the Home panel row and the `VIEW ALL` route row, so the
/// two cannot disagree about what `done` looks like — and exhaustive, so a
/// state added to the sealed type is named here by the analyser.
Color agentStateColor(AgentState state) => switch (state) {
  WorkingState() => SpectacleColors.accent,
  BlockedState() => SpectacleColors.warning,
  // Work that finished and has not been read yet, against work that was.
  DoneState() => SpectacleColors.textPrimary,
  IdleState() || UnknownState() => SpectacleColors.textMuted,
};

/// The glyph box, now carrying the agent's own mark
/// instead of a letter. Shared by the Home panel row and the `VIEW ALL` route
/// row so the two cannot drift on which kinds have a file.
///
/// A scoped exception to the icon rules: a third-party mark is allowed
/// here and nowhere else, reduced to one colour, never in the vendor's own.
class AgentMark extends StatelessWidget {
  const AgentMark(this.agent, {super.key});

  /// The glyph box, kept at 24.
  static const markBox = 24.0;

  final String agent;

  @override
  Widget build(BuildContext context) {
    final asset = agentMarkAsset(agent);
    return Container(
      width: markBox,
      height: markBox,
      alignment: Alignment.center,
      // A foreground decoration rather than a background one: `decoration`
      // insets the child by the border, which would land the mark at 22/24 of
      // the size the mark asks for. Painted over the child it costs nothing —
      // the mark never reaches the edge it is drawn on.
      foregroundDecoration: BoxDecoration(
        border: Border.all(color: SpectacleColors.borderNormal),
        borderRadius: BorderRadius.circular(Radii.sharp),
      ),
      // The same tint path the `hl-*` glyphs take through [SpectacleIcon]: the
      // file is `currentColor` throughout and the colour is decided here.
      //
      // Drawn at the full 24 of the box, not at 16. The mark files carry
      // their fit themselves — `translate(4 4) scale(.6666667)` on the
      // path, so the art occupies the central 16 units of a 24 grid — and
      // asking for 16 here would shrink that 16 again, to a little under 11.
      child: asset == null
          ? const Text('?', style: SpectacleText.valueStrong)
          : SvgPicture.asset(
              asset,
              width: markBox,
              height: markBox,
              theme: const SvgTheme(currentColor: SpectacleColors.textPrimary),
            ),
    );
  }
}
