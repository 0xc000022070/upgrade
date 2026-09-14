import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_mosh/dart_mosh.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../herdr_client.dart';
import '../host_keys.dart';
import 'mosh_channel.dart';
import 'remote_shell.dart';
import 'shell_connection.dart';

/// The slice of [SSHClient] this file uses, named so a test can stand in for
/// the one part that needs a machine on the other end.
abstract interface class ShellHost {
  Future<void> get authenticated;

  /// A session channel with a pty on it and nothing else on it.
  Future<ShellPty> shell(SSHPtyConfig pty);

  /// A session channel with a pty on it running one command, which is what
  /// `ssh -t host cmd` asks for.
  Future<ShellPty> run(String command, SSHPtyConfig pty);

  /// A session channel running one command, without a pty.
  Future<ShellExec> execute(String command);

  Future<void> close();
}

/// One channel carrying a command. The real one is an [SSHSession] too.
abstract interface class ShellExec {
  Stream<Uint8List> get stdout;
  Stream<Uint8List> get stderr;
  Future<void> get done;
  int? get exitCode;

  void write(Uint8List bytes);
  Future<void> closeStdin();
}

/// One channel carrying a pty. The real one is an [SSHSession].
abstract interface class ShellPty {
  Stream<Uint8List> get stdout;
  Stream<Uint8List> get stderr;

  /// Completes when the channel goes, after which [exitCode] is whatever the
  /// remote reported, or null if it reported nothing.
  Future<void> get done;
  int? get exitCode;

  void write(Uint8List bytes);
  void resizeTerminal(int columns, int rows);
  void close();
}

/// Everything up to and including the ssh client, injectable because the
/// socket is the half a test cannot have. The real one is [dialSsh].
typedef ShellDialer = Future<ShellHost> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  required Duration timeout,
  required Duration keepAlive,
  HostKeyVerifier? verifier,
});

/// The transport: the host's own ssh connection with a pty inside it, carrying
/// either the remote's login shell or one command.
///
/// A tab with no persistent session is the user's rule and the whole of it: a
/// shell request or one command on a session channel with a pty.
///
/// A tab with one is an exec request on the same kind of channel, which is
/// what `ssh -t` is. It exists because typing a line at a login shell is a
/// race against everything that shell reads before its prompt: a host whose rc
/// asks which session to open eats the line's first character, and no delay
/// fixes it because the reader is what runs first, not what runs late.
class ShellTunnel {
  const ShellTunnel({
    this.timeout = const Duration(seconds: 10),
    this.keepAlive = const Duration(seconds: 15),
    this.moshHealthInterval = const Duration(seconds: 3),
    this.dial = dialSsh,
    this.moshDialer = dialMosh,
  });

  /// What the remote is told the terminal is. The view is an xterm emulator
  /// with a 256 colour palette, so this is a description and not a preference.
  static const terminalType = 'xterm-256color';

  final Duration timeout;
  final Duration keepAlive;
  final Duration moshHealthInterval;
  final ShellDialer dial;
  final MoshDialer moshDialer;

  /// Opens the connection, authenticates, and asks for the shell.
  ///
  /// The failure mapping is the agent poll's plus this section's own: a name
  /// that did not resolve, a machine that did not answer, a key the host would
  /// not take, a request the host denied — which is what a key line reading
  /// `restrict` without `pty` gives every time — and a stream that ended
  /// before the login did.
  Future<ShellConnection> open({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    required int columns,
    required int rows,
    String? command,
    String? tabSession,
    String? persistentSession,
    HostKeyVerifier? verifier,
  }) async {
    final host = await _guard(
      address,
      () => dial(
        address: address,
        port: port,
        user: user,
        privateKey: privateKey,
        timeout: timeout,
        keepAlive: keepAlive,
        verifier: verifier,
      ),
      verifier,
    );
    try {
      // The host key is checked inside the handshake, which is what
      // [ShellHost.authenticated] is waiting on: a refusal surfaces here as an
      // ssh error, and the verifier is the only thing that knows which of the
      // two refusals it was.
      await _guard(address, () => host.authenticated, verifier);
      final config = SSHPtyConfig(
        type: terminalType,
        width: columns,
        height: rows,
      );
      final requestedSession = persistentSession;
      final durable = requestedSession == null
          ? null
          : await _durableTarget(host, requestedSession);
      final run = durable == null
          ? command
          : durableShellCommand(
              durable.tmux,
              durable.session,
              command ?? 'exec \$SHELL -l',
            );
      final tab = tabSession;
      if (tab != null && durableShellSession.hasMatch(tab)) {
        final mosh = await _openMosh(
          host: host,
          address: address,
          port: port,
          user: user,
          privateKey: privateKey,
          columns: columns,
          rows: rows,
          command: run ?? 'exec \$SHELL -l',
          tabSession: tab,
          continuity: durable?.continuity ?? ShellContinuity.plain,
          tmux: durable?.tmux,
          verifier: verifier,
        );
        if (mosh != null) return mosh;
      }
      final pty = await _guard(
        address,
        () => run == null ? host.shell(config) : host.run(run, config),
        verifier,
      );
      _log(address, '${run ?? 'shell'} on $terminalType ${columns}x$rows');
      return SshShellConnection(
        host,
        pty,
        continuity: durable?.continuity ?? ShellContinuity.plain,
        tmux: durable?.tmux,
      );
    } catch (_) {
      // Half-open is worse than none: an ssh connection left behind counts
      // against the host until its own timeout, and there is no reconnect
      // loop to come back and reuse it.
      await host.close();
      rethrow;
    }
  }

  Future<_DurableTarget?> _durableTarget(ShellHost host, String session) async {
    if (!durableShellSession.hasMatch(session)) return null;
    try {
      final result = await _exec(host, durableShellProbeCommand(session));
      if (!result.ok) return null;
      String? tmux;
      var resumed = false;
      for (final line in result.out.split('\n')) {
        if (line.startsWith('DAZZLE_TMUX=/')) {
          tmux = line.substring('DAZZLE_TMUX='.length).trim();
        } else if (line.trim() == 'DAZZLE_RESUME=1') {
          resumed = true;
        }
      }
      if (tmux == null || tmux.contains(RegExp(r'[\r\n]'))) return null;
      return _DurableTarget(
        session,
        tmux,
        resumed ? ShellContinuity.resumed : ShellContinuity.started,
      );
    } catch (_) {
      return null;
    }
  }

  Future<MoshShellConnection?> _openMosh({
    required ShellHost host,
    required String address,
    required int port,
    required String user,
    required String privateKey,
    required int columns,
    required int rows,
    required String command,
    required String tabSession,
    required ShellContinuity continuity,
    required String? tmux,
    required HostKeyVerifier? verifier,
  }) async {
    String? serverPath;
    MoshShellConnection? connection;
    try {
      serverPath = await _moshServer(host);
      if (serverPath == null) return null;
      final cleanup = await _exec(host, moshServerCleanupCommand(tabSession));
      if (!cleanup.ok) return null;
      final launch = MoshSshBootstrap(
        serverBinary: serverPath,
        locale: 'C.UTF-8',
        term: terminalType,
      ).command();
      final bootstrap = await _exec(
        host,
        '$moshTabVariable=${shellQuote(tabSession)} $launch -- '
        'sh -c ${shellQuote(command)}',
      );
      if (!bootstrap.ok) {
        await _exec(host, moshServerCleanupCommand(tabSession));
        return null;
      }
      final server = MoshServerConfig.parse(
        '${bootstrap.out}\n${bootstrap.err}',
        host: address,
      );
      final channel = await moshDialer(
        server: server,
        columns: columns,
        rows: rows,
      );
      final trusted = verifier?.verified ?? verifier?.pinned;
      connection = MoshShellConnection(
        host,
        channel,
        address: address,
        columns: columns,
        rows: rows,
        continuity: continuity,
        tmux: tmux,
        redial: () => _redial(
          address: address,
          port: port,
          user: user,
          privateKey: privateKey,
          verifier: trusted == null
              ? null
              : HostKeyVerifier.pinnedOnly(trusted),
        ),
        healthInterval: moshHealthInterval,
      );
      await connection.ready.timeout(timeout);
      _log(address, 'mosh ${server.port} on ${columns}x$rows');
      return connection;
    } catch (error) {
      _log(address, 'mosh fallback: $error');
      await connection?.abandon();
      if (serverPath != null) {
        try {
          await _exec(host, moshServerCleanupCommand(tabSession));
        } catch (_) {}
      }
      return null;
    }
  }

  Future<String?> _moshServer(ShellHost host) async {
    try {
      final result = await _exec(host, moshServerProbeCommand());
      if (!result.ok) return null;
      for (final line in result.out.split('\n')) {
        if (!line.startsWith('DAZZLE_MOSH=/')) continue;
        final path = line.substring('DAZZLE_MOSH='.length).trim();
        if (!path.contains(RegExp(r'[\r\n]'))) return path;
      }
    } catch (_) {}
    return null;
  }

  Future<ShellHost> _redial({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    required HostKeyVerifier? verifier,
  }) async {
    final host = await _guard(
      address,
      () => dial(
        address: address,
        port: port,
        user: user,
        privateKey: privateKey,
        timeout: timeout,
        keepAlive: keepAlive,
        verifier: verifier,
      ),
      verifier,
    );
    try {
      await _guard(address, () => host.authenticated, verifier);
      return host;
    } catch (_) {
      await host.close();
      rethrow;
    }
  }

  Future<T> _guard<T>(
    String address,
    Future<T> Function() body, [
    HostKeyVerifier? verifier,
  ]) async {
    try {
      return await body();
    } catch (error) {
      // The refusal wins over whatever the transport threw. A rejected host
      // key closes the connection, and which error that close surfaces as
      // depends on how far the handshake had got; the verifier's answer does
      // not.
      final failure = shellFailureFor(error, verifier?.refusal);
      _log(address, '${failure ?? error}');
      throw failure ?? error;
    }
  }
}

class _DurableTarget {
  const _DurableTarget(this.session, this.tmux, this.continuity);

  final String session;
  final String tmux;
  final ShellContinuity continuity;
}

void _log(String address, Object message) =>
    debugPrint('dazzle.shell $address: $message');

/// Every error the ssh layer can raise, on the seam's five lines.
///
/// Null for anything unexpected: the real error belongs in the debug log, and
/// a bug in the layer above reads better as itself than as a reason line.
ShellFailure? shellFailureFor(
  Object error, [
  HostKeyRefusal? refusal,
]) => switch (error) {
  ShellFailure() => error,
  // The verifier said no, and the connection went away carrying whichever
  // error the handshake had reached. The refusal is the reason, whatever the
  // error is, so it is read before the error is looked at.
  _ when refusal != null => ShellFailure(switch (refusal) {
    HostKeyRefusal.unverified => ShellFailureKind.hostKeyUnverified,
    HostKeyRefusal.changed => ShellFailureKind.hostKeyChanged,
  }, detail: '$error'),
  // Nobody refused anything and the key still did not check out: the server's
  // signature was wrong, or it swapped its key across a rekey. Either way the
  // machine is not the one that was pinned.
  SSHHostkeyError() => ShellFailure(
    ShellFailureKind.hostKeyChanged,
    detail: '$error',
  ),
  // The channel open, or the pty or shell request on it. All three are the
  // same sentence to the user: sshd would not give them a shell.
  SSHChannelOpenError() => ShellFailure(
    ShellFailureKind.shellRefused,
    detail: '$error',
  ),
  SSHChannelRequestError() => ShellFailure(
    ShellFailureKind.shellRefused,
    detail: '$error',
  ),
  // The server ran out of methods to try, or the pem never was one.
  SSHAuthFailError() => ShellFailure(
    ShellFailureKind.keyRejected,
    detail: '$error',
  ),
  SSHKeyDecodeError() => ShellFailure(
    ShellFailureKind.keyRejected,
    detail: '$error',
  ),
  // Auth that ended without the server saying no: the connection went away
  // under it, or nothing came back at all. What the socket said, if it said
  // anything, is the better line of the two.
  SSHAuthAbortError(:final reason?) =>
    shellFailureFor(reason, refusal) ??
        ShellFailure(ShellFailureKind.streamClosed, detail: '$error'),
  SSHAuthAbortError() => ShellFailure(
    ShellFailureKind.streamClosed,
    detail: '$error',
  ),
  // An orderly close is how a transport that stopped mid-request reads from
  // this side.
  SSHStateError() => ShellFailure(
    ShellFailureKind.streamClosed,
    detail: '$error',
  ),
  // The socket's own error, wrapped. Unwrapped here so a refused connection
  // under a handshake reads as the refusal it is.
  SSHSocketError() =>
    shellFailureFor(error.error, refusal) ??
        ShellFailure(ShellFailureKind.unreachable, detail: '$error'),
  // The only failure that happens before an address exists. The test is
  // [HerdrClient]'s, deliberately: which errno family a lookup failure lands
  // in is a platform detail, and one copy of that guess is enough.
  SocketException() when HerdrClient.isLookupFailure(error) => ShellFailure(
    ShellFailureKind.unresolved,
    detail: '$error',
  ),
  SocketException() => ShellFailure(
    ShellFailureKind.unreachable,
    detail: '$error',
  ),
  TimeoutException() => ShellFailure(
    ShellFailureKind.unreachable,
    detail: '$error',
  ),
  SSHError() => ShellFailure(ShellFailureKind.unreachable, detail: '$error'),
  _ => null,
};

/// The real dialer: the socket and the client over it, authenticated lazily by
/// [ShellHost.authenticated] so the caller decides where auth is awaited.
Future<ShellHost> dialSsh({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  required Duration timeout,
  required Duration keepAlive,
  HostKeyVerifier? verifier,
}) async {
  final socket = await SSHSocket.connect(address, port, timeout: timeout);
  return sshHostOver(
    socket,
    user: user,
    privateKey: privateKey,
    timeout: timeout,
    keepAlive: keepAlive,
    verifier: verifier,
  );
}

/// The client over a socket that is already open. Split from [dialSsh] because
/// the socket is the one half a test cannot have, and what happens to a
/// connection that dies under the handshake is worth a test.
ShellHost sshHostOver(
  SSHSocket socket, {
  required String user,
  required String privateKey,
  required Duration timeout,
  required Duration keepAlive,
  HostKeyVerifier? verifier,
}) => _SshHost(
  socket,
  SSHClient(
    socket,
    username: user,
    identities: SSHKeyPair.fromPem(privateKey),
    handshakeTimeout: timeout,
    authTimeout: timeout,
    keepAliveInterval: keepAlive,
    onVerifyHostKey: verifier?.verify,
  ),
);

class _SshHost implements ShellHost {
  _SshHost(this._socket, this._client);

  final SSHSocket _socket;
  final SSHClient _client;

  @override
  Future<void> get authenticated => _client.authenticated;

  @override
  Future<ShellPty> shell(SSHPtyConfig pty) async =>
      // The pty and nothing beside it: no environment map, no x11, and the
      // shell request rather than an exec.
      _SshPty(await _client.shell(pty: pty));

  @override
  Future<ShellPty> run(String command, SSHPtyConfig pty) async =>
      // Same channel and same pty as [shell]; the exec request in place of the
      // shell request is the only difference, so a detach ends the channel the
      // way `exit` ends a shell.
      _SshPty(await _client.execute(command, pty: pty));

  @override
  Future<ShellExec> execute(String command) async =>
      _SshExec(await _client.execute(command));

  @override
  Future<void> close() async {
    _client.close();
    // Closing a socket the host reset finishes with the reset, and every dial
    // that failed closes what it opened: unawaited, that error escapes to the
    // zone and every unreachable host puts an unhandled exception in the log
    // beside the failure the app had already worded.
    await _socket.close().catchError((Object _) {});
  }
}

class _SshExec implements ShellExec {
  _SshExec(this._session);

  final SSHSession _session;

  @override
  Stream<Uint8List> get stdout => _session.stdout;

  @override
  Stream<Uint8List> get stderr => _session.stderr;

  @override
  Future<void> get done => _session.done;

  @override
  int? get exitCode => _session.exitCode;

  @override
  void write(Uint8List bytes) => _session.stdin.add(bytes);

  @override
  Future<void> closeStdin() => _session.stdin.close();
}

class _SshPty implements ShellPty {
  _SshPty(this._session);

  final SSHSession _session;

  @override
  Stream<Uint8List> get stdout => _session.stdout;

  @override
  Stream<Uint8List> get stderr => _session.stderr;

  @override
  Future<void> get done => _session.done;

  @override
  int? get exitCode => _session.exitCode;

  @override
  void write(Uint8List bytes) => _session.write(bytes);

  @override
  void resizeTerminal(int columns, int rows) =>
      _session.resizeTerminal(columns, rows);

  @override
  void close() => _session.close();
}

/// A Mosh UDP session plus an SSH control connection for file, clipboard,
/// directory, and cleanup commands. The control connection is discarded on a
/// network handover and redialled on demand; the terminal never waits for it.
class MoshShellConnection implements ShellConnection {
  MoshShellConnection(
    ShellHost host,
    this._mosh, {
    required this.address,
    required this.columns,
    required this.rows,
    required this.continuity,
    required this.tmux,
    required this.redial,
    this.healthInterval = const Duration(seconds: 3),
  }) : _host = host {
    _reading.add(_mosh.output.listen(_emit));
    _reading.add(_mosh.errors.listen((error) => _log(address, 'mosh: $error')));
    _reading.add(_mosh.echoAcks.listen(_acknowledge));
    _mosh.done.then(
      (_) => _finish(0),
      onError: (Object error) {
        _log(address, 'mosh: $error');
        _finish(null);
      },
    );
  }

  final String address;
  final MoshChannel _mosh;
  final Future<ShellHost> Function() redial;
  final Duration healthInterval;
  ShellHost? _host;
  Future<ShellHost>? _openingHost;
  final String? tmux;

  @override
  final ShellContinuity continuity;

  @override
  ShellTransport get transport => ShellTransport.mosh;

  final _reading = <StreamSubscription<Object>>[];
  final _pending = <Uint8List>[];
  final _exit = Completer<int?>();
  final _ready = Completer<void>();
  Timer? _healthTimer;
  int? _probeState;
  var _missedProbes = 0;
  int columns;
  int rows;
  var _health = ShellConnectionHealth.connected;
  var _closed = false;

  late final StreamController<ShellConnectionHealth> _healthEvents =
      StreamController<ShellConnectionHealth>.broadcast(
        onListen: () => scheduleMicrotask(() {
          if (!_healthEvents.isClosed) _healthEvents.add(_health);
        }),
      );

  late final StreamController<Uint8List> _out =
      StreamController<Uint8List>.broadcast(
        onListen: () => scheduleMicrotask(_drain),
      );

  Future<void> get ready => _ready.future;

  @override
  Stream<Uint8List> get output => _out.stream;

  @override
  Stream<ShellConnectionHealth> get health => _healthEvents.stream;

  @override
  Future<int?> get exitCode => _exit.future;

  @override
  void write(Uint8List bytes) {
    if (_closed) return;
    _mosh.send(bytes);
  }

  @override
  void resize(int columns, int rows) {
    if (_closed) return;
    this.columns = columns;
    this.rows = rows;
    _probeState = _mosh.resize(columns, rows);
  }

  @override
  Future<ExecResult> exec(String command, {Uint8List? stdin}) =>
      _withHost((host) => _exec(host, command, stdin: stdin));

  @override
  Future<bool> terminateRemote(
    String session, {
    required bool durableShell,
  }) async {
    if (!durableShellSession.hasMatch(session)) return false;
    final mosh = await exec(moshServerCleanupCommand(session));
    if (!mosh.ok) return false;
    final path = tmux;
    if (!durableShell || path == null) return true;
    return (await exec(durableShellTerminateCommand(path, session))).ok;
  }

  @override
  Future<String?> remoteDirectory(String session) async {
    final path = tmux;
    if (path == null || !durableShellSession.hasMatch(session)) return null;
    final result = await exec(durableShellDirectoryCommand(path, session));
    if (!result.ok) return null;
    final directory = result.out.trim();
    return directory.startsWith('/') ? directory : null;
  }

  @override
  Future<void> rehome() async {
    if (_closed) return;
    _setHealth(ShellConnectionHealth.reconnecting);
    await _mosh.rehome();
    _probeState = _mosh.resize(columns, rows);
    await _dropHost(_host);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _healthTimer?.cancel();
    _setHealth(ShellConnectionHealth.disconnected);
    for (final subscription in _reading) {
      await subscription.cancel();
    }
    await _mosh.close();
    await _dropHost(_host);
    _finish(null);
    if (!_ready.isCompleted) _ready.complete();
    await _out.close();
    await _healthEvents.close();
  }

  /// Drops a Mosh attempt that never became a shell while leaving its SSH
  /// connection available for the plain fallback in the same dial.
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

  Future<T> _withHost<T>(Future<T> Function(ShellHost host) body) async {
    var host = await _currentHost();
    try {
      return await body(host);
    } catch (_) {
      await _dropHost(host);
      host = await _currentHost();
      return body(host);
    }
  }

  Future<ShellHost> _currentHost() async {
    final current = _host;
    if (current != null) return current;
    final opening = _openingHost;
    if (opening != null) return opening;
    final next = redial();
    _openingHost = next;
    try {
      final host = await next;
      if (_closed) {
        await host.close();
        throw StateError('Mosh connection is closed.');
      }
      _host = host;
      return host;
    } finally {
      _openingHost = null;
    }
  }

  Future<void> _dropHost(ShellHost? host) async {
    if (host == null) return;
    if (identical(_host, host)) _host = null;
    try {
      await host.close();
    } catch (_) {}
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
    if (!_closed) _setHealth(ShellConnectionHealth.disconnected);
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

  void _checkHealth() {
    if (_closed) return;
    if (_probeState == null) {
      _probeState = _mosh.resize(columns, rows);
      return;
    }
    _missedProbes++;
    _setHealth(
      _missedProbes >= 3
          ? ShellConnectionHealth.disconnected
          : ShellConnectionHealth.reconnecting,
    );
  }

  void _setHealth(ShellConnectionHealth health) {
    if (_health == health) return;
    _health = health;
    if (!_healthEvents.isClosed) _healthEvents.add(health);
  }
}

/// One live shell: the two output streams merged, stdin, the window size, and
/// the three things that close together.
class SshShellConnection implements ShellConnection {
  SshShellConnection(
    this._host,
    this._pty, {
    required this.continuity,
    this.tmux,
  }) {
    _reading.add(_pty.stdout.listen(_emit, onError: _onStreamError));
    _reading.add(_pty.stderr.listen(_emit, onError: _onStreamError));
    _pty.done.then(
      (_) => _finish(_pty.exitCode),
      onError: (Object _) => _finish(null),
    );
  }

  final ShellHost _host;
  final ShellPty _pty;
  @override
  final ShellContinuity continuity;

  @override
  ShellTransport get transport => ShellTransport.ssh;

  @override
  Stream<ShellConnectionHealth> get health => const Stream.empty();
  final String? tmux;
  final _reading = <StreamSubscription<Uint8List>>[];
  final _exit = Completer<int?>();

  /// Held until someone is listening. A login shell prints its banner and its
  /// prompt the moment the channel opens, which is before the store that opened
  /// it has had a turn to subscribe, and a prompt that never arrives reads as a
  /// shell that never started.
  final _pending = <Uint8List>[];

  late final StreamController<Uint8List> _out =
      StreamController<Uint8List>.broadcast(
        onListen: () => scheduleMicrotask(_drain),
      );

  @override
  Stream<Uint8List> get output => _out.stream;

  @override
  Future<int?> get exitCode => _exit.future;

  @override
  void write(Uint8List bytes) => _pty.write(bytes);

  @override
  void resize(int columns, int rows) => _pty.resizeTerminal(columns, rows);

  @override
  Future<ExecResult> exec(String command, {Uint8List? stdin}) async {
    return _exec(_host, command, stdin: stdin);
  }

  @override
  Future<bool> terminateRemote(
    String session, {
    required bool durableShell,
  }) async {
    if (!durableShell) return true;
    final path = tmux;
    if (path == null) return true;
    if (!durableShellSession.hasMatch(session)) return false;
    return (await _exec(_host, durableShellTerminateCommand(path, session))).ok;
  }

  @override
  Future<void> rehome() async {}

  @override
  Future<String?> remoteDirectory(String session) async {
    final path = tmux;
    if (path == null || !durableShellSession.hasMatch(session)) return null;
    final result = await _exec(
      _host,
      durableShellDirectoryCommand(path, session),
    );
    if (!result.ok) return null;
    final directory = result.out.trim();
    return directory.startsWith('/') ? directory : null;
  }

  @override
  Future<void> close() async {
    for (final subscription in _reading) {
      await subscription.cancel();
    }
    _pty.close();
    await _host.close();
    _finish(null);
    await _out.close();
  }

  /// Everything queues, so a chunk that arrives in the same turn as the first
  /// listener still lands behind the ones that came before it.
  void _emit(Uint8List bytes) {
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

  /// A stream that fails takes the session with it: the reason belongs to
  /// whoever is drawing the terminal, worded as the seam's kinds.
  void _onStreamError(Object error) {
    if (_out.isClosed) return;
    _out.addError(
      shellFailureFor(error) ??
          ShellFailure(ShellFailureKind.streamClosed, detail: '$error'),
    );
  }

  void _finish(int? code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }
}

Future<ExecResult> _exec(
  ShellHost host,
  String command, {
  Uint8List? stdin,
}) async {
  final channel = await host.execute(command);
  final out = BytesBuilder(copy: false);
  final err = BytesBuilder(copy: false);
  final drained = Future.wait([
    channel.stdout.forEach(out.add),
    channel.stderr.forEach(err.add),
  ]);
  if (stdin != null) channel.write(stdin);
  await channel.closeStdin();
  await channel.done;
  await drained;
  return ExecResult(
    exitCode: channel.exitCode,
    stdout: out.takeBytes(),
    stderr: err.takeBytes(),
  );
}
