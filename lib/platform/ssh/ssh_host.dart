// Part of the SSH connection policy library; read the header in connection_supervisor.dart before editing.
part of 'connection_supervisor.dart';

/// Public only as the seam a test dialer fakes; no host the app builds leaves this library.
abstract interface class ShellHost {
  Future<void> get authenticated;

  /// The transport is gone: the one verdict that the host is dead.
  Future<void> get done;

  Future<ShellPty> shell(SSHPtyConfig pty);

  Future<ShellPty> run(String command, SSHPtyConfig pty);

  Future<ShellExec> execute(String command);

  Future<bool> check();

  Future<void> close();
}

abstract interface class ShellExec {
  Stream<Uint8List> get stdout;
  Stream<Uint8List> get stderr;
  Future<void> get done;
  int? get exitCode;

  void write(Uint8List bytes);
  Future<void> closeStdin();

  /// Without waiting for exit: the only way to end a command blocked forever.
  void close();
}

abstract interface class ShellPty {
  Stream<Uint8List> get stdout;
  Stream<Uint8List> get stderr;

  Future<void> get done;
  int? get exitCode;

  /// Without the leading SIG; set when a signal, not an exit, ended the remote process.
  String? get exitSignal;

  void write(Uint8List bytes);
  void resizeTerminal(int columns, int rows);
  void close();
}

typedef ShellDialer = Future<ShellHost> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  required Duration timeout,
  required HostKeyVerifier verifier,
});

ShellDialer _dialOver(HostLinks links) =>
    ({
      required address,
      required port,
      required user,
      required privateKey,
      required timeout,
      required verifier,
    }) async => _SshHost.claimed(
      await links.claim(
        address: address,
        port: port,
        user: user,
        privateKey: privateKey,
        verifier: verifier,
        use: HostUse.tab,
      ),
    );

@visibleForTesting
ShellHost sshHostOver(SSHSocket socket, SSHClient client) =>
    _SshHost.over(socket, client);

class _SshHost implements ShellHost {
  _SshHost.over(SSHSocket socket, this._client)
    : _execute = ((command, pty) => _client.execute(command, pty: pty)),
      _shell = ((pty) => _client.shell(pty: pty)),
      // Unpooled: nothing here may close the socket on a missed ping.
      _check = (() async => !_client.isClosed),
      _close = (() => closeSettled(_client, socket));

  _SshHost.claimed(HostLease lease)
    : _client = lease.client,
      _execute = ((command, pty) => lease.execute(command, pty: pty)),
      _shell = lease.shell,
      _check = lease.check,
      _close = (() async => lease.release());

  final SSHClient _client;
  final Future<SSHSession> Function(String command, SSHPtyConfig? pty) _execute;
  final Future<SSHSession> Function(SSHPtyConfig pty) _shell;
  final Future<bool> Function() _check;
  final Future<void> Function() _close;

  @override
  Future<void> get authenticated => _client.authenticated;

  @override
  Future<void> get done => _client.done;

  @override
  Future<ShellPty> shell(SSHPtyConfig pty) async => _SshPty(await _shell(pty));

  @override
  Future<ShellPty> run(String command, SSHPtyConfig pty) async =>
      // An exec request, not a shell one, is what makes a detach end the channel like `exit`.
      _SshPty(await _execute(command, pty));

  @override
  Future<ShellExec> execute(String command) async =>
      _SshExec(await _execute(command, null));

  @override
  Future<bool> check() => _check();

  @override
  Future<void> close() => _close();
}

@visibleForTesting
ShellExec sshExecOver(SSHSession session) => _SshExec(session);

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

  @override
  void close() => endExec(_session);
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
  String? get exitSignal => _session.exitSignal?.signalName;

  @override
  void write(Uint8List bytes) => _session.write(bytes);

  @override
  void resizeTerminal(int columns, int rows) =>
      _session.resizeTerminal(columns, rows);

  @override
  void close() => _session.close();
}
