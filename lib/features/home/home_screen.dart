import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../application/drop_selection.dart';
import '../../application/fresh_drops.dart';
import '../../application/navigation.dart';
import '../../application/native_plugins.dart';
import '../../application/plugin_placements.dart';
import '../../data/repositories/plugin_placement_repository.dart';
import '../../design/components/dot_spinner.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_text_action.dart';
import '../../design/components/toolbar_icon_action.dart';
import '../../design/icons/upgrade_icons.dart';
import '../../design/tokens.dart';
import '../../design/spacing.dart';
import '../../platform/plugins/contributions.dart';
import '../screen_scaffold.dart';
import '../tasks/item_search_screen.dart';
import '../tasks/selection_bar.dart';
import '../plugins/plugin_management_screen.dart';
import 'agents_panel.dart';
import 'home_card_viewport.dart';
import 'home_actions.dart';

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
  late final _visible = ref.read(homeAgentsVisibleProvider.notifier);
  final _agentsKey = GlobalKey();
  final _cardsKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncVisible());
  }

  bool _onStage = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final onStage = TickerMode.valuesOf(context).enabled;
    if (onStage == _onStage) return;
    _onStage = onStage;
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncVisible());
  }

  void _syncVisible() {
    if (mounted) {
      _visible.state =
          _onStage && ref.read(navIndexProvider) == HomeScreen.navIndex;
    }
  }

  void _leave() {
    ref.read(dropSelectionProvider.notifier).clear();
    ref.read(freshDropsProvider.notifier).clear();
  }

  @override
  void dispose() {
    if (_visible.mounted) _visible.state = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(navIndexProvider, (previous, next) {
      if (previous == HomeScreen.navIndex && next != HomeScreen.navIndex) {
        _leave();
      }
      _syncVisible();
    });
    final catalog = ref.watch(pluginContributionCatalogProvider);
    final drops = ref.watch(nativeSurfaceOwnerProvider('home.layout')) != null;
    final placementState = ref.watch(pluginPlacementsProvider);
    final placements = placementState.valueOrNull;
    final selecting = ref
        .watch(dropSelectionProvider)
        .ownedBy(DropSelection.homeScope);
    final cards = placements == null
        ? const <PluginWidgetRegistration>[]
        : [
            for (final id in placements.homeOrder)
              if (catalog.widget(id) case final widget?
                  when widget.enabled &&
                      placements.placements[id] ==
                          PluginPlacementLocation.homeCard &&
                      !placements.hiddenHome.contains(id))
                widget,
          ];
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
      for (final widget in cards)
        _PlacedPluginWidget(registration: widget, placements: placements!),
      if (placements != null && cards.isEmpty && composer == null)
        _PluginsOffPanel(catalog: catalog),
    ];
    final fill = panels.indexWhere(
      (panel) =>
          panel is _PlacedPluginWidget &&
          panel.registration.contribution.surface == 'home.drops',
    );

    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = _HomeColumns.isWide(constraints.maxWidth, panels);
              return ScreenScaffold(
                fill: wide,
                maxContentWidth: 1100,
                breadcrumbTrailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (drops)
                      ToolbarIconAction(
                        label: 'SEARCH',
                        icon: UpgradeIcons.search,
                        onTap: () {
                          _leave();
                          openItemSearch(context);
                        },
                      ),
                    if (drops) const SizedBox(width: Spacing.sm),
                    HomeActions(beforeOpen: _leave),
                  ],
                ),
                children: [
                  _HomeColumns(
                    wide: wide,
                    agentsKey: _agentsKey,
                    cardsKey: _cardsKey,
                    fill: fill < 0 ? null : fill,
                    children: panels,
                  ),
                ],
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
    required this.agentsKey,
    required this.cardsKey,
    required this.fill,
    required this.children,
  });

  static const _agentsWidth = 300.0;

  static const _minCardHeight = 240.0;

  static bool isWide(double width, List<Widget> children) =>
      width - 2 * Spacing.screenEdge >= 760 && children.isNotEmpty;

  final bool wide;
  final GlobalKey agentsKey;
  final GlobalKey cardsKey;

  final int? fill;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final agents = KeyedSubtree(key: agentsKey, child: const AgentsPanel());
    Widget cards([double? viewport]) => KeyedSubtree(
      key: cardsKey,
      child: _CardColumn(
        viewport: viewport,
        minFill: _minCardHeight,
        fill: fill,
        children: children,
      ),
    );
    if (!wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          agents,
          const SizedBox(height: Spacing.panelGap),
          cards(),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: _agentsWidth,
          child: SingleChildScrollView(child: agents),
        ),
        const SizedBox(width: Spacing.panelGap),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final height = math.max(constraints.maxHeight, _minCardHeight);
              return SingleChildScrollView(
                child: HomeCardViewport(height: height, child: cards(height)),
              );
            },
          ),
        ),
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
    child: NativeContributionSurface.widget(registration),
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

/// The promise is read off the plugin's own contributions, never written per plugin, so a
/// plugin the app has never heard of is described the same way as the bundled two.
class _PluginsOffPanel extends StatelessWidget {
  const _PluginsOffPanel({required this.catalog});

  final PluginContributionCatalog catalog;

  static String promise(PluginContributionOwner owner) => [
    for (final page in owner.pages)
      '${page.contribution.title.toUpperCase()} '
          '${page.contribution.defaultPinned ? 'TAB' : 'PAGE'}',
    for (final widget in owner.widgets)
      if (widget.contribution.locations.contains(
        PluginPlacementLocation.homeCard,
      ))
        '${widget.contribution.title.toUpperCase()} CARD'
      else if (widget.contribution.locations.contains(
        PluginPlacementLocation.homeComposer,
      ))
        '${widget.contribution.title.toUpperCase()} BAR',
  ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final off = [
      for (final owner in catalog.owners)
        if (!owner.plugin.enabled)
          if (promise(owner) case final words when words.isNotEmpty)
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
