import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/agents.dart';
import '../application/alerts.dart';
import '../application/pin_alerts.dart';
import '../data/enums.dart';
import '../data/repositories/host_repository.dart';
import '../features/agents/agents_screen.dart';
import '../features/shell/shell_sheet.dart';
import '../platform/agent_watcher.dart';
import '../platform/alert_actions.dart';
import '../platform/alert_notifications.dart';
import '../platform/pin_notifications.dart';

/// The alert wiring: what `main()` has to do before the first frame, and the
/// override that hands Home the watcher's snapshots instead of its own poll.

/// Set when the process was started by an `OPEN` tap on an alert, so a cold
/// launch lands on the `AGENTS` route once there is a navigator to push it on.
bool _pendingOpen = false;

/// The host of an `AUTHORIZATION REQUIRED` tap that arrived the same way, so
/// the launch lands on that host's shell instead.
String? _pendingPinHost;

/// Parks an `OPEN` that arrived before [AlertsHost] existed.
///
/// The splash owns the screen for the first ~1.8s of a cold start and
/// [AlertsHost] is inside the route it pushes, so the tap that launched the app
/// lands in that window with no handler installed — `handleAlertAction` would
/// drop it and the launch would end on Home. The splash installs this instead,
/// which is the same flag a launch through `getNotificationAppLaunchDetails`
/// sets, and [AlertsHost] drains it on its first frame either way.
void deferAlertOpen() => _pendingOpen = true;

void deferPinOpen(String hostId) => _pendingPinHost = hostId;

Future<void> initAlerts() async {
  await AgentWatcher.init();
  await AlertNotifications.initialize(
    onResponse: (response) => unawaited(handleAlertAction(response)),
    onBackgroundResponse: alertActionBackground,
  );
  await PinNotifications.createChannel();
  final launch = await AlertNotifications.plugin
      .getNotificationAppLaunchDetails();
  if (launch?.didNotificationLaunchApp ?? false) {
    final response = launch!.notificationResponse;
    final pinHost = pinPayloadHost(response?.payload);
    if (pinHost != null) {
      _pendingPinHost = pinHost;
    } else {
      _pendingOpen =
          response?.actionId == alertActionOpen || response?.actionId == null;
    }
  }
}

List<Override> alertOverrides() => [
  agentRetryProvider.overrideWith((ref) {
    final foreground = foregroundAgentRetry(ref);
    return (host) async {
      if (!await AgentWatcher.running) return foreground(host);
      return AgentWatcher.retry(host);
    };
  }),
  watcherFeedProvider.overrideWith(
    (ref) => AgentWatcher.feed(
      ref
          .watch(hostRepositoryProvider)
          .watchWithIntegration(IntegrationKind.herdr),
    ),
  ),
];

/// Keeps the foreground service in step with the two conditions that ask for
/// it and turns an `OPEN` tap into a route.
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
    pinOpenHandler = _openShell;
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
      final pinHost = _pendingPinHost;
      if (pinHost != null) {
        _pendingPinHost = null;
        _openShell(pinHost);
      }
    });
  }

  @override
  void dispose() {
    if (identical(alertOpenHandler, _open)) alertOpenHandler = null;
    if (identical(pinOpenHandler, _openShell)) pinOpenHandler = null;
    super.dispose();
  }

  void _open() {
    if (!mounted) return;
    openAgents(context);
  }

  /// The shell of the host the notification named, where the sheet is. A host
  /// that has since been deleted opens nothing: the request went with it.
  void _openShell(String hostId) {
    unawaited(() async {
      final hosts = await ref.read(hostRepositoryProvider).all();
      final host = hosts.where((host) => host.id == hostId).firstOrNull;
      if (host == null || !mounted) return;
      openHostShell(context, host);
    }());
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
