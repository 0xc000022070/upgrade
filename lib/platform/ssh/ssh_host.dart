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
  required Duration keepAlive,
  required HostKeyVerifier verifier,
});

Future<ShellHost> _dialSsh({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  required Duration timeout,
  required Duration keepAlive,
  required HostKeyVerifier verifier,
}) async {
  final ssh = await HostLinks.own(
    address: address,
    port: port,
    user: user,
    privateKey: privateKey,
    timeout: timeout,
    keepAlive: keepAlive,
    verifier: verifier,
  );
  return _SshHost(ssh.socket, ssh.client);
}

@visibleForTesting
ShellHost sshHostOver(SSHSocket socket, SSHClient client) =>
    _SshHost(socket, client);

class _SshHost implements ShellHost {
  _SshHost(this._socket, this._client);

  final SSHSocket _socket;
  final SSHClient _client;

  @override
  Future<void> get authenticated => _client.authenticated;

  @override
  Future<void> get done => _client.done;

  @override
  Future<ShellPty> shell(SSHPtyConfig pty) async =>
      _SshPty(await _client.shell(pty: pty));

  @override
  Future<ShellPty> run(String command, SSHPtyConfig pty) async =>
      // An exec request, not a shell one, is what makes a detach end the channel like `exit`.
      _SshPty(await _client.execute(command, pty: pty));

  @override
  Future<ShellExec> execute(String command) async =>
      _SshExec(await _client.execute(command));

  @override
  Future<void> close() => closeSettled(_client, _socket);
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
  void write(Uint8List bytes) => _session.write(bytes);

  @override
  void resizeTerminal(int columns, int rows) =>
      _session.resizeTerminal(columns, rows);

  @override
  void close() => _session.close();
}
