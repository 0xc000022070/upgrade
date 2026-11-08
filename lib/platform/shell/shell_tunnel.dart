import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mosh/dart_mosh.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import 'package:upgrade/platform/ssh/host_failure.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/host_links.dart';
import 'package:upgrade/platform/ssh/connection_supervisor.dart';
import 'package:upgrade/platform/ssh/ssh_settle.dart';
import 'package:upgrade/platform/shell/daemon_link.dart';
import 'package:upgrade/platform/shell/engine_channel.dart';
import 'package:upgrade/platform/shell/liveness_watchdog.dart';
import 'package:upgrade/platform/shell/mosh_channel.dart';
import 'package:upgrade/platform/shell/remote_shell.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/platform/shell/udp_path.dart';
import 'package:upgrade/brand.dart';

/// A tab with a launch command is an exec request rather than a shell request,
/// because typing a line at a login shell is a race against everything that shell reads
/// before its prompt: a host whose rc asks which session to open eats the line's first
/// character, and no delay fixes it because the reader is what runs first.
class ShellTunnel {
  ShellTunnel({
    this.timeout = const Duration(seconds: 10),
    this.moshHealthInterval = const Duration(seconds: 3),
    this.moshGiveUp = const Duration(seconds: 30),
    HostLinks? links,
    this.moshDialer = dialMosh,
    this.engineDialer = dialEngine,
    EngineDaemons? daemons,
    UdpVerdicts? udpVerdicts,
  }) : _daemons = daemons ?? EngineDaemons.shared,
       udpVerdicts = udpVerdicts ?? UdpVerdicts(),
       _connector = SshConnector(links: links, timeout: timeout);

  static const terminalType = 'xterm-256color';

  final Duration timeout;
  final Duration moshHealthInterval;
  final Duration moshGiveUp;
  final MoshDialer moshDialer;
  final EngineDialer engineDialer;
  final EngineDaemons _daemons;
  final SshConnector _connector;

  final UdpVerdicts udpVerdicts;

  final _resumes = <String, ({String epoch, EngineResume state})>{};

  /// Only the verifier knows which refusal an ssh error from the handshake was.
  Future<ShellConnection> open({
    required OpenReason reason,
    required String address,
    required int port,
    required String user,
    required String privateKey,
    required int columns,
    required int rows,
    String? command,
    String? tabSession,
    required HostKeyVerifier verifier,
    void Function(Reconnect retry)? failed,
    bool alone = false,
  }) => _guard(
    '$address:$port',
    () => _connector.establish(
      address: address,
      port: port,
      user: user,
      privateKey: privateKey,
      verifier: verifier,
      reason: reason,
      failed: failed,
      alone: alone,
      startup: (supervisor) => _start(
        supervisor,
        address: address,
        port: port,
        user: user,
        columns: columns,
        rows: rows,
        command: command,
        tabSession: tabSession,
      ),
    ),
    verifier,
  );

  Future<ShellConnection> _start(
    ConnectionSupervisor supervisor, {
    required String address,
    required int port,
    required String user,
    required int columns,
    required int rows,
    required String? command,
    required String? tabSession,
  }) async {
    final config = SSHPtyConfig(
      type: terminalType,
      width: columns,
      height: rows,
    );
    final tab = tabSession;
    if (tab != null && durableShellSession.hasMatch(tab)) {
      final place = '$user@$address:$port/$tab';
      final earlier = _resumes.remove(place);
      if (udpVerdicts.silent(address)) {
        _log(supervisor.endpoint, 'udp silent, ssh until the verdict lapses');
      } else {
        final engine = await _openEngine(
          supervisor: supervisor,
          address: address,
          user: user,
          columns: columns,
          rows: rows,
          command: command ?? 'exec \$SHELL -l',
          tabSession: tab,
          place: place,
          earlier: earlier,
        );
        if (engine != null) return engine;
        final mosh = udpVerdicts.silent(address)
            ? null
            : await _openMosh(
                supervisor: supervisor,
                address: address,
                columns: columns,
                rows: rows,
                command: command ?? 'exec \$SHELL -l',
                tabSession: tab,
              );
        if (mosh != null) return mosh;
      }
    }
    final pty = await openWithin(
      supervisor.pty(command, config),
      timeout,
      (pty) => pty.channel.destroy(),
    );
    _log(
      supervisor.endpoint,
      '${command ?? 'shell'} on $terminalType ${columns}x$rows',
    );
    return SshShellConnection(supervisor, pty);
  }

  Future<EngineShellConnection?> _openEngine({
    required ConnectionSupervisor supervisor,
    required String address,
    required String user,
    required int columns,
    required int rows,
    required String command,
    required String tabSession,
    required String place,
    required ({String epoch, EngineResume state})? earlier,
  }) async {
    var started = false;
    var overUdp = false;
    EngineShellConnection? connection;
    try {
      final start = await _engineCall(
        (command, stdin) =>
            supervisor.exec(command, stdin: stdin, timeout: timeout),
        owner: user,
        tab: tabSession,
        op: 'start',
        args: {
          'tab': tabSession,
          'cols': columns,
          'rows': rows,
          'width_px': 0,
          'height_px': 0,
          'term': terminalType,
          'command': ['sh', '-c', command],
          'resume': true,
        },
      );
      if (start == null) {
        _log(supervisor.endpoint, 'engine: no shell/1, falling back');
        return null;
      }
      final resumed = start['resumed'] == true;
      started = !resumed;
      final udpPort = start['port'];
      final key = start['key'];
      if (udpPort is! int || udpPort < 1 || udpPort > 65535 || key is! String) {
        throw FormatException('engine start answered $start');
      }
      final epoch = start['epoch'];
      final carried = resumed && epoch is String && earlier?.epoch == epoch
          ? earlier?.state
          : null;
      final relay = await _relay(
        supervisor,
        address: address,
        user: user,
        tab: tabSession,
      );
      overUdp = true;
      final channel = await engineDialer(
        host: relay == null ? address : InternetAddress.loopbackIPv4.address,
        port: relay ?? udpPort,
        key: key,
        columns: columns,
        rows: rows,
        resume: carried,
      );
      connection = EngineShellConnection(
        supervisor,
        channel,
        address: address,
        owner: user,
        tab: tabSession,
        port: udpPort,
        daemons: _daemons,
        columns: columns,
        rows: rows,
        continuity: resumed ? ShellContinuity.resumed : ShellContinuity.plain,
        seamless: carried != null,
        onLeave: epoch is String
            ? (state) => _resumes[place] = (epoch: epoch, state: state)
            : null,
        healthInterval: moshHealthInterval,
        giveUp: moshGiveUp,
      );
      await channel.firstContact;
      await connection.ready.timeout(timeout);
      udpVerdicts.clear(address);
      _log(
        supervisor.endpoint,
        'engine $udpPort${relay == null ? '' : ' through the daemon'}'
        ' on ${columns}x$rows'
        '${carried != null
            ? ', carried on'
            : resumed
            ? ', resumed'
            : ''}',
      );
      supervisor.reopenWhenHostDies();
      return connection;
    } catch (error) {
      final fatal = await _fellBack(
        'engine',
        supervisor,
        address,
        error,
        overUdp: overUdp,
        connection: connection,
        cleanup: () async {
          _resumes.remove(place);
          if (!started) return;
          await _engineCall(
            (command, stdin) =>
                supervisor.exec(command, stdin: stdin, timeout: timeout),
            owner: user,
            tab: tabSession,
            op: 'stop',
            args: {'tab': tabSession},
          );
        },
      );
      if (fatal) rethrow;
      return null;
    }
  }

  Future<int?> _relay(
    ConnectionSupervisor supervisor, {
    required String address,
    required String user,
    required String tab,
  }) async {
    try {
      return await _daemons.attach(
        address: address,
        user: user,
        tab: tab,
        timeout: timeout,
        start: () => _engineCall(
          (command, stdin) =>
              supervisor.exec(command, stdin: stdin, timeout: timeout),
          service: 'daemon/1',
          owner: user,
          tab: tab,
          op: 'start',
          args: const {},
        ),
      );
    } catch (error) {
      _log(supervisor.endpoint, 'daemon fallback: $error');
      return null;
    }
  }

  Future<MoshShellConnection?> _openMosh({
    required ConnectionSupervisor supervisor,
    required String address,
    required int columns,
    required int rows,
    required String command,
    required String tabSession,
  }) async {
    String? serverPath;
    var overUdp = false;
    MoshShellConnection? connection;
    try {
      serverPath = await _moshServer(supervisor);
      if (serverPath == null) return null;
      final cleanup = await supervisor.exec(
        moshServerCleanupCommand(tabSession),
        timeout: timeout,
      );
      if (cleanup == null || moshSwept(cleanup.out) == null) return null;
      final launch = MoshSshBootstrap(
        serverBinary: serverPath,
        locale: 'C.UTF-8',
        term: terminalType,
      ).command();
      final bootstrap = await supervisor.exec(
        '$moshTabVariable=${shellQuote(tabSession)} $launch '
        '${moshServerMark(tabSession)} -- '
        'sh -c ${shellQuote(command)}',
        timeout: timeout,
      );
      if (bootstrap == null) return null;
      if (!bootstrap.ok) {
        await supervisor.exec(
          moshServerCleanupCommand(tabSession),
          timeout: timeout,
        );
        return null;
      }
      final server = MoshServerConfig.parse(
        '${bootstrap.out}\n${bootstrap.err}',
        host: address,
      );
      overUdp = true;
      final channel = await moshDialer(
        server: server,
        columns: columns,
        rows: rows,
      );
      connection = MoshShellConnection(
        supervisor,
        channel,
        address: address,
        tab: tabSession,
        columns: columns,
        rows: rows,
        healthInterval: moshHealthInterval,
        giveUp: moshGiveUp,
      );
      await channel.firstContact;
      await connection.ready.timeout(timeout);
      udpVerdicts.clear(address);
      _log(supervisor.endpoint, 'mosh ${server.port} on ${columns}x$rows');
      supervisor.reopenWhenHostDies();
      return connection;
    } catch (error) {
      final fatal = await _fellBack(
        'mosh',
        supervisor,
        address,
        error,
        overUdp: overUdp,
        connection: connection,
        cleanup: serverPath == null
            ? null
            : () => supervisor.exec(
                moshServerCleanupCommand(tabSession),
                timeout: timeout,
              ),
      );
      if (fatal) rethrow;
      return null;
    }
  }

  Future<bool> _fellBack(
    String name,
    ConnectionSupervisor supervisor,
    String address,
    Object error, {
    required bool overUdp,
    required _ChannelConnection<Object>? connection,
    required Future<void> Function()? cleanup,
  }) async {
    final link = !overUdp && await _linkFailed(supervisor, error);
    if (!link && error is! Error && !_silent(supervisor, address, error)) {
      _log(supervisor.endpoint, '$name fallback: $error');
    }
    await connection?.abandon();
    if (cleanup != null) {
      try {
        await cleanup();
      } catch (error) {
        _log(supervisor.endpoint, '$name cleanup after fallback: $error');
      }
    }
    return link || error is Error;
  }

  /// A startup error is the link's when SSH threw it, except a stalled command on an open
  /// channel, which counts only if a keepalive round finds the link dead too.
  static Future<bool> _linkFailed(
    ConnectionSupervisor supervisor,
    Object error,
  ) async {
    if (!isHostFailure(error) && !isKeyFailure(error)) return false;
    if (error is! TimeoutException || error is ChannelOpenTimeout) return true;
    return !await supervisor.check();
  }

  bool _silent(ConnectionSupervisor supervisor, String address, Object error) {
    if (error is! UdpSilent) return false;
    udpVerdicts.record(address);
    _log(
      supervisor.endpoint,
      '$error; ssh for ${UdpSilent.spell(udpVerdicts.ttl)}',
    );
    return true;
  }

  Future<String?> _moshServer(HostChannels channels) async {
    final result = await channels.exec(
      moshServerProbeCommand(),
      timeout: timeout,
    );
    if (result == null || !result.ok) return null;
    for (final line in result.out.split('\n')) {
      if (!line.startsWith('UPGRADE_MOSH=/')) continue;
      final path = line.substring('UPGRADE_MOSH='.length).trim();
      if (!path.contains(RegExp(r'[\r\n]'))) return path;
    }
    return null;
  }

  Future<T> _guard<T>(
    String endpoint,
    Future<T> Function() body, [
    HostKeyVerifier? verifier,
  ]) async {
    try {
      return await body();
    } catch (error) {
      // The refusal wins over whatever the transport threw: which error a closing handshake
      // surfaces depends on how far it had got, and the verifier's answer does not.
      final failure = shellFailureFor(error, verifier?.refusal);
      _log(endpoint, '${failure ?? error}');
      throw failure ?? error;
    }
  }
}

/// The terminal never waits for this; a miss leaves background reads null until the next.
Future<void> _reopen(
  ConnectionSupervisor supervisor,
  ReopenReason reason,
) async {
  try {
    await supervisor.open(reason);
  } catch (error) {
    _log(supervisor.endpoint, 'ssh control path: $error');
  }
}

void _log(String endpoint, Object message) =>
    debugPrint('$appSlug.shell $endpoint: $message');

/// Null for anything unexpected: a bug in the layer above reads better as itself than as
/// a reason line.
ShellFailure? shellFailureFor(Object error, [HostKeyRefusal? refusal]) =>
    switch (error) {
      ShellFailure() => error,
      _ => switch (classifyHostFailure(error, refusal)) {
        null => null,
        final kind => ShellFailure(switch (kind) {
          HostFailureKind.unresolved => ShellFailureKind.unresolved,
          HostFailureKind.unreachable => ShellFailureKind.unreachable,
          HostFailureKind.keyRejected => ShellFailureKind.keyRejected,
          HostFailureKind.refused => ShellFailureKind.shellRefused,
          HostFailureKind.streamClosed => ShellFailureKind.streamClosed,
          HostFailureKind.hostKeyUnverified =>
            ShellFailureKind.hostKeyUnverified,
          HostFailureKind.hostKeyChanged => ShellFailureKind.hostKeyChanged,
        }, detail: _words(error)),
      },
    };

String _words(Object error) => switch (error) {
  SSHSocketError() => _words(error.error),
  SocketException() => socketWords(error),
  TimeoutException() => timeoutWords(error),
  _ => '$error',
};

abstract class _ChannelConnection<E> implements ShellConnection {
  _ChannelConnection(
    this._supervisor, {
    required this.address,
    required this.columns,
    required this.rows,
    required this.healthInterval,
    required this.giveUp,
  });

  final String address;
  final ConnectionSupervisor _supervisor;
  final Duration healthInterval;
  final Duration giveUp;

  final _reading = <StreamSubscription<void>>[];
  final _pending = <E>[];
  final _exit = Completer<int?>();
  final _ready = Completer<void>();
  int columns;
  int rows;
  var _closed = false;
  var _suspended = false;
  Future<void>? _suspending;
  ShellEnded? _ended;
  var _heard = false;

  String get _name;

  LivenessWatchdog get _liveness;

  Future<void> _suspendWire();

  Future<void> _rehomeWire();

  Future<void> _closeWire();

  void _probeAgain();

  Future<bool?> _serverGone();

  late final StreamController<E> _out = StreamController<E>.broadcast(
    onListen: () {
      _supervisor.claim();
      scheduleMicrotask(_drain);
    },
  );

  Future<void> get ready => _ready.future;

  @override
  Stream<ShellConnectionHealth> get health => _liveness.health;

  @override
  Future<int?> get exitCode => _exit.future;

  @override
  ShellEnded? get ended => _ended;

  @override
  HostChannels get channels => _supervisor.channels;

  @override
  Stream<ControlLink> get controlLink => _supervisor.controlLink;

  @override
  Future<HostChannels?> channelsFor(UserAction action) async =>
      _closed ? null : _supervisor.open(action);

  @override
  Future<void> rehome({NetworkChanged? network}) async {
    if (_closed) return;
    if (_suspended) {
      if (network != null) await _supervisor.drop(network);
      return;
    }
    _liveness.report(ShellConnectionHealth.reconnecting);
    await _rehomeWire();
    _liveness.forget();
    _heard = false;
    _probeAgain();
    if (network == null) return;
    await _supervisor.drop(network);
    unawaited(_reopenAndAsk(network));
  }

  @override
  Future<void> suspend(AppSuspended reason) {
    if (_closed || _suspended) return Future.value();
    _suspended = true;
    _liveness.stop();
    return _suspending = () async {
      await _suspendWire();
      await _supervisor.drop(reason);
    }();
  }

  /// The suspend's drop lands before this resume's open, never after it.
  @override
  Future<void> resume(AppResumed reason) async {
    if (_closed || !_suspended) return;
    _suspended = false;
    await _suspending?.then((_) {}, onError: (Object _) {});
    if (_closed) return;
    await rehome();
    if (_ready.isCompleted && !_closed && !_suspended) _liveness.start();
    await _reopenAndAsk(reason);
  }

  /// UDP says nothing about a port nobody listens on, so a channel still silent once the
  /// host is reached asks it whether its server survived, e.g. a reboot while away.
  Future<void> _reopenAndAsk(ReopenReason reason) async {
    await _reopen(_supervisor, reason);
    if (!_unheard) return;
    final gone = await _serverGone();
    if (gone != true || !_unheard) return;
    _end('$_name: the server is gone from the host, dropping the channel');
  }

  bool get _unheard => !_closed && !_suspended && !_heard && _ended == null;

  @override
  bool accepts(DropReason reason) => _supervisor.accepts(reason);

  @override
  Future<void> close(DropReason reason) async {
    if (_closed || !_supervisor.accepts(reason)) return;
    final dropped = _supervisor.drop(reason);
    await _teardown(report: true);
    await dropped;
  }

  @override
  Future<bool> discard() async {
    if (_closed || _supervisor.claimed) return false;
    final dropped = _supervisor.discard();
    await _teardown(report: true);
    return dropped;
  }

  Future<void> _teardown({required bool report}) async {
    _closed = true;
    _liveness.stop();
    if (report) _liveness.report(ShellConnectionHealth.disconnected);
    for (final subscription in _reading) {
      await subscription.cancel();
    }
    await _closeWire();
    _finish(null);
    if (!_ready.isCompleted) _ready.complete();
    await _out.close();
    await _liveness.close();
  }

  /// Leaves the SSH connection available for the plain fallback in the same dial.
  Future<void> abandon() async {
    if (_closed) return;
    await _teardown(report: false);
  }

  void _drain() {
    if (_out.isClosed || !_out.hasListener) return;
    for (final event in _pending) {
      _out.add(event);
    }
    _pending.clear();
  }

  void _finish(int? code) {
    if (!_closed) {
      _liveness.report(ShellConnectionHealth.disconnected);
      _ended ??= _supervisor.terminalEnded();
    }
    if (!_exit.isCompleted) _exit.complete(code);
  }

  void _abandonSilentChannel() =>
      _end('$_name: no answer in ${giveUp.inSeconds}s, dropping the channel');

  void _end(String why) {
    _ended ??= _supervisor.terminalEnded();
    _liveness.report(ShellConnectionHealth.disconnected);
    _log(_supervisor.endpoint, why);
    if (!_out.isClosed) {
      _out.addError(
        ShellFailure(
          ShellFailureKind.streamClosed,
          detail: 'the $_name channel stopped answering',
        ),
      );
    }
  }
}

Future<bool> _sweep(HostChannels channels, String session) async {
  final swept = await channels.exec(
    moshServerCleanupCommand(session),
    timeout: remoteCommandDeadline,
  );
  return swept != null && moshSwept(swept.out) != null;
}

class MoshShellConnection extends _ChannelConnection<Uint8List> {
  MoshShellConnection(
    super._supervisor,
    this._mosh, {
    required super.address,
    required this.tab,
    required super.columns,
    required super.rows,
    super.healthInterval = const Duration(seconds: 3),
    super.giveUp = const Duration(seconds: 30),
  }) {
    _reading.add(_mosh.output.listen(_emit));
    _reading.add(
      _mosh.errors.listen(
        (error) => _log(_supervisor.endpoint, 'mosh: $error'),
      ),
    );
    _reading.add(_mosh.echoAcks.listen(_acknowledge));
    _reading.add(_mosh.contacts.listen((_) => _contact()));
    _mosh.done.then(
      (_) => _finish(0),
      onError: (Object error) {
        _log(_supervisor.endpoint, 'mosh: $error');
        _finish(null);
      },
    );
  }

  final MoshChannel _mosh;
  final String tab;

  @override
  ShellContinuity get continuity => ShellContinuity.plain;

  @override
  ShellTransport get transport => ShellTransport.mosh;

  @override
  String get _name => 'mosh';

  int? _probeState;

  @override
  late final _liveness = LivenessWatchdog(
    interval: healthInterval,
    giveUp: giveUp,
    probing: () => _probeState != null,
    probe: () => _probeState = _mosh.resize(columns, rows),
    onSilent: _abandonSilentChannel,
  );

  @override
  Stream<Uint8List> get output => _out.stream;

  @override
  Stream<Uint8List> get snapshots => const Stream.empty();

  @override
  Stream<String> get foregroundProcesses => const Stream.empty();

  @override
  void write(Uint8List bytes) {
    if (_closed) return;
    _mosh.send(bytes);
  }

  @override
  void resize(int columns, int rows, {int widthPx = 0, int heightPx = 0}) {
    if (_closed) return;
    this.columns = columns;
    this.rows = rows;
    _probeState = _mosh.resize(columns, rows);
  }

  @override
  Future<bool> terminateRemote(String session, {UserAction? action}) async {
    if (!durableShellSession.hasMatch(session)) return false;
    final channels = action == null ? _supervisor : await channelsFor(action);
    return channels != null && await _sweep(channels, session);
  }

  @override
  Future<bool?> _serverGone() async {
    final found = await _supervisor.exec(
      moshServerFindCommand(tab),
      timeout: remoteCommandDeadline,
    );
    final up = found == null ? null : moshServerFound(found.out);
    return up == null ? null : !up;
  }

  @override
  Future<void> _suspendWire() => _mosh.suspend();

  @override
  Future<void> _rehomeWire() => _mosh.rehome();

  @override
  Future<void> _closeWire() => _mosh.close();

  @override
  void _probeAgain() => _probeState = _mosh.resize(columns, rows);

  void _emit(Uint8List bytes) {
    if (_closed || bytes.isEmpty) return;
    _contact();
    if (!_ready.isCompleted) {
      _ready.complete();
      _liveness.start();
    }
    _pending.add(bytes);
    _drain();
  }

  void _acknowledge(int state) {
    final probe = _probeState;
    if (probe == null || state < probe) return;
    _contact();
  }

  void _contact() {
    _heard = true;
    _probeState = null;
    _liveness.heard();
  }
}

Future<Map<String, Object?>?> _engineCall(
  Future<ExecResult?> Function(String command, Uint8List stdin) run, {
  String service = 'shell/1',
  required String owner,
  required String tab,
  required String op,
  required Map<String, Object?> args,
}) async {
  final result = await run(
    '$moshTabVariable=${shellQuote(tab)} upgraded',
    Uint8List.fromList(
      utf8.encode(jsonEncode(engineRequest(service, op, args, owner: owner))),
    ),
  );
  return result == null ? null : _engineResult(result.out);
}

Map<String, Object?>? _engineResult(String out) {
  final Object? reply;
  try {
    reply = jsonDecode(out);
  } on FormatException {
    // ignored: an unreadable reply is a failed call, as a refused one is.
    return null;
  }
  if (reply is! Map<String, Object?> || reply['ok'] != true) return null;
  final body = reply['result'];
  return body is Map<String, Object?> ? body : null;
}

class EngineShellConnection extends _ChannelConnection<EngineEvent> {
  EngineShellConnection(
    super._supervisor,
    this._engine, {
    required super.address,
    required this.owner,
    required this.tab,
    required this.port,
    required super.columns,
    required super.rows,
    required this.continuity,
    this.seamless = false,
    this.onLeave,
    required this.daemons,
    super.healthInterval = const Duration(seconds: 3),
    super.giveUp = const Duration(seconds: 30),
  }) {
    _reading.add(_engine.events.listen(_emit));
    _reading.add(
      _engine.errors.listen(
        (error) => _log(_supervisor.endpoint, 'engine: $error'),
      ),
    );
    _reading.add(
      _engine.contacts.listen((_) {
        _contact();
        // A stream carried on owes no output: an idle shell may have none to send.
        if (seamless) _settle();
      }),
    );
  }

  final String owner;
  final String tab;
  final int port;
  final EngineChannel _engine;
  final EngineDaemons daemons;

  final bool seamless;

  final void Function(EngineResume state)? onLeave;

  @override
  final ShellContinuity continuity;

  @override
  ShellTransport get transport => ShellTransport.engine;

  @override
  String get _name => 'engine';

  var _probing = false;
  var _stopped = false;
  var _delivered = 0;

  @override
  late final _liveness = LivenessWatchdog(
    interval: healthInterval,
    giveUp: giveUp,
    probing: () => _probing,
    probe: () {
      _probing = true;
      _engine.poke();
    },
    onSilent: _abandonSilentChannel,
    probeOnMiss: true,
  );

  @override
  Stream<Uint8List> get output =>
      _out.stream.where((event) => event is EnginePty).map((event) {
        _delivered++;
        return (event as EnginePty).bytes;
      });

  @override
  Stream<Uint8List> get snapshots =>
      _out.stream.where((event) => event is EngineSnapshot).map((event) {
        _delivered++;
        return (event as EngineSnapshot).bytes;
      });

  @override
  Stream<String> get foregroundProcesses =>
      _out.stream.where((event) => event is EngineForeground).map((event) {
        _delivered++;
        return (event as EngineForeground).processes;
      });

  @override
  void write(Uint8List bytes) {
    if (_closed) return;
    _engine.send(bytes);
  }

  @override
  void resize(int columns, int rows, {int widthPx = 0, int heightPx = 0}) {
    if (_closed) return;
    this.columns = columns;
    this.rows = rows;
    _engine.resize(columns, rows, widthPx: widthPx, heightPx: heightPx);
  }

  @override
  Future<bool> terminateRemote(String session, {UserAction? action}) async {
    if (!durableShellSession.hasMatch(session)) return false;
    if (session == tab) {
      _stopped = true;
      await _engine.close(end: true);
    }
    final channels = action == null ? _supervisor : await channelsFor(action);
    if (channels == null) return false;
    final stopped = await _call(channels, session, 'stop', {'tab': session});
    final swept = await channels.exec(
      moshServerCleanupCommand(session),
      timeout: remoteCommandDeadline,
    );
    final sweep = swept == null ? null : moshSwept(swept.out);
    if (sweep == null) return false;
    if (stopped != null) return true;
    _log(_supervisor.endpoint, 'engine: no stop for $session, swept');
    return sweep == MoshSweep.environments;
  }

  Future<Map<String, Object?>?> _call(
    HostChannels channels,
    String session,
    String op,
    Map<String, Object?> args,
  ) async {
    Future<Map<String, Object?>?> overSsh(
      String service,
      String op,
      Map<String, Object?> args,
    ) => _engineCall(
      (command, stdin) =>
          channels.exec(command, stdin: stdin, timeout: remoteCommandDeadline),
      service: service,
      owner: owner,
      tab: session,
      op: op,
      args: args,
    );
    final String? answer;
    try {
      answer = await daemons.call(
        address: address,
        user: owner,
        body: jsonEncode(engineRequest('shell/1', op, args, owner: owner)),
        timeout: remoteCommandDeadline,
        start: () => overSsh('daemon/1', 'start', const {}),
      );
    } catch (error) {
      _log(_supervisor.endpoint, 'engine $op through the daemon: $error');
      return null;
    }
    return answer == null
        ? overSsh('shell/1', op, args)
        : _engineResult(answer);
  }

  @override
  Future<bool?> _serverGone() async {
    final listed = await _call(_supervisor, tab, 'list', const {});
    final shells = listed?['shells'];
    if (shells is! List) return null;
    return !shells.any(
      (shell) => shell is Map && shell['tab'] == tab && shell['port'] == port,
    );
  }

  @override
  Future<void> _suspendWire() => _engine.suspend();

  @override
  Future<void> _rehomeWire() => _engine.rehome();

  @override
  Future<void> _closeWire() async {
    await _engine.close();
    _leave();
  }

  @override
  void _probeAgain() => _probing = true;

  void _leave() {
    if (_stopped || _exit.isCompleted) return;
    final state = _engine.resumable;
    if (state != null && state.emitted == _delivered) onLeave?.call(state);
  }

  void _emit(EngineEvent event) {
    if (_closed) return;
    _contact();
    _settle();
    if (event is EngineExit) {
      scheduleMicrotask(() => _finish(event.status));
      return;
    }
    _pending.add(event);
    _drain();
  }

  void _settle() {
    if (_closed || _ready.isCompleted) return;
    _ready.complete();
    _liveness.start();
  }

  void _contact() {
    _heard = true;
    _probing = false;
    _liveness.heard();
  }
}

class SshShellConnection implements ShellConnection {
  SshShellConnection(this._supervisor, this._pty) {
    _reading.add(_pty.stdout.listen(_emit, onError: _onStreamError));
    _reading.add(_pty.stderr.listen(_emit, onError: _onStreamError));
    _pty.done.then(
      (_) => _finish(_pty.exitCode, signal: _pty.exitSignal?.signalName),
      onError: (Object error) {
        _onStreamError(error);
        _finish(null);
      },
    );
  }

  static const stallWindow = Duration(seconds: 5);

  final ConnectionSupervisor _supervisor;
  final SSHSession _pty;
  Timer? _stall;
  @override
  ShellContinuity get continuity => ShellContinuity.plain;

  @override
  ShellTransport get transport => ShellTransport.ssh;

  @override
  Stream<ShellConnectionHealth> get health => const Stream.empty();
  final _reading = <StreamSubscription<Uint8List>>[];
  final _exit = Completer<int?>();
  var _closed = false;
  var _failed = false;
  ShellEnded? _ended;

  /// A login shell prints its banner and its prompt the moment the channel opens, which is
  /// before the store that opened it has had a turn to subscribe, and a prompt that never
  /// arrives reads as a shell that never started.
  final _pending = <Uint8List>[];

  late final StreamController<Uint8List> _out =
      StreamController<Uint8List>.broadcast(
        onListen: () {
          _supervisor.claim();
          scheduleMicrotask(_drain);
        },
      );

  @override
  Stream<Uint8List> get output => _out.stream;

  @override
  Stream<Uint8List> get snapshots => const Stream.empty();

  @override
  Stream<String> get foregroundProcesses => const Stream.empty();

  @override
  Future<int?> get exitCode => _exit.future;

  @override
  ShellEnded? get ended => _ended;

  /// A half-open link swallows writes until its keepalive gives up, minutes later; a
  /// write nothing answers asks sooner. One watchdog at a time, so typing costs no timers.
  @override
  void write(Uint8List bytes) {
    _pty.write(bytes);
    if (_closed || _exit.isCompleted || _stall != null) return;
    _stall = Timer(stallWindow, () {
      _stall = null;
      if (!_closed && !_exit.isCompleted) unawaited(_supervisor.check());
    });
  }

  @override
  void resize(int columns, int rows, {int widthPx = 0, int heightPx = 0}) =>
      _pty.resizeTerminal(columns, rows);

  @override
  HostChannels get channels => _supervisor.channels;

  /// The terminal is a channel on the host, so the host going is the terminal ending.
  @override
  Stream<ControlLink> get controlLink => const Stream.empty();

  /// Never dials: a fresh host would not carry this tab's pty.
  @override
  Future<HostChannels?> channelsFor(UserAction action) async {
    if (_exit.isCompleted) return null;
    final live = await _supervisor.answers();
    return !live || _exit.isCompleted ? null : _supervisor.channels;
  }

  @override
  Future<bool> terminateRemote(String session, {UserAction? action}) async =>
      durableShellSession.hasMatch(session) &&
      await _sweep(_supervisor, session);

  /// Nothing to carry: a link the old network took fails its check and ends, which ends
  /// the pty as a lost stream, and the tab's schedule dials again.
  @override
  Future<void> rehome({NetworkChanged? network}) async {
    if (_closed || _exit.isCompleted) return;
    await _supervisor.check();
  }

  @override
  Future<void> suspend(AppSuspended reason) async {}

  @override
  Future<void> resume(AppResumed reason) async {}

  @override
  bool accepts(DropReason reason) => _supervisor.accepts(reason);

  @override
  Future<void> close(DropReason reason) async {
    if (_closed || !_supervisor.accepts(reason)) return;
    final dropped = _supervisor.drop(reason);
    await _shut();
    await dropped;
  }

  @override
  Future<bool> discard() async {
    if (_closed || _supervisor.claimed) return false;
    final dropped = _supervisor.discard();
    await _shut();
    return dropped;
  }

  Future<void> _shut() async {
    _closed = true;
    _stall?.cancel();
    _stall = null;
    for (final subscription in _reading) {
      await subscription.cancel();
    }
    // close() only sends EOF, which a pty shell ignores; destroy sends CHANNEL_CLOSE.
    _pty.channel.destroy();
    _finish(null);
    await _out.close();
  }

  /// Everything queues, so a chunk that arrives in the same turn as the first listener
  /// still lands behind the ones that came before it.
  void _emit(Uint8List bytes) {
    _stall?.cancel();
    _stall = null;
    _pending.add(bytes);
    _drain();
  }

  void _drain() {
    if (_out.isClosed || !_out.hasListener) return;
    for (final bytes in _pending) {
      _out.add(bytes);
    }
    _pending.clear();
  }

  void _onStreamError(Object error) {
    if (!_closed) _ended ??= _supervisor.terminalEnded();
    if (_failed || _out.isClosed) return;
    _failed = true;
    _out.addError(
      shellFailureFor(error) ??
          ShellFailure(ShellFailureKind.streamClosed, detail: '$error'),
    );
  }

  /// dartssh2 ends every channel of a link that died cleanly and with no exit status, so
  /// an end with neither a code nor a [signal] that this side did not ask for is the
  /// link, not the shell.
  void _finish(int? code, {String? signal}) {
    _stall?.cancel();
    _stall = null;
    if (!_closed && code == null && signal == null && !_exit.isCompleted) {
      _onStreamError(
        const ShellFailure(
          ShellFailureKind.streamClosed,
          detail: 'the link to the host ended',
        ),
      );
    }
    if (!_closed) _ended ??= _supervisor.terminalEnded();
    if (!_exit.isCompleted) _exit.complete(code);
  }
}

/// Nothing of the socket's report of itself: the address and port it prints are the
/// phone's end of a connection that never existed.
String socketWords(SocketException error) =>
    (error.osError?.message ?? error.message).toLowerCase();

String timeoutWords(TimeoutException error) {
  final duration = error.duration;
  return duration == null ? 'no answer' : 'no answer in ${duration.inSeconds}s';
}
