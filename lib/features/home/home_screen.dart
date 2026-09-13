import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../application/drop_selection.dart';
import '../../application/fresh_drops.dart';
import '../../application/navigation.dart';
import '../../application/providers.dart';
import '../../data/views.dart';
import '../../design/colors.dart';
import '../../design/components/list_row.dart';
import '../../design/components/panel.dart';
import '../../design/effects/glitch.dart';
import '../../design/icons/dazzle_icon.dart';
import '../../design/icons/dazzle_icons.dart';
import '../../design/spacing.dart';
import '../screen_scaffold.dart';
import '../settings/settings_screen.dart';
import '../tasks/drops_panel.dart';
import '../tasks/item_sheet.dart';
import '../tasks/selection_bar.dart';
import 'agents_panel.dart';
import 'capture_bar.dart';

/// What is flagged, what is
/// moving, what has not been filed yet. BLOCKED and RECENT are gone — a blocked
/// item still says so on its own row wherever it lives, and the activity stream
/// is still written, just not displayed.
///
/// The PROJECTS panel is gone with it. Projects have a tab of
/// their own and the panel was the same list a tap away, saying it twice; HOME
/// is AGENTS, NEXT ACTION, DROPS and nothing else.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  /// The tab this screen is, which is what decides whether it is on screen.
  static const navIndex = 0;

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// Captured while the element is alive. `ref` throws once dispose runs, and
  /// the flag has to be put down on the way out or a Home that is gone leaves
  /// the poller running.
  late final _visible = ref.read(homeAgentsVisibleProvider.notifier);

  /// A landed capture tears the panel it lands in. The nav icon takes the
  /// same event, but the IME covers HOME's bottom edge at the moment
  /// the row arrives, so the strip is the half of it the user can see.
  final _landing = GlitchController();

  @override
  void initState() {
    super.initState();
    // The panel polls only while Home is in front. Mounting is not the
    // signal — the shell keeps every tab mounted in an IndexedStack — so the
    // selected index is, and the first sync waits for the frame that is
    // building right now to finish.
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncVisible());
  }

  @override
  void dispose() {
    _visible.state = false;
    _landing.dispose();
    super.dispose();
  }

  void _syncVisible() {
    if (!mounted) return;
    _visible.state = ref.read(navIndexProvider) == HomeScreen.navIndex;
  }

  /// No selection survives a navigation. The tab shell closes the mode
  /// on a tab switch; a route pushed over HOME leaves the tab where it is, so
  /// every door of that kind closes it here instead. The fresh set is
  /// on the same door: leaving the screen is what ends both.
  void _leaving(VoidCallback go) {
    ref.read(dropSelectionProvider.notifier).clear();
    ref.read(freshDropsProvider.notifier).clear();
    go();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(navIndexProvider, (_, _) => _syncVisible());
    final nextAction = ref.watch(nextActionProvider);
    final drops = ref.watch(dropsProvider);

    final selecting = ref
        .watch(dropSelectionProvider)
        .ownedBy(DropSelection.homeScope);

    final next = nextAction.valueOrNull;

    return Column(
      children: [
        Expanded(
          child: ScreenScaffold(
            // `TODAY_` is gone. The breadcrumb and its SYS door stay.

            // The door to settings. Text only, in the slot a project's EDIT
            // uses: a glyph for it would be a new icon, and icons are not this
            // side's to invent.
            breadcrumbTrailing: PanelAffordance(
              'SYS',
              showIcon: false,
              onTap: () => _leaving(() => openSettings(context)),
            ),
            children: [
              PanelStack(
                children: [
                  // The order: AGENTS, NEXT ACTION, DROPS. BLOCKED and
                  // RECENT are still gone, and PROJECTS is the tab.
                  const AgentsPanel(),
                  // No suggestion fallback, so with nothing flagged
                  // there is no panel. An empty NEXT ACTION frame would be the
                  // screen asking a question it cannot answer.
                  if (next != null)
                    Panel(
                      title: 'NEXT ACTION',
                      affordance: const PanelAffordance('1', showIcon: false),
                      bodyPadding: panelRowsPadding,
                      child: _NextActionRow(
                        task: next,
                        onOpen: () =>
                            _leaving(() => openItemSheet(context, next.taskId)),
                      ),
                    ),
                  DropsPanel(
                    scope: DropSelection.homeScope,
                    drops: drops,
                    landing: _landing,
                  ),
                ],
              ),
            ],
          ),
        ),
        // The mode's bar takes the capture bar's slot rather than
        // sitting on a strip that scrolls away. The capture bar is not drawn
        // while it is up and comes back when the mode ends.
        if (selecting)
          const SelectionBar(scope: DropSelection.homeScope)
        else
          CaptureBar(scope: DropSelection.homeScope, landing: _landing),
      ],
    );
  }
}

/// The one row on HOME that is not a list item: the primary action has to
/// be findable in one second, so it takes the accent arrow and the 13px title.
class _NextActionRow extends StatelessWidget {
  const _NextActionRow({required this.task, required this.onOpen});

  final NextAction task;

  /// The sheet is a route like any other door out of HOME, so opening it runs
  /// the screen's own selection clear on the way.
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return ListRow(
      leading: const DazzleIcon(
        DazzleIcons.forward,
        size: IconSizes.glyph,
        color: DazzleColors.accent,
      ),
      title: task.title,
      subtitle: task.projectName,
      lead: true,
      decode: true,
      // Every row opens the quick view, and this one most of all — a
      // flagged item nothing responds to is the mock the user complained about.
      onTap: onOpen,
      onLongPress: onOpen,
    );
  }
}
