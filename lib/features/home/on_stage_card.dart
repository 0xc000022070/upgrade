import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'package:upgrade/application/navigation.dart';

/// Raises [visible] while Home is the shown tab and lowers it once the last
/// card holding the same flag is gone.
class OnStageCard extends ConsumerStatefulWidget {
  const OnStageCard({super.key, required this.visible, required this.child});

  final StateProvider<bool> visible;
  final Widget child;

  @override
  ConsumerState<OnStageCard> createState() => _OnStageCardState();
}

class _OnStageCardState extends ConsumerState<OnStageCard> {
  static final _mounted = <StateProvider<bool>, int>{};
  late final StateProvider<bool> _provider;
  late final StateController<bool> _visible;
  bool _onStage = true;

  @override
  void initState() {
    super.initState();
    _provider = widget.visible;
    _mounted.update(_provider, (n) => n + 1, ifAbsent: () => 1);
    _visible = ref.read(_provider.notifier);
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
      _visible.state = _onStage && ref.read(navIndexProvider) == homeNavIndex;
    }
  }

  @override
  void dispose() {
    final (provider, visible) = (_provider, _visible);
    _mounted.update(provider, (n) => n - 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if ((_mounted[provider] ?? 0) > 0) return;
      if (visible.mounted) visible.state = false;
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(navIndexProvider, (_, _) => _sync());
    return widget.child;
  }
}
