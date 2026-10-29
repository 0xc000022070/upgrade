import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/drops/drop_selection.dart';
import 'package:striked/application/drops/fresh_drops.dart';
import 'package:striked/application/navigation.dart';
import 'package:striked/application/plugins/native_plugins.dart';
import 'package:striked/application/plugins/plugin_placements.dart';
import 'package:striked/data/repositories/plugin_placement_repository.dart';
import 'package:striked/design/components/dot_spinner.dart';
import 'package:striked/design/components/held_drag.dart';
import 'package:striked/design/components/list_row.dart';
import 'package:striked/design/components/panel.dart';
import 'package:striked/design/components/panel_text_action.dart';
import 'package:striked/design/components/toolbar_icon_action.dart';
import 'package:striked/design/icons/striked_icons.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/platform/plugins/contributions.dart';
import 'package:striked/design/components/screen_scaffold.dart';
import 'package:striked/features/tasks/item_search_screen.dart';
import 'package:striked/features/tasks/selection_bar.dart';
import 'package:striked/features/plugins/plugin_card.dart';
import 'package:striked/features/plugins/plugin_management_screen.dart';
import 'package:striked/features/plugins/plugin_promise.dart';
import 'package:striked/features/home/home_card_viewport.dart';
import 'package:striked/features/home/home_actions.dart';

String _placementErrorMessage(Object? error) =>
    error is PluginPlacementException
    ? error.message
    : 'HOME LAYOUT COULD NOT BE LOADED. SAVED LAYOUT WAS NOT CHANGED.';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});
  static const navIndex = 0;

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _entryKeys = <String, GlobalKey>{};
  double _swipe = 0;

  void _leave() {
    ref.read(dropSelectionProvider.notifier).clear();
    ref.read(freshDropsProvider.notifier).clear();
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
      if (previous == HomeScreen.navIndex && next != HomeScreen.navIndex) {
        _leave();
      }
    });
    final catalog = ref.watch(pluginContributionCatalogProvider);
    final search = ref.watch(nativeSurfaceOwnerProvider('item.detail')) != null;
    final placementState = ref.watch(pluginPlacementsProvider);
    final placements = placementState.valueOrNull;
    final selecting = ref
        .watch(dropSelectionProvider)
        .ownedBy(DropSelection.homeScope);
    PluginWidgetRegistration? shown(String id) => switch (catalog.widget(id)) {
      final widget?
          when widget.enabled &&
              placements!.placements[id] == PluginPlacementLocation.homeCard &&
              !placements.hiddenHome.contains(id) =>
        widget,
      _ => null,
    };
    final space = placements?.homeSpace ?? 1;
    final live = [
      for (final id in placements?.homeOrder ?? const <String>[])
        if (shown(id) != null) id,
    ];
    final numbers = {
      for (final id in live) placements!.spaceOf(id),
      space,
    }.toList()..sort();
    final free = [
      for (var n = 1; n <= homeSpaceCount; n++)
        if (!numbers.contains(n)) n,
    ].firstOrNull;
    final columns = placements?.columnsOf(space) ?? const <HomeColumn>[];
    final order = [
      for (final column in columns)
        for (final id in column.cards)
          if (shown(id) != null) id,
    ];
    final tiles = <_Tile>[];
    for (var i = 0; i < columns.length; i++) {
      final cards = [for (final id in columns[i].cards) ?shown(id)];
      if (cards.isEmpty) continue;
      tiles.add(
        _Tile(
          column: i,
          weight: columns[i].weight,
          bounds: [for (final card in cards) _bounds(card, placements!)],
          cards: [
            for (final card in cards)
              _HomeEntry(
                key: ValueKey(card.stableId),
                id: card.stableId,
                title: card.contribution.title,
                order: order,
                onMove: (id, over) =>
                    unawaited(_layout.moveHome(id, over: over)),
                fills: card.contribution.fill,
                child: KeyedSubtree(
                  key: _entryKeys.putIfAbsent(card.stableId, GlobalKey.new),
                  child: _PlacedPluginWidget(
                    registration: card,
                    placements: placements!,
                  ),
                ),
              ),
          ],
        ),
      );
    }
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
      if (tiles.isEmpty) const _EmptySpace(),
      if (placements != null &&
          !live.any((id) => id != agentsCardId) &&
          composer == null)
        _PluginsOffPanel(catalog: catalog),
    ];

    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final split = _HomeTiles.splits(
                math.min(constraints.maxWidth, homeMaxContentWidth) -
                    2 * Spacing.screenEdge,
                tiles,
              );
              return GestureDetector(
                onHorizontalDragUpdate: (details) =>
                    _swipe += details.primaryDelta ?? 0,
                onHorizontalDragEnd: (details) =>
                    _swiped(numbers, space, details.primaryVelocity ?? 0),
                onHorizontalDragCancel: () => _swipe = 0,
                child: ScreenScaffold(
                  fill: split,
                  maxContentWidth: homeMaxContentWidth,
                  breadcrumbTrailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (search)
                        ToolbarIconAction(
                          label: 'SEARCH',
                          icon: StrikedIcons.search,
                          onTap: () {
                            _leave();
                            openItemSearch(context);
                          },
                        ),
                      if (search) const SizedBox(width: Spacing.sm),
                      HomeActions(beforeOpen: _leave),
                    ],
                  ),
                  header: _SpaceStrip(
                    numbers: numbers,
                    current: space,
                    free: free,
                    onShow: (n) => unawaited(_layout.showHomeSpace(n)),
                    onDrop: (id, n) =>
                        unawaited(_layout.moveHome(id, space: n)),
                  ),
                  children: [
                    _HomeTiles(
                      key: ValueKey(space),
                      split: split,
                      head: head,
                      tiles: tiles,
                      tail: tail,
                      onNewColumn: (id, column) => unawaited(
                        _layout.moveHome(
                          id,
                          space: space,
                          column: column,
                          newColumn: true,
                        ),
                      ),
                      onWeights: (weights) => unawaited(
                        _layout.setColumnWeights(space, [
                          for (var i = 0; i < columns.length; i++)
                            weights[i] ?? columns[i].weight,
                        ]),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        if (selecting)
          if (composer == null)
            const SelectionBar(scope: DropSelection.homeScope)
          else
            _PlacedPluginBounds(
              registration: composer,
              placements: placements!,
              child: const SelectionBar(scope: DropSelection.homeScope),
            )
        else if (composer != null)
          _PlacedPluginWidget(registration: composer, placements: placements!),
      ],
    );
  }
}

const homeMaxContentWidth = 1100.0;

(double, double) _bounds(
  PluginWidgetRegistration registration,
  PluginPlacementState placements,
) {
  final contribution = registration.contribution;
  final size = contribution.size(
    placements.selectedSizes[registration.stableId] ?? contribution.defaultSize,
  );
  if (size.fixedWidth case final fixed?) return (fixed, fixed);
  final chosen = placements.selectedWidths[registration.stableId];
  return (chosen?.min ?? size.minWidth!, chosen?.max ?? size.maxWidth!);
}

class _Tile {
  _Tile({
    required this.column,
    required this.weight,
    required this.bounds,
    required this.cards,
  });

  final int column;
  final double weight;
  final List<(double, double)> bounds;
  final List<_HomeEntry> cards;

  late final double min = bounds.map((bound) => bound.$1).reduce(math.max);
  late final double max = math.max(
    min,
    bounds.map((bound) => bound.$2).reduce(math.min),
  );
  late final int? fill = switch (cards.indexWhere((card) => card.fills)) {
    < 0 => null,
    final at => at,
  };
}

class _HomeTiles extends StatefulWidget {
  const _HomeTiles({
    super.key,
    required this.split,
    required this.head,
    required this.tiles,
    required this.tail,
    required this.onNewColumn,
    required this.onWeights,
  });

  static const _seam = 16.0;
  static const _minCardHeight = 240.0;

  static bool splits(double width, List<_Tile> tiles) =>
      tiles.length > 1 &&
      tiles.fold(0.0, (sum, tile) => sum + tile.min) + _seam * tiles.length <=
          width;

  final bool split;
  final List<Widget> head;
  final List<_Tile> tiles;
  final List<Widget> tail;
  final void Function(String id, int column) onNewColumn;
  final ValueChanged<Map<int, double>> onWeights;

  @override
  State<_HomeTiles> createState() => _HomeTilesState();
}

class _HomeTilesState extends State<_HomeTiles> {
  List<double>? _held;
  (double, List<double>)? _grip;

  static List<double> _widths(double available, List<_Tile> tiles) {
    final widths = List<double?>.filled(tiles.length, null);
    while (true) {
      final open = [
        for (var i = 0; i < tiles.length; i++)
          if (widths[i] == null) i,
      ];
      if (open.isEmpty) break;
      final free =
          available - widths.fold(0.0, (sum, width) => sum + (width ?? 0));
      final total = open.fold(0.0, (sum, i) => sum + tiles[i].weight);
      var clamped = false;
      for (final i in open) {
        final share = free * tiles[i].weight / total;
        if (share < tiles[i].min || share > tiles[i].max) {
          widths[i] = share.clamp(tiles[i].min, tiles[i].max);
          clamped = true;
        }
      }
      if (clamped) continue;
      for (final i in open) {
        widths[i] = free * tiles[i].weight / total;
      }
    }
    return [for (final width in widths) width!];
  }

  void _resize(int seam, double x) {
    final (start, widths) = _grip!;
    final delta = x - start;
    final (left, right) = (widget.tiles[seam - 1], widget.tiles[seam]);
    final held = [...widths];
    final pair = held[seam - 1] + held[seam];
    final low = math.max(left.min, pair - right.max);
    final high = math.min(left.max, pair - right.min);
    if (low > high) return;
    held[seam - 1] = (held[seam - 1] + delta).clamp(low, high);
    held[seam] = pair - held[seam - 1];
    setState(() => _held = held);
  }

  void _settle() {
    final held = _held;
    if (held == null) return;
    widget.onWeights({
      for (var i = 0; i < widget.tiles.length; i++)
        widget.tiles[i].column: held[i] / 100,
    });
  }

  @override
  void didUpdateWidget(_HomeTiles oldWidget) {
    super.didUpdateWidget(oldWidget);
    final before = [for (final tile in oldWidget.tiles) tile.weight];
    final after = [for (final tile in widget.tiles) tile.weight];
    if (!listEquals(before, after)) _held = null;
  }

  Widget _cards(
    _Tile tile, {
    double? viewport,
    List<Widget> extra = const [],
  }) => _CardColumn(
    viewport: viewport,
    minFill: _HomeTiles._minCardHeight,
    fill: tile.fill,
    children: [...tile.cards, ...extra],
  );

  @override
  Widget build(BuildContext context) {
    final tiles = widget.tiles;
    if (!widget.split) {
      final cards = [for (final tile in tiles) ...tile.cards];
      return _CardColumn(
        viewport: null,
        minFill: _HomeTiles._minCardHeight,
        fill: switch (cards.indexWhere((card) => card.fills)) {
          < 0 => null,
          final at => at + widget.head.length,
        },
        children: [...widget.head, ...cards, ...widget.tail],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final panel in widget.head) ...[
          panel,
          const SizedBox(height: Spacing.panelGap),
        ],
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final available =
                  constraints.maxWidth - _HomeTiles._seam * tiles.length;
              final held = _held;
              final widths =
                  held != null &&
                      held.length == tiles.length &&
                      (held.fold(0.0, (sum, width) => sum + width) - available)
                              .abs() <
                          1
                  ? held
                  : _widths(available, tiles);
              final height = math.max(
                constraints.maxHeight,
                _HomeTiles._minCardHeight,
              );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < tiles.length; i++) ...[
                    if (i > 0)
                      _Seam(
                        key: ValueKey('home-seam-$i'),
                        onDrop: (id) => widget.onNewColumn(id, tiles[i].column),
                        onGrip: (x) => _grip = (x, widths),
                        onResize: (x) => _resize(i, x),
                        onSettle: _settle,
                      ),
                    SizedBox(
                      width: widths[i],
                      child: SingleChildScrollView(
                        child: HomeCardViewport(
                          height: height,
                          child: _cards(
                            tiles[i],
                            viewport: height,
                            extra: i == tiles.length - 1
                                ? widget.tail
                                : const [],
                          ),
                        ),
                      ),
                    ),
                  ],
                  _Seam(
                    key: ValueKey('home-seam-${tiles.length}'),
                    onDrop: (id) =>
                        widget.onNewColumn(id, tiles.last.column + 1),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Seam extends StatelessWidget {
  const _Seam({
    super.key,
    required this.onDrop,
    this.onGrip,
    this.onResize,
    this.onSettle,
  });

  final ValueChanged<String> onDrop;
  final ValueChanged<double>? onGrip;
  final ValueChanged<double>? onResize;
  final VoidCallback? onSettle;

  @override
  Widget build(BuildContext context) => DragTarget<String>(
    onAcceptWithDetails: (details) => onDrop(details.data),
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
      child: SizedBox(
        width: _HomeTiles._seam,
        child: Center(
          child: Container(
            width: BarSizes.inlineThickness,
            color: candidates.isEmpty ? null : context.tokens.accent,
          ),
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
  });

  final PluginWidgetRegistration registration;
  final PluginPlacementState placements;

  @override
  Widget build(BuildContext context) => _PlacedPluginBounds(
    registration: registration,
    placements: placements,
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
  });

  final PluginWidgetRegistration registration;
  final PluginPlacementState placements;
  final Widget child;

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
          child: SizedBox(width: width, height: size.height, child: child),
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

class _HomeEntry extends StatelessWidget {
  const _HomeEntry({
    super.key,
    required this.id,
    required this.title,
    required this.order,
    required this.onMove,
    this.fills = false,
    required this.child,
  });

  static const _ghostHeight = 96.0;

  final String id;
  final String title;
  final List<String> order;
  final void Function(String id, String over) onMove;
  final bool fills;
  final Widget child;

  static Offset _anchor(
    Draggable<Object> draggable,
    BuildContext context,
    Offset position,
  ) {
    final box = context.findRenderObject()! as RenderBox;
    final local = box.globalToLocal(position);
    return Offset(
      local.dx,
      math.min(local.dy, math.min(box.size.height, _ghostHeight) / 2),
    );
  }

  @override
  Widget build(BuildContext context) => DragTarget<String>(
    onWillAcceptWithDetails: (details) => details.data != id,
    onAcceptWithDetails: (details) => onMove(details.data, id),
    builder: (context, candidates, _) {
      final held = candidates.firstOrNull;
      final edge = BorderSide(
        color: context.tokens.accent,
        width: BarSizes.inlineThickness,
      );
      final below = held != null && order.indexOf(held) < order.indexOf(id);
      return DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: held == null
              ? null
              : Border(
                  top: below ? BorderSide.none : edge,
                  bottom: below ? edge : BorderSide.none,
                ),
        ),
        child: HeldDrag<String>(
          data: id,
          anchor: _anchor,
          ghost: (context, size) => Container(
            width: size.width,
            height: math.min(size.height, _ghostHeight),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: context.tokens.backgroundPrimary,
              border: Border.all(color: context.tokens.accent),
            ),
            child: Text(
              title.toUpperCase(),
              style: context.tokens.panelHeader.copyWith(
                color: context.tokens.accent,
              ),
            ),
          ),
          child: child,
        ),
      );
    },
  );
}

class _SpaceStrip extends StatelessWidget {
  const _SpaceStrip({
    required this.numbers,
    required this.current,
    required this.free,
    required this.onShow,
    required this.onDrop,
  });

  final List<int> numbers;
  final int current;
  final int? free;
  final ValueChanged<int> onShow;
  final void Function(String id, int space) onDrop;

  @override
  Widget build(BuildContext context) {
    Widget cell(String label, int space, {bool lit = false}) =>
        DragTarget<String>(
          onAcceptWithDetails: (details) => onDrop(details.data, space),
          builder: (context, candidates, _) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onShow(space),
            child: Container(
              key: ValueKey('home-space-$label'),
              width: TapTargets.minHeight,
              decoration: BoxDecoration(
                border: candidates.isEmpty
                    ? null
                    : Border.all(color: context.tokens.accent),
              ),
              child: Column(
                children: [
                  SizedBox(
                    height: TapTargets.minHeight - BarSizes.inlineThickness,
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
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: Row(
        children: [
          for (final n in numbers) cell('$n', n, lit: n == current),
          if (free case final free?) cell('+', free),
        ],
      ),
    );
  }
}

class _EmptySpace extends StatelessWidget {
  const _EmptySpace();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Spacing.xxl),
    child: Text(
      'EMPTY · HOLD A CARD AND DROP IT ON A NUMBER',
      textAlign: TextAlign.center,
      style: context.tokens.label.copyWith(color: context.tokens.textMuted),
    ),
  );
}
