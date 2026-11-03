import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'package:upgrade/application/agents/agent_usage.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/navigation.dart';
import 'package:upgrade/features/home/agents_panel.dart';
import 'package:upgrade/features/home/home_screen.dart';
import 'package:upgrade/features/home/usage_panel.dart';

class AgentsCard extends ConsumerStatefulWidget {
  const AgentsCard({super.key});

  @override
  ConsumerState<AgentsCard> createState() => _AgentsCardState();
}

class _AgentsCardState extends ConsumerState<AgentsCard> {
  static var _mounted = 0;
  late final StateController<bool> _visible;
  late final StateController<bool> _usageVisible;
  bool _onStage = true;

  @override
  void initState() {
    super.initState();
    _mounted++;
    _visible = ref.read(homeAgentsVisibleProvider.notifier);
    _usageVisible = ref.read(homeUsageVisibleProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final onStage = TickerMode.valuesOf(context).enabled;
    if (onStage == _onStage) return;
    _onStage = onStage;
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  void _sync() {
    if (mounted) {
      _visible.state = _usageVisible.state =
          _onStage && ref.read(navIndexProvider) == HomeScreen.navIndex;
    }
  }

  @override
  void dispose() {
    _mounted--;
    final (visible, usageVisible) = (_visible, _usageVisible);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_mounted > 0) return;
      if (visible.mounted) visible.state = false;
      if (usageVisible.mounted) usageVisible.state = false;
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(navIndexProvider, (_, _) => _sync());
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [AgentsPanel(), UsagePanel()],
    );
  }
}
