import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/agents/agent_usage.dart';
import 'package:striked/application/agents/send_queue.dart';
import 'package:striked/application/home/compose_window.dart';
import 'package:striked/application/home/composer_focus.dart';
import 'package:striked/application/home/input_bar_holder.dart';
import 'package:striked/application/launcher/launcher_sends.dart';
import 'package:striked/application/navigation.dart';
import 'package:striked/application/prompt/prompt_target.dart';
import 'package:striked/features/agents/agents_screen.dart';
import 'package:striked/features/agents/sent_screen.dart';
import 'package:striked/features/home/agent_mark.dart';
import 'package:striked/features/home/bar_window.dart';
import 'package:striked/features/home/compose_sheet.dart';
import 'package:striked/features/home/home_screen.dart';
import 'package:striked/features/home/usage_panel.dart';
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
  String? _usage;

  @override
  void initState() {
    super.initState();
    ref.listenManual(inputBarHolderProvider, (_, _) => _writeBar());
    ref.listenManual(composerSummaryProvider, (_, _) => _writeBar());
    _writeBar();
    ref.listenManual<LauncherTarget?>(
      launcherTargetProvider,
      (_, target) => unawaited(
        LauncherWidget.setTarget(target?.directory, target?.detail),
      ),
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
    ref.listenManual<List<HostUsage>>(usageFeedProvider, (_, next) {
      final accounts = launcherUsage(next);
      final written = jsonEncode(accounts);
      if (written == _usage) return;
      _usage = written;
      unawaited(LauncherWidget.setUsage(accounts));
    });
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

  void _openWindow(Route<void> route) {
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) return;
    _dropWindow();
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
    switch (tap.open) {
      case LauncherOpen.sheet:
        return _openWindow(composeWindowRoute());
      case LauncherOpen.barSheet:
        return _openWindow(launcherWindowRoute(const BarWindow()));
      default:
    }
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
      case LauncherOpen.home:
        ref.read(navIndexProvider.notifier).state = HomeScreen.navIndex;
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
      case LauncherOpen.barSheet:
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

List<Map<String, Object?>> launcherUsage(List<HostUsage> usages) => [
  for (final (:host, :usage) in usages)
    {
      'name': usage.plan == null
          ? agentMarkName(usage.agent)
          : '${agentMarkName(usage.agent)} · ${usage.plan!.toUpperCase()}',
      'host': host.name.toUpperCase(),
      'captured': ?usage.captured?.millisecondsSinceEpoch,
      'windows': [
        if (usage.limits.firstOrNull case final limit?)
          for (final window in limit.windows)
            {
              'label': windowLabel(window.minutes),
              'used': window.usedPercent.round(),
              'share': window.usedPercent,
              'minutes': ?window.minutes,
              'resets': ?window.resetsAt?.millisecondsSinceEpoch,
              'hit': limitHit(limit, window),
            },
      ],
    },
];
