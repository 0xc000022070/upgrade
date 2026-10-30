import 'package:flutter/widgets.dart';

import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/features/plugins/plugin_board.dart';
import 'package:upgrade/platform/plugins/store.dart';

typedef PluginEdge = ({String from, String to});

class PluginGraphLayout {
  const PluginGraphLayout({
    required this.rows,
    required this.edges,
    required this.unlinked,
    required this.missing,
  });

  final List<List<String>> rows;

  final List<PluginEdge> edges;
  final List<String> unlinked;
  final Set<String> missing;
}

PluginGraphLayout pluginGraph(List<InstalledPlugin> catalog) {
  final byId = {for (final plugin in catalog) plugin.id: plugin};
  final edges = <PluginEdge>[
    for (final plugin in catalog)
      for (final dependency in plugin.manifest.dependencies.keys)
        (from: dependency, to: plugin.id),
  ];
  final missing = {
    for (final edge in edges)
      if (!byId.containsKey(edge.from)) edge.from,
  };
  final linked = {
    for (final edge in edges) ...[edge.from, edge.to],
  };
  final nodes = [
    for (final plugin in catalog)
      if (linked.contains(plugin.id)) plugin.id,
    ...missing,
  ];
  final needs = <String, List<String>>{
    for (final id in nodes)
      id: [
        for (final edge in edges)
          if (edge.to == id) edge.from,
      ],
  };

  // A cycle among disabled plugins is legal to store; the edge that closes it is
  // ignored for placing rows and still drawn.
  final layer = <String, int>{};
  final visiting = <String>{};
  int place(String id) {
    if (layer[id] case final known?) return known;
    visiting.add(id);
    var row = 0;
    for (final dependency in needs[id]!) {
      if (visiting.contains(dependency)) continue;
      final below = place(dependency) + 1;
      if (below > row) row = below;
    }
    visiting.remove(id);
    return layer[id] = row;
  }

  nodes.forEach(place);
  final depth = nodes.isEmpty
      ? 0
      : layer.values.reduce((a, b) => a > b ? a : b) + 1;
  final rows = [
    for (var r = 0; r < depth; r++)
      [
        for (final id in nodes)
          if (layer[id] == r) id,
      ],
  ];

  final position = <String, double>{};
  void index() {
    for (final row in rows) {
      for (var i = 0; i < row.length; i++) {
        position[row[i]] = i.toDouble();
      }
    }
  }

  void sweep(Iterable<int> order, Iterable<String> Function(String id) peers) {
    for (final r in order) {
      final at = {
        for (final id in rows[r])
          id: switch ([for (final peer in peers(id)) position[peer]!]) {
            [] => position[id]!,
            final spots => spots.reduce((a, b) => a + b) / spots.length,
          },
      };
      final original = {for (final id in rows[r]) id: position[id]!};
      rows[r].sort((a, b) {
        final byBary = at[a]!.compareTo(at[b]!);
        return byBary != 0 ? byBary : original[a]!.compareTo(original[b]!);
      });
      for (var i = 0; i < rows[r].length; i++) {
        position[rows[r][i]] = i.toDouble();
      }
    }
  }

  Iterable<String> neededBy(String id) => [
    for (final edge in edges)
      if (edge.from == id) edge.to,
  ];

  index();
  for (var pass = 0; pass < 2; pass++) {
    sweep([for (var r = 1; r < depth; r++) r], (id) => needs[id]!);
    sweep([for (var r = depth - 2; r >= 0; r--) r], neededBy);
  }

  return PluginGraphLayout(
    rows: rows,
    edges: edges,
    unlinked: [
      for (final plugin in catalog)
        if (!linked.contains(plugin.id)) plugin.id,
    ],
    missing: missing,
  );
}

abstract final class _Graph {
  static const node = 48.0;
  static const ring = 5.0;
  static const run = 44.0;
  static const column = 104.0;
}

class PluginGraphCanvas extends StatelessWidget {
  const PluginGraphCanvas({
    super.key,
    required this.graph,
    required this.byId,
    required this.lit,
    required this.onTap,
  });

  final PluginGraphLayout graph;
  final Map<String, InstalledPlugin> byId;

  final Set<String>? lit;
  final void Function(String id) onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.6);
    final label = scaler.scale(12) * 1.35;
    final cell = _Graph.node * 1.09 + _Graph.ring * 2 + Spacing.xs + label * 3;
    final tier = cell + _Graph.run;

    Widget node(String id) => Opacity(
      opacity: lit == null || lit!.contains(id) ? 1 : 0.3,
      child: _GraphNode(
        key: ValueKey('node-$id'),
        id: id,
        plugin: byId[id],
        blocked: switch (byId[id]) {
          final plugin? when !plugin.enabled => blockedReason(plugin, byId),
          _ => null,
        },
        scaler: scaler,
        onTap: () => onTap(id),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / _Graph.column).floor().clamp(
          1,
          99,
        );
        final loose = Wrap(
          children: [
            for (final id in graph.unlinked)
              SizedBox(
                width: constraints.maxWidth / columns,
                height: cell + Spacing.lg,
                child: node(id),
              ),
          ],
        );
        if (graph.rows.isEmpty) return loose;

        final widest = graph.rows
            .map((row) => row.length)
            .reduce((a, b) => a > b ? a : b);
        final width = (_Graph.column * widest).clamp(
          constraints.maxWidth,
          double.infinity,
        );
        final spots = <String, Offset>{
          for (var r = 0; r < graph.rows.length; r++)
            for (var i = 0; i < graph.rows[r].length; i++)
              graph.rows[r][i]: Offset(
                (width - _Graph.column * graph.rows[r].length) / 2 +
                    _Graph.column * (i + 0.5),
                tier * r,
              ),
        };
        final Widget tiers = SizedBox(
          width: width,
          height: tier * graph.rows.length - _Graph.run,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _GraphLines(
                    edges: graph.edges,
                    spots: spots,
                    cell: cell,
                    lit: lit,
                    on: {
                      for (final plugin in byId.values)
                        if (plugin.enabled) plugin.id,
                    },
                    accent: tokens.accent,
                    idle: tokens.borderNormal,
                    shell: tokens.backgroundPrimary,
                  ),
                ),
              ),
              for (final MapEntry(key: id, value: spot) in spots.entries)
                Positioned(
                  left: spot.dx - _Graph.column / 2,
                  top: spot.dy,
                  width: _Graph.column,
                  height: cell,
                  child: node(id),
                ),
            ],
          ),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (width <= constraints.maxWidth)
              tiers
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: tiers,
              ),
            if (graph.unlinked.isNotEmpty) ...[
              const SizedBox(height: Spacing.xl),
              loose,
            ],
          ],
        );
      },
    );
  }
}

class _GraphNode extends StatefulWidget {
  const _GraphNode({
    super.key,
    required this.id,
    required this.plugin,
    required this.blocked,
    required this.scaler,
    required this.onTap,
  });

  final String id;
  final InstalledPlugin? plugin;
  final String? blocked;
  final TextScaler scaler;
  final VoidCallback onTap;

  @override
  State<_GraphNode> createState() => _GraphNodeState();
}

class _GraphNodeState extends State<_GraphNode> {
  var _down = false;

  void _press(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final plugin = widget.plugin;
    final on = plugin?.enabled ?? false;
    final (String state, Color tone) = switch (plugin) {
      null => ('MISSING', tokens.textDisabled),
      _ when on => ('ON', tokens.accent),
      _ when widget.blocked != null => ('LOCKED', tokens.danger),
      _ => ('OFF', tokens.textMuted),
    };
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onTapDown: (_) => _press(true),
      onTapUp: (_) => _press(false),
      onTapCancel: () => _press(false),
      child: Column(
        children: [
          Container(
            width: _Graph.node + _Graph.ring * 2,
            height: _Graph.node * 1.09 + _Graph.ring * 2,
            alignment: Alignment.center,
            child: PluginNode(
              id: widget.id,
              emblem: plugin?.manifest.emblem,
              on: on,
              blocked: widget.blocked != null,
              missing: plugin == null,
              pressed: _down,
              size: _Graph.node,
            ),
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            (plugin?.manifest.name ?? widget.id).toUpperCase(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            textScaler: widget.scaler,
            style: tokens.label.copyWith(
              color: plugin == null ? tokens.textDisabled : tokens.textPrimary,
              fontSize: 12,
            ),
          ),
          Text(
            state,
            maxLines: 1,
            textScaler: widget.scaler,
            style: tokens.label.copyWith(color: tone, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _GraphLines extends CustomPainter {
  _GraphLines({
    required this.edges,
    required this.spots,
    required this.cell,
    required this.lit,
    required this.on,
    required this.accent,
    required this.idle,
    required this.shell,
  });

  final List<PluginEdge> edges;
  final Map<String, Offset> spots;
  final double cell;
  final Set<String>? lit;
  final Set<String> on;
  final Color accent;
  final Color idle;
  final Color shell;

  static const _head = 7.0;

  @override
  void paint(Canvas canvas, Size size) {
    bool bright(PluginEdge edge) =>
        lit == null || (lit!.contains(edge.from) && lit!.contains(edge.to));
    final ordered = [...edges.where((e) => !bright(e)), ...edges.where(bright)];
    for (final edge in ordered) {
      final from = spots[edge.from]! + Offset(0, cell);
      final to = spots[edge.to]! + const Offset(0, _Graph.ring - 1);
      final bend = (to.dy - from.dy) / 2;
      final path = Path()
        ..moveTo(from.dx, from.dy)
        ..cubicTo(
          from.dx,
          from.dy + bend,
          to.dx,
          to.dy - bend,
          to.dx,
          to.dy - _head,
        );
      var tone = on.contains(edge.from) && on.contains(edge.to) ? accent : idle;
      if (!bright(edge)) tone = tone.withAlpha(70);
      canvas.drawPath(
        path,
        Paint()
          ..color = shell
          ..strokeWidth = 7
          ..style = PaintingStyle.stroke,
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = tone
          ..strokeWidth = 2.5
          ..style = PaintingStyle.stroke,
      );
      canvas.drawPath(
        Path()
          ..moveTo(to.dx - _head * 0.75, to.dy - _head)
          ..lineTo(to.dx + _head * 0.75, to.dy - _head)
          ..lineTo(to.dx, to.dy)
          ..close(),
        Paint()..color = tone,
      );
    }
  }

  @override
  bool shouldRepaint(_GraphLines old) =>
      old.edges != edges ||
      old.spots != spots ||
      old.cell != cell ||
      !_sameLit(old.lit, lit) ||
      old.on.length != on.length ||
      !old.on.containsAll(on) ||
      old.accent != accent ||
      old.idle != idle;
}

bool _sameLit(Set<String>? a, Set<String>? b) => a == null
    ? b == null
    : b != null && a.length == b.length && a.containsAll(b);
