import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/agents.dart';
import '../../application/navigation.dart';
import '../../application/native_plugins.dart';
import '../../design/components/panel.dart';
import '../screen_scaffold.dart';
import '../settings/settings_screen.dart';
import 'agents_panel.dart';

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

  @override
  void dispose() {
    _visible.state = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(navIndexProvider, (_, _) => _syncVisible());
    return NativeSurface(
      'home.layout',
      fallback: ScreenScaffold(
        breadcrumbTrailing: PanelAffordance(
          'SYS',
          showIcon: false,
          onTap: () => openSettings(context),
        ),
        children: const [AgentsPanel()],
      ),
    );
  }
}
