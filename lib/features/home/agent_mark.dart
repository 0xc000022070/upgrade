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

/// What stands in for a mark the bundle does not have. The agent's own initial,
/// mechanically — not a second-guess at what its logo looks like, and not the
/// `?` that used to stand here, which drew every unplaceable name as the same
/// box and left a column of agents the reader could not tell apart. `?` is kept
/// for the one case it is honest in: a pane herdr named nothing at all.
String agentMarkLetter(String agent) {
  final letters = agent.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');
  return letters.isEmpty ? '?' : letters[0];
}

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

/// The glyph box: the agent's own mark where the bundle has one, and the
/// agent's initial where it does not. Shared by the Home panel row, the
/// `VIEW ALL` route row and the corner window, so the three cannot drift on
/// which kinds have a file or on what stands in when none does.
///
/// A scoped exception to the icon rules: a third-party mark is allowed
/// here and nowhere else, reduced to one colour, never in the vendor's own.
class AgentMark extends StatelessWidget {
  const AgentMark(this.agent, {this.size = markBox, super.key});

  /// The glyph box, kept at 24.
  static const markBox = 24.0;

  final String agent;

  /// The side of the box. The corner window is the one caller that asks for
  /// anything else: it is a couple of hundred points wide and a 24 box beside
  /// an 11 point line reads as a button rather than as a mark on a row.
  final double size;

  @override
  Widget build(BuildContext context) {
    final asset = agentMarkAsset(agent);
    return SizedBox(
      width: size,
      height: size,
      child: Container(
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
        // Drawn at the full side of the box rather than inset. The mark files
        // carry their fit themselves — `translate(4 4) scale(.6666667)` on the
        // path, so the art occupies the central 16 units of a 24 grid — and
        // insetting here would shrink that 16 again.
        child: asset == null
            ? Text(
                agentMarkLetter(agent),
                // The box is a fixed square and the reader's scale does not
                // move it, so a glyph that took the scale would climb out of
                // the border it is drawn inside.
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  fontFamily: FontFamilies.mono,
                  fontSize: size * _letter,
                  height: 1,
                  fontWeight: FontWeight.w500,
                  // Dimmer than the marks the app does have, which is the
                  // difference: this one is the app admitting it does not know
                  // the agent, not a drawing of it.
                  color: SpectacleColors.textSecondary,
                ),
              )
            : SvgPicture.asset(
                asset,
                width: size,
                height: size,
                theme: const SvgTheme(
                  currentColor: SpectacleColors.textPrimary,
                ),
              ),
      ),
    );
  }

  /// The initial against the box it sits in, at the proportion the `?` it
  /// replaces was drawn at.
  static const _letter = 0.42;
}
