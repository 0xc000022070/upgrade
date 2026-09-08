import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../herdr_client.dart';
import '../host_keys.dart';
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
/// A tab with no command is the user's rule and the whole of it: a shell
/// request on a session channel with a pty. No `exec`, no environment, no rc
/// of our own and no multiplexer — what sshd starts for the user is what runs.
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
    this.dial = dialSsh,
  });

  /// What the remote is told the terminal is. The view is an xterm emulator
  /// with a 256 colour palette, so this is a description and not a preference.
  static const terminalType = 'xterm-256color';

  final Duration timeout;
  final Duration keepAlive;
  final ShellDialer dial;

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
      final pty = await _guard(
        address,
        () => command == null ? host.shell(config) : host.run(command, config),
        verifier,
      );
      _log(address, '${command ?? 'shell'} on $terminalType ${columns}x$rows');
      return SshShellConnection(host, pty);
    } catch (_) {
      // Half-open is worse than none: an ssh connection left behind counts
      // against the host until its own timeout, and there is no reconnect
      // loop to come back and reuse it.
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

void _log(String address, Object message) =>
    debugPrint('spectacle.shell $address: $message');

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

/// One live shell: the two output streams merged, stdin, the window size, and
/// the three things that close together.
class SshShellConnection implements ShellConnection {
  SshShellConnection(this._host, this._pty) {
    _reading.add(_pty.stdout.listen(_emit, onError: _onStreamError));
    _reading.add(_pty.stderr.listen(_emit, onError: _onStreamError));
    _pty.done.then(
      (_) => _finish(_pty.exitCode),
      onError: (Object _) => _finish(null),
    );
  }

  final ShellHost _host;
  final ShellPty _pty;
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
    final channel = await _host.execute(command);
    final out = BytesBuilder(copy: false);
    final err = BytesBuilder(copy: false);
    // Subscribed before stdin goes out: a command that answers at once would
    // otherwise print into a stream nobody is reading yet.
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
