import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/drops/drop_selection.dart';
import 'package:upgrade/application/drops/fresh_drops.dart';
import 'package:upgrade/application/navigation.dart';
import 'package:upgrade/application/plugins/home_layout.dart';
import 'package:upgrade/application/plugins/native_plugins.dart';
import 'package:upgrade/application/plugins/plugin_placements.dart';
import 'package:upgrade/data/repositories/plugin_placement_repository.dart';
import 'package:upgrade/design/components/anchor_menu.dart';
import 'package:upgrade/design/components/dot_spinner.dart';
import 'package:upgrade/design/components/held_drag.dart';
import 'package:upgrade/design/components/list_row.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/panel_text_action.dart';
import 'package:upgrade/design/components/toolbar_icon_action.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/data/plugins/contributions.dart';
import 'package:upgrade/design/components/screen_scaffold.dart';
import 'package:upgrade/features/tasks/selection_bar.dart';
import 'package:upgrade/features/plugins/plugin_card.dart';
import 'package:upgrade/features/plugins/plugin_management_screen.dart';
import 'package:upgrade/features/plugins/plugin_promise.dart';
import 'package:upgrade/features/home/home_card_viewport.dart';
import 'package:upgrade/features/home/home_actions.dart';
import 'package:upgrade/features/home/home_workspaces.dart';

String _placementErrorMessage(Object? error) =>
    error is PluginPlacementException
    ? error.message
    : 'HOME LAYOUT COULD NOT BE LOADED. SAVED LAYOUT WAS NOT CHANGED.';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _entryKeys = <String, GlobalKey>{};
  double _swipe = 0;

  List<String>? _picked;
  int? _arranged;
  bool _overview = false;

  void _leave() {
    ref.read(dropSelectionProvider.notifier).clear();
    ref.read(freshDropsProvider.notifier).clear();
    if (_picked != null) _edit(false);
  }

  void _edit(bool on) => setState(() {
    _picked = on ? [] : null;
    _arranged = null;
  });

  void _pick(String id) => setState(() {
    final picked = _picked!;
    picked.contains(id) ? picked.remove(id) : picked.add(id);
    _arranged = null;
  });

  /// [picked] is the gathering as the workspace in front shows it: a card
  /// gathered on another workspace starts the turns over without it.
  void _arrange(List<String> picked) {
    final next = picked.length == _picked!.length
        ? ((_arranged ?? -1) + 1) % homeArrangements(picked.length)
        : 0;
    setState(() {
      _picked = [...picked];
      _arranged = next;
    });
    unawaited(_layout.arrangeHome(picked, next));
  }

  void _remove(String id) {
    setState(() {
      _picked?.remove(id);
      _arranged = null;
    });
    unawaited(_layout.takeOffHome(id));
  }

  PluginPlacements get _layout => ref.read(pluginPlacementsProvider.notifier);

  void _swiped(List<int> numbers, int space, double velocity) {
    final travel = _swipe;
    _swipe = 0;
    if (travel.abs() < 64 && velocity.abs() < 400) return;
    final next = numbers.indexOf(space) + ((travel + velocity) < 0 ? 1 : -1);
    if (next >= 0 && next < numbers.length) {
      unawaited(_layout.showHomeSpace(numbers[next]));
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(navIndexProvider, (previous, next) {
      if (previous == homeNavIndex && next != homeNavIndex) {
        _leave();
      }
    });
    final catalog = ref.watch(pluginContributionCatalogProvider);
    final placementState = ref.watch(pluginPlacementsProvider);
    final placements = placementState.value;
    final selecting = ref
        .watch(dropSelectionProvider)
        .ownedBy(DropSelection.homeScope);
    final home = HomeLayout(placements ?? PluginPlacementState(), catalog);
    final shown = home.shown;
    final space = placements?.homeSpace ?? 1;
    var drawn = double.infinity;
    VoidCallback? beside(String id, List<int> path, HomeEdge edge) =>
        home.moves(id, space: space, path: path, edge: edge, width: drawn)
        ? () => unawaited(
            _layout.moveHome(id, space: space, path: path, edge: edge),
          )
        : null;
    final live = [
      for (final id in placements?.homeOrder ?? const <String>[])
        if (shown(id) != null) id,
    ];
    final numbers = home.numbers;
    final free = home.freeNumber;
    final picked = _picked?.where((id) {
      final card = shown(id);
      return card != null && placements!.spaceOf(id) == space;
    }).toList();
    final stored = placements?.tileOf(space);
    _Shape? shape(HomeTile tile, List<int> path) => switch (tile) {
      HomeCard(:final id) => switch (shown(id)) {
        final card? => _Leaf(
          id: card.stableId,
          path: path,
          bounds: home.bounds(card),
          entry: (width, sideways) => _HomeEntry(
            key: ValueKey(card.stableId),
            id: card.stableId,
            path: path,
            min: home.bounds(card).$1,
            title: card.contribution.title,
            width: width,
            sideways: sideways,
            onSwap: (id, over) => unawaited(_layout.moveHome(id, over: over)),
            onBeside: beside,
            fills: card.contribution.fill,
            pick: picked == null
                ? null
                : switch (picked.indexOf(card.stableId)) {
                    < 0 => 0,
                    final at => at + 1,
                  },
            onPick: () => _pick(card.stableId),
            onRemove: () => _remove(card.stableId),
            child: KeyedSubtree(
              key: _entryKeys.putIfAbsent(card.stableId, GlobalKey.new),
              child: _PlacedPluginWidget(
                registration: card,
                placements: placements!,
                fill: true,
              ),
            ),
          ),
        ),
        null => null,
      },
      HomeSplit(:final axis, :final children) => switch ([
        for (var i = 0; i < children.length; i++)
          if (shape(children[i], [...path, i]) case final child?)
            child
              ..slot = [...path, i]
              ..weight = children[i].weight,
      ]) {
        [] => null,
        [final only] => only,
        final shown => _Split(path: path, axis: axis, children: shown),
      },
    };
    final root = stored == null ? null : shape(stored, const []);
    final composer = placements == null
        ? null
        : catalog.widgets
              .where(
                (widget) =>
                    widget.enabled &&
                    placements.placements[widget.stableId] ==
                        PluginPlacementLocation.homeComposer,
              )
              .firstOrNull;

    final head = <Widget>[
      if (placementState.isLoading && catalog.widgets.isNotEmpty)
        const Panel(title: '[ PLUGINS ]', child: DelayedSpinner()),
      if (placementState.hasError)
        Panel(
          title: '[ PLUGIN LAYOUT ERROR ]',
          bodyPadding: panelRowsPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _placementErrorMessage(placementState.error),
                style: context.tokens.rowSubtitle,
              ),
              PanelTextAction(
                label: 'RETRY',
                onTap: () => ref.invalidate(pluginPlacementsProvider),
              ),
            ],
          ),
        ),
    ];
    final tail = <Widget>[
      if (root == null) _EmptySpace(onAdd: () => showAddWidgets(context)),
      if (placements != null &&
          !live.any((id) => id != agentsCardId) &&
          composer == null)
        _PluginsOffPanel(catalog: catalog),
    ];

    return PopScope(
      canPop: picked == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _edit(false);
      },
      child: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = homeContentWidth(
                  constraints.maxWidth,
                  MediaQuery.paddingOf(context).horizontal,
                );
                drawn = width;
                final split = _HomeTiles.splits(width, root);
                return GestureDetector(
                  onHorizontalDragUpdate: (details) =>
                      _swipe += details.primaryDelta ?? 0,
                  onHorizontalDragEnd: (details) =>
                      _swiped(numbers, space, details.primaryVelocity ?? 0),
                  onHorizontalDragCancel: () => _swipe = 0,
                  child: ScreenScaffold(
                    fill: split,
                    maxContentWidth: homeMaxContentWidth,
                    breadcrumbWidget: _SpaceStrip(
                      numbers: numbers,
                      labelOf: (n) =>
                          placements == null ? '$n' : homeLabel(placements, n),
                      current: space,
                      free: free,
                      onShow: (n) => unawaited(_layout.showHomeSpace(n)),
                      onDrop: (id, n) =>
                          unawaited(_layout.moveHome(id, space: n)),
                    ),
                    breadcrumbTrailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ToolbarIconAction(
                          label: 'WORKSPACES',
                          icon: UpgradeIcons.workspaces,
                          lit: _overview,
                          onTap: () async {
                            setState(() => _overview = true);
                            await showWorkspaces(context);
                            if (mounted) setState(() => _overview = false);
                          },
                        ),
                        HomeActions(
                          beforeOpen: _leave,
                          entries: [
                            MenuEntry(
                              'EDIT LAYOUT',
                              UpgradeIcons.split,
                              () => _edit(true),
                            ),
                            MenuEntry(
                              'ADD WIDGETS',
                              UpgradeIcons.add,
                              () => showAddWidgets(context),
                            ),
                            MenuEntry(
                              'RENAME WORKSPACE',
                              UpgradeIcons.edit,
                              () => showWorkspaceName(
                                context,
                                space: space,
                                fresh: false,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    children: [
                      _HomeTiles(
                        key: ValueKey(space),
                        split: split,
                        head: head,
                        root: root,
                        tail: tail,
                        onBeside: beside,
                        onWeights: (path, weights) {
                          final row =
                              placements!.homeTileAt(space, path)! as HomeSplit;
                          unawaited(
                            _layout.setRowWeights(space, path, [
                              for (var i = 0; i < row.children.length; i++)
                                weights[i] ?? row.children[i].weight,
                            ]),
                          );
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          if (picked != null)
            HomeEditBar(
              selected: picked.length,
              arrangement: _arranged == null
                  ? null
                  : (_arranged!, homeArrangements(picked.length)),
              onArrange: picked.length < 2 ? null : () => _arrange(picked),
              onAdd: () => showAddWidgets(context),
              onDone: () => _edit(false),
            )
          else if (selecting)
            if (composer == null)
              const SelectionBar(scope: DropSelection.homeScope)
            else
              _PlacedPluginBounds(
                registration: composer,
                placements: placements!,
                child: const SelectionBar(scope: DropSelection.homeScope),
              )
          else if (composer != null)
            _PlacedPluginWidget(
              registration: composer,
              placements: placements!,
            ),
        ],
      ),
    );
  }
}

sealed class _Shape {
  _Shape(this.path);

  final List<int> path;

  /// The saved child of the parent split this shape stands for, which is a
  /// split further out than [path] when hidden cards left it one child.
  late List<int> slot = path;
  double weight = 1;

  double get min;
  double get max;
}

typedef _Fits = bool Function(_Lift lift);

typedef _Beside = VoidCallback? Function(
  String id,
  List<int> path,
  HomeEdge edge,
);

final class _Leaf extends _Shape {
  _Leaf({
    required this.id,
    required List<int> path,
    required this.bounds,
    required this.entry,
  }) : super(path);

  final String id;
  final (double, double) bounds;
  final _HomeEntry Function(double width, _Fits sideways) entry;

  @override
  double get min => bounds.$1;

  @override
  double get max => math.max(bounds.$1, bounds.$2);
}

final class _Split extends _Shape {
  _Split({required List<int> path, required this.axis, required this.children})
    : super(path);

  final HomeAxis axis;
  final List<_Shape> children;

  double get _seams => _HomeTiles._seam * (children.length - 1);

  @override
  late final double min = axis == HomeAxis.row
      ? children.fold(0.0, (sum, child) => sum + child.min) + _seams
      : children.map((child) => child.min).reduce(math.max);

  @override
  late final double max = axis == HomeAxis.row
      ? children.fold(0.0, (sum, child) => sum + child.max) + _seams
      : math.max(min, children.map((child) => child.max).reduce(math.min));

  bool fits(double width) => axis == HomeAxis.row && min <= width;

  _Fits joins(double width) =>
      (lift) =>
          children.any((child) => child is _Leaf && child.id == lift.id) ||
          min + lift.min + _HomeTiles._seam <= width;
}

List<Widget> _stack(
  _Shape shape,
  double width,
  Widget Function(_Split row, double width) row, {
  bool stand = true,
  _Fits? beside,
}) {
  final room = stand ? width : width - _HomeTiles._seam;
  return switch (shape) {
    _Leaf() => [
      shape.entry(
        width,
        beside ?? (lift) => shape.min + lift.min + _HomeTiles._seam <= room,
      ),
    ],
    _Split() when stand && shape.fits(width) => [row(shape, width)],
    _Split(:final axis, :final children) => [
      for (final child in children)
        ..._stack(
          child,
          width,
          row,
          beside: axis == HomeAxis.row && child is _Leaf ? (_) => false : null,
        ),
    ],
  };
}

int? _fillOf(List<Widget> items) =>
    switch (items.indexWhere((item) => item is _HomeEntry && item.fills)) {
      < 0 => null,
      final at => at,
    };

class _HomeTiles extends StatelessWidget {
  const _HomeTiles({
    super.key,
    required this.split,
    required this.head,
    required this.root,
    required this.tail,
    required this.onBeside,
    required this.onWeights,
  });

  static const _seam = homeSeam;
  static const _minCardHeight = 240.0;

  static bool splits(double width, _Shape? root) =>
      root is _Split && root.fits(width - _seam);

  final bool split;
  final List<Widget> head;
  final _Shape? root;
  final List<Widget> tail;
  final _Beside onBeside;
  final void Function(List<int> path, Map<int, double> weights) onWeights;

  Widget _row(
    _Split row,
    double width, {
    Widget Function(_Shape child, double width, bool last, _Fits? beside)? cell,
  }) => _TileRow(
    key: ValueKey('home-row-${row.path.join('.')}'),
    row: row,
    width: width,
    top: cell != null,
    onBeside: onBeside,
    onWeights: onWeights,
    cell:
        cell ??
        (child, width, _, beside) => _column(child, width, beside: beside),
  );

  Widget _column(
    _Shape shape,
    double width, {
    double? viewport,
    List<Widget> head = const [],
    List<Widget> tail = const [],
    bool stand = true,
    _Fits? beside,
  }) {
    final items = [
      ...head,
      ..._stack(shape, width, _row, stand: stand, beside: beside),
      ...tail,
    ];
    return _CardColumn(
      viewport: viewport,
      minFill: _minCardHeight,
      fill: _fillOf(items),
      children: items,
    );
  }

  @override
  Widget build(BuildContext context) {
    final root = this.root;
    if (root == null) {
      return _CardColumn(
        viewport: null,
        minFill: _minCardHeight,
        fill: null,
        children: [...head, ...tail],
      );
    }
    if (!split || root is! _Split) {
      return LayoutBuilder(
        builder: (context, constraints) => _column(
          root,
          constraints.maxWidth,
          head: head,
          tail: tail,
          stand: false,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final panel in head) ...[
          panel,
          const SizedBox(height: Spacing.panelGap),
        ],
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final height = math.max(constraints.maxHeight, _minCardHeight);
              return _row(
                root,
                constraints.maxWidth,
                cell: (child, width, last, beside) => SingleChildScrollView(
                  child: HomeCardViewport(
                    height: height,
                    child: _column(
                      child,
                      width,
                      viewport: height,
                      tail: last ? tail : const [],
                      beside: beside,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _TileRow extends StatefulWidget {
  const _TileRow({
    super.key,
    required this.row,
    required this.width,
    required this.top,
    required this.onBeside,
    required this.onWeights,
    required this.cell,
  });

  final _Split row;
  final double width;
  final bool top;
  final _Beside onBeside;
  final void Function(List<int> path, Map<int, double> weights) onWeights;
  final Widget Function(_Shape child, double width, bool last, _Fits? beside)
  cell;

  @override
  State<_TileRow> createState() => _TileRowState();
}

class _TileRowState extends State<_TileRow> {
  List<double>? _held;
  (double, List<double>)? _grip;

  void _resize(int seam, double x) {
    final (start, widths) = _grip!;
    final delta = x - start;
    final tiles = widget.row.children;
    final (left, right) = (tiles[seam - 1], tiles[seam]);
    final held = [...widths];
    final pair = held[seam - 1] + held[seam];
    var (low, high) = (
      math.max(left.min, pair - right.max),
      math.min(left.max, pair - right.min),
    );
    if (low > high) (low, high) = (left.min, pair - right.min);
    if (low > high) return;
    held[seam - 1] = (held[seam - 1] + delta).clamp(low, high);
    held[seam] = pair - held[seam - 1];
    setState(() => _held = held);
  }

  void _settle() {
    final held = _held;
    if (held == null) return;
    final tiles = widget.row.children;
    widget.onWeights(widget.row.path, {
      for (var i = 0; i < tiles.length; i++) tiles[i].slot.last: held[i] / 100,
    });
  }

  @override
  void didUpdateWidget(_TileRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final before = [for (final tile in oldWidget.row.children) tile.weight];
    final after = [for (final tile in widget.row.children) tile.weight];
    if (!listEquals(before, after)) _held = null;
  }

  @override
  Widget build(BuildContext context) {
    final tiles = widget.row.children;
    const seam = _HomeTiles._seam;
    final available =
        widget.width - seam * (tiles.length - 1) - (widget.top ? seam : 0);
    final held = _held;
    final widths =
        held != null &&
            held.length == tiles.length &&
            (held.fold(0.0, (sum, width) => sum + width) - available).abs() < 1
        ? held
        : homeShares(available, [
            for (final tile in tiles) (tile.weight, tile.min, tile.max),
          ]);
    final joins = widget.row.joins(widget.width - (widget.top ? seam : 0));
    final lefts = <double>[];
    var x = 0.0;
    for (final width in widths) {
      lefts.add(x);
      x += width + seam;
    }
    return Stack(
      children: [
        Row(
          crossAxisAlignment: widget.top
              ? CrossAxisAlignment.stretch
              : CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < tiles.length; i++) ...[
              if (i > 0) const SizedBox(width: seam),
              SizedBox(
                width: widths[i],
                child: widget.cell(
                  tiles[i],
                  widths[i],
                  i == tiles.length - 1,
                  tiles[i] is _Leaf ? joins : null,
                ),
              ),
            ],
            if (widget.top) const SizedBox(width: seam),
          ],
        ),
        for (var i = 1; i < tiles.length; i++)
          Positioned(
            left: lefts[i] - seam,
            top: 0,
            bottom: 0,
            width: seam,
            child: _Seam(
              key: ValueKey('home-seam-${[...widget.row.path, i].join('.')}'),
              accepts: joins,
              drop: (id) =>
                  widget.onBeside(id, tiles[i - 1].slot, HomeEdge.right),
              onGrip: (x) => _grip = (x, widths),
              onResize: (x) => _resize(i, x),
              onSettle: _settle,
            ),
          ),
        if (widget.top)
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: seam,
            child: _Seam(
              key: const ValueKey('home-seam-end'),
              accepts: joins,
              drop: (id) => widget.onBeside(id, const [], HomeEdge.right),
            ),
          ),
      ],
    );
  }
}

class _Seam extends StatelessWidget {
  const _Seam({
    super.key,
    required this.accepts,
    required this.drop,
    this.onGrip,
    this.onResize,
    this.onSettle,
  });

  final _Fits accepts;
  final VoidCallback? Function(String id) drop;
  final ValueChanged<double>? onGrip;
  final ValueChanged<double>? onResize;
  final VoidCallback? onSettle;

  @override
  Widget build(BuildContext context) => DragTarget<_Lift>(
    onWillAcceptWithDetails: (details) =>
        accepts(details.data) && drop(details.data.id) != null,
    onAcceptWithDetails: (details) => drop(details.data.id)?.call(),
    builder: (context, candidates, _) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      dragStartBehavior: DragStartBehavior.down,
      onHorizontalDragStart: onGrip == null
          ? null
          : (details) => onGrip!(details.globalPosition.dx),
      onHorizontalDragUpdate: onResize == null
          ? null
          : (details) => onResize!(details.globalPosition.dx),
      onHorizontalDragEnd: onSettle == null ? null : (_) => onSettle!(),
      child: Center(
        child: Container(
          width: BarSizes.inlineThickness,
          color: candidates.isEmpty ? null : context.tokens.accent,
        ),
      ),
    ),
  );
}

class _CardColumn extends MultiChildRenderObjectWidget {
  const _CardColumn({
    required this.viewport,
    required this.minFill,
    required this.fill,
    required super.children,
  });

  final double? viewport;
  final double minFill;
  final int? fill;

  @override
  _RenderCardColumn createRenderObject(BuildContext context) =>
      _RenderCardColumn(viewport: viewport, minFill: minFill, fill: fill);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderCardColumn renderObject,
  ) {
    renderObject
      ..viewport = viewport
      ..minFill = minFill
      ..fill = fill;
  }
}

class _CardParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderCardColumn extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _CardParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _CardParentData> {
  _RenderCardColumn({
    required this._viewport,
    required this._minFill,
    required this._fill,
  });

  double? _viewport;
  set viewport(double? value) {
    if (value == _viewport) return;
    _viewport = value;
    markNeedsLayout();
  }

  double _minFill;
  set minFill(double value) {
    if (value == _minFill) return;
    _minFill = value;
    markNeedsLayout();
  }

  int? _fill;
  set fill(int? value) {
    if (value == _fill) return;
    _fill = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _CardParentData) {
      child.parentData = _CardParentData();
    }
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    final cards = getChildrenAsList();
    final fill = _fill != null && _fill! < cards.length ? cards[_fill!] : null;
    var taken = 0.0;
    for (final card in cards) {
      if (card == fill) continue;
      card.layout(BoxConstraints.tightFor(width: width), parentUsesSize: true);
      if (card.size.height > 0) taken += card.size.height + Spacing.panelGap;
    }
    final viewport = _viewport;
    fill?.layout(
      BoxConstraints(
        minWidth: width,
        maxWidth: width,
        maxHeight: viewport == null
            ? double.infinity
            : math.max(viewport - taken, _minFill),
      ),
      parentUsesSize: true,
    );
    var y = 0.0;
    for (final card in cards) {
      final shown = card.size.height > 0;
      if (shown && y > 0) y += Spacing.panelGap;
      (card.parentData! as _CardParentData).offset = Offset(0, y);
      if (shown) y += card.size.height;
    }
    size = constraints.constrain(Size(width, y));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

class _PlacedPluginWidget extends StatelessWidget {
  const _PlacedPluginWidget({
    required this.registration,
    required this.placements,
    this.fill = false,
  });

  final PluginWidgetRegistration registration;
  final PluginPlacementState placements;
  final bool fill;

  @override
  Widget build(BuildContext context) => _PlacedPluginBounds(
    registration: registration,
    placements: placements,
    fill: fill,
    child: registration.luau
        ? PluginCard(registration: registration)
        : NativeContributionSurface.widget(registration),
  );
}

class _PlacedPluginBounds extends StatelessWidget {
  const _PlacedPluginBounds({
    required this.registration,
    required this.placements,
    required this.child,
    this.fill = false,
  });

  final PluginWidgetRegistration registration;
  final PluginPlacementState placements;
  final Widget child;
  final bool fill;

  @override
  Widget build(BuildContext context) {
    final contribution = registration.contribution;
    final size = contribution.size(
      placements.selectedSizes[registration.stableId] ??
          contribution.defaultSize,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final double width;
        try {
          width = size.resolveWidth(
            constraints.maxWidth,
            selected: placements.selectedWidths[registration.stableId],
          );
        } on PluginPlacementException catch (error) {
          return Panel(
            title: contribution.title.toUpperCase(),
            child: Text(error.message, style: context.tokens.rowSubtitle),
          );
        }
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: fill ? constraints.maxWidth : width,
            height: size.height,
            child: child,
          ),
        );
      },
    );
  }
}

class _PluginsOffPanel extends StatelessWidget {
  const _PluginsOffPanel({required this.catalog});

  final PluginContributionCatalog catalog;

  @override
  Widget build(BuildContext context) {
    final off = [
      for (final owner in catalog.owners)
        if (!owner.plugin.enabled)
          if (pluginPromise(owner) case final words when words.isNotEmpty)
            (owner.plugin.manifest.name, words),
    ];
    return Panel(
      title: '[ PLUGINS ]',
      bodyPadding: panelRowsPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (off.isEmpty)
            Text(
              'ADD HOME CARDS, AN INPUT BAR, AND TOOL PAGES.',
              style: context.tokens.rowSubtitle,
            ),
          for (final (name, words) in off)
            ListRow(
              title: name,
              subtitle: words,
              value: 'OFF',
              valueColor: context.tokens.textMuted,
              onTap: () => openPluginManagement(context),
            ),
          PanelTextAction(
            label: 'MANAGE PLUGINS',
            onTap: () => openPluginManagement(context),
          ),
        ],
      ),
    );
  }
}

class _Lift {
  _Lift(this.id);

  final String id;

  double min = 0;

  Offset grip = Offset.zero;
}

class _HomeEntry extends StatefulWidget {
  const _HomeEntry({
    super.key,
    required this.id,
    required this.path,
    required this.min,
    required this.title,
    required this.width,
    required this.sideways,
    required this.onSwap,
    required this.onBeside,
    this.fills = false,
    this.pick,
    this.onPick,
    this.onRemove,
    required this.child,
  });

  static const _ghostHeight = 96.0;
  static const _edgeShare = 0.25;

  final String id;
  final List<int> path;
  final double min;
  final String title;
  final double width;

  final _Fits sideways;
  final void Function(String id, String over) onSwap;
  final _Beside onBeside;
  final bool fills;

  final int? pick;
  final VoidCallback? onPick;
  final VoidCallback? onRemove;
  final Widget child;

  @override
  State<_HomeEntry> createState() => _HomeEntryState();
}

class _HomeEntryState extends State<_HomeEntry> {
  late final _lift = _Lift(widget.id);
  final _target = GlobalKey();
  HomeEdge? _edge;

  Offset _anchor(
    Draggable<Object> draggable,
    BuildContext context,
    Offset position,
  ) {
    final box = context.findRenderObject()! as RenderBox;
    final local = box.globalToLocal(position);
    _lift.min = widget.min;
    return _lift.grip = Offset(
      local.dx,
      math.min(
        local.dy,
        math.min(box.size.height, _HomeEntry._ghostHeight) / 2,
      ),
    );
  }

  HomeEdge? _zone(DragTargetDetails<_Lift> details) {
    final box = _target.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || box.size.isEmpty) return null;
    final at = box.globalToLocal(details.offset + details.data.grip);
    final x = at.dx / box.size.width;
    final y = at.dy / box.size.height;
    final sideways = widget.sideways(details.data);
    final (edge, near) = [
      if (sideways) ...[(HomeEdge.left, x), (HomeEdge.right, 1 - x)],
      (HomeEdge.top, y),
      (HomeEdge.bottom, 1 - y),
    ].reduce((a, b) => b.$2 < a.$2 ? b : a);
    return near < _HomeEntry._edgeShare &&
            widget.onBeside(details.data.id, widget.path, edge) != null
        ? edge
        : null;
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: SizedBox(
      key: _target,
      width: widget.width,
      child: DragTarget<_Lift>(
        onWillAcceptWithDetails: (details) => details.data.id != widget.id,
        onMove: (details) {
          final edge = _zone(details);
          if (edge != _edge) setState(() => _edge = edge);
        },
        onAcceptWithDetails: (details) => switch (_zone(details)) {
          final edge? => widget.onBeside(details.data.id, widget.path, edge)!(),
          null => widget.onSwap(details.data.id, widget.id),
        },
        builder: (context, candidates, _) {
          final line = BorderSide(
            color: context.tokens.accent,
            width: BarSizes.inlineThickness,
          );
          return DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              border: candidates.isEmpty
                  ? null
                  : switch (_edge) {
                      null => Border.fromBorderSide(line),
                      HomeEdge.left => Border(left: line),
                      HomeEdge.right => Border(right: line),
                      HomeEdge.top => Border(top: line),
                      HomeEdge.bottom => Border(bottom: line),
                    },
            ),
            child: HeldDrag<_Lift>(
              data: _lift,
              anchor: _anchor,
              ghost: (context, size) => Container(
                width: size.width,
                height: math.min(size.height, _HomeEntry._ghostHeight),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: context.tokens.backgroundPrimary,
                  border: Border.all(color: context.tokens.accent),
                ),
                child: Text(
                  widget.title.toUpperCase(),
                  style: context.tokens.panelHeader.copyWith(
                    color: context.tokens.accent,
                  ),
                ),
              ),
              child: switch (widget.pick) {
                null => widget.child,
                final pick => _Editable(
                  title: widget.title,
                  pick: pick,
                  onPick: widget.onPick!,
                  onRemove: widget.onRemove!,
                  child: widget.child,
                ),
              },
            ),
          );
        },
      ),
    ),
  );
}

class _Editable extends StatelessWidget {
  const _Editable({
    required this.title,
    required this.pick,
    required this.onPick,
    required this.onRemove,
    required this.child,
  });

  final String title;
  final int pick;
  final VoidCallback onPick;
  final VoidCallback onRemove;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final accent = context.tokens.accent;
    final upper = title.toUpperCase();
    return Stack(
      children: [
        ExcludeSemantics(child: child),
        Positioned.fill(
          child: Semantics(
            button: true,
            selected: pick > 0,
            label: 'GATHER $upper',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onPick,
              child: Container(
                decoration: BoxDecoration(
                  color: pick > 0 ? null : context.tokens.scrim,
                  border: Border.all(
                    color: pick > 0 ? accent : context.tokens.borderNormal,
                    width: pick > 0
                        ? BarSizes.inlineThickness
                        : Borders.hairline,
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          right: BarSizes.inlineThickness,
          top: BarSizes.inlineThickness,
          child: ColoredBox(
            color: context.tokens.surfaceSecondary,
            child: Row(
              children: [
                if (pick > 0)
                  Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    color: accent,
                    child: Text(
                      '$pick',
                      style: context.tokens.panelHeader.copyWith(
                        color: context.tokens.backgroundPrimary,
                      ),
                    ),
                  ),
                SizedBox(
                  width: TapTargets.minHeight,
                  height: RowMetrics.minHeight - BarSizes.inlineThickness,
                  child: Center(
                    child: UpgradeIcon(
                      UpgradeIcons.close,
                      size: IconSizes.sm,
                      color: context.tokens.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          right: BarSizes.inlineThickness,
          top: BarSizes.inlineThickness,
          width: TapTargets.minHeight,
          height: TapTargets.minHeight,
          child: Semantics(
            button: true,
            label: 'REMOVE $upper',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onRemove,
            ),
          ),
        ),
      ],
    );
  }
}

class _SpaceStrip extends StatelessWidget {
  const _SpaceStrip({
    required this.numbers,
    required this.labelOf,
    required this.current,
    required this.free,
    required this.onShow,
    required this.onDrop,
  });

  final List<int> numbers;
  final String Function(int space) labelOf;
  final int current;
  final int? free;
  final ValueChanged<int> onShow;
  final void Function(String id, int space) onDrop;

  void _more(BuildContext anchor) => unawaited(
    showAnchorMenu(
      anchor,
      title: 'WORKSPACE',
      entries: [
        if (free case final free?)
          MenuEntry(
            'NEW WORKSPACE',
            UpgradeIcons.add,
            () => showWorkspaceName(anchor, space: free, fresh: true),
          ),
        MenuEntry(
          'ALL WORKSPACES',
          UpgradeIcons.workspaces,
          () => showWorkspaces(anchor),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    Widget cell(
      String key,
      String label, {
      int? space,
      bool lit = false,
      required void Function(BuildContext anchor) onTap,
    }) => DragTarget<_Lift>(
      onWillAcceptWithDetails: (_) => space != null,
      onAcceptWithDetails: (details) => onDrop(details.data.id, space!),
      builder: (context, candidates, _) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onTap(context),
        child: Container(
          key: ValueKey('home-space-$key'),
          constraints: const BoxConstraints(minWidth: TapTargets.minHeight),
          padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
          decoration: BoxDecoration(
            border: candidates.isEmpty
                ? null
                : Border.all(color: context.tokens.accent),
          ),
          child: IntrinsicWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Center(
                    child: Text(
                      label,
                      style: context.tokens.rowKicker.copyWith(
                        color: lit
                            ? context.tokens.accent
                            : context.tokens.textMuted,
                      ),
                    ),
                  ),
                ),
                Container(
                  height: BarSizes.inlineThickness,
                  color: lit ? context.tokens.accent : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final n in numbers)
            cell(
              '$n',
              labelOf(n),
              space: n,
              lit: n == current,
              onTap: (_) => onShow(n),
            ),
          cell('+', '+', space: free, onTap: _more),
        ],
      ),
    );
  }
}

class _EmptySpace extends StatelessWidget {
  const _EmptySpace({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Spacing.xxl),
    child: Column(
      children: [
        Text(
          'EMPTY · HOLD A CARD AND DROP IT ON A TAB',
          textAlign: TextAlign.center,
          style: context.tokens.label.copyWith(color: context.tokens.textMuted),
        ),
        PanelTextAction(label: 'ADD WIDGETS', onTap: onAdd),
      ],
    ),
  );
}
