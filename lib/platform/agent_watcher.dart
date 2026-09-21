import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../application/agent_state.dart';
import '../application/agents.dart';
import '../application/alerts.dart';
import '../data/repositories/host_repository.dart';
import 'alert_notifications.dart';
import 'herdr_client.dart';
import 'host_keys.dart';
import 'keys.dart';

/// The service runs its own isolate. Nothing in this file may reach for a provider, the
/// database or a widget: what it needs travels through
/// [FlutterForegroundTask.saveData] and the keystore.

/// Only the ending nobody announces needs it — a service the system killed — so the
/// period is the agent poll's own cadence rather than anything tighter.
const watcherLivenessPeriod = Duration(seconds: 10);

const watcherChannelId = 'watcher';
const watcherChannelName = 'Agent watcher';
const watcherNotificationTitle = 'DAZZLE';

const _hostsKey = 'dazzle.watcher.hosts';
const _kindsKey = 'dazzle.watcher.kinds';

/// With `--dart-define=DAZZLE_FAKE_WATCH=true` each host's stream is a canned pair of
/// snapshots, which is what produces the alert on an emulator with no key on the host.
const _fakeWatch = bool.fromEnvironment('DAZZLE_FAKE_WATCH');

String encodeWatcherHosts(List<Host> hosts) => jsonEncode([
  for (final host in hosts)
    {
      'id': host.id,
      'name': host.name,
      'address': host.address,
      'port': host.port,
      'user': host.user,
      'key_id': host.keyId,
      // The pin travels with the host. The service dials unattended and has nobody to ask, so
      // a host whose key it cannot see is one it refuses on every tick.
      if (host.hostKey case final key?)
        'host_key': {
          'type': key.type,
          'fingerprint': key.fingerprint,
          'pinned_at': key.pinnedAt.toIso8601String(),
        },
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
            hostKey: _decodePinnedKey(row['host_key']),
          ),
    ];
  } catch (_) {
    return const [];
  }
}

String encodeWatcherKinds(Set<AlertKind> kinds) => jsonEncode([
  for (final kind in AlertKind.values)
    if (kinds.contains(kind)) kind.name,
]);

Set<AlertKind> decodeWatcherKinds(String? raw) {
  if (raw == null || raw.isEmpty) return const {};
  try {
    final json = jsonDecode(raw);
    if (json is! List<Object?>) return const {};
    return {
      for (final kind in AlertKind.values)
        if (json.contains(kind.name)) kind,
    };
  } catch (_) {
    return const {};
  }
}

PinnedHostKey? _decodePinnedKey(Object? raw) {
  if (raw is! Map<String, Object?>) return null;
  final at = raw['pinned_at'];
  final type = raw['type'];
  final fingerprint = raw['fingerprint'];
  // Read rather than cast: a payload this cannot make sense of costs the pin, and a throw
  // would cost the whole host list the decode is building.
  final pinnedAt = at is String ? DateTime.tryParse(at) : null;
  if (pinnedAt == null || type is! String || fingerprint is! String) {
    return null;
  }
  return PinnedHostKey(
    type: type,
    fingerprint: fingerprint,
    pinnedAt: pinnedAt,
  );
}

class AgentWatcher {
  const AgentWatcher._();

  static Future<void> init() async {
    // Without this every report is sent into nothing: the callbacks [taskData] adds are
    // held and nobody ever calls them.
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: watcherChannelId,
        channelName: watcherChannelName,
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
        stopWithTask: false,
        allowAutoRestart: true,
      ),
    );
  }

  static Future<bool> get running => FlutterForegroundTask.isRunningService;

  static Future<bool> requestPermission() async {
    final current = await FlutterForegroundTask.checkNotificationPermission();
    if (current == NotificationPermission.granted) return true;
    final asked = await FlutterForegroundTask.requestNotificationPermission();
    return asked == NotificationPermission.granted;
  }

  static Future<void> start(List<Host> hosts, Set<AlertKind> kinds) async {
    await _save(hosts, kinds);
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
      debugPrint('dazzle.herdr watcher: ${result.error}');
    }
  }

  static Future<void> setHosts(List<Host> hosts, Set<AlertKind> kinds) async {
    await _save(hosts, kinds);
    if (await FlutterForegroundTask.isRunningService) {
      FlutterForegroundTask.sendDataToTask(_reloadHosts);
    }
  }

  static Future<void> _save(List<Host> hosts, Set<AlertKind> kinds) async {
    await FlutterForegroundTask.saveData(
      key: _hostsKey,
      value: encodeWatcherHosts(hosts),
    );
    await FlutterForegroundTask.saveData(
      key: _kindsKey,
      value: encodeWatcherKinds(kinds),
    );
  }

  static Future<HostOutcome> retry(Host host) async {
    final requestId =
        '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
        '${(_retryRequests++).toRadixString(36)}';
    final response = taskData()
        .map(_decodeReport)
        .where((report) => report != null)
        .cast<WatcherReport>()
        .firstWhere(
          (report) => report.hostId == host.id && report.requestId == requestId,
        )
        .timeout(const Duration(seconds: 20));
    FlutterForegroundTask.sendDataToTask(
      jsonEncode({
        'command': _retryHost,
        'host_id': host.id,
        'request_id': requestId,
      }),
    );
    return (await response).toOutcome(host);
  }

  static Future<void> stop() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
    // Said even when nothing was running: [_sync] calls stop for every state that is not
    // "on with a host", and a feed still holding the last report has to be cleared.
    _stops.add(null);
  }

  /// Broadcast because a process may hold more than one feed over its life and none of
  /// them is the one that called stop.
  static final _stops = StreamController<void>.broadcast();

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

  static Stream<Object> taskData() {
    late StreamController<Object> controller;
    void onData(Object data) => controller.add(data);
    controller = StreamController<Object>(
      onListen: () => FlutterForegroundTask.addTaskDataCallback(onData),
      onCancel: () => FlutterForegroundTask.removeTaskDataCallback(onData),
    );
    return controller.stream;
  }

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
            // Nothing stands behind the last report any more, and `onDestroy` unwinds every host
            // loop, so that word can be a retry line for a host that is perfectly fine.
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
const _retryHost = 'retry-host';
var _retryRequests = 0;

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

  final _AlertBook _book = _AlertBook();
  final Map<String, _HostLoop> _loops = {};
  final Map<String, WatcherReport> _reports = {};

  String? _persistent;
  List<Host> _hosts = const [];

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) =>
      _reloadFromStore();

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  void onReceiveData(Object data) {
    if (data == _reloadHosts) {
      unawaited(_reloadFromStore());
      return;
    }
    if (data is! String) return;
    try {
      final message = jsonDecode(data);
      if (message is! Map<String, Object?> ||
          message['command'] != _retryHost ||
          message['host_id'] is! String ||
          message['request_id'] is! String) {
        return;
      }
      retryHost(
        message['host_id']! as String,
        message['request_id']! as String,
      );
    } catch (_) {}
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    for (final loop in _loops.values.toList()) {
      await loop.stop();
    }
    _loops.clear();
  }

  Future<void> _reloadFromStore() async {
    final hosts = await FlutterForegroundTask.getData<String>(key: _hostsKey);
    final kinds = await FlutterForegroundTask.getData<String>(key: _kindsKey);
    await setKinds(decodeWatcherKinds(kinds));
    await setHosts(decodeWatcherHosts(hosts));
  }

  @visibleForTesting
  Future<void> setKinds(Set<AlertKind> kinds) async {
    for (final kind in AlertKind.values) {
      if (kinds.contains(kind) || !_book.kinds.contains(kind)) continue;
      final edges = _book.edges[kind]!;
      for (final host in _hosts) {
        for (final pane in edges.panesOn(host.id)) {
          await AlertNotifications.cancel(
            kindNotificationId(kind, host.id, pane),
          );
        }
        edges.reset(host.id);
      }
    }
    _book.kinds = kinds;
  }

  /// Public only so a test can reach the loops without the store the isolate reads them
  /// from, which is a plugin channel no test binding answers.
  @visibleForTesting
  Future<void> setHosts(List<Host> hosts) async {
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
        book: _book,
        onReport: _publish,
      )..start();
    }
    _redrawPersistent();
  }

  @visibleForTesting
  void retryHost(String hostId, String requestId) {
    _loops[hostId]?.retry(requestId);
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
    final text = outcomes.isEmpty
        ? watcherNotificationText([
            for (final host in _hosts)
              HostOutcome(host: host, kind: AgentOutcomeKind.snapshot),
          ])
        : watcherNotificationText(outcomes, retries: retries);
    // Most of what a host reports does not move the line, and posting it again is a binder
    // call and a redraw of a row in the shade that already reads that way.
    if (text == _persistent) return;
    _persistent = text;
    FlutterForegroundTask.updateService(
      notificationTitle: watcherNotificationTitle,
      notificationText: text,
    );
  }
}

class _AlertBook {
  final Map<AlertKind, AgentEdges> edges = {
    for (final kind in AlertKind.values) kind: AgentEdges(kind),
  };

  Set<AlertKind> kinds = const {};
}

class _HostLoop {
  _HostLoop({
    required this.host,
    required this.keys,
    required this.client,
    required this.book,
    required this.onReport,
  });

  final Host host;
  final Ed25519Keys keys;
  final HerdrClient client;
  final _AlertBook book;
  final void Function(WatcherReport) onReport;

  final WatcherBackoff _backoff = WatcherBackoff();
  Future<void>? _running;
  HerdrSession? _session;
  bool _stopped = false;
  bool _interrupting = false;
  String? _requestId;
  Completer<void>? _waiting;
  List<AgentSnapshot> _lastAgents = const [];
  DateTime? _lastGoodAt;

  bool sameHost(Host other) =>
      other.address == host.address &&
      other.port == host.port &&
      other.user == host.user &&
      other.keyId == host.keyId &&
      // A pin that appeared or changed is a different dial: the loop started under the old
      // one goes on refusing the machine every tick.
      other.hostKey?.type == host.hostKey?.type &&
      other.hostKey?.fingerprint == host.hostKey?.fingerprint;

  void start() {
    if (_running != null) return;
    final running = _run();
    _running = running;
    unawaited(
      running.whenComplete(() {
        if (identical(_running, running)) _running = null;
      }),
    );
  }

  void retry(String requestId) {
    if (_stopped) return;
    _requestId = requestId;
    _backoff.reset();
    if (_waiting case final waiting? when !waiting.isCompleted) {
      waiting.complete();
      return;
    }
    final session = _session;
    if (session != null) {
      _interrupting = true;
      session.close();
      return;
    }
    if (_running == null) start();
  }

  Future<void> stop() async {
    _stopped = true;
    _session?.close();
    // A loop between retries is asleep in [_wait], and `await _running` would hold the
    // caller there for the rest of that sleep.
    if (_waiting case final waiting? when !waiting.isCompleted) {
      waiting.complete();
    }
    await _running;
    // The alert is cleared when the app stops being able to say the pane is still in the
    // state that posted it, and a watcher that is going away cannot.
    for (final kind in AlertKind.values) {
      final edges = book.edges[kind]!;
      for (final pane in edges.panesOn(host.id)) {
        await AlertNotifications.cancel(
          kindNotificationId(kind, host.id, pane),
        );
      }
      edges.reset(host.id);
    }
  }

  void _log(Object error) => debugPrint('dazzle.herdr ${host.name}: $error');

  /// Every wait this loop takes goes through it: the service is torn down by Android's
  /// `onDestroy`, which is on a clock, and a loop asleep in its own backoff carries the
  /// whole service past it.
  Future<void> _wait(Duration duration) async {
    final waiting = _waiting = Completer<void>();
    final timer = Timer(duration, waiting.complete);
    await waiting.future;
    timer.cancel();
    _waiting = null;
  }

  Future<void> _run() async {
    while (!_stopped) {
      var kind = AgentOutcomeKind.unreachable;
      var interrupted = false;
      try {
        await _connectAndWatch();
        // The stream ended without an error: the remote loop closed.
        throw const HerdrUnreachable('watch stream ended');
      } on HerdrFailure catch (error) {
        kind = _kindOf(error);
        interrupted = _interrupting;
        _interrupting = false;
        if (!interrupted) {
          _log(error.detail ?? error);
          _reportFailure(kind, protocol: _protocolOf(error));
        }
      } catch (error) {
        interrupted = _interrupting;
        _interrupting = false;
        if (!interrupted) {
          _log(error);
          _reportFailure(kind);
        }
      } finally {
        _session?.close();
        _session = null;
      }
      if (_stopped) return;
      if (interrupted) continue;
      // An answer nothing is going to ask again is stood on rather than slept off: the loop
      // ends here until the host row or the setting changes under it.
      if (!kind.retryable) return;
      await _wait(_backoff.current);
      _backoff.advance();
    }
  }

  /// [stop] closes the session, and closing it is what ends the watch, so the unwind would
  /// otherwise arrive here as an unreachable host.
  void _reportFailure(AgentOutcomeKind kind, {int? protocol}) {
    if (_stopped) return;
    _report(
      kind,
      protocol: protocol,
      retryIn: kind.retryable ? _backoff.current : null,
    );
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
      // A background service with nothing on screen: an unpinned host is refused rather than
      // trusted on nobody's word.
      verifier: HostKeyVerifier.pinnedOnly(host.hostKey),
    );
    _session = session;
    // No reset here. A reconnect inside one service life keeps the set, because the panes
    // did not change while the link was down: resetting re-entered every pane still
    // blocked, which reposted the alert and overwrote an answer the user had already given.
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
    // The backoff is per outage: a connection that carried a snapshot has earned the next
    // one its full start.
    _backoff.reset();
    for (final kind in AlertKind.values) {
      if (!book.kinds.contains(kind)) continue;
      final delta = book.edges[kind]!.apply(host.id, agents);
      for (final pane in delta.left) {
        await AlertNotifications.cancel(
          kindNotificationId(kind, host.id, pane),
        );
      }
      for (final snapshot in delta.entered) {
        await _post(kind, snapshot, session);
      }
    }
    _report(AgentOutcomeKind.snapshot);
  }

  Future<void> _post(
    AlertKind kind,
    AgentSnapshot snapshot,
    HerdrSession? session,
  ) async {
    final target = AlertTarget.forHost(host, snapshot);
    if (kind == AlertKind.done) {
      return AlertNotifications.done(target: target, snapshot: snapshot);
    }
    final tail = session == null ? null : await session.read(snapshot.pane);
    return AlertNotifications.alert(
      target: target,
      snapshot: snapshot,
      tail: tail,
    );
  }

  void _report(AgentOutcomeKind kind, {int? protocol, Duration? retryIn}) {
    final requestId = _requestId;
    _requestId = null;
    onReport(
      WatcherReport(
        hostId: host.id,
        kind: kind,
        // A host that blinks does not empty the panel, so the last good agents ride along with
        // the failure.
        agents: _lastAgents,
        lastGoodAt: _lastGoodAt,
        protocol: protocol,
        retryIn: retryIn,
        requestId: requestId,
      ),
    );
  }

  Future<void> _watchFake() async {
    const agents = [
      AgentSnapshot(
        session: 'default',
        paneId: 'wF:p1',
        agent: 'claude',
        state: BlockedState(),
        terminalTitleStripped: 'RUN THE MIGRATION?',
        workspaceId: 'wF',
        cwd: '~/src/dazzle',
        stateChangeSeq: 2,
      ),
      AgentSnapshot(
        session: 'default',
        paneId: 'wF:p2',
        agent: 'codex',
        state: WorkingState(),
        terminalTitleStripped: 'wiring the diff viewer',
        workspaceId: 'wF',
        cwd: '~/src/dazzle',
        stateChangeSeq: 7,
      ),
      AgentSnapshot(
        session: 'default',
        paneId: 'wF:p3',
        agent: 'aider',
        state: WorkingState(),
        terminalTitleStripped: 'rewriting the migration',
        workspaceId: 'wF',
        cwd: '~/src/herdr',
        stateChangeSeq: 4,
      ),
      AgentSnapshot(
        session: 'default',
        paneId: 'wF:p4',
        agent: 'gemini',
        state: WorkingState(),
        terminalTitleStripped: 'reading the spec',
        workspaceId: 'wG',
        cwd: '~/src/dazzle',
        stateChangeSeq: 3,
      ),
      AgentSnapshot(
        session: 'default',
        paneId: 'wF:p5',
        agent: 'opencode',
        state: IdleState(),
        terminalTitleStripped: 'zsh',
        workspaceId: 'wG',
        cwd: '~/src/dazzle',
        stateChangeSeq: 1,
      ),
    ];
    await _onSnapshot(const [], null);
    await _wait(const Duration(seconds: 5));
    if (_stopped) return;
    await _onSnapshot(agents, null);
    await _wait(const Duration(seconds: 5));
    if (_stopped) return;
    await _onSnapshot([
      for (final agent in agents)
        if (agent.paneId == 'wF:p2')
          AgentSnapshot(
            session: agent.session,
            paneId: agent.paneId,
            agent: agent.agent,
            state: const DoneState(),
            terminalTitleStripped: agent.terminalTitleStripped,
            workspaceId: agent.workspaceId,
            cwd: agent.cwd,
            stateChangeSeq: agent.stateChangeSeq + 1,
          )
        else
          agent,
    ], null);
    while (!_stopped) {
      await _wait(const Duration(seconds: 30));
    }
  }
}

AgentOutcomeKind _kindOf(HerdrFailure error) => switch (error) {
  HerdrKeyRejected() => AgentOutcomeKind.keyRejected,
  HerdrProtocolMismatch() => AgentOutcomeKind.protocolMismatch,
  HerdrUnresolved() => AgentOutcomeKind.unresolved,
  HerdrUnreachable() => AgentOutcomeKind.unreachable,
  HerdrHostKeyUnverified() => AgentOutcomeKind.hostKeyUnverified,
  HerdrHostKeyChanged() => AgentOutcomeKind.hostKeyChanged,
};

int? _protocolOf(HerdrFailure error) =>
    error is HerdrProtocolMismatch ? error.protocol : null;
