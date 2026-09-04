import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:hotline/features/shell/shell_sessions.dart';
import 'package:hotline/platform/shell/shell_connection.dart';
import 'package:hotline/platform/host_keys.dart';

/// A connection with no host behind it: what went out, what came in, and an
/// exit the test decides the moment of.
class FakeShellConnection implements ShellConnection {
  final _output = StreamController<Uint8List>.broadcast();
  final _exit = Completer<int?>();

  final writes = <Uint8List>[];
  final resizes = <List<int>>[];
  var closed = false;

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
    closed = true;
    if (!_exit.isCompleted) _exit.complete(null);
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

  /// Set to make the next dial fail, cleared to let it succeed. Null keeps a
  /// dial pending forever, which is how `CONNECTING` is held still.
  ShellFailure? refuse;
  var stall = false;

  Future<ShellConnection> open({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    HostKeyVerifier? verifier,
    required int columns,
    required int rows,
  }) async {
    sizes.add([columns, rows]);
    verifiers.add(verifier);
    if (stall) return Completer<ShellConnection>().future;
    final failure = refuse;
    if (failure != null) throw failure;
    final connection = FakeShellConnection();
    opened.add(connection);
    return connection;
  }
}

ShellSessions fakeShellSessions(
  FakeShellTransport transport, {
  String? privateKey = 'PRIVATE KEY',
  Future<void> Function(String hostId, PinnedHostKey key)? pinHostKey,
}) => ShellSessions(
  readPrivateKey: (_) async => privateKey,
  pinHostKey: pinHostKey ?? (_, _) async {},
  open: transport.open,
);
