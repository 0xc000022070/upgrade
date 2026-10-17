import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mosh/dart_mosh.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/platform/ssh/host_keys.dart';
import 'package:upgrade/platform/ssh/host_links.dart';
import 'package:upgrade/platform/ssh/connection_supervisor.dart';
import 'package:upgrade/platform/ssh/ssh_settle.dart';
import 'package:upgrade/platform/shell/engine_channel.dart';
import 'package:upgrade/platform/shell/mosh_channel.dart';
import 'package:upgrade/platform/shell/remote_shell.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/platform/shell/udp_path.dart';

/// A tab with a persistent session is an exec request rather than a shell request,
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
    UdpVerdicts? udpVerdicts,
  }) : udpVerdicts = udpVerdicts ?? UdpVerdicts(),
       _connector = SshConnector(links: links, timeout: timeout);

  static const terminalType = 'xterm-256color';

  final Duration timeout;
  final Duration moshHealthInterval;
  final Duration moshGiveUp;
  final MoshDialer moshDialer;
  final EngineDialer engineDialer;
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
    String? persistentSession,
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
        persistentSession: persistentSession,
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
    required String? persistentSession,
  }) async {
    final config = SSHPtyConfig(
      type: terminalType,
      width: columns,
      height: rows,
    );
    final requestedSession = persistentSession;
    final durable = requestedSession == null
        ? null
        : await _durableTarget(supervisor, requestedSession);
    final run = durable == null
        ? command
        : durableShellCommand(
            durable.tmux,
            durable.session,
            command ?? 'exec \$SHELL -l',
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
          command: run ?? 'exec \$SHELL -l',
          tabSession: tab,
          place: place,
          earlier: earlier,
          continuity: durable?.continuity ?? ShellContinuity.plain,
          tmux: durable?.tmux,
        );
        if (engine != null) return engine;
        final mosh = udpVerdicts.silent(address)
            ? null
            : await _openMosh(
                supervisor: supervisor,
                address: address,
                columns: columns,
                rows: rows,
                command: run ?? 'exec \$SHELL -l',
                tabSession: tab,
                continuity: durable?.continuity ?? ShellContinuity.plain,
                tmux: durable?.tmux,
              );
        if (mosh != null) return mosh;
      }
    }
    final pty = await openWithin(
      supervisor.pty(run, config),
      timeout,
      (pty) => pty.channel.destroy(),
    );
    _log(
      supervisor.endpoint,
      '${run ?? 'shell'} on $terminalType ${columns}x$rows',
    );
    return SshShellConnection(
      supervisor,
      pty,
      continuity: durable?.continuity ?? ShellContinuity.plain,
      tmux: durable?.tmux,
    );
  }

  Future<_DurableTarget?> _durableTarget(
    HostChannels channels,
    String session,
  ) async {
    if (!durableShellSession.hasMatch(session)) return null;
    final result = await channels.exec(
      durableShellProbeCommand(session),
      timeout: timeout,
    );
    if (result == null || !result.ok) return null;
    String? tmux;
    var resumed = false;
    for (final line in result.out.split('\n')) {
      if (line.startsWith('UPGRADE_TMUX=/')) {
        tmux = line.substring('UPGRADE_TMUX='.length).trim();
      } else if (line.trim() == 'UPGRADE_RESUME=1') {
        resumed = true;
      }
    }
    if (tmux == null || tmux.contains(RegExp(r'[\r\n]'))) return null;
    return _DurableTarget(
      session,
      tmux,
      resumed ? ShellContinuity.resumed : ShellContinuity.started,
    );
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
    required ShellContinuity continuity,
    required String? tmux,
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
      overUdp = true;
      final channel = await engineDialer(
        host: address,
        port: udpPort,
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
        columns: columns,
        rows: rows,
        continuity: resumed ? ShellContinuity.resumed : continuity,
        tmux: tmux,
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
        'engine $udpPort on ${columns}x$rows'
        '${carried != null
            ? ', carried on'
            : resumed
            ? ', resumed'
            : ''}',
      );
      supervisor.reopenWhenHostDies();
      return connection;
    } catch (error) {
      final link = !overUdp && await _linkFailed(supervisor, error);
      if (!link && error is! Error && !_silent(supervisor, address, error)) {
        _log(supervisor.endpoint, 'engine fallback: $error');
      }
      await connection?.abandon();
      _resumes.remove(place);
      if (started) {
        try {
          await _engineCall(
            (command, stdin) =>
                supervisor.exec(command, stdin: stdin, timeout: timeout),
            owner: user,
            tab: tabSession,
            op: 'stop',
            args: {'tab': tabSession},
          );
        } catch (error) {
          _log(supervisor.endpoint, 'engine stop after fallback: $error');
        }
      }
      if (link || error is Error) rethrow;
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
    required ShellContinuity continuity,
    required String? tmux,
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
      if (cleanup == null || !cleanup.ok) return null;
      final launch = MoshSshBootstrap(
        serverBinary: serverPath,
        locale: 'C.UTF-8',
        term: terminalType,
      ).command();
      final bootstrap = await supervisor.exec(
        '$moshTabVariable=${shellQuote(tabSession)} $launch -- '
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
        columns: columns,
        rows: rows,
        continuity: continuity,
        tmux: tmux,
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
      final link = !overUdp && await _linkFailed(supervisor, error);
      if (!link && error is! Error && !_silent(supervisor, address, error)) {
        _log(supervisor.endpoint, 'mosh fallback: $error');
      }
      await connection?.abandon();
      if (serverPath != null) {
        try {
          await supervisor.exec(
            moshServerCleanupCommand(tabSession),
            timeout: timeout,
          );
        } catch (error) {
          _log(supervisor.endpoint, 'mosh cleanup after fallback: $error');
        }
      }
      if (link || error is Error) rethrow;
      return null;
    }
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

class _DurableTarget {
  const _DurableTarget(this.session, this.tmux, this.continuity);

  final String session;
  final String tmux;
  final ShellContinuity continuity;
}

void _log(String endpoint, Object message) =>
    debugPrint('upgrade.shell $endpoint: $message');

/// Null for anything unexpected: a bug in the layer above reads better as itself than as
/// a reason line.
ShellFailure? shellFailureFor(Object error, [HostKeyRefusal? refusal]) =>
    switch (error) {
      ShellFailure() => error,
      _ when refusal != null => ShellFailure(switch (refusal) {
        HostKeyRefusal.unverified => ShellFailureKind.hostKeyUnverified,
        HostKeyRefusal.changed => ShellFailureKind.hostKeyChanged,
      }, detail: '$error'),
      // Nobody refused anything and the key still did not check out: the server's signature
      // was wrong, or it swapped its key across a rekey.
      SSHHostkeyError() => ShellFailure(
        ShellFailureKind.hostKeyChanged,
        detail: '$error',
      ),
      // The channel open, or the pty or shell request on it. All three are the same sentence
      // to the user: sshd would not give them a shell.
      SSHChannelOpenError() => ShellFailure(
        ShellFailureKind.shellRefused,
        detail: '$error',
      ),
      SSHChannelRequestError() => ShellFailure(
        ShellFailureKind.shellRefused,
        detail: '$error',
      ),
      SSHAuthFailError() => ShellFailure(
        ShellFailureKind.keyRejected,
        detail: '$error',
      ),
      SSHKeyDecodeError() => ShellFailure(
        ShellFailureKind.keyRejected,
        detail: '$error',
      ),
      // Auth that ended without the server saying no: the connection went away under it, or
      // nothing came back at all.
      SSHAuthAbortError(:final reason?) =>
        shellFailureFor(reason, refusal) ??
            ShellFailure(ShellFailureKind.streamClosed, detail: '$error'),
      SSHAuthAbortError() => ShellFailure(
        ShellFailureKind.streamClosed,
        detail: '$error',
      ),
      SSHStateError() => ShellFailure(
        ShellFailureKind.streamClosed,
        detail: '$error',
      ),
      // The socket's own error, unwrapped here so a refused connection under a handshake
      // reads as the refusal it is.
      SSHSocketError() =>
        shellFailureFor(error.error, refusal) ??
            ShellFailure(ShellFailureKind.unreachable, detail: '$error'),
      // The only failure that happens before an address exists. The test is [HerdrClient]'s,
      // deliberately: which errno family a lookup failure lands in is a platform detail.
      SocketException() when HerdrClient.isLookupFailure(error) => ShellFailure(
        ShellFailureKind.unresolved,
        detail: socketWords(error),
      ),
      SocketException() => ShellFailure(
        ShellFailureKind.unreachable,
        detail: socketWords(error),
      ),
      TimeoutException() => ShellFailure(
        ShellFailureKind.unreachable,
        detail: timeoutWords(error),
      ),
      SSHError() => ShellFailure(
        ShellFailureKind.unreachable,
        detail: '$error',
      ),
      _ => null,
    };

/// The control connection is replaced on a network handover and opened again on resume;
/// the terminal never waits for it.
class MoshShellConnection implements ShellConnection {
  MoshShellConnection(
    this._supervisor,
    this._mosh, {
    required this.address,
    required this.columns,
    required this.rows,
    required this.continuity,
    required this.tmux,
    this.healthInterval = const Duration(seconds: 3),
    this.giveUp = const Duration(seconds: 30),
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

  final String address;
  final MoshChannel _mosh;
  final ConnectionSupervisor _supervisor;
  final Duration healthInterval;
  final Duration giveUp;
  final String? tmux;

  @override
  final ShellContinuity continuity;

  @override
  ShellTransport get transport => ShellTransport.mosh;

  final _reading = <StreamSubscription<void>>[];
  final _pending = <Uint8List>[];
  final _exit = Completer<int?>();
  final _ready = Completer<void>();
  final _ticking = Stopwatch()..start();
  Timer? _healthTimer;
  int? _probeState;
  int? _tickedAt;
  var _missedProbes = 0;
  int columns;
  int rows;
  var _health = ShellConnectionHealth.connected;
  var _closed = false;
  var _suspended = false;
  Future<void>? _suspending;
  ShellEnded? _ended;

  late final StreamController<ShellConnectionHealth> _healthEvents =
      StreamController<ShellConnectionHealth>.broadcast(
        onListen: () => scheduleMicrotask(() {
          if (!_healthEvents.isClosed) _healthEvents.add(_health);
        }),
      );

  late final StreamController<Uint8List> _out =
      StreamController<Uint8List>.broadcast(
        onListen: () {
          _supervisor.claim();
          scheduleMicrotask(_drain);
        },
      );

  Future<void> get ready => _ready.future;

  @override
  Stream<Uint8List> get output => _out.stream;

  @override
  Stream<Uint8List> get snapshots => const Stream.empty();

  @override
  Stream<String> get foregroundProcesses => const Stream.empty();

  @override
  Stream<ShellConnectionHealth> get health => _healthEvents.stream;

  @override
  Future<int?> get exitCode => _exit.future;

  @override
  ShellEnded? get ended => _ended;

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
  HostChannels get channels => _supervisor.channels;

  @override
  Stream<ControlLink> get controlLink => _supervisor.controlLink;

  @override
  Future<HostChannels?> channelsFor(UserAction action) async =>
      _closed ? null : _supervisor.open(action);

  @override
  Future<bool> terminateRemote(
    String session, {
    required bool durableShell,
    UserAction? action,
  }) async {
    if (!durableShellSession.hasMatch(session)) return false;
    final channels = action == null ? _supervisor : await channelsFor(action);
    if (channels == null) return false;
    final mosh = await channels.exec(
      moshServerCleanupCommand(session),
      timeout: remoteCommandDeadline,
    );
    if (mosh == null || !mosh.ok) return false;
    final path = tmux;
    if (!durableShell || path == null) return true;
    final ended = await channels.exec(
      durableShellTerminateCommand(path, session),
      timeout: remoteCommandDeadline,
    );
    return ended?.ok ?? false;
  }

  @override
  Future<String?> remoteDirectory(String session) async {
    final path = tmux;
    if (path == null || !durableShellSession.hasMatch(session)) return null;
    final result = await _supervisor.exec(
      durableShellDirectoryCommand(path, session),
      timeout: remoteCommandDeadline,
    );
    if (result == null || !result.ok) return null;
    final directory = result.out.trim();
    return directory.startsWith('/') ? directory : null;
  }

  @override
  Future<void> rehome({NetworkChanged? network}) async {
    if (_closed) return;
    if (_suspended) {
      if (network != null) await _supervisor.drop(network);
      return;
    }
    _setHealth(ShellConnectionHealth.reconnecting);
    await _mosh.rehome();
    _missedProbes = 0;
    _tickedAt = null;
    _probeState = _mosh.resize(columns, rows);
    if (network == null) return;
    await _supervisor.drop(network);
    unawaited(_reopen(_supervisor, network));
  }

  @override
  Future<void> suspend(AppSuspended reason) {
    if (_closed || _suspended) return Future.value();
    _suspended = true;
    _healthTimer?.cancel();
    _healthTimer = null;
    return _suspending = () async {
      await _mosh.suspend();
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
    if (_ready.isCompleted && !_closed && !_suspended) {
      _healthTimer?.cancel();
      _healthTimer = Timer.periodic(healthInterval, (_) => _checkHealth());
    }
    await _reopen(_supervisor, reason);
  }

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
    _healthTimer?.cancel();
    _setHealth(ShellConnectionHealth.disconnected);
    for (final subscription in _reading) {
      await subscription.cancel();
    }
    await _mosh.close();
    _finish(null);
    if (!_ready.isCompleted) _ready.complete();
    await _out.close();
    await _healthEvents.close();
  }

  /// Leaves the SSH connection available for the plain fallback in the same dial.
  Future<void> abandon() async {
    if (_closed) return;
    _closed = true;
    _healthTimer?.cancel();
    for (final subscription in _reading) {
      await subscription.cancel();
    }
    await _mosh.close();
    _finish(null);
    if (!_ready.isCompleted) _ready.complete();
    await _out.close();
    await _healthEvents.close();
  }

  void _emit(Uint8List bytes) {
    if (_closed || bytes.isEmpty) return;
    _contact();
    if (!_ready.isCompleted) {
      _ready.complete();
      _healthTimer = Timer.periodic(healthInterval, (_) => _checkHealth());
    }
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

  void _finish(int? code) {
    if (!_closed) {
      _setHealth(ShellConnectionHealth.disconnected);
      _ended ??= _supervisor.terminalEnded();
    }
    if (!_exit.isCompleted) _exit.complete(code);
  }

  void _acknowledge(int state) {
    final probe = _probeState;
    if (probe == null || state < probe) return;
    _contact();
  }

  void _contact() {
    _probeState = null;
    _missedProbes = 0;
    _setHealth(ShellConnectionHealth.connected);
  }

  int get _probesToGiveUp {
    final probes = giveUp.inMicroseconds ~/ healthInterval.inMicroseconds;
    return probes < 3 ? 3 : probes;
  }

  void _checkHealth() {
    if (_closed) return;
    final now = _ticking.elapsedMicroseconds;
    final previous = _tickedAt;
    _tickedAt = now;
    if (_probeState == null) {
      _probeState = _mosh.resize(columns, rows);
      return;
    }
    // A process Android froze fires every tick it owed the moment it thaws, back to
    // back: that run is one gap in the link and not one missed answer each.
    if (previous != null &&
        now - previous < healthInterval.inMicroseconds ~/ 2) {
      return;
    }
    _missedProbes++;
    if (_missedProbes >= _probesToGiveUp) {
      _abandonSilentChannel();
      return;
    }
    _setHealth(
      _missedProbes >= 3
          ? ShellConnectionHealth.disconnected
          : ShellConnectionHealth.reconnecting,
    );
  }

  void _abandonSilentChannel() {
    _healthTimer?.cancel();
    _healthTimer = null;
    _ended ??= _supervisor.terminalEnded();
    _setHealth(ShellConnectionHealth.disconnected);
    _log(
      _supervisor.endpoint,
      'mosh: no answer in ${giveUp.inSeconds}s, dropping the channel',
    );
    if (!_out.isClosed) {
      _out.addError(
        const ShellFailure(
          ShellFailureKind.streamClosed,
          detail: 'the mosh channel stopped answering',
        ),
      );
    }
  }

  void _setHealth(ShellConnectionHealth health) {
    if (_health == health) return;
    _health = health;
    if (!_healthEvents.isClosed) _healthEvents.add(health);
  }
}

Future<Map<String, Object?>?> _engineCall(
  Future<ExecResult?> Function(String command, Uint8List stdin) run, {
  required String owner,
  required String tab,
  required String op,
  required Map<String, Object?> args,
}) async {
  final result = await run(
    '$moshTabVariable=${shellQuote(tab)} strikedddd',
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'service': 'shell/1',
          'op': op,
          'owner': owner,
          'args': args,
        }),
      ),
    ),
  );
  if (result == null) return null;
  final Object? reply;
  try {
    reply = jsonDecode(result.out);
  } on FormatException {
    return null;
  }
  if (reply is! Map<String, Object?> || reply['ok'] != true) return null;
  final body = reply['result'];
  return body is Map<String, Object?> ? body : null;
}

class EngineShellConnection implements ShellConnection {
  EngineShellConnection(
    this._supervisor,
    this._engine, {
    required this.address,
    required this.owner,
    required this.tab,
    required this.columns,
    required this.rows,
    required this.continuity,
    required this.tmux,
    this.seamless = false,
    this.onLeave,
    this.healthInterval = const Duration(seconds: 3),
    this.giveUp = const Duration(seconds: 30),
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

  final String address;
  final String owner;
  final String tab;
  final EngineChannel _engine;
  final ConnectionSupervisor _supervisor;

  final bool seamless;

  final void Function(EngineResume state)? onLeave;
  final Duration healthInterval;
  final Duration giveUp;
  final String? tmux;

  @override
  final ShellContinuity continuity;

  @override
  ShellTransport get transport => ShellTransport.engine;

  final _reading = <StreamSubscription<void>>[];
  final _pending = <EngineEvent>[];
  final _exit = Completer<int?>();
  final _ready = Completer<void>();
  final _ticking = Stopwatch()..start();
  Timer? _healthTimer;
  var _probing = false;
  int? _tickedAt;
  var _missedProbes = 0;
  int columns;
  int rows;
  var _health = ShellConnectionHealth.connected;
  var _closed = false;
  var _suspended = false;
  Future<void>? _suspending;
  ShellEnded? _ended;
  var _stopped = false;
  var _delivered = 0;

  late final StreamController<ShellConnectionHealth> _healthEvents =
      StreamController<ShellConnectionHealth>.broadcast(
        onListen: () => scheduleMicrotask(() {
          if (!_healthEvents.isClosed) _healthEvents.add(_health);
        }),
      );

  late final StreamController<EngineEvent> _frames =
      StreamController<EngineEvent>.broadcast(
        onListen: () {
          _supervisor.claim();
          scheduleMicrotask(_drain);
        },
      );

  Future<void> get ready => _ready.future;

  @override
  Stream<Uint8List> get output =>
      _frames.stream.where((event) => event is EnginePty).map((event) {
        _delivered++;
        return (event as EnginePty).bytes;
      });

  @override
  Stream<Uint8List> get snapshots =>
      _frames.stream.where((event) => event is EngineSnapshot).map((event) {
        _delivered++;
        return (event as EngineSnapshot).bytes;
      });

  @override
  Stream<String> get foregroundProcesses =>
      _frames.stream.where((event) => event is EngineForeground).map((event) {
        _delivered++;
        return (event as EngineForeground).processes;
      });

  @override
  Stream<ShellConnectionHealth> get health => _healthEvents.stream;

  @override
  Future<int?> get exitCode => _exit.future;

  @override
  ShellEnded? get ended => _ended;

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
  HostChannels get channels => _supervisor.channels;

  @override
  Stream<ControlLink> get controlLink => _supervisor.controlLink;

  @override
  Future<HostChannels?> channelsFor(UserAction action) async =>
      _closed ? null : _supervisor.open(action);

  @override
  Future<bool> terminateRemote(
    String session, {
    required bool durableShell,
    UserAction? action,
  }) async {
    if (!durableShellSession.hasMatch(session)) return false;
    if (session == tab) {
      _stopped = true;
      await _engine.close(end: true);
    }
    final channels = action == null ? _supervisor : await channelsFor(action);
    if (channels == null) return false;
    final stopped = await _engineCall(
      (command, stdin) =>
          channels.exec(command, stdin: stdin, timeout: remoteCommandDeadline),
      owner: owner,
      tab: session,
      op: 'stop',
      args: {'tab': session},
    );
    final swept = await channels.exec(
      moshServerCleanupCommand(session),
      timeout: remoteCommandDeadline,
    );
    if (swept == null || !swept.ok) return false;
    if (stopped == null) {
      _log(_supervisor.endpoint, 'engine: no stop for $session, swept');
    }
    final path = tmux;
    if (!durableShell || path == null) return true;
    final ended = await channels.exec(
      durableShellTerminateCommand(path, session),
      timeout: remoteCommandDeadline,
    );
    return ended?.ok ?? false;
  }

  @override
  Future<String?> remoteDirectory(String session) async {
    final path = tmux;
    if (path == null || !durableShellSession.hasMatch(session)) return null;
    final result = await _supervisor.exec(
      durableShellDirectoryCommand(path, session),
      timeout: remoteCommandDeadline,
    );
    if (result == null || !result.ok) return null;
    final directory = result.out.trim();
    return directory.startsWith('/') ? directory : null;
  }

  @override
  Future<void> rehome({NetworkChanged? network}) async {
    if (_closed) return;
    if (_suspended) {
      if (network != null) await _supervisor.drop(network);
      return;
    }
    _setHealth(ShellConnectionHealth.reconnecting);
    await _engine.rehome();
    _missedProbes = 0;
    _tickedAt = null;
    _probing = true;
    if (network == null) return;
    await _supervisor.drop(network);
    unawaited(_reopen(_supervisor, network));
  }

  @override
  Future<void> suspend(AppSuspended reason) {
    if (_closed || _suspended) return Future.value();
    _suspended = true;
    _healthTimer?.cancel();
    _healthTimer = null;
    return _suspending = () async {
      await _engine.suspend();
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
    if (_ready.isCompleted && !_closed && !_suspended) {
      _healthTimer?.cancel();
      _healthTimer = Timer.periodic(healthInterval, (_) => _checkHealth());
    }
    await _reopen(_supervisor, reason);
  }

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
    _healthTimer?.cancel();
    _setHealth(ShellConnectionHealth.disconnected);
    for (final subscription in _reading) {
      await subscription.cancel();
    }
    await _engine.close();
    _leave();
    _finish(null);
    if (!_ready.isCompleted) _ready.complete();
    await _frames.close();
    await _healthEvents.close();
  }

  Future<void> abandon() async {
    if (_closed) return;
    _closed = true;
    _healthTimer?.cancel();
    for (final subscription in _reading) {
      await subscription.cancel();
    }
    await _engine.close();
    _leave();
    _finish(null);
    if (!_ready.isCompleted) _ready.complete();
    await _frames.close();
    await _healthEvents.close();
  }

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
    _healthTimer = Timer.periodic(healthInterval, (_) => _checkHealth());
  }

  void _drain() {
    if (_frames.isClosed || !_frames.hasListener) return;
    for (final event in _pending) {
      _frames.add(event);
    }
    _pending.clear();
  }

  void _finish(int? code) {
    if (!_closed) {
      _setHealth(ShellConnectionHealth.disconnected);
      _ended ??= _supervisor.terminalEnded();
    }
    if (!_exit.isCompleted) _exit.complete(code);
  }

  void _contact() {
    _probing = false;
    _missedProbes = 0;
    _setHealth(ShellConnectionHealth.connected);
  }

  int get _probesToGiveUp {
    final probes = giveUp.inMicroseconds ~/ healthInterval.inMicroseconds;
    return probes < 3 ? 3 : probes;
  }

  void _checkHealth() {
    if (_closed) return;
    final now = _ticking.elapsedMicroseconds;
    final previous = _tickedAt;
    _tickedAt = now;
    if (!_probing) {
      _probing = true;
      _engine.poke();
      return;
    }
    if (previous != null &&
        now - previous < healthInterval.inMicroseconds ~/ 2) {
      return;
    }
    _missedProbes++;
    _engine.poke();
    if (_missedProbes >= _probesToGiveUp) {
      _abandonSilentChannel();
      return;
    }
    _setHealth(
      _missedProbes >= 3
          ? ShellConnectionHealth.disconnected
          : ShellConnectionHealth.reconnecting,
    );
  }

  void _abandonSilentChannel() {
    _healthTimer?.cancel();
    _healthTimer = null;
    _ended ??= _supervisor.terminalEnded();
    _setHealth(ShellConnectionHealth.disconnected);
    _log(
      _supervisor.endpoint,
      'engine: no answer in ${giveUp.inSeconds}s, dropping the channel',
    );
    if (!_frames.isClosed) {
      _frames.addError(
        const ShellFailure(
          ShellFailureKind.streamClosed,
          detail: 'the engine channel stopped answering',
        ),
      );
    }
  }

  void _setHealth(ShellConnectionHealth health) {
    if (_health == health) return;
    _health = health;
    if (!_healthEvents.isClosed) _healthEvents.add(health);
  }
}

class SshShellConnection implements ShellConnection {
  SshShellConnection(
    this._supervisor,
    this._pty, {
    required this.continuity,
    this.tmux,
  }) {
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
  final ShellContinuity continuity;

  @override
  ShellTransport get transport => ShellTransport.ssh;

  @override
  Stream<ShellConnectionHealth> get health => const Stream.empty();
  final String? tmux;
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
  Future<bool> terminateRemote(
    String session, {
    required bool durableShell,
    UserAction? action,
  }) async {
    if (!durableShell) return true;
    final path = tmux;
    if (path == null) return true;
    if (!durableShellSession.hasMatch(session)) return false;
    final channels = action == null ? _supervisor : await channelsFor(action);
    final ended = await channels?.exec(
      durableShellTerminateCommand(path, session),
      timeout: remoteCommandDeadline,
    );
    return ended?.ok ?? false;
  }

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
  Future<String?> remoteDirectory(String session) async {
    final path = tmux;
    if (path == null || !durableShellSession.hasMatch(session)) return null;
    final result = await _supervisor.exec(
      durableShellDirectoryCommand(path, session),
      timeout: remoteCommandDeadline,
    );
    if (result == null || !result.ok) return null;
    final directory = result.out.trim();
    return directory.startsWith('/') ? directory : null;
  }

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
