import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/agents.dart';
import '../application/alerts.dart';
import '../data/enums.dart';
import '../data/repositories/host_repository.dart';
import '../features/agents/agents_screen.dart';
import '../platform/agent_watcher.dart';
import '../platform/alert_actions.dart';
import '../platform/alert_notifications.dart';

/// SPEC.md §39.31's wiring: what `main()` has to do before the first frame, and
/// the override that hands Home the watcher's snapshots instead of its own
/// poll.

/// Set when the process was started by an `OPEN` tap on an alert, so a cold
/// launch lands on the `AGENTS` route once there is a navigator to push it on.
bool _pendingOpen = false;

Future<void> initAlerts() async {
  await AgentWatcher.init();
  await AlertNotifications.initialize(
    onResponse: (response) => unawaited(handleAlertAction(response)),
    onBackgroundResponse: alertActionBackground,
  );
  final launch = await AlertNotifications.plugin
      .getNotificationAppLaunchDetails();
  if (launch?.didNotificationLaunchApp ?? false) {
    _pendingOpen =
        launch!.notificationResponse?.actionId == alertActionOpen ||
        launch.notificationResponse?.actionId == null;
  }
}

List<Override> alertOverrides() => [
  watcherFeedProvider.overrideWith(
    (ref) => AgentWatcher.feed(
      ref
          .watch(hostRepositoryProvider)
          .watchWithIntegration(IntegrationKind.herdr),
    ),
  ),
];

/// Keeps the foreground service in step with §39.31's two conditions and turns
/// an `OPEN` tap into a route.
///
/// A widget rather than a provider listener: the route needs a [BuildContext],
/// and the service has to stop when the app is disposed with `ALERTS` off.
class AlertsHost extends ConsumerStatefulWidget {
  const AlertsHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AlertsHost> createState() => _AlertsHostState();
}

class _AlertsHostState extends ConsumerState<AlertsHost> {
  /// The host set the service was last told to watch, or the empty string for
  /// "stopped". Two providers drive one reconciliation, and without this a
  /// change in either would restart a service already watching these hosts.
  String? _applied;

  @override
  void initState() {
    super.initState();
    alertOpenHandler = _open;
    // Both conditions in one place, so the two cannot drift out of step. In
    // `build` this was a side effect that ran again on every rebuild, including
    // the ones neither provider caused.
    ref.listenManual(watcherWantedProvider, (_, _) => _sync());
    ref.listenManual(
      herdrHostsProvider,
      (_, _) => _sync(),
      fireImmediately: true,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pendingOpen) {
        _pendingOpen = false;
        _open();
      }
    });
  }

  @override
  void dispose() {
    if (identical(alertOpenHandler, _open)) alertOpenHandler = null;
    super.dispose();
  }

  void _open() {
    if (!mounted) return;
    openAgents(context);
  }

  void _sync() {
    final wanted = ref.read(watcherWantedProvider);
    final hosts = ref.read(herdrHostsProvider).valueOrNull ?? const <Host>[];
    final next = wanted && hosts.isNotEmpty ? encodeWatcherHosts(hosts) : '';
    if (next == _applied) return;
    _applied = next;
    unawaited(next.isEmpty ? AgentWatcher.stop() : AgentWatcher.start(hosts));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
