import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../design/colors.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';

/// SPEC.md §39.30. The kinds that have a mark under `assets/icons/`.
///
/// A manifest rather than a lookup: the asset bundle can be enumerated at
/// runtime only by parsing `AssetManifest`, which is a file read and a decode
/// on the way to drawing a 16px glyph. So the list is the truth, and the files
/// are checked against it by [agentMarkAsset]'s test rather than at runtime — a
/// kind added here without its file renders an empty box, which is worse than
/// the `?` it would have fallen back to.
const agentMarkKinds = {'claude', 'codex'};

/// The mark file for a kind, or null when it falls back to `?`.
String? agentMarkAsset(String agent) =>
    agentMarkKinds.contains(agent) ? 'assets/icons/agent-$agent.svg' : null;

/// §39.30: the name as herdr reports it, uppercased, `?` when it reports none.
String agentMarkName(String agent) =>
    agent.isEmpty ? '?' : agent.toUpperCase();

/// SPEC.md §39.30. The §39.20 glyph box, now carrying the agent's own mark
/// instead of a letter. Shared by the Home panel row and the `VIEW ALL` route
/// row so the two cannot drift on which kinds have a file.
///
/// §39.30 is a scoped exception to §3 and §10: a third-party mark is allowed
/// here and nowhere else, reduced to one colour, never in the vendor's own.
class AgentMark extends StatelessWidget {
  const AgentMark(this.agent, {super.key});

  /// §39.20's box, kept at 24 by §39.30.
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
      // the size §39.30 asks for. Painted over the child it costs nothing —
      // the mark never reaches the edge it is drawn on.
      foregroundDecoration: BoxDecoration(
        border: Border.all(color: HotlineColors.borderNormal),
        borderRadius: BorderRadius.circular(Radii.sharp),
      ),
      // The same tint path the `hl-*` glyphs take through [HotlineIcon]: the
      // file is `currentColor` throughout and the colour is decided here.
      //
      // Drawn at the full 24 of the box, not at 16. The mark files carry
      // §39.30's fit themselves — `translate(4 4) scale(.6666667)` on the
      // path, so the art occupies the central 16 units of a 24 grid — and
      // asking for 16 here would shrink that 16 again, to a little under 11.
      child: asset == null
          ? const Text('?', style: HotlineText.valueStrong)
          : SvgPicture.asset(
              asset,
              width: markBox,
              height: markBox,
              theme: const SvgTheme(currentColor: HotlineColors.textPrimary),
            ),
    );
  }
}
