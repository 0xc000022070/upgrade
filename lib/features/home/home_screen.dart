import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../application/drop_selection.dart';
import '../../application/fresh_drops.dart';
import '../../application/navigation.dart';
import '../../application/native_plugins.dart';
import '../../application/plugin_placements.dart';
import '../../application/providers.dart';
import '../../data/repositories/plugin_placement_repository.dart';
import '../../design/components/panel.dart';
import '../../design/components/panel_text_action.dart';
import '../../design/components/solid_action_bar.dart';
import '../../design/typography.dart';
import '../../platform/plugins/contributions.dart';
import '../screen_scaffold.dart';
import '../tasks/selection_bar.dart';
import '../plugins/plugin_management_screen.dart';
import 'agents_panel.dart';
import 'home_actions.dart';
import 'home_feedback.dart';

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
  Timer? _undoTimer;

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

  void _holdUndo(String taskId) {
    _undoTimer?.cancel();
    _undoTimer = Timer(const Duration(seconds: 30), () {
      if (mounted && ref.read(homeUndoTaskProvider) == taskId) {
        ref.read(homeUndoTaskProvider.notifier).state = null;
      }
    });
  }

  Future<void> _undoDone() async {
    final taskId = ref.read(homeUndoTaskProvider);
    if (taskId == null) return;
    _undoTimer?.cancel();
    ref.read(homeUndoTaskProvider.notifier).state = null;
    await ref.read(taskRepositoryProvider).setDone(taskId, false);
  }

  @override
  void dispose() {
    _undoTimer?.cancel();
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
    ref.listen<String?>(homeUndoTaskProvider, (_, next) {
      if (next != null) _holdUndo(next);
    });
    final catalog = ref.watch(pluginContributionCatalogProvider);
    final placementState = ref.watch(pluginPlacementsProvider);
    final placements = placementState.valueOrNull;
    final selecting = ref
        .watch(dropSelectionProvider)
        .ownedBy(DropSelection.homeScope);
    final undoTaskId = ref.watch(homeUndoTaskProvider);
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
                    const Panel(
                      title: '[ PLUGINS ]',
                      child: Text(
                        'LOADING HOME LAYOUT',
                        style: DazzleText.rowSubtitle,
                      ),
                    ),
                  if (placementState.hasError)
                    Panel(
                      title: '[ PLUGIN LAYOUT ERROR ]',
                      bodyPadding: panelRowsPadding,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            _placementErrorMessage(placementState.error),
                            style: DazzleText.rowSubtitle,
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
                    Panel(
                      title: '[ PLUGINS ]',
                      bodyPadding: panelRowsPadding,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'ADD HOME CARDS, AN INPUT BAR, AND TOOL PAGES.',
                            style: DazzleText.rowSubtitle,
                          ),
                          PanelTextAction(
                            label: 'MANAGE PLUGINS',
                            onTap: () => openPluginManagement(context),
                          ),
                        ],
                      ),
                    ),
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
        else if (undoTaskId != null)
          SolidActionBar(label: 'DONE · UNDO', onTap: _undoDone)
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
            child: Text(reason, style: DazzleText.rowSubtitle),
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
