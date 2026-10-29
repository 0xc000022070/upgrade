import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:striked/data/plugin_emblems.dart';
import 'package:striked/design/effects/glitch.dart';
import 'package:striked/design/icons/striked_icon.dart';
import 'package:striked/design/icons/striked_icons.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/platform/plugins/store.dart';

String? blockedReason(
  InstalledPlugin plugin,
  Map<String, InstalledPlugin> byId, [
  Set<String>? seen,
]) {
  if (!plugin.manifest.supported) return plugin.manifest.incompatibility;
  final visited = seen ?? <String>{};
  if (!visited.add(plugin.id)) return null;
  for (final entry in plugin.manifest.dependencies.entries) {
    final target = byId[entry.key];
    if (target == null) return 'NEEDS ${entry.key} · NOT INSTALLED';
    if (!entry.value.allows(target.manifest.version)) {
      return 'NEEDS ${target.manifest.name.toUpperCase()} ${entry.value}';
    }
    if (blockedReason(target, byId, visited) != null) {
      return 'NEEDS ${target.manifest.name.toUpperCase()} · BLOCKED';
    }
  }
  return null;
}

/// Resolver order: dependencies first when turning on, dependents first when turning
/// off; [id] itself last.
List<String> switchPlan(List<InstalledPlugin> catalog, String id, bool on) {
  final byId = {for (final plugin in catalog) plugin.id: plugin};
  final order = <String>[];
  final seen = <String>{};
  void visit(String current) {
    if (!seen.add(current)) return;
    if (on) {
      final plugin = byId[current];
      if (plugin == null) return;
      for (final dependency in plugin.manifest.dependencies.keys) {
        if (byId[dependency]?.enabled == false) visit(dependency);
      }
    } else {
      for (final plugin in catalog) {
        if (plugin.enabled &&
            plugin.manifest.dependencies.containsKey(current)) {
          visit(plugin.id);
        }
      }
    }
    order.add(current);
  }

  visit(id);
  return order;
}

const pluginArmWindow = Duration(seconds: 3);

const pluginNodeSize = 60.0;

class _NodeFace extends StatelessWidget {
  const _NodeFace({
    required this.emblem,
    required this.on,
    required this.blocked,
    required this.warm,
    required this.busy,
    this.pressed = false,
    this.flicker,
    this.size = pluginNodeSize,
  });

  final PluginEmblem? emblem;
  final bool on;
  final bool blocked;
  final bool warm;
  final bool busy;
  final bool pressed;
  final double size;

  final Color? flicker;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final ink = tokens.backgroundPrimary;
    final face =
        flicker ??
        (warm
            ? tokens.warning
            : on
            ? tokens.accent
            : emblem == null || blocked
            ? tokens.borderSubtle
            : Color.lerp(tokens.borderNormal, tokens.textDisabled, 0.45)!);
    final lit = on || warm || flicker != null;
    final lip = size * (pressed ? 0.03 : 0.09);
    final outline = size >= pluginNodeSize ? 3.0 : 2.0;
    final icon = emblem == null
        ? StrikedIcon(
            StrikedIcons.add,
            size: size * 0.4,
            color: tokens.textDisabled,
          )
        : SvgPicture.asset(
            emblem!.asset,
            width: size * 0.56,
            height: size * 0.56,
            theme: SvgTheme(currentColor: lit ? ink : tokens.textMuted),
            excludeFromSemantics: true,
          );
    return AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 90),
      width: size,
      height: size,
      margin: EdgeInsets.only(top: size * 0.09 - lip),
      decoration: BoxDecoration(
        color: ink,
        borderRadius: BorderRadius.circular(3),
        boxShadow: [
          BoxShadow(color: ink, offset: Offset(0, lip + outline)),
          BoxShadow(
            color: Color.lerp(face, ink, 0.55)!,
            offset: Offset(0, lip),
            spreadRadius: -outline,
          ),
        ],
      ),
      padding: EdgeInsets.all(outline),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(1),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [0, 0.06, 0.06, 1],
            colors: [
              Color.lerp(face, tokens.textPrimary, 0.3)!,
              Color.lerp(face, tokens.textPrimary, 0.3)!,
              face,
              face,
            ],
          ),
        ),
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            Opacity(
              opacity: busy ? 0.4 : (blocked && flicker == null ? 0.55 : 1),
              child: icon,
            ),
            if (blocked && emblem != null)
              Positioned(
                right: -size * 0.1,
                bottom: -size * 0.1,
                child: Container(
                  padding: EdgeInsets.all(size * 0.04),
                  decoration: BoxDecoration(
                    color: tokens.danger,
                    borderRadius: BorderRadius.circular(2),
                    border: Border.all(color: ink, width: outline - 1),
                  ),
                  child: StrikedIcon(
                    StrikedIcons.blocked,
                    size: size * 0.24,
                    color: tokens.textPrimary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class PluginNode extends StatefulWidget {
  const PluginNode({
    super.key,
    required this.id,
    required this.emblem,
    required this.on,
    this.blocked = false,
    this.missing = false,
    this.pressed = false,
    this.size = pluginNodeSize,
  });

  final String id;
  final String? emblem;
  final bool on;
  final bool blocked;
  final bool missing;
  final bool pressed;
  final double size;

  @override
  State<PluginNode> createState() => _PluginNodeState();
}

class _PluginNodeState extends State<PluginNode> {
  final _glitch = GlitchController(frames: iconGlitchSteps.length);

  @override
  void didUpdateWidget(PluginNode old) {
    super.didUpdateWidget(old);
    if (old.on != widget.on) _glitch.fire();
  }

  @override
  void dispose() {
    _glitch.dispose();
    super.dispose();
  }

  _NodeFace _face({Color? flicker}) => _NodeFace(
    emblem: widget.missing ? null : PluginEmblem.of(widget.id, widget.emblem),
    on: widget.on,
    blocked: widget.blocked,
    warm: false,
    busy: false,
    pressed: widget.pressed,
    size: widget.size,
    flicker: flicker,
  );

  @override
  Widget build(BuildContext context) => MediaQuery.disableAnimationsOf(context)
      ? _face()
      : GlitchedIcon(
          controller: _glitch,
          rest: _face(),
          frame: ({required Color paint}) => _face(flicker: paint),
        );
}

class PluginNodeBadge extends StatelessWidget {
  const PluginNodeBadge({
    super.key,
    required this.id,
    required this.emblem,
    required this.on,
    this.blocked = false,
    this.missing = false,
    this.size = pluginNodeSize,
  });

  final String id;
  final String? emblem;
  final bool on;
  final bool blocked;
  final bool missing;
  final double size;

  @override
  Widget build(BuildContext context) => _NodeFace(
    emblem: missing ? null : PluginEmblem.of(id, emblem),
    on: on,
    blocked: blocked,
    warm: false,
    busy: false,
    size: size,
  );
}

class PluginGameButton extends StatefulWidget {
  const PluginGameButton({
    super.key,
    required this.label,
    required this.face,
    required this.onTap,
  });

  final String label;
  final Color face;
  final VoidCallback? onTap;

  @override
  State<PluginGameButton> createState() => _PluginGameButtonState();
}

class _PluginGameButtonState extends State<PluginGameButton> {
  var _down = false;

  void _press(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final ink = tokens.backgroundPrimary;
    final live = widget.onTap != null;
    final face = live ? widget.face : tokens.surfaceSecondary;
    final lip = live && !_down ? 5.0 : 1.0;
    final dark = face.computeLuminance() < 0.3;
    return Semantics(
      button: true,
      enabled: live,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: live ? (_) => _press(true) : null,
        onTapUp: (_) => _press(false),
        onTapCancel: () => _press(false),
        child: AnimatedContainer(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 70),
          constraints: const BoxConstraints(minHeight: 48),
          margin: EdgeInsets.only(top: 5 - lip, bottom: lip),
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.lg,
            vertical: Spacing.sm,
          ),
          decoration: BoxDecoration(
            color: face,
            borderRadius: BorderRadius.circular(2),
            border: Border.all(color: ink, width: 3),
            boxShadow: [
              BoxShadow(
                color: Color.lerp(face, ink, 0.55)!,
                offset: Offset(0, lip),
              ),
              BoxShadow(color: ink, offset: Offset(0, lip + 2)),
            ],
          ),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Text(
              widget.label,
              style: tokens.label.copyWith(
                color: !live
                    ? tokens.textDisabled
                    : dark
                    ? tokens.textPrimary
                    : ink,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
