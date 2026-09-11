import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:spectacle/data/repositories/shell_tab_repository.dart';
import 'package:spectacle/features/shell/shell_sessions.dart';
import 'package:spectacle/platform/shell/shell_connection.dart';
import 'package:spectacle/platform/host_keys.dart';

/// A connection with no host behind it: what went out, what came in, and an
/// exit the test decides the moment of.
class FakeShellConnection implements ShellConnection {
  final _output = StreamController<Uint8List>.broadcast();
  final _exit = Completer<int?>();

  final writes = <Uint8List>[];
  final resizes = <List<int>>[];
  var closed = false;

  /// Every command run on a second channel, with what was written into it.
  final execs = <({String command, Uint8List? stdin})>[];

  /// Held to keep [close] from completing, so a test can act inside the window
  /// a redial spends shutting the shell that died down.
  Completer<void>? hold;

  /// What those commands answer. The default is a host that runs anything
  /// and says nothing, which is what an upload looks like from here.
  ExecResult Function(String command, Uint8List? stdin) answer = (_, _) =>
      ExecResult(exitCode: 0, stdout: Uint8List(0), stderr: Uint8List(0));

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  void write(Uint8List bytes) => writes.add(bytes);

  @override
  void resize(int columns, int rows) => resizes.add([columns, rows]);

  @override
  Future<int?> get exitCode => _exit.future;

  @override
  Future<void> close() async {
    await hold?.future;
    closed = true;
    if (!_exit.isCompleted) _exit.complete(null);
  }

  @override
  Future<ExecResult> exec(String command, {Uint8List? stdin}) async {
    execs.add((command: command, stdin: stdin));
    return answer(command, stdin);
  }

  /// A host that prints [stdout] for the next commands, with this exit.
  void answerWith(String stdout, {int exitCode = 0}) {
    answer = (_, _) => ExecResult(
      exitCode: exitCode,
      stdout: Uint8List.fromList(utf8.encode(stdout)),
      stderr: Uint8List(0),
    );
  }

  void emit(String text) => emitBytes(utf8.encode(text));

  void emitBytes(List<int> bytes) => _output.add(Uint8List.fromList(bytes));

  /// The link going away under a live shell: the stream errors and the
  /// connection is never told, which is what a phone leaving wifi looks like.
  void drop([Object error = 'link lost']) => _output.addError(error);

  void exit(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  /// Everything written to the connection as one string, which is what a
  /// remote's line discipline would see.
  String get written => writes.map(String.fromCharCodes).join();
}

/// The opener a test hands the store, and the connections it handed back.
class FakeShellTransport {
  final opened = <FakeShellConnection>[];
  final sizes = <List<int>>[];

  /// One per dial, in order: what the store handed the transport to check the
  /// host with.
  final verifiers = <HostKeyVerifier?>[];

  /// One per dial, in order: what the tab asked to run in place of the login
  /// shell, and null for the tabs that wanted the login shell.
  final commands = <String?>[];

  /// Set to make the next dial fail, cleared to let it succeed. Null keeps a
  /// dial pending forever, which is how `CONNECTING` is held still.
  Object? refuse;
  var stall = false;

  /// Run on every connection the moment it is handed back, which is the only
  /// place a test can answer a question the screen asks on its first frame.
  void Function(FakeShellConnection connection)? opening;

  /// The dials [stall] is holding, so a test can let one land late — after
  /// whatever it was dialling for has moved on.
  final _stalled = <Completer<ShellConnection>>[];

  Future<ShellConnection> open({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    HostKeyVerifier? verifier,
    required int columns,
    required int rows,
    String? command,
  }) async {
    sizes.add([columns, rows]);
    verifiers.add(verifier);
    commands.add(command);
    if (stall) {
      final pending = Completer<ShellConnection>();
      _stalled.add(pending);
      return pending.future;
    }
    final failure = refuse;
    if (failure != null) throw failure;
    final connection = FakeShellConnection();
    opened.add(connection);
    opening?.call(connection);
    return connection;
  }

  /// Completes every dial [stall] is holding, oldest first.
  void land() {
    for (final pending in _stalled) {
      final connection = FakeShellConnection();
      opened.add(connection);
      opening?.call(connection);
      pending.complete(connection);
    }
    _stalled.clear();
  }
}

ShellSessions fakeShellSessions(
  FakeShellTransport transport, {
  String? privateKey = 'PRIVATE KEY',
  Future<void> Function(String hostId, PinnedHostKey key)? pinHostKey,
  ShellTabRepository? tabs,
}) => ShellSessions(
  readPrivateKey: (_) async => privateKey,
  pinHostKey: pinHostKey ?? (_, _) async {},
  tabs: tabs,
  open: transport.open,
);
