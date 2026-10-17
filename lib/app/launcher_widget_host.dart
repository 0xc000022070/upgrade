import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/home/composer_focus.dart';
import 'package:striked/application/home/input_bar_holder.dart';
import 'package:striked/application/navigation.dart';
import 'package:striked/features/agents/agents_screen.dart';
import 'package:striked/features/home/home_screen.dart';
import 'package:striked/features/plugins/plugin_management_screen.dart';
import 'package:striked/platform/launcher_widget/launcher_widget.dart';

class LauncherWidgetHost extends ConsumerStatefulWidget {
  const LauncherWidgetHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<LauncherWidgetHost> createState() => _LauncherWidgetHostState();
}

class _LauncherWidgetHostState extends ConsumerState<LauncherWidgetHost> {
  @override
  void initState() {
    super.initState();
    ref.listenManual(inputBarHolderProvider, (_, _) => _writeBar());
    ref.listenManual(composerSummaryProvider, (_, _) => _writeBar());
    _writeBar();
    LauncherWidget.onOpened(() => unawaited(_take()));
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_take()));
  }

  void _writeBar() {
    if (ref.read(inputBarHolderProvider) case AsyncData(:final value)) {
      final summary = value == null ? null : ref.read(composerSummaryProvider);
      unawaited(LauncherWidget.setBar(value?.contribution.title, summary));
    }
  }

  @override
  void dispose() {
    LauncherWidget.onOpened(null);
    super.dispose();
  }

  Future<void> _take() async {
    final open = await LauncherWidget.take();
    if (open == null || !mounted) return;
    var guarded = false;
    rootNavigatorKey.currentState?.popUntil((route) {
      guarded =
          !route.isFirst &&
          route.popDisposition == RoutePopDisposition.doNotPop;
      return route.isFirst || guarded;
    });
    if (guarded) return;
    switch (open) {
      case LauncherOpen.agents:
        openAgents(context);
      case LauncherOpen.plugins:
        openPluginManagement(context);
      case LauncherOpen.inputBar:
        ref.read(navIndexProvider.notifier).state = HomeScreen.navIndex;
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
        ref.read(composerFocusRequestProvider.notifier).request();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
