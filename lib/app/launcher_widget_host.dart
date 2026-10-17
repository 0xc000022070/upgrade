import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/agents/send_queue.dart';
import 'package:striked/application/home/compose_window.dart';
import 'package:striked/application/home/composer_focus.dart';
import 'package:striked/application/home/input_bar_holder.dart';
import 'package:striked/application/launcher/launcher_sends.dart';
import 'package:striked/application/navigation.dart';
import 'package:striked/application/prompt/prompt_target.dart';
import 'package:striked/features/agents/agents_screen.dart';
import 'package:striked/features/agents/sent_screen.dart';
import 'package:striked/features/home/compose_sheet.dart';
import 'package:striked/features/home/home_screen.dart';
import 'package:striked/features/plugins/plugin_management_screen.dart';
import 'package:striked/features/settings/settings_screen.dart';
import 'package:striked/platform/launcher_widget/launcher_widget.dart';

class LauncherWidgetHost extends ConsumerStatefulWidget {
  const LauncherWidgetHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<LauncherWidgetHost> createState() => _LauncherWidgetHostState();
}

class _LauncherWidgetHostState extends ConsumerState<LauncherWidgetHost> {
  final _started = <String, DateTime>{};
  Route<void>? _window;

  @override
  void initState() {
    super.initState();
    ref.listenManual(inputBarHolderProvider, (_, _) => _writeBar());
    ref.listenManual(composerSummaryProvider, (_, _) => _writeBar());
    _writeBar();
    ref.listenManual<String?>(
      promptSummaryProvider,
      (_, label) => unawaited(LauncherWidget.setTarget(label)),
      fireImmediately: true,
    );
    ref.listenManual<List<PendingSend>>(sendQueueProvider, (previous, next) {
      final rows = launcherRowsMoved(
        previous ?? const [],
        next,
        _started,
        DateTime.now(),
      );
      for (final row in rows) {
        unawaited(LauncherWidget.putSend(row));
      }
    });
    unawaited(
      LauncherWidget.settleSends(
        ref.read(sendQueueProvider).map(launcherSendId),
      ),
    );
    LauncherWidget.onOpened((
      opened: () => unawaited(_take()),
      app: _dropWindow,
      composeGone: _dropWindow,
    ));
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

  void _openWindow() {
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) return;
    _dropWindow();
    final route = composeWindowRoute();
    _window = route;
    ref.read(composeWindowProvider.notifier).state = true;
    unawaited(navigator.push(route));
  }

  void _dropWindow() {
    final route = _window;
    _window = null;
    if (route != null && route.isActive) route.navigator?.removeRoute(route);
    if (mounted) ref.read(composeWindowProvider.notifier).state = false;
  }

  Future<void> _take() async {
    final tap = await LauncherWidget.take();
    if (tap == null || !mounted) return;
    if (tap.open == LauncherOpen.sheet) return _openWindow();
    _dropWindow();
    var guarded = false;
    rootNavigatorKey.currentState?.popUntil((route) {
      guarded =
          !route.isFirst &&
          route.popDisposition == RoutePopDisposition.doNotPop;
      return route.isFirst || guarded;
    });
    if (guarded) return;
    switch (tap.open) {
      case LauncherOpen.agents:
        openAgents(context);
      case LauncherOpen.plugins:
        openPluginManagement(context);
      case LauncherOpen.settings:
        openSettings(context);
      case LauncherOpen.compose:
        unawaited(showCompose(context));
      case LauncherOpen.run:
        final send = tap.send;
        if (send == null) return openSent(context);
        openRun(context, send);
      case LauncherOpen.sent:
        openSent(context);
      case LauncherOpen.sheet:
        break;
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
