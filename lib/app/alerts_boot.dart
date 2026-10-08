import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/agents.dart';
import '../application/alerts.dart';
import '../application/pin_alerts.dart';
import '../features/agents/agents_screen.dart';
import '../features/shell/shell_sheet.dart';
import '../platform/agent_watcher.dart';
import '../platform/alert_actions.dart';
import '../platform/alert_notifications.dart';
import '../platform/herdr_client.dart';
import '../platform/host_links.dart';
import '../platform/pin_notifications.dart';

/// Set when the process was started by an `OPEN` tap on an alert, so a cold launch
/// lands on the `AGENTS` route once there is a navigator to push it on.
bool _pendingOpen = false;

/// The host of an `AUTHORIZATION REQUIRED` tap that arrived the same way.
String? _pendingPinHost;

void deferAlertOpen() => _pendingOpen = true;

void deferPinOpen(String hostId) => _pendingPinHost = hostId;

Future<void> initAlerts() async {
  // Boot runs before there is a navigator, so a tap answered in here has nothing to push
  // on. Parked in the flags [AlertsHost] drains once it mounts over them.
  alertOpenHandler = deferAlertOpen;
  pinOpenHandler = deferPinOpen;
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
    return (host, {source = AgentSource.herdr}) async {
      if (!await AgentWatcher.running) return foreground(host, source: source);
      return AgentWatcher.retry(host, source: source);
    };
  }),
  watcherFeedProvider.overrideWith(
    (ref) => AgentWatcher.feed(
      watchAgentChannels(ref.watch(hostRepositoryProvider)),
      running: AgentWatcher.serviceLiveness(
        visible: ref.watch(appVisibleProvider.notifier).readings,
      ),
    ),
  ),
];

/// A widget rather than a provider listener: the route needs a [BuildContext], and the
/// service has to stop when the app is disposed with `ALERTS` off.
class AlertsHost extends ConsumerStatefulWidget {
  const AlertsHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AlertsHost> createState() => _AlertsHostState();
}

class _AlertsHostState extends ConsumerState<AlertsHost> {
  /// The hosts and kinds the service was last told to watch, or the empty string for
  /// "stopped". Two providers drive one reconciliation, and without this a change in either
  /// would restart a service already watching these hosts for these kinds.
  String? _applied;

  HostLinks? _links;

  @override
  void initState() {
    super.initState();
    alertOpenHandler = _open;
    pinOpenHandler = _openShell;
    alertLinks = _links = ref.read(hostLinksProvider);
    // Both conditions in one place. In `build` this was a side effect that ran again on
    // every rebuild, including the ones neither provider caused.
    ref.listenManual(alertsWantedProvider, (_, _) => _sync());
    ref.listenManual(
      agentChannelsProvider,
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
    if (identical(alertLinks, _links)) alertLinks = null;
    super.dispose();
  }

  void _open() {
    if (!mounted) return;
    openAgents(context);
  }

  /// A host that has since been deleted opens nothing: the request went with it.
  void _openShell(String hostId) {
    unawaited(() async {
      final hosts = await ref.read(hostRepositoryProvider).all();
      final host = hosts.where((host) => host.id == hostId).firstOrNull;
      if (host == null || !mounted) return;
      openHostShell(context, host);
    }());
  }

  void _sync() {
    final kinds = ref.read(alertsWantedProvider);
    final (:hosts, :sources) = watcherHostsOf(
      ref.read(agentChannelsProvider).valueOrNull ?? const [],
    );
    final next = kinds.isEmpty || hosts.isEmpty
        ? ''
        : '${encodeWatcherKinds(kinds)}'
              '${encodeWatcherHosts(hosts, sources: sources)}';
    if (next == _applied) return;
    _applied = next;
    unawaited(
      next.isEmpty
          ? AgentWatcher.stop()
          : AgentWatcher.start(hosts, kinds, sources: sources),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
