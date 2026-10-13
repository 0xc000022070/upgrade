import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:upgrade/data/plugin_emblems.dart';
import 'package:upgrade/application/native_plugins.dart';
import 'package:upgrade/application/plugin_hosts.dart';
import 'package:upgrade/application/plugins.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_text_action.dart';
import 'package:upgrade/design/effects/glitch.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/platform/plugins/store.dart';
import 'package:upgrade/features/plugins/plugin_promise.dart';

class BoardRow {
  const BoardRow({
    required this.id,
    required this.plugin,
    required this.depth,
    required this.guides,
    required this.topLit,
    required this.elbowLit,
    required this.below,
    required this.childLit,
    required this.hasChildren,
  });

  final String id;
  final InstalledPlugin? plugin;
  final int depth;

  final List<bool?> guides;

  final bool topLit;
  final bool elbowLit;

  final bool? below;

  final bool childLit;
  final bool hasChildren;
}

List<BoardRow> boardRows(List<InstalledPlugin> catalog) {
  final byId = {for (final plugin in catalog) plugin.id: plugin};
  final children = <String?, List<String>>{};
  final placed = <String>{};

  String? parentOf(InstalledPlugin plugin) =>
      plugin.manifest.dependencies.keys.firstOrNull;

  // A cycle among disabled plugins is legal to store; a plugin whose chain loops back is
  // hung off the bus rather than lost.
  bool reachesBus(String id) {
    final seen = <String>{};
    String? current = id;
    while (current != null) {
      if (!seen.add(current)) return false;
      final plugin = byId[current];
      if (plugin == null) return true;
      current = parentOf(plugin);
    }
    return true;
  }

  for (final plugin in catalog) {
    final parent = reachesBus(plugin.id) ? parentOf(plugin) : null;
    if (parent != null && !byId.containsKey(parent) && placed.add(parent)) {
      children.putIfAbsent(null, () => []).add(parent);
    }
    children.putIfAbsent(parent, () => []).add(plugin.id);
  }

  final rows = <BoardRow>[];
  void walk(String? parent, bool parentOn, List<bool?> guides) {
    final siblings = children[parent] ?? const <String>[];
    final lit = [
      for (final id in siblings) parentOn && (byId[id]?.enabled ?? false),
    ];
    for (var i = 0; i < siblings.length; i++) {
      final id = siblings[i];
      final plugin = byId[id];
      final on = plugin?.enabled ?? false;
      final last = i == siblings.length - 1;
      final below = last ? null : lit.skip(i + 1).any((l) => l);
      final kids = children[id] ?? const <String>[];
      rows.add(
        BoardRow(
          id: id,
          plugin: plugin,
          depth: guides.length,
          guides: guides,
          topLit: lit.skip(i).any((l) => l),
          elbowLit: lit[i],
          below: below,
          childLit: on && kids.any((kid) => byId[kid]?.enabled ?? false),
          hasChildren: kids.isNotEmpty,
        ),
      );
      walk(id, on, [...guides, below]);
    }
  }

  walk(null, true, const []);
  return rows;
}

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

class _Placed {
  _Placed(this.row, this.parent);
  final BoardRow row;
  final _Placed? parent;
  final children = <_Placed>[];
  double column = 0;
}

List<_Placed> _placeTree(List<BoardRow> rows) {
  final placed = <_Placed>[];
  final stack = <_Placed>[];
  for (final row in rows) {
    while (stack.length > row.depth) {
      stack.removeLast();
    }
    final node = _Placed(row, stack.lastOrNull);
    node.parent?.children.add(node);
    placed.add(node);
    stack.add(node);
  }
  var next = 0.0;
  void lay(_Placed node) {
    if (node.children.isEmpty) {
      node.column = next++;
      return;
    }
    node.children.forEach(lay);
    node.column = (node.children.first.column + node.children.last.column) / 2;
  }

  placed.where((node) => node.parent == null).forEach(lay);
  return placed;
}

abstract final class _Tree {
  static const node = 60.0;
  static const ring = 6.0;
  static const core = 36.0;
  static const run = 36.0;
  static const minColumn = 92.0;
}

class PluginBoard extends ConsumerStatefulWidget {
  const PluginBoard({
    super.key,
    required this.onOpen,
    required this.onAdd,
    required this.onBrowse,
  });

  final void Function(InstalledPlugin plugin) onOpen;
  final VoidCallback? onAdd;
  final VoidCallback onBrowse;

  @override
  ConsumerState<PluginBoard> createState() => _PluginBoardState();
}

class _PluginBoardState extends ConsumerState<PluginBoard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _current = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  final _errors = <String, String>{};
  String? _selected;
  String? _armed;
  Timer? _disarm;
  bool _busy = false;
  String? _pauseError;

  @override
  void dispose() {
    _disarm?.cancel();
    _current.dispose();
    super.dispose();
  }

  void _arm(String? id) {
    _disarm?.cancel();
    setState(() => _armed = id);
    if (id == null) return;
    _disarm = Timer(pluginArmWindow, () {
      if (mounted) setState(() => _armed = null);
    });
  }

  void _select(String id) {
    if (_selected == id) return;
    _arm(null);
    setState(() => _selected = id);
  }

  Future<void> _switch(
    List<InstalledPlugin> catalog,
    InstalledPlugin plugin,
  ) async {
    if (_busy) return;
    final on = !plugin.enabled;
    final plan = switchPlan(catalog, plugin.id, on);
    if (plan.length > 1 && _armed != plugin.id) {
      _arm(plugin.id);
      return;
    }
    _arm(null);
    setState(() {
      _busy = true;
      _errors.remove(plugin.id);
    });
    try {
      final plugins = ref.read(pluginsProvider.notifier);
      for (final id in plan) {
        await plugins.setEnabled(id, on);
      }
    } catch (error) {
      if (mounted) setState(() => _errors[plugin.id] = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final plugins = ref.watch(pluginsProvider);
    final pauses = ref.watch(pendingHostPausesProvider);
    final catalog = ref.watch(effectivePluginsProvider);
    final owners = {
      for (final owner in ref.watch(pluginContributionCatalogProvider).owners)
        owner.plugin.id: owner,
    };
    final byId = {for (final plugin in catalog) plugin.id: plugin};
    final rows = boardRows(catalog);
    final blocked = {
      for (final plugin in catalog)
        if (!plugin.enabled) plugin.id: ?blockedReason(plugin, byId),
    };
    final armedPlan = switch (byId[_armed]) {
      final plugin? => switchPlan(catalog, plugin.id, !plugin.enabled).toSet(),
      null => const <String>{},
    };
    final on = catalog.where((p) => p.enabled).length;
    final off = catalog.length - on - blocked.length;
    final selected =
        byId[_selected] ?? rows.map((row) => row.plugin).nonNulls.firstOrNull;

    final animate =
        !MediaQuery.disableAnimationsOf(context) &&
        (rows.any((row) => row.elbowLit) || armedPlan.isNotEmpty);
    if (animate != _current.isAnimating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (animate) {
          _current.repeat();
        } else {
          _current.stop();
        }
      });
    }

    int pips(String id) => switch (owners[id]) {
      final owner? =>
        owner.pages.length +
            owner.widgets.length +
            owner.plugin.manifest.actions.length,
      null => 0,
    };

    return Panel(
      title: '[ BOARD ]',
      bodyPadding: panelRowsPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (plugins.hasError)
            Text('${plugins.error}', style: tokens.rowSubtitle),
          if (pauses.hasError)
            Text(
              'Host pause status unavailable: ${pauses.error}',
              style: tokens.rowSubtitle,
            ),
          if ((pauses.valueOrNull ?? 0) > 0) ...[
            Text(
              '${pauses.valueOrNull} HOST PAUSES PENDING',
              style: tokens.rowSubtitle,
            ),
            PanelTextAction(
              label: 'RETRY HOST PAUSES',
              onTap: () async {
                try {
                  await ref
                      .read(pluginHostRegistryProvider)
                      .retryPending
                      ?.call();
                  if (mounted) setState(() => _pauseError = null);
                } catch (error) {
                  if (mounted) setState(() => _pauseError = '$error');
                }
              },
            ),
            if (_pauseError != null)
              Text(
                _pauseError!,
                style: tokens.rowSubtitle.copyWith(color: tokens.danger),
              ),
          ],
          const SizedBox(height: Spacing.md),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$on ON · $off OFF'
                      '${blocked.isEmpty ? '' : ' · ${blocked.length} BLOCKED'}',
                      style: tokens.valueStrong,
                    ),
                    Text(
                      '${catalog.length}/${PluginStore.maxInstalled} SLOTS',
                      style: tokens.rowSubtitle,
                    ),
                  ],
                ),
              ),
              _GameButton(
                label: 'ADD',
                face: tokens.accent,
                onTap: widget.onAdd,
              ),
            ],
          ),
          const SizedBox(height: Spacing.lg),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Spacing.lg),
              child: Text('NO PLUGINS INSTALLED', style: tokens.rowSubtitle),
            )
          else
            _TreeView(
              rows: rows,
              current: _current,
              animate: animate,
              busy: _busy,
              selected: selected?.id,
              armed: _armed,
              armedPlan: armedPlan,
              blocked: blocked,
              pips: pips,
              onTap: (row) {
                if (row.plugin == null) {
                  widget.onBrowse();
                } else {
                  _select(row.id);
                }
              },
            ),
          const SizedBox(height: Spacing.lg),
          if (selected != null)
            _NodeCard(
              key: ValueKey('node-card-${selected.id}'),
              plugin: selected,
              promise: switch (owners[selected.id]) {
                final owner? => pluginPromise(owner),
                null => '',
              },
              blocked: blocked[selected.id],
              error: _errors[selected.id],
              armed: _armed == selected.id,
              busy: _busy,
              carried: [
                for (final id in switchPlan(
                  catalog,
                  selected.id,
                  !selected.enabled,
                ))
                  if (id != selected.id)
                    byId[id]?.manifest.name.toUpperCase() ?? id,
              ],
              onSwitch: () => _switch(catalog, selected),
              onOpen: () => widget.onOpen(selected),
            ),
          const SizedBox(height: Spacing.md),
        ],
      ),
    );
  }
}

class _TreeView extends StatelessWidget {
  const _TreeView({
    required this.rows,
    required this.current,
    required this.animate,
    required this.busy,
    required this.selected,
    required this.armed,
    required this.armedPlan,
    required this.blocked,
    required this.pips,
    required this.onTap,
  });

  final List<BoardRow> rows;
  final Animation<double> current;
  final bool animate;
  final bool busy;
  final String? selected;
  final String? armed;
  final Set<String> armedPlan;
  final Map<String, String> blocked;
  final int Function(String id) pips;
  final void Function(BoardRow row) onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final placed = _placeTree(rows);
    final columns = placed.where((node) => node.children.isEmpty).length;
    final depth = rows.map((row) => row.depth).reduce((a, b) => a > b ? a : b);
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.6);
    final label = scaler.scale(13) * 1.35;
    final caption = _Tree.node + _Tree.ring * 2 + Spacing.sm + label * 3 + 8;
    final tier = caption + _Tree.run;
    final top = _Tree.core + _Tree.run;
    final height = top + tier * (depth + 1) - _Tree.run;

    return LayoutBuilder(
      builder: (context, constraints) {
        final columnWidth = (constraints.maxWidth / columns).clamp(
          _Tree.minColumn,
          220.0,
        );
        final width = (columnWidth * columns).clamp(
          constraints.maxWidth,
          double.infinity,
        );
        final inset = (width - columnWidth * columns) / 2;
        double x(_Placed node) => inset + columnWidth * (node.column + 0.5);
        double y(_Placed node) => top + tier * node.row.depth;
        double base(_Placed node) {
          final name = TextPainter(
            text: TextSpan(
              text: (node.row.plugin?.manifest.name ?? node.row.id)
                  .toUpperCase(),
              style: tokens.label.copyWith(fontSize: 13),
            ),
            textScaler: scaler,
            textDirection: TextDirection.ltr,
            maxLines: 2,
          )..layout(maxWidth: columnWidth);
          final lines = name.computeLineMetrics().length;
          name.dispose();
          return y(node) + caption - label * (2 - lines);
        }

        final tree = SizedBox(
          width: width,
          height: height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _TreeWires(
                    placed: placed,
                    x: x,
                    y: y,
                    coreX: width / 2,
                    base: base,
                    current: current,
                    animate: animate,
                    armedPlan: armedPlan,
                    lit: tokens.accent,
                    warn: tokens.warning,
                    dim: tokens.borderNormal,
                    shell: tokens.backgroundPrimary,
                    glint: tokens.textPrimary,
                  ),
                ),
              ),
              Positioned(
                left: width / 2 - _Tree.core / 2,
                top: 0,
                child: _Core(),
              ),
              for (final node in placed)
                Positioned(
                  left: x(node) - columnWidth / 2,
                  top: y(node),
                  width: columnWidth,
                  child: _TreeNode(
                    key: ValueKey('board-${node.row.id}'),
                    row: node.row,
                    busy: busy,
                    selected: selected == node.row.id,
                    armed: armed == node.row.id,
                    carriedAlong:
                        armed != node.row.id && armedPlan.contains(node.row.id),
                    blocked: blocked[node.row.id],
                    pips: pips(node.row.id),
                    scaler: scaler,
                    onTap: () => onTap(node.row),
                  ),
                ),
            ],
          ),
        );
        if (width <= constraints.maxWidth) return tree;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: tree,
        );
      },
    );
  }
}

class _Core extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final ink = tokens.backgroundPrimary;
    return Container(
      width: _Tree.core,
      height: _Tree.core,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tokens.accent,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: ink, width: 3),
        boxShadow: [
          BoxShadow(
            color: Color.lerp(tokens.accent, ink, 0.55)!,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Text(
        'UP',
        textScaler: TextScaler.noScaling,
        style: tokens.valueStrong.copyWith(color: ink, fontSize: 12),
      ),
    );
  }
}

class _TreeNode extends StatefulWidget {
  const _TreeNode({
    super.key,
    required this.row,
    required this.busy,
    required this.selected,
    required this.armed,
    required this.carriedAlong,
    required this.blocked,
    required this.pips,
    required this.scaler,
    required this.onTap,
  });

  final BoardRow row;
  final bool busy;
  final bool selected;
  final bool armed;
  final bool carriedAlong;
  final String? blocked;
  final int pips;
  final TextScaler scaler;
  final VoidCallback onTap;

  @override
  State<_TreeNode> createState() => _TreeNodeState();
}

class _TreeNodeState extends State<_TreeNode> {
  final _glitch = GlitchController(frames: iconGlitchSteps.length);
  var _down = false;

  void _press(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  void didUpdateWidget(_TreeNode old) {
    super.didUpdateWidget(old);
    final was = old.row.plugin?.enabled ?? false;
    final now = widget.row.plugin?.enabled ?? false;
    if (was != now) _glitch.fire();
    if (widget.selected && !old.selected && widget.blocked != null) {
      _glitch.fire();
    }
  }

  @override
  void dispose() {
    _glitch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final row = widget.row;
    final plugin = row.plugin;
    final on = plugin?.enabled ?? false;
    final blocked = widget.blocked != null;
    final warm = widget.armed || widget.carriedAlong;

    final (String state, Color stateColor) = switch (plugin) {
      null => ('MISSING', tokens.textDisabled),
      _ when warm => (on ? 'GOES OFF' : 'GOES ON', tokens.warning),
      _ when on => ('ON', tokens.accent),
      _ when blocked => ('LOCKED', tokens.textMuted),
      _ => ('OFF', tokens.textMuted),
    };

    final face = _NodeFace(
      emblem: plugin == null
          ? null
          : PluginEmblem.of(plugin.id, plugin.manifest.emblem),
      on: on,
      blocked: blocked,
      warm: warm,
      busy: widget.busy,
      pressed: _down,
    );
    final ringTone = widget.selected
        ? (warm ? tokens.warning : tokens.textPrimary)
        : tokens.backgroundPrimary.withAlpha(0);

    return GestureDetector(
      key: ValueKey('key-${row.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: widget.busy ? null : widget.onTap,
      onTapDown: widget.busy ? null : (_) => _press(true),
      onTapUp: (_) => _press(false),
      onTapCancel: () => _press(false),
      child: Column(
        children: [
          Container(
            width: _Tree.node + _Tree.ring * 2,
            height: _Tree.node * 1.09 + _Tree.ring * 2,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(color: ringTone, width: 2),
              borderRadius: BorderRadius.circular(3),
            ),
            child: MediaQuery.disableAnimationsOf(context)
                ? face
                : GlitchedIcon(
                    controller: _glitch,
                    rest: face,
                    frame: ({required Color paint}) => _NodeFace(
                      emblem: face.emblem,
                      on: face.on,
                      blocked: face.blocked,
                      warm: face.warm,
                      busy: face.busy,
                      pressed: face.pressed,
                      flicker: paint,
                    ),
                  ),
          ),
          const SizedBox(height: Spacing.sm),
          if (widget.pips > 0)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < widget.pips.clamp(0, 6); i++)
                  Container(
                    width: 5,
                    height: 5,
                    margin: const EdgeInsets.symmetric(horizontal: 1.5),
                    color: on ? tokens.accent : tokens.borderNormal,
                  ),
              ],
            ),
          const SizedBox(height: 3),
          Text(
            (plugin?.manifest.name ?? row.id).toUpperCase(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            textScaler: widget.scaler,
            style: tokens.label.copyWith(
              color: plugin == null ? tokens.textDisabled : tokens.textPrimary,
              fontSize: 13,
            ),
          ),
          Text(
            state,
            maxLines: 1,
            textScaler: widget.scaler,
            style: tokens.label.copyWith(color: stateColor, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _NodeFace extends StatelessWidget {
  const _NodeFace({
    required this.emblem,
    required this.on,
    required this.blocked,
    required this.warm,
    required this.busy,
    this.pressed = false,
    this.flicker,
    this.size = _Tree.node,
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
    final outline = size >= _Tree.node ? 3.0 : 2.0;
    final icon = emblem == null
        ? UpgradeIcon(
            UpgradeIcons.add,
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
                  child: UpgradeIcon(
                    UpgradeIcons.blocked,
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

class PluginNodeBadge extends StatelessWidget {
  const PluginNodeBadge({
    super.key,
    required this.id,
    required this.emblem,
    required this.on,
    this.blocked = false,
    this.missing = false,
    this.size = _Tree.node,
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

class _GameButton extends StatefulWidget {
  const _GameButton({
    super.key,
    required this.label,
    required this.face,
    required this.onTap,
  });

  final String label;
  final Color face;
  final VoidCallback? onTap;

  @override
  State<_GameButton> createState() => _GameButtonState();
}

class _GameButtonState extends State<_GameButton> {
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

class _NodeCard extends StatelessWidget {
  const _NodeCard({
    super.key,
    required this.plugin,
    required this.promise,
    required this.blocked,
    required this.error,
    required this.armed,
    required this.busy,
    required this.carried,
    required this.onSwitch,
    required this.onOpen,
  });

  final InstalledPlugin plugin;
  final String promise;
  final String? blocked;
  final String? error;
  final bool armed;
  final bool busy;
  final List<String> carried;
  final VoidCallback onSwitch;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final on = plugin.enabled;
    final tone = armed
        ? tokens.warning
        : on
        ? tokens.accent
        : tokens.borderNormal;
    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: tokens.surfacePrimary,

        border: Border.all(color: tone, width: 2),
        boxShadow: [
          BoxShadow(
            color: Color.lerp(tone, tokens.backgroundPrimary, 0.6)!,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PluginNodeBadge(
                id: plugin.id,
                emblem: plugin.manifest.emblem,
                on: on,
                blocked: blocked != null,
                size: 44,
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Text(
                  plugin.manifest.name.toUpperCase(),
                  style: tokens.heroName,
                ),
              ),
              const SizedBox(width: Spacing.md),
              Text('v${plugin.manifest.version}', style: tokens.label),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            plugin.manifest.purpose,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: tokens.rowSubtitle,
          ),
          if (promise.isNotEmpty) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              promise,
              style: tokens.label.copyWith(
                color: on ? tokens.accent : tokens.textSecondary,
              ),
            ),
          ],
          if (blocked != null) ...[
            const SizedBox(height: Spacing.sm),
            Text(blocked!, style: tokens.label.copyWith(color: tokens.danger)),
          ],
          if (error != null) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              error!,
              style: tokens.rowSubtitle.copyWith(color: tokens.danger),
            ),
          ],
          if (carried.isNotEmpty && blocked == null) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              '${on ? 'ALSO TURNS OFF' : 'ALSO TURNS ON'} ${carried.join(' · ')}',
              style: tokens.label.copyWith(
                color: armed ? tokens.warning : tokens.textMuted,
              ),
            ),
          ],
          const SizedBox(height: Spacing.md),
          Wrap(
            spacing: Spacing.md,
            runSpacing: Spacing.md,
            children: [
              _GameButton(
                key: ValueKey('switch-${plugin.id}'),
                label: armed
                    ? 'TAP AGAIN · SWITCH ${carried.length + 1}'
                    : on
                    ? 'POWER DOWN'
                    : 'POWER UP',
                face: armed
                    ? tokens.warning
                    : on
                    ? tokens.borderNormal
                    : tokens.accent,
                onTap: busy || blocked != null ? null : onSwitch,
              ),
              _GameButton(
                label: 'DETAILS',
                face: tokens.borderSubtle,
                onTap: onOpen,
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          SizedBox(
            height: 2,
            child: armed
                ? TweenAnimationBuilder<double>(
                    tween: Tween(begin: 1, end: 0),
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : pluginArmWindow,
                    builder: (context, left, _) => Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: MediaQuery.disableAnimationsOf(context)
                            ? 1
                            : left,
                        child: Container(height: 2, color: tokens.warning),
                      ),
                    ),
                  )
                : null,
          ),
        ],
      ),
    );
  }
}

class _TreeWires extends CustomPainter {
  _TreeWires({
    required this.placed,
    required this.x,
    required this.y,
    required this.coreX,
    required this.base,
    required this.current,
    required this.animate,
    required this.armedPlan,
    required this.lit,
    required this.warn,
    required this.dim,
    required this.shell,
    required this.glint,
  }) : super(repaint: animate ? current : null);

  final List<_Placed> placed;
  final double Function(_Placed node) x;
  final double Function(_Placed node) y;
  final double coreX;
  final double Function(_Placed node) base;
  final Animation<double> current;
  final bool animate;
  final Set<String> armedPlan;
  final Color lit;
  final Color warn;
  final Color dim;
  final Color shell;
  final Color glint;

  static const _dash = 4.0;
  static const _period = 16.0;

  @override
  void paint(Canvas canvas, Size size) {
    final phase = animate ? current.value * _period : 0.0;

    void wire(List<Offset> points, Color? tone) {
      final path = Path()..addPolygon(points, false);
      canvas.drawPath(
        path,
        Paint()
          ..color = shell
          ..strokeWidth = 9
          ..style = PaintingStyle.stroke,
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = tone ?? dim
          ..strokeWidth = 4
          ..style = PaintingStyle.stroke,
      );
      if (tone == null || !animate) return;
      final pulse = Paint()
        ..color = Color.lerp(tone, glint, 0.6)!
        ..strokeWidth = 4;
      var travelled = 0.0;
      for (var i = 0; i + 1 < points.length; i++) {
        final a = points[i];
        final b = points[i + 1];
        final length = (b - a).distance;
        if (length == 0) continue;
        final unit = (b - a) / length;
        final start = (phase - travelled) % _period - _period;
        for (var s = start; s < length; s += _period) {
          final from = s.clamp(0.0, length);
          final to = (s + _dash).clamp(0.0, length);
          if (to > from) {
            canvas.drawLine(a + unit * from, a + unit * to, pulse);
          }
        }
        travelled += length;
      }
    }

    for (final node in placed) {
      final row = node.row;
      final parent = node.parent;
      final fromX = parent == null ? coreX : x(parent);
      final fromY = parent == null ? _Tree.core : base(parent);
      final toX = x(node);
      final toY = y(node) + _Tree.ring;
      final mid = toY - _Tree.run / 2 - _Tree.ring;
      final parentOn = parent == null || (parent.row.plugin?.enabled ?? false);
      final on = row.plugin?.enabled ?? false;
      final carried =
          armedPlan.contains(row.id) &&
          (parent == null || armedPlan.contains(parent.row.id) || parentOn);
      final Color? tone = carried
          ? warn
          : parentOn && on
          ? lit
          : null;
      wire([
        Offset(fromX, fromY),
        Offset(fromX, mid),
        Offset(toX, mid),
        Offset(toX, toY),
      ], tone);
    }
  }

  @override
  bool shouldRepaint(_TreeWires old) =>
      old.placed != placed ||
      old.animate != animate ||
      old.armedPlan != armedPlan ||
      old.lit != lit ||
      old.dim != dim ||
      old.shell != shell ||
      old.glint != glint;
}
