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
import '../../design/tokens.dart';
import '../../platform/plugins/contributions.dart';
import '../screen_scaffold.dart';
import '../tasks/selection_bar.dart';
import '../plugins/plugin_management_screen.dart';
import 'agents_panel.dart';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncVisible());
  }

  void _syncVisible() {
    if (mounted) {
      _visible.state = ref.read(navIndexProvider) == HomeScreen.navIndex;
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

    return Column(
      children: [
        Expanded(
          child: ScreenScaffold(
            breadcrumbTrailing: HomeActions(beforeOpen: _leave),
            children: [
              PanelStack(
                children: [
                  const AgentsPanel(),
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
                            onTap: () =>
                                ref.invalidate(pluginPlacementsProvider),
                          ),
                        ],
                      ),
                    ),
                  for (final widget in cards)
                    _PlacedPluginWidget(
                      registration: widget,
                      placements: placements!,
                    ),
                  if (placements != null && cards.isEmpty && composer == null)
                    _PluginsOffPanel(catalog: catalog),
                ],
              ),
            ],
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
