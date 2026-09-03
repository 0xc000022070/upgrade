import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../application/agents.dart';
import '../application/alerts.dart';
import '../data/repositories/host_repository.dart';
import 'alert_notifications.dart';
import 'herdr_client.dart';
import 'keys.dart';

/// SPEC.md §39.31's watcher: the foreground service that holds one `agent
/// watch` connection per HERDR host for as long as `[ ALERTS ]` is on.
///
/// The service runs its own isolate. Nothing in this file may reach for a
/// provider, the database or a widget — the isolate has none of them. What it
/// needs travels through [FlutterForegroundTask.saveData] (the host rows) and
/// the keystore (the secrets, which never leave it).

/// How often the feed asks Android whether the service is still there. Only
/// the ending nobody announces needs it — a service the system killed — so the
/// period is §39.20's own cadence rather than anything tighter.
const watcherLivenessPeriod = Duration(seconds: 10);

/// The service's own notification, not the alerts'. §39.31 wants it silent and
/// at the bottom of the shade.
const watcherChannelId = 'watcher';
const watcherChannelName = 'Agent watcher';
const watcherNotificationTitle = 'HOTLINE';

const _hostsKey = 'hotline.watcher.hosts';

/// The evidence seam. With `--dart-define=HOTLINE_FAKE_WATCH=true` the watcher
/// never dials: each host's stream is a canned pair of snapshots, which is what
/// produces §39.31's alert on an emulator that has no key on the host.
const _fakeWatch = bool.fromEnvironment('HOTLINE_FAKE_WATCH');

String encodeWatcherHosts(List<Host> hosts) => jsonEncode([
  for (final host in hosts)
    {
      'id': host.id,
      'name': host.name,
      'address': host.address,
      'port': host.port,
      'user': host.user,
      'key_id': host.keyId,
    },
]);

List<Host> decodeWatcherHosts(String? raw) {
  if (raw == null || raw.isEmpty) return const [];
  try {
    final json = jsonDecode(raw);
    if (json is! List<Object?>) return const [];
    return [
      for (final row in json)
        if (row is Map<String, Object?>)
          Host(
            id: row['id']! as String,
            name: row['name']! as String,
            address: row['address']! as String,
            port: row['port']! as int,
            user: row['user']! as String,
            keyId: row['key_id']! as String,
          ),
    ];
  } catch (_) {
    return const [];
  }
}

/// The main isolate's half: start, stop and re-feed the service.
class AgentWatcher {
  const AgentWatcher._();

  static Future<void> init() async {
    // The service isolate's [FlutterForegroundTask.sendDataToMain] posts to a
    // port this registers under a name. Without it every report is sent into
    // nothing: the callbacks [taskData] adds are held, and nobody ever calls
    // them, so §39.31's "Home reads its snapshots" is a stream that stays empty
    // for the life of the process.
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: watcherChannelId,
        channelName: watcherChannelName,
        // §39.31: "a persistent notification at minimum importance, silent".
        channelImportance: NotificationChannelImportance.MIN,
        priority: NotificationPriority.MIN,
        playSound: false,
        enableVibration: false,
        showWhen: false,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        // The watcher is woken by its own ssh streams, not by a timer.
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
        // §39.31: "It survives the activity being swiped away."
        stopWithTask: false,
        allowAutoRestart: true,
      ),
    );
  }

  static Future<bool> get running => FlutterForegroundTask.isRunningService;

  /// §39.31: the toggle asks for the notification permission when it is turned
  /// on, and goes back off when the OS refuses.
  static Future<bool> requestPermission() async {
    final current = await FlutterForegroundTask.checkNotificationPermission();
    if (current == NotificationPermission.granted) return true;
    final asked = await FlutterForegroundTask.requestNotificationPermission();
    return asked == NotificationPermission.granted;
  }

  static Future<void> start(List<Host> hosts) async {
    await FlutterForegroundTask.saveData(
      key: _hostsKey,
      value: encodeWatcherHosts(hosts),
    );
    if (await FlutterForegroundTask.isRunningService) {
      FlutterForegroundTask.sendDataToTask(_reloadHosts);
      return;
    }
    final result = await FlutterForegroundTask.startService(
      serviceTypes: const [ForegroundServiceTypes.specialUse],
      notificationTitle: watcherNotificationTitle,
      notificationText: watcherNotificationText(const []),
      callback: agentWatcherEntry,
    );
    if (result is ServiceRequestFailure) {
      debugPrint('hotline.herdr watcher: ${result.error}');
    }
  }

  static Future<void> setHosts(List<Host> hosts) async {
    await FlutterForegroundTask.saveData(
      key: _hostsKey,
      value: encodeWatcherHosts(hosts),
    );
    if (await FlutterForegroundTask.isRunningService) {
      FlutterForegroundTask.sendDataToTask(_reloadHosts);
    }
  }

  static Future<void> stop() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
    // Said even when nothing was running: [_sync] calls stop for every state
    // that is not "on with a host", and a feed still holding the last report
    // has to be cleared by whichever of them it lands in.
    _stops.add(null);
  }

  /// Every [stop], for [serviceLiveness] to pass on. Broadcast because a
  /// process may hold more than one feed over its life and none of them is the
  /// one that called stop.
  static final _stops = StreamController<void>.broadcast();

  /// False once no foreground service is running. [stop] says so at once; the
  /// poll is there for the other ending, a service Android killed or that
  /// died, which tells nobody.
  static Stream<bool> serviceLiveness({
    Duration period = watcherLivenessPeriod,
  }) {
    late StreamController<bool> controller;
    StreamSubscription<void>? stops;
    Timer? timer;
    var live = true;
    controller = StreamController<bool>(
      onListen: () {
        stops = _stops.stream.listen((_) => controller.add(false));
        timer = Timer.periodic(period, (_) async {
          final running = await FlutterForegroundTask.isRunningService;
          if (live) controller.add(running);
        });
      },
      onCancel: () async {
        live = false;
        timer?.cancel();
        await stops?.cancel();
      },
    );
    return controller.stream;
  }

  /// What the service isolate sends the main one, as a stream. The plugin
  /// offers a callback pair; [feed] wants something a test can hand a fake of.
  static Stream<Object> taskData() {
    late StreamController<Object> controller;
    void onData(Object data) => controller.add(data);
    controller = StreamController<Object>(
      onListen: () => FlutterForegroundTask.addTaskDataCallback(onData),
      onCancel: () => FlutterForegroundTask.removeTaskDataCallback(onData),
    );
    return controller.stream;
  }

  /// The service's reports, folded into the panel state Home reads. Null until
  /// the first report and null again once the service is gone, which is what
  /// hands Home back to §39.20's own poll at both ends.
  ///
  /// Both sources are arguments so the fold can be exercised without the
  /// plugin; both default to it.
  static Stream<AgentPanelState?> feed(
    Stream<List<Host>> hosts, {
    Stream<Object>? data,
    Stream<bool>? running,
  }) {
    final controller = StreamController<AgentPanelState?>();
    final reports = <String, WatcherReport>{};
    final subscriptions = <StreamSubscription<Object?>>[];
    var known = <Host>[];

    void emit() {
      if (reports.isEmpty) {
        controller.add(null);
        return;
      }
      controller.add(
        AgentPanelState([
          for (final host in known)
            if (reports[host.id] case final report?) report.toOutcome(host),
        ]),
      );
    }

    controller
      ..onListen = () {
        subscriptions.add(
          hosts.listen((list) {
            known = list;
            reports.removeWhere(
              (hostId, _) => !list.any((host) => host.id == hostId),
            );
            emit();
          }),
        );
        subscriptions.add(
          (data ?? taskData()).listen((message) {
            final report = _decodeReport(message);
            if (report == null) return;
            reports[report.hostId] = report;
            emit();
          }),
        );
        subscriptions.add(
          (running ?? serviceLiveness()).listen((alive) {
            if (alive || reports.isEmpty) return;
            // Nothing stands behind the last report any more. Keeping it would
            // freeze Home on the watcher's final word, and `onDestroy` unwinds
            // every host loop, so that word can be a retry line for a host that
            // is perfectly fine.
            reports.clear();
            emit();
          }),
        );
        emit();
      }
      ..onCancel = () async {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        subscriptions.clear();
      };
    return controller.stream;
  }
}

const _reloadHosts = 'reload-hosts';

WatcherReport? _decodeReport(Object data) {
  if (data is! String) return null;
  try {
    final json = jsonDecode(data);
    if (json is! Map<String, Object?>) return null;
    return WatcherReport.fromJson(json);
  } catch (_) {
    return null;
  }
}

@pragma('vm:entry-point')
void agentWatcherEntry() {
  FlutterForegroundTask.setTaskHandler(AgentWatcherHandler());
}

class AgentWatcherHandler extends TaskHandler {
  AgentWatcherHandler({Ed25519Keys? keys, HerdrClient? client})
    : _keys = keys ?? const Ed25519Keys(SecurePrivateKeyStore()),
      _client = client ?? const HerdrClient(keepAlive: watcherKeepAlive);

  final Ed25519Keys _keys;
  final HerdrClient _client;

  final BlockedEdges _edges = BlockedEdges();
  final Map<String, _HostLoop> _loops = {};
  final Map<String, WatcherReport> _reports = {};
  List<Host> _hosts = const [];

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) =>
      _reloadFromStore();

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  void onReceiveData(Object data) {
    if (data == _reloadHosts) unawaited(_reloadFromStore());
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    for (final loop in _loops.values.toList()) {
      await loop.stop();
    }
    _loops.clear();
  }

  Future<void> _reloadFromStore() async {
    final raw = await FlutterForegroundTask.getData<String>(key: _hostsKey);
    await _setHosts(decodeWatcherHosts(raw));
  }

  Future<void> _setHosts(List<Host> hosts) async {
    _hosts = hosts;
    final wanted = {for (final host in hosts) host.id: host};
    for (final id in _loops.keys.toList()) {
      if (wanted.containsKey(id)) continue;
      await _loops.remove(id)!.stop();
      _reports.remove(id);
    }
    for (final host in hosts) {
      final existing = _loops[host.id];
      if (existing != null && existing.sameHost(host)) continue;
      await existing?.stop();
      _loops[host.id] = _HostLoop(
        host: host,
        keys: _keys,
        client: _client,
        edges: _edges,
        onReport: _publish,
      )..start();
    }
    _redrawPersistent();
  }

  void _publish(WatcherReport report) {
    _reports[report.hostId] = report;
    FlutterForegroundTask.sendDataToMain(jsonEncode(report.toJson()));
    _redrawPersistent();
  }

  void _redrawPersistent() {
    final outcomes = <HostOutcome>[];
    final retries = <String, Duration>{};
    for (final host in _hosts) {
      final report = _reports[host.id];
      if (report == null) continue;
      outcomes.add(report.toOutcome(host));
      if (report.retryIn case final retry?) retries[host.id] = retry;
    }
    FlutterForegroundTask.updateService(
      notificationTitle: watcherNotificationTitle,
      notificationText: outcomes.isEmpty
          ? watcherNotificationText([
              for (final host in _hosts)
                HostOutcome(host: host, kind: AgentOutcomeKind.snapshot),
            ])
          : watcherNotificationText(outcomes, retries: retries),
    );
  }
}

/// One host's connection, with §39.31's reconnect schedule around it.
class _HostLoop {
  _HostLoop({
    required this.host,
    required this.keys,
    required this.client,
    required this.edges,
    required this.onReport,
  });

  final Host host;
  final Ed25519Keys keys;
  final HerdrClient client;
  final BlockedEdges edges;
  final void Function(WatcherReport) onReport;

  final WatcherBackoff _backoff = WatcherBackoff();
  Future<void>? _running;
  HerdrSession? _session;
  bool _stopped = false;
  List<AgentSnapshot> _lastAgents = const [];
  DateTime? _lastGoodAt;

  bool sameHost(Host other) =>
      other.address == host.address &&
      other.port == host.port &&
      other.user == host.user &&
      other.keyId == host.keyId;

  void start() => _running = _run();

  Future<void> stop() async {
    _stopped = true;
    _session?.close();
    await _running;
    // §39.31: the alert is cleared when the app stops being able to say the
    // pane is still blocked, and a watcher that is going away cannot.
    for (final pane in edges.blockedOn(host.id)) {
      await AlertNotifications.cancel(alertNotificationId(host.id, pane));
    }
    edges.reset(host.id);
  }

  // §39.29: one line per failure, naming the host and what the transport said.
  void _log(Object error) => debugPrint('hotline.herdr ${host.name}: $error');

  Future<void> _run() async {
    while (!_stopped) {
      try {
        await _connectAndWatch();
        // The stream ended without an error: the gate closed the connection.
        throw const HerdrUnreachable('watch stream ended');
      } on HerdrFailure catch (error) {
        _log(error.detail ?? error);
        _reportFailure(_kindOf(error), protocol: _protocolOf(error));
      } catch (error) {
        _log(error);
        _reportFailure(AgentOutcomeKind.unreachable);
      } finally {
        _session?.close();
        _session = null;
      }
      if (_stopped) return;
      await Future<void>.delayed(_backoff.current);
      _backoff.advance();
    }
  }

  /// A stopped loop says nothing more. [stop] closes the session, and closing
  /// it is what ends the watch, so the unwind arrives here as an unreachable
  /// host — a claim the panel would then hold for a host that never went down.
  void _reportFailure(AgentOutcomeKind kind, {int? protocol}) {
    if (_stopped) return;
    _report(kind, protocol: protocol, retryIn: _backoff.current);
  }

  Future<void> _connectAndWatch() async {
    if (_fakeWatch) return _watchFake();
    final privateKey = await keys.privateKey(host.keyId);
    if (privateKey == null) {
      throw HerdrKeyRejected('no private key stored for ${host.keyId}');
    }
    final session = await client.connect(
      address: host.address,
      port: host.port,
      user: host.user,
      privateKey: privateKey,
    );
    _session = session;
    // §39.31: "the first snapshot after a connect counts every blocked pane as
    // new", which is what a fresh difference set means.
    edges.reset(host.id);
    await for (final agents in session.watch()) {
      if (_stopped) return;
      await _onSnapshot(agents, session);
    }
  }

  Future<void> _onSnapshot(
    List<AgentSnapshot> agents,
    HerdrSession? session,
  ) async {
    _lastAgents = agents;
    _lastGoodAt = DateTime.now();
    // §39.31's backoff is per outage: a connection that carried a snapshot has
    // earned the next one its full 5 s start.
    _backoff.reset();
    final delta = edges.apply(host.id, agents);
    for (final pane in delta.left) {
      await AlertNotifications.cancel(alertNotificationId(host.id, pane));
    }
    for (final snapshot in delta.entered) {
      // §39.31: the expanded form carries the pane's tail, read over the same
      // connection. A tail that fails to arrive is not worth losing the alert
      // over, so [HerdrSession.read] answers null and the alert goes out flat.
      final tail = session == null ? null : await session.read(snapshot.paneId);
      await AlertNotifications.alert(
        target: AlertTarget.forHost(host, snapshot),
        snapshot: snapshot,
        tail: tail,
      );
    }
    _report(AgentOutcomeKind.snapshot);
  }

  void _report(
    AgentOutcomeKind kind, {
    int? protocol,
    Duration? retryIn,
  }) => onReport(
    WatcherReport(
      hostId: host.id,
      kind: kind,
      // §39.20's rule, kept here too: a host that blinks does not empty the
      // panel, so the last good agents ride along with the failure.
      agents: _lastAgents,
      lastGoodAt: _lastGoodAt,
      protocol: protocol,
      retryIn: retryIn,
    ),
  );

  Future<void> _watchFake() async {
    edges.reset(host.id);
    const blocked = AgentSnapshot(
      paneId: 'wF:p1',
      agent: 'claude',
      agentStatus: 'blocked',
      terminalTitleStripped: 'RUN THE MIGRATION?',
      workspaceId: 'wF',
      cwd: '~/src/hotline',
      stateChangeSeq: 2,
    );
    await _onSnapshot(const [], null);
    await Future<void>.delayed(const Duration(seconds: 5));
    if (_stopped) return;
    await _onSnapshot(const [blocked], null);
    while (!_stopped) {
      await Future<void>.delayed(const Duration(seconds: 30));
    }
  }
}

AgentOutcomeKind _kindOf(HerdrFailure error) => switch (error) {
  HerdrKeyRejected() => AgentOutcomeKind.keyRejected,
  HerdrProtocolMismatch() => AgentOutcomeKind.protocolMismatch,
  HerdrUnresolved() => AgentOutcomeKind.unresolved,
  HerdrUnreachable() => AgentOutcomeKind.unreachable,
};

int? _protocolOf(HerdrFailure error) =>
    error is HerdrProtocolMismatch ? error.protocol : null;
