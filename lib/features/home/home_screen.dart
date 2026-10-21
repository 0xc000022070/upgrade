import 'dart:async';
import 'dart:math' as math;

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
  final _cardsKey = GlobalKey();
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
    bool shown(String id) => switch (catalog.widget(id)) {
      final widget? =>
        widget.enabled &&
            placements!.placements[id] == PluginPlacementLocation.homeCard &&
            !placements.hiddenHome.contains(id),
      null => false,
    };
    final order = placements?.homeOrder ?? const <String>[];
    final space = placements?.homeSpace ?? 1;
    final live = [
      for (final id in order)
        if (shown(id)) id,
    ];
    final here = [
      for (final id in live)
        if ((placements?.spaceOf(id) ?? 1) == space) id,
    ];
    final numbers = {
      for (final id in live) placements?.spaceOf(id) ?? 1,
      space,
    }.toList()..sort();
    final free = [
      for (var n = 1; n <= homeSpaceCount; n++)
        if (!numbers.contains(n)) n,
    ].firstOrNull;
    void move(String id, String over) =>
        unawaited(_layout.moveHome(id, over: over));
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

    final panels = <Widget>[
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
      for (final id in here)
        if (catalog.widget(id) case final widget?)
          _HomeEntry(
            key: ValueKey(id),
            id: id,
            title: widget.contribution.title,
            order: here,
            onMove: move,
            fills: widget.contribution.surface == 'home.drops',
            child: KeyedSubtree(
              key: _entryKeys.putIfAbsent(id, GlobalKey.new),
              child: _PlacedPluginWidget(
                registration: widget,
                placements: placements!,
              ),
            ),
          ),
      if (here.isEmpty) const _EmptySpace(),
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
              final wide = _HomeColumns.isWide(constraints.maxWidth, panels);
              return GestureDetector(
                onHorizontalDragUpdate: (details) =>
                    _swipe += details.primaryDelta ?? 0,
                onHorizontalDragEnd: (details) =>
                    _swiped(numbers, space, details.primaryVelocity ?? 0),
                onHorizontalDragCancel: () => _swipe = 0,
                child: ScreenScaffold(
                  fill: wide,
                  maxContentWidth: 1100,
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
                    _HomeColumns(
                      wide: wide,
                      cardsKey: _cardsKey,
                      children: panels,
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

class _HomeColumns extends StatelessWidget {
  const _HomeColumns({
    required this.wide,
    required this.cardsKey,
    required this.children,
  });

  static const _agentsWidth = 300.0;

  static const _minCardHeight = 240.0;

  static bool isWide(double width, List<Widget> children) =>
      width - 2 * Spacing.screenEdge >= 760 &&
      children.any((child) => child is! _HomeEntry || child.id != agentsCardId);

  final bool wide;
  final GlobalKey cardsKey;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final agents = children
        .whereType<_HomeEntry>()
        .where((entry) => entry.id == agentsCardId)
        .firstOrNull;
    final column = wide
        ? [
            for (final child in children)
              if (child != agents) child,
          ]
        : children;
    final fill = column.indexWhere(
      (child) => child is _HomeEntry && child.fills,
    );
    Widget cards([double? viewport]) => KeyedSubtree(
      key: cardsKey,
      child: _CardColumn(
        viewport: viewport,
        minFill: _minCardHeight,
        fill: fill < 0 ? null : fill,
        children: column,
      ),
    );
    if (!wide) return cards();
    final right = LayoutBuilder(
      builder: (context, constraints) {
        final height = math.max(constraints.maxHeight, _minCardHeight);
        return SingleChildScrollView(
          child: HomeCardViewport(height: height, child: cards(height)),
        );
      },
    );
    if (agents == null) return right;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: _agentsWidth,
          child: SingleChildScrollView(child: agents),
        ),
        const SizedBox(width: Spacing.panelGap),
        Expanded(child: right),
      ],
    );
  }
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
        final available = constraints.maxWidth;
        final selected = placements.selectedWidths[registration.stableId];
        final candidate =
            size.fixedWidth ??
            selected ??
            available.clamp(size.minWidth!, size.maxWidth!);
        if (candidate > available || !size.supportsWidth(candidate)) {
          final reason = candidate > available
              ? 'CHOSEN WIDTH ${candidate.toStringAsFixed(0)} DOES NOT FIT ${available.toStringAsFixed(0)} AVAILABLE'
              : size.unsupportedWidthMessage(available);
          return Panel(
            title: contribution.title.toUpperCase(),
            child: Text(reason, style: context.tokens.rowSubtitle),
          );
        }
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(width: candidate, height: size.height, child: child),
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
