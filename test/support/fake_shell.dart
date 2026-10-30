import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:upgrade/data/repositories/shell_tab_repository.dart';
import 'package:upgrade/data/shell_snapshot_store.dart';
import 'package:upgrade/application/alerts/pin_alerts.dart';
import 'package:upgrade/data/enums.dart';
import 'package:upgrade/data/repositories/host_repository.dart' show Host;
import 'package:upgrade/features/shell/session/shell_sessions.dart';
import 'package:dartssh2/dartssh2.dart' show SSHChannelRequestError;
import 'package:upgrade/platform/links/link_probe.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/platform/ssh/host_files.dart'
    show FileBody, PutProgress, collectBytes, putFile, putLanded;
import 'package:upgrade/platform/ssh/host_keys.dart';

class FakeShellConnection implements ShellConnection {
  FakeShellConnection({
    this.continuity = ShellContinuity.plain,
    this.transport = ShellTransport.ssh,
  });

  final _output = StreamController<Uint8List>.broadcast();
  final _snapshots = StreamController<Uint8List>.broadcast();
  final _foregroundProcesses = StreamController<String>.broadcast();
  final _health = StreamController<ShellConnectionHealth>.broadcast();
  final _controlLink = StreamController<ControlLink>.broadcast();
  final _exit = Completer<int?>();

  final writes = <Uint8List>[];
  final resizes = <List<int>>[];
  final pixels = <List<int>>[];
  var closed = false;
  var terminateRemoteResult = true;
  final terminated = <String>[];

  final terminateActions = <UserAction?>[];
  final closes = <DropReason>[];
  final opens = <UserAction>[];
  var rehomes = 0;
  var networkRehomes = 0;
  var suspends = 0;
  var resumes = 0;

  @override
  final ShellContinuity continuity;

  @override
  final ShellTransport transport;

  /// Every command run on a second channel, with what was written into it.
  final execs = <({String command, Uint8List? stdin})>[];

  final timedProbes = <String>[];

  /// False: the host was dropped, and background reads get null until something opens it.
  bool hostHeld = true;
  Completer<ExecResult?>? holdTimedProbe;

  /// Held to keep [close] from completing, so a test can act inside the window a redial
  /// spends shutting the shell that died down.
  Completer<void>? hold;

  /// Held to keep every command from coming back, so a test can look at the screen while
  /// the host is still answering.
  Completer<void>? holdExec;

  /// The default is a host that runs anything and says nothing.
  ExecResult Function(String command, Uint8List? stdin) answer = (_, _) =>
      ExecResult(exitCode: 0, stdout: Uint8List(0), stderr: Uint8List(0));

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Stream<Uint8List> get snapshots => _snapshots.stream;

  @override
  Stream<String> get foregroundProcesses => _foregroundProcesses.stream;

  @override
  Stream<ShellConnectionHealth> get health => _health.stream;

  @override
  Stream<ControlLink> get controlLink => _controlLink.stream;

  void setControlDown(bool down) =>
      _controlLink.add(down ? const ControlReconnecting() : const ControlUp());

  void setControlGaveUp(Object error) => _controlLink.add(ControlGaveUp(error));

  @override
  void write(Uint8List bytes) => writes.add(bytes);

  Object? resizeRefused;

  @override
  void resize(int columns, int rows, {int widthPx = 0, int heightPx = 0}) {
    final refused = resizeRefused;
    if (refused != null) throw refused;
    resizes.add([columns, rows]);
    pixels.add([widthPx, heightPx]);
  }

  @override
  Future<int?> get exitCode => _exit.future;

  @override
  ShellEnded? ended;

  var discarded = false;

  @override
  Future<bool> discard() async {
    discarded = true;
    closed = true;
    if (!_exit.isCompleted) _exit.complete(null);
    await _health.close();
    return true;
  }

  @override
  bool accepts(DropReason reason) => true;

  @override
  Future<void> close(DropReason reason) async {
    closes.add(reason);
    await hold?.future;
    closed = true;
    if (!_exit.isCompleted) _exit.complete(null);
    await _health.close();
  }

  @override
  Future<bool> terminateRemote(String session, {UserAction? action}) async {
    terminated.add(session);
    terminateActions.add(action);
    return terminateRemoteResult;
  }

  @override
  Future<void> rehome({NetworkChanged? network}) async {
    rehomes++;
    if (network != null) networkRehomes++;
  }

  @override
  Future<void> suspend(AppSuspended reason) async => suspends++;

  @override
  Future<void> resume(AppResumed reason) async => resumes++;

  @override
  late final HostChannels channels = _FakeChannels(this, background: true);

  late final HostChannels _opened = _FakeChannels(this, background: false);

  Object? openRefused;

  @override
  Future<HostChannels?> channelsFor(UserAction action) async {
    opens.add(action);
    if (closed) return null;
    final refused = openRefused;
    if (refused != null) throw refused;
    hostHeld = true;
    return _opened;
  }

  Future<ExecResult> _exec(
    String command, {
    Uint8List? stdin,
    required Duration timeout,
  }) async {
    execs.add((command: command, stdin: stdin));
    await holdExec?.future;
    if (!wedged) return answer(command, stdin);
    final never = Completer<ExecResult>().future;
    return never.timeout(timeout);
  }

  /// A command that reaches the host and never comes back, which is what writing into a
  /// fifo nobody is reading looks like from this end.
  bool wedged = false;

  void answerWith(String stdout, {int exitCode = 0}) {
    answer = (_, _) => ExecResult(
      exitCode: exitCode,
      stdout: Uint8List.fromList(utf8.encode(stdout)),
      stderr: Uint8List(0),
    );
  }

  void emit(String text) => emitBytes(utf8.encode(text));

  void emitBytes(List<int> bytes) => _output.add(Uint8List.fromList(bytes));

  void emitSnapshot(Uint8List bytes) => _snapshots.add(bytes);

  void emitForeground(String processes) => _foregroundProcesses.add(processes);

  /// A link that died: dartssh2 ends the pty cleanly with no exit status, and the SSH
  /// connection reports that as a failed stream before its exit, which stays null.
  void drop([
    Object error = const ShellFailure(
      ShellFailureKind.streamClosed,
      detail: 'link lost',
    ),
  ]) {
    fail(error);
    if (!_exit.isCompleted) _exit.complete(null);
  }

  void fail([Object error = 'link lost']) {
    ended ??= ShellEnded.unbound();
    _output.addError(error);
  }

  void setHealth(ShellConnectionHealth health) => _health.add(health);

  void exit(int code) {
    ended ??= ShellEnded.unbound();
    if (!_exit.isCompleted) _exit.complete(code);
  }

  String get written => writes.map(String.fromCharCodes).join();
}

class _FakeChannels implements HostChannels {
  _FakeChannels(this._connection, {required this.background});

  final FakeShellConnection _connection;
  final bool background;

  @override
  Future<ExecResult?> exec(
    String command, {
    Uint8List? stdin,
    required Duration timeout,
  }) {
    final connection = _connection;
    if (background && !connection.hostHeld) return Future.value(null);
    if (background && timeout == agentProbeDeadline) {
      connection.timedProbes.add(command);
      final hold = connection.holdTimedProbe;
      if (hold != null) return hold.future;
    }
    return connection._exec(command, stdin: stdin, timeout: timeout);
  }

  @override
  Future<FileWrite?> put(
    String path,
    FileBody body, {
    required Duration timeout,
    PutProgress? onProgress,
  }) async {
    if (background && !_connection.hostHeld) return null;
    return putFile(
      sftp: () => throw SSHChannelRequestError('no sftp'),
      exec: (command, stdin) async {
        final result = await _connection._exec(
          command,
          stdin: await collectBytes(stdin),
          timeout: timeout,
        );
        if (!result.ok) return result;
        return ExecResult(
          exitCode: result.exitCode,
          stdout: Uint8List.fromList(utf8.encode('$putLanded\n')),
          stderr: result.stderr,
        );
      },
      path: path,
      body: body,
      timeout: timeout,
      onProgress: onProgress,
    );
  }
}

class FakeShellTransport {
  final opened = <FakeShellConnection>[];
  final sizes = <List<int>>[];

  /// One per dial, in order.
  final verifiers = <HostKeyVerifier?>[];

  /// One per dial, in order: what the tab asked to run in place of the login shell, and
  /// null for the tabs that wanted the login shell.
  final commands = <String?>[];

  final reasons = <OpenReason>[];
  final ports = <int>[];
  final tabSessions = <String?>[];
  final alone = <bool>[];

  ShellTransport transport = ShellTransport.ssh;

  /// Set to make the next dial fail, cleared to let it succeed. Null keeps a dial pending
  /// forever, which is how `CONNECTING` is held still.
  Object? refuse;
  var stall = false;

  /// Run on every connection the moment it is handed back, which is the only place a test
  /// can answer a question the screen asks on its first frame.
  void Function(FakeShellConnection connection)? opening;

  /// The dials [stall] is holding, so a test can let one land late.
  final _stalled = <Completer<ShellConnection>>[];

  Future<ShellConnection> open({
    required OpenReason reason,
    required String address,
    required int port,
    required String user,
    required String privateKey,
    HostKeyVerifier? verifier,
    required int columns,
    required int rows,
    String? command,
    String? tabSession,
    void Function(Reconnect retry)? failed,
    bool alone = false,
  }) async {
    reasons.add(reason);
    ports.add(port);
    this.alone.add(alone);
    sizes.add([columns, rows]);
    verifiers.add(verifier);
    commands.add(command);
    tabSessions.add(tabSession);
    if (stall) {
      final pending = Completer<ShellConnection>();
      _stalled.add(pending);
      return pending.future;
    }
    final failure = refuse;
    if (failure != null) {
      failed?.call(ShellEnded.unbound().reconnect);
      throw failure;
    }
    final connection = FakeShellConnection(transport: transport);
    opened.add(connection);
    opening?.call(connection);
    return connection;
  }

  /// Completes every dial [stall] is holding, oldest first.
  void land() {
    for (final pending in _stalled) {
      final connection = FakeShellConnection(transport: transport);
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
  ShellSnapshotStore? snapshots,
  Duration snapshotQuiet = const Duration(seconds: 5),
  Duration sleepGrace = const Duration(seconds: 10),
  Duration pinRecheck = const Duration(seconds: 5),
  Duration pinStale = const Duration(minutes: 5),
  Duration pinAnswerWait = const Duration(seconds: 5),
  PinNotifier? notifier,
  DateTime Function() now = DateTime.now,
  Future<void> Function(String hostId, HostSystem system)? recordSystem,
  Future<Host> Function(Host host)? beforeDial,
  Future<LinkResult> Function(String address, int port)? probeHost,
}) => ShellSessions(
  readPrivateKey: (_) async => privateKey,
  pinHostKey: pinHostKey ?? (_, _) async {},
  tabs: tabs,
  snapshots: snapshots,
  snapshotQuiet: snapshotQuiet,
  sleepGrace: sleepGrace,
  open: transport.open,
  pinRecheck: pinRecheck,
  pinStale: pinStale,
  pinAnswerWait: pinAnswerWait,
  notifier: notifier,
  now: now,
  recordSystem: recordSystem,
  beforeDial: beforeDial,
  probeHost: probeHost ?? (_, _) async => const LinkResult(LinkStatus.noRoute),
);
