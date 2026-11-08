import 'dart:async';
import 'dart:convert';
import 'dart:io' show pid;

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'package:upgrade/data/pinned_host_key.dart';
import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/application/alerts/alerts.dart';
import 'package:upgrade/platform/notifications/pin_alerts.dart';
import 'package:upgrade/platform/herdr/watcher_backoff.dart';
import 'package:upgrade/application/launcher/launcher_feed.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/platform/notifications/alert_notifications.dart';
import 'package:upgrade/platform/herdr/engine_agents.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/launcher_widget/launcher_widget.dart';
import 'package:upgrade/platform/ssh/host_links.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/keys.dart';
import 'package:upgrade/platform/notifications/pin_notifications.dart';
import 'package:upgrade/data/serial.dart';
import 'package:upgrade/brand.dart';

/// The service runs its own isolate. Nothing in this file may reach for a provider, the
/// database or a widget: what it needs travels through
/// [FlutterForegroundTask.saveData] and the keystore.

/// Only the ending nobody announces needs it — a service the system killed — so the
/// period is the agent poll's own cadence rather than anything tighter.
const watcherLivenessPeriod = Duration(seconds: 10);

const watcherChannelId = 'watcher';
const watcherChannelName = 'Agent watcher';
const watcherNotificationTitle = appNameCaps;

const _hostsKey = 'upgrade.watcher.hosts';
const _kindsKey = 'upgrade.watcher.kinds';
const _shellsKey = 'upgrade.watcher.shells';

const shellsAskPeriod = Duration(minutes: 1);

String shellsNotificationText(int count) =>
    'HOLDING $count SSH TAB${count == 1 ? '' : 'S'}';

String encodeHeldShells(int count) => jsonEncode({'count': count, 'pid': pid});

int decodeHeldShells(String? raw, {int? process}) {
  if (raw == null || raw.isEmpty) return 0;
  try {
    return switch (jsonDecode(raw)) {
      {'count': final int count, 'pid': final int writer}
          when writer == (process ?? pid) =>
        count,
      _ => 0,
    };
  } catch (_) {
    // ignored: an unreadable count holds no shells, the safe side.
    return 0;
  }
}

String encodeWatcherHosts(
  List<Host> hosts, {
  Map<String, Set<AgentSource>> sources = const {},
}) => jsonEncode([
  for (final host in hosts)
    {
      'id': host.id,
      if (sources[host.id] case final named?)
        'sources': [for (final source in named) source.name],
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

Map<String, Set<AgentSource>> decodeWatcherSources(String? raw) {
  if (raw == null || raw.isEmpty) return const {};
  try {
    final json = jsonDecode(raw);
    if (json is! List<Object?>) return const {};
    return {
      for (final row in json)
        if (row case {
          'id': final String id,
          'sources': final List<Object?> named,
        })
          id: {
            for (final source in AgentSource.values)
              if (named.contains(source.name)) source,
          },
    };
  } catch (_) {
    return const {};
  }
}

Set<AgentSource> _sourcesOf(Map<String, Set<AgentSource>> sources, Host host) =>
    sources[host.id] ?? const {AgentSource.herdr};

({List<Host> hosts, Map<String, Set<AgentSource>> sources}) watcherHostsOf(
  List<AgentChannel> channels,
) {
  final hosts = <String, Host>{};
  final sources = <String, Set<AgentSource>>{};
  for (final (:host, :source) in channels) {
    hosts[host.id] = host;
    sources.putIfAbsent(host.id, () => {}).add(source);
  }
  return (hosts: hosts.values.toList(), sources: sources);
}

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
        // The watcher is woken by its own ssh streams; the tick only asks after the shells.
        eventAction: ForegroundTaskEventAction.repeat(
          shellsAskPeriod.inMilliseconds,
        ),
        allowWakeLock: false,
        allowWifiLock: false,
        stopWithTask: false,
        allowAutoRestart: true,
      ),
    );
    FlutterForegroundTask.addTaskDataCallback(_answerShells);
  }

  static bool _watching = false;
  static int _shells = 0;
  static Future<void> _turn = Future.value();

  static Future<bool> get running async =>
      _watching && await FlutterForegroundTask.isRunningService;

  static Future<bool> hasPermission() async =>
      await FlutterForegroundTask.checkNotificationPermission() ==
      NotificationPermission.granted;

  static Future<bool> requestPermission() async {
    final current = await FlutterForegroundTask.checkNotificationPermission();
    if (current == NotificationPermission.granted) return true;
    final asked = await FlutterForegroundTask.requestNotificationPermission();
    return asked == NotificationPermission.granted;
  }

  static Future<void> start(
    List<Host> hosts,
    Set<AlertKind> kinds, {
    Map<String, Set<AgentSource>> sources = const {},
  }) {
    _watching = true;
    return _serial(() async {
      await _save(hosts, kinds, sources);
      await _apply();
    });
  }

  static Future<void> holdShells(int count) {
    _shells = count;
    return _serial(() async {
      await FlutterForegroundTask.saveData(
        key: _shellsKey,
        value: encodeHeldShells(count),
      );
      await _apply();
    });
  }

  static void _answerShells(Object data) {
    if (data != _askShells) return;
    FlutterForegroundTask.sendDataToTask(
      jsonEncode({'command': _heldShells, 'count': _shells}),
    );
  }

  static Future<void> _serial(Future<void> Function() step) {
    final next = _turn.then((_) => step());
    _turn = next.catchError((Object error) {
      debugPrint('$appSlug.herdr watcher: $error');
    });
    return next;
  }

  static Future<void> _apply() async {
    final running = await FlutterForegroundTask.isRunningService;
    if (!_watching && _shells == 0) {
      if (running) await FlutterForegroundTask.stopService();
      return;
    }
    // A service kept for the shells alone, restarted by the system, must not come back
    // watching the hosts it was last given.
    if (!_watching) {
      await FlutterForegroundTask.saveData(key: _hostsKey, value: '[]');
    }
    if (running) {
      FlutterForegroundTask.sendDataToTask(_reloadHosts);
      return;
    }
    final result = await FlutterForegroundTask.startService(
      serviceTypes: const [ForegroundServiceTypes.specialUse],
      notificationTitle: watcherNotificationTitle,
      notificationText: _watching
          ? watcherNotificationText(const [])
          : shellsNotificationText(_shells),
      callback: agentWatcherEntry,
    );
    if (result is ServiceRequestFailure) {
      debugPrint('$appSlug.herdr watcher: ${result.error}');
    }
  }

  static Future<void> setHosts(
    List<Host> hosts,
    Set<AlertKind> kinds, {
    Map<String, Set<AgentSource>> sources = const {},
  }) async {
    await _save(hosts, kinds, sources);
    if (await FlutterForegroundTask.isRunningService) {
      FlutterForegroundTask.sendDataToTask(_reloadHosts);
    }
  }

  static Future<void> _save(
    List<Host> hosts,
    Set<AlertKind> kinds,
    Map<String, Set<AgentSource>> sources,
  ) async {
    await FlutterForegroundTask.saveData(
      key: _hostsKey,
      value: encodeWatcherHosts(hosts, sources: sources),
    );
    await FlutterForegroundTask.saveData(
      key: _kindsKey,
      value: encodeWatcherKinds(kinds),
    );
  }

  static Future<HostOutcome> retry(
    Host host, {
    AgentSource source = AgentSource.herdr,
  }) async {
    final requestId =
        '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
        '${(_retryRequests++).toRadixString(36)}';
    final response = taskData()
        .map(_decodeReport)
        .where((report) => report != null)
        .cast<WatcherReport>()
        .firstWhere(
          (report) =>
              report.hostId == host.id &&
              report.source == source &&
              report.requestId == requestId,
        )
        .timeout(const Duration(seconds: 20));
    FlutterForegroundTask.sendDataToTask(
      jsonEncode({
        'command': _retryHost,
        'host_id': host.id,
        'source': source.name,
        'request_id': requestId,
      }),
    );
    return (await response).toOutcome(host);
  }

  static Future<void> stop() async {
    _watching = false;
    await _serial(_apply);
    // Said even when nothing was running: [_sync] calls stop for every state that is not
    // "on with a host", and a feed still holding the last report has to be cleared.
    _stops.add(null);
  }

  /// Broadcast because a process may hold more than one feed over its life and none of
  /// them is the one that called stop.
  static final _stops = StreamController<void>.broadcast();

  /// Polls only while [visible] last said true, reading once as soon as it does; without
  /// [visible] it polls for as long as it is listened to.
  static Stream<bool> serviceLiveness({
    Duration period = watcherLivenessPeriod,
    Stream<bool>? visible,
    Future<bool> Function()? isRunning,
  }) {
    final read = isRunning ?? () => running;
    late StreamController<bool> controller;
    StreamSubscription<void>? stops;
    StreamSubscription<bool>? seen;
    Timer? timer;
    var live = true;
    Future<void> check() async {
      final running = await read();
      if (live) controller.add(running);
    }

    void poll(bool on) {
      if (on == (timer != null)) return;
      timer?.cancel();
      timer = null;
      if (!on) return;
      unawaited(check());
      timer = Timer.periodic(period, (_) => check());
    }

    controller = StreamController<bool>(
      onListen: () {
        stops = _stops.stream.listen((_) => controller.add(false));
        if (visible == null) return poll(true);
        seen = visible.listen(poll);
      },
      onCancel: () async {
        live = false;
        timer?.cancel();
        await seen?.cancel();
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
    Stream<List<AgentChannel>> channels, {
    Stream<Object>? data,
    Stream<bool>? running,
  }) {
    final controller = StreamController<AgentPanelState?>();
    final reports = <String, WatcherReport>{};
    final subscriptions = <StreamSubscription<Object?>>[];
    var known = <AgentChannel>[];

    void emit() {
      if (reports.isEmpty) {
        controller.add(null);
        return;
      }
      controller.add(
        AgentPanelState.linked([
          for (final (:host, :source) in known)
            if (reports[channelKey(host.id, source)] case final report?)
              report.toOutcome(host),
        ]),
      );
    }

    controller
      ..onListen = () {
        subscriptions.add(
          channels.listen((list) {
            known = list;
            reports.removeWhere(
              (key, _) => !list.any(
                (channel) => channelKey(channel.host.id, channel.source) == key,
              ),
            );
            emit();
          }),
        );
        subscriptions.add(
          (data ?? taskData()).listen((message) {
            final report = _decodeReport(message);
            if (report == null) return;
            reports[report.key] = report;
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
const _heldShells = 'held-shells';
const _askShells = 'held-shells?';
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
  AgentWatcherHandler({
    Ed25519Keys? keys,
    HerdrClient? client,
    PinNotifier? pins,
  }) : _keys = keys ?? const Ed25519Keys(SecurePrivateKeyStore()),
       _client =
           client ?? HerdrClient(links: HostLinks(), use: HostUse.watcher),
       _pins = pins ?? const PinNotifications();

  final Ed25519Keys _keys;
  final HerdrClient _client;
  final PinNotifier _pins;

  final _AlertBook _book = _AlertBook();
  final Map<String, _HostLoop> _loops = {};
  final Map<String, WatcherReport> _reports = {};

  String? _persistent;
  LauncherTally? _tally;
  bool _tallied = false;
  Map<String, LauncherLive>? _live;
  Future<void> _living = Future.value();
  List<AgentChannel> _channels = const [];

  int _shells = 0;
  bool _asked = false;

  final _turns = Serial();

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await PinNotifications.createChannel();
    await _reloadFromStore();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    if (_shells == 0) return;
    if (_asked) return setShells(0);
    _asked = true;
    FlutterForegroundTask.sendDataToMain(_askShells);
  }

  @override
  void onReceiveData(Object data) {
    if (data == _reloadHosts) {
      unawaited(_reloadFromStore());
      return;
    }
    if (data is! String) return;
    try {
      final message = jsonDecode(data);
      if (message case {'command': _heldShells, 'count': final int count}) {
        return setShells(count);
      }
      if (message is! Map<String, Object?> ||
          message['command'] != _retryHost ||
          message['host_id'] is! String ||
          message['request_id'] is! String) {
        return;
      }
      retryHost(
        message['host_id']! as String,
        message['request_id']! as String,
        source:
            AgentSource.values
                .where((value) => value.name == message['source'])
                .firstOrNull ??
            AgentSource.herdr,
      );
    } catch (_) {
      // ignored: a malformed message from the app asks for nothing.
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) =>
      _turns.run(() async {
        for (final loop in _loops.values.toList()) {
          await loop.stop();
        }
        _loops.clear();
        _client.links.close();
      });

  Future<void> _reloadFromStore() async {
    final hosts = await FlutterForegroundTask.getData<String>(key: _hostsKey);
    final kinds = await FlutterForegroundTask.getData<String>(key: _kindsKey);
    final shells = await FlutterForegroundTask.getData<String>(key: _shellsKey);
    _shells = decodeHeldShells(shells);
    _asked = false;
    await setKinds(decodeWatcherKinds(kinds));
    await setHosts(
      decodeWatcherHosts(hosts),
      sources: decodeWatcherSources(hosts),
    );
  }

  @visibleForTesting
  void setShells(int count) {
    _shells = count;
    _asked = false;
    _redrawPersistent();
  }

  @visibleForTesting
  Future<void> setKinds(Set<AlertKind> kinds) =>
      _turns.run(() => _setKinds(kinds));

  Future<void> _setKinds(Set<AlertKind> kinds) async {
    for (final kind in AlertKind.values) {
      if (kinds.contains(kind) || !_book.kinds.contains(kind)) continue;
      final edges = _book.edges[kind]!;
      for (final key in _loops.keys) {
        for (final edge in edges.panesOn(key)) {
          await AlertNotifications.cancel(kindNotificationId(kind, key, edge));
        }
        edges.reset(key);
      }
    }
    _book.kinds = kinds;
  }

  /// Public only so a test can reach the loops without the store the isolate reads them
  /// from, which is a plugin channel no test binding answers.
  @visibleForTesting
  Future<void> setHosts(
    List<Host> hosts, {
    Map<String, Set<AgentSource>> sources = const {},
  }) => _turns.run(() => _setHosts(hosts, sources));

  Future<void> _setHosts(
    List<Host> hosts,
    Map<String, Set<AgentSource>> sources,
  ) async {
    _channels = [
      for (final host in hosts)
        for (final source in AgentSource.values)
          if (_sourcesOf(sources, host).contains(source))
            (host: host, source: source),
    ];
    final wanted = {
      for (final channel in _channels)
        channelKey(channel.host.id, channel.source): channel,
    };
    for (final key in _loops.keys.toList()) {
      if (wanted.containsKey(key)) continue;
      await _loops.remove(key)!.stop();
      _reports.remove(key);
    }
    for (final MapEntry(:key, value: (:host, :source)) in wanted.entries) {
      final existing = _loops[key];
      final watchesPins =
          AgentSource.values.firstWhere(_sourcesOf(sources, host).contains) ==
          source;
      if (existing != null &&
          existing.sameHost(host) &&
          existing.watchesPins == watchesPins) {
        existing.host = host;
        continue;
      }
      await existing?.stop();
      _loops[key] = _HostLoop(
        host: host,
        source: source,
        keys: _keys,
        client: _client,
        pins: _pins,
        watchesPins: watchesPins,
        book: _book,
        onReport: _publish,
      )..start();
    }
    _redrawPersistent();
  }

  @visibleForTesting
  void retryHost(
    String hostId,
    String requestId, {
    AgentSource source = AgentSource.herdr,
  }) {
    _loops[channelKey(hostId, source)]?.retry(requestId);
  }

  void _publish(WatcherReport report) {
    _reports[report.key] = report;
    FlutterForegroundTask.sendDataToMain(jsonEncode(report.toJson()));
    _redrawPersistent();
  }

  void _redrawPersistent() {
    if (_channels.isEmpty) {
      if (_shells == 0) {
        unawaited(FlutterForegroundTask.stopService());
        return;
      }
      _feedLauncher(const []);
      return _post(shellsNotificationText(_shells));
    }
    final outcomes = <HostOutcome>[];
    final retries = <String, Duration>{};
    final hosts = <String, Host>{};
    for (final (:host, :source) in _channels) {
      hosts[host.id] = host;
      final report = _reports[channelKey(host.id, source)];
      if (report == null) continue;
      outcomes.add(report.toOutcome(host));
      if (report.retryIn case final retry?) retries[host.id] = retry;
    }
    final text = outcomes.isEmpty
        ? watcherNotificationText([
            for (final host in hosts.values)
              HostOutcome(host: host, kind: AgentOutcomeKind.snapshot),
          ])
        : watcherNotificationText(linkAgents(outcomes), retries: retries);
    _feedLauncher(outcomes);
    _post(text);
  }

  void _post(String text) {
    // Most of what a host reports does not move the line, and posting it again is a binder
    // call and a redraw of a row in the shade that already reads that way.
    if (text == _persistent) return;
    _persistent = text;
    FlutterForegroundTask.updateService(
      notificationTitle: watcherNotificationTitle,
      notificationText: text,
    );
  }

  void _feedLauncher(List<HostOutcome> outcomes) {
    final watched = _channels.isEmpty || _book.kinds.isEmpty
        ? const <HostOutcome>[]
        : outcomes;
    final tally = launcherTally(watched);
    if (!_tallied || tally != _tally) {
      _tallied = true;
      _tally = tally;
      unawaited(LauncherWidget.setTally(tally));
    }
    _living = _living.then((_) => _writeLive(watched));
  }

  Future<void> _writeLive(List<HostOutcome> outcomes) async {
    final sends = outcomes.isEmpty
        ? const <OpenSend>[]
        : await LauncherWidget.openSends();
    final previous = _live;
    final live = launcherLive(sends, outcomes, previous ?? const {});
    if (previous != null && mapEquals(previous, live)) return;
    _live = live;
    await LauncherWidget.setLive(live);
  }
}

class _AlertBook {
  final Map<AlertKind, AgentEdges> edges = {
    for (final kind in AlertKind.values) kind: AgentEdges(kind),
  };

  Set<AlertKind> kinds = const {};

  final Map<String, Set<String>> claimed = {};
}

class _HostLoop {
  _HostLoop({
    required this.host,
    required this.source,
    required this.keys,
    required this.client,
    required this.pins,
    required this.watchesPins,
    required this.book,
    required this.onReport,
  });

  Host host;
  final AgentSource source;
  final Ed25519Keys keys;
  final HerdrClient client;
  final PinNotifier pins;
  final bool watchesPins;
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

  String get _key => channelKey(host.id, source);

  bool get _engine => source == AgentSource.engine;

  static const _engineWait = Duration(seconds: 25);

  late final PinShade _shade = PinShade(pins);
  Timer? _pinTicks;
  StreamSubscription<String>? _pinChanges;
  bool _askingPin = false;

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
    _stopPinTicks();
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
      for (final edge in edges.panesOn(_key)) {
        await AlertNotifications.cancel(kindNotificationId(kind, _key, edge));
      }
      edges.reset(_key);
    }
    if (_engine) book.claimed.remove(host.id);
    if (watchesPins) await _tellShade(null);
  }

  void _log(Object error) =>
      debugPrint('upgrade.${source.name} ${host.name}: $error');

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
        throw const HostFailure.unreachable('watch stream ended');
      } on HostFailure catch (error) {
        kind = AgentOutcomeKind.of(error);
        interrupted = _interrupting;
        _interrupting = false;
        if (!interrupted) {
          _log(error.detail ?? error);
          _reportFailure(kind, protocol: error.protocol);
        }
      } on EngineRefused catch (error) {
        kind = AgentOutcomeKind.protocolMismatch;
        interrupted = _interrupting;
        _interrupting = false;
        if (!interrupted) {
          _log(error);
          _reportFailure(kind);
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
    final privateKey = await keys.privateKey(host.keyId);
    if (privateKey == null) {
      throw HostFailure.keyRejected('no private key stored for ${host.keyId}');
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
    if (watchesPins) _startPinTicks(session);
    try {
      if (_engine) return await _watchEngine(session);
      await for (final agents in session.watch()) {
        if (_stopped) return;
        await _onSnapshot(agents, session);
      }
    } finally {
      _stopPinTicks();
    }
  }

  Future<void> _watchEngine(HerdrSession session) async {
    final engine = EngineAgents(session, owner: host.user);
    int? generation;
    while (!_stopped && identical(_session, session)) {
      final seen = await engine.watch(
        generation: generation,
        wait: generation == null ? Duration.zero : _engineWait,
      );
      if (_stopped) return;
      if (seen.generation == generation) continue;
      generation = seen.generation;
      book.claimed[host.id] = {
        for (final agent in seen.agents) ?agent.herdrPane,
      };
      await _onSnapshot(seen.agents, null);
    }
  }

  void _startPinTicks(HerdrSession session) {
    _stopPinTicks();
    _pinChanges = session.pinRequestChanges().listen(
      (listing) {
        if (_stopped || !identical(_session, session)) return;
        unawaited(_tellShade(PinRequest.decodeOpen(listing).firstOrNull));
      },
      onError: (Object error) => _log(error),
      onDone: () => _pollPins(session),
    );
  }

  void _pollPins(HerdrSession session) {
    _pinChanges = null;
    if (_stopped || !identical(_session, session)) return;
    _pinTicks?.cancel();
    _pinTicks = Timer.periodic(
      pinWatchInterval,
      (_) => unawaited(_askPin(session)),
    );
    unawaited(_askPin(session));
  }

  void _stopPinTicks() {
    _pinTicks?.cancel();
    _pinTicks = null;
    unawaited(_pinChanges?.cancel());
    _pinChanges = null;
  }

  Future<void> _askPin(HerdrSession session) async {
    if (_stopped || _askingPin || !identical(_session, session)) return;
    _askingPin = true;
    try {
      final listing = await session.openPinRequests();
      if (_stopped || !identical(_session, session)) return;
      await _tellShade(PinRequest.decodeOpen(listing).firstOrNull);
    } catch (error) {
      _log(error);
    } finally {
      _askingPin = false;
    }
  }

  Future<void> _tellShade(PinRequest? held) =>
      _shade.tell(hostId: host.id, hostName: host.name, held: held);

  Future<void> _onSnapshot(
    List<AgentSnapshot> agents,
    HerdrSession? session,
  ) async {
    _lastAgents = agents;
    _lastGoodAt = DateTime.now();
    // The backoff is per outage: a connection that carried a snapshot has earned the next
    // one its full start.
    _backoff.reset();
    final claimed = _engine ? const <String>{} : book.claimed[host.id] ?? {};
    final alerting = [
      for (final agent in agents)
        if (!claimed.contains(agent.paneId)) agent,
    ];
    for (final kind in AlertKind.values) {
      if (!book.kinds.contains(kind)) continue;
      final delta = book.edges[kind]!.apply(_key, alerting);
      for (final edge in delta.left) {
        await AlertNotifications.cancel(kindNotificationId(kind, _key, edge));
      }
      for (final snapshot in delta.entered) {
        await _post(
          kind,
          snapshot,
          session,
          quiet: delta.quiet.contains(snapshot.edgeId),
        );
      }
    }
    _report(AgentOutcomeKind.snapshot);
  }

  Future<void> _post(
    AlertKind kind,
    AgentSnapshot snapshot,
    HerdrSession? session, {
    bool quiet = false,
  }) async {
    final target = alertTargetFor(host, snapshot, channel: _key);
    if (kind == AlertKind.done) {
      return AlertNotifications.done(target: target, snapshot: snapshot);
    }
    final tail = session == null || _engine
        ? null
        : await session.read(snapshot.pane);
    return AlertNotifications.alert(
      target: target,
      snapshot: snapshot,
      tail: tail,
      quiet: quiet,
    );
  }

  void _report(AgentOutcomeKind kind, {int? protocol, Duration? retryIn}) {
    final requestId = _requestId;
    _requestId = null;
    onReport(
      WatcherReport(
        hostId: host.id,
        source: source,
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
}
