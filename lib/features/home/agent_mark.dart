import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../application/agent_kind.dart';
import '../../application/agent_state.dart';
import '../../design/tokens.dart';
import '../../design/spacing.dart';
import '../../design/typography.dart';

/// The kind names its own file rather than the bundle being searched: enumerating the
/// asset bundle at runtime means parsing `AssetManifest`, a file read and a decode on the
/// way to a 16px glyph. The files are checked against the kinds by this function's test,
/// because a kind whose file is missing renders an empty box rather than falling back.
String? agentMarkAsset(String agent) => AgentKind.lookup(agent)?.markAsset;

String agentMarkName(String agent) => agent.isEmpty ? '?' : agent.toUpperCase();

String agentMarkLetter(String agent) {
  final letters = agent.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');
  return letters.isEmpty ? '?' : letters[0];
}

Color agentStateColor(BuildContext context, AgentState state) =>
    switch (state) {
      WorkingState() => context.tokens.warning,
      BlockedState() => context.tokens.danger,
      DoneState() => context.tokens.textPrimary,
      IdleState() || UnknownState() => context.tokens.textMuted,
    };

class AgentMark extends StatelessWidget {
  const AgentMark(this.agent, {this.size = markBox, super.key});

  static const markBox = 24.0;

  final String agent;

  final double size;

  @override
  Widget build(BuildContext context) {
    final asset = agentMarkAsset(agent);
    return SizedBox(
      width: size,
      height: size,
      child: Container(
        alignment: Alignment.center,
        // A foreground decoration rather than a background one: `decoration` insets the child by
        // the border, which would land the mark at 22/24 of the size it asks for.
        foregroundDecoration: BoxDecoration(
          border: Border.all(color: context.tokens.borderNormal),
          borderRadius: BorderRadius.circular(Radii.sharp),
        ),
        // Drawn at the full side of the box rather than inset: the mark files carry their fit
        // themselves — `translate(4 4) scale(.6666667)` on the path — and insetting here would
        // shrink that again.
        child: asset == null
            ? Text(
                agentMarkLetter(agent),
                // The box is a fixed square and the reader's scale does not move it, so a glyph that
                // took the scale would climb out of the border it is drawn inside.
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  fontFamily: FontFamilies.mono,
                  fontSize: size * _letter,
                  height: 1,
                  fontWeight: FontWeight.w500,
                  color: context.tokens.textSecondary,
                ),
              )
            : SvgPicture.asset(
                asset,
                width: size,
                height: size,
                theme: SvgTheme(currentColor: context.tokens.textPrimary),
              ),
      ),
    );
  }

  static const _letter = 0.42;
}
