import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_mosh/dart_mosh.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/features/shell/shell_sessions.dart';
import 'package:upgrade/platform/shell/engine_channel.dart';
import 'package:upgrade/platform/shell/mosh_channel.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/platform/shell/remote_shell.dart';
import 'package:upgrade/platform/shell/shell_tunnel.dart';
import 'package:upgrade/platform/shell/udp_path.dart';
import 'package:upgrade/platform/host_keys.dart';
import 'package:upgrade/platform/host_links.dart';
import 'package:upgrade/platform/keys.dart';
import 'package:upgrade/platform/ssh/connection_supervisor.dart'
    show ConnectionSupervisor;
import 'package:upgrade/platform/ssh_settle.dart';

import 'support/host_links.dart';
import 'support/ssh_exec.dart';

/// `dart:io` reports a reset on both ends of the socket: the stream the transport reads
/// and the `done` nothing in dartssh2 is holding.
class RudeSocket implements SSHSocket {
  final _incoming = StreamController<Uint8List>();
  final _outgoing = StreamController<List<int>>();
  final _done = Completer<void>();

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Future<void> get done => _done.future;

  bool get closed => _done.isCompleted;

  static const _reason = SocketException('Connection reset by peer');

  var _reset = false;

  @override
  Future<void> close() async {
    if (_reset) throw _reason;
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void destroy() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> flush() async {}

  void reset() {
    _reset = true;
    _incoming.addError(_reason);
  }
}

class FakePty implements SSHSession {
  // A cancel with no onCancel hands back a root-zone future, which a fake clock never
  // completes: a tab closing under testWidgets would wait on it forever.
  final _stdout = StreamController<Uint8List>(onCancel: () async {});
  final _stderr = StreamController<Uint8List>(onCancel: () async {});
  final _done = Completer<void>();

  final writes = <Uint8List>[];
  final resizes = <String>[];
  bool closed = false;
  int? reported;
  String? signal;

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  @override
  Future<void> get done => _done.future;

  @override
  int? get exitCode => reported;

  @override
  SSHSessionExitSignal? get exitSignal {
    final name = signal;
    return name == null
        ? null
        : SSHSessionExitSignal(
            signalName: name,
            coreDumped: false,
            errorMessage: '',
            languageTag: '',
          );
  }

  @override
  void write(Uint8List bytes) => writes.add(bytes);

  @override
  void resizeTerminal(
    int columns,
    int rows, [
    int pixelWidth = 0,
    int pixelHeight = 0,
  ]) => resizes.add('${columns}x$rows');

  @override
  void close() => closed = true;

  void out(List<int> bytes) => _stdout.add(Uint8List.fromList(bytes));

  void err(List<int> bytes) => _stderr.add(Uint8List.fromList(bytes));

  void fail(Object error) => _stdout.addError(error);

  void exit(int? code) {
    reported = code;
    _done.complete();
  }

  void signalled(String name) {
    signal = name;
    _done.complete();
  }

  /// dartssh2 4.0.0 on a dead link: every channel is destroyed, which closes its stream
  /// cleanly and completes `done` normally, with no exit status.
  void lose() {
    if (_done.isCompleted) return;
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    _done.complete();
  }

  void endOn(Object error) => _done.completeError(error);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeExec implements SSHSession {
  FakeExec({this.out = '', this.err = '', this.reported = 0, this.answerInput});

  final String Function(String stdin)? answerInput;
  final _input = BytesBuilder();
  final _answer = StreamController<Uint8List>();
  final _channel = FakeExecChannel();
  late final _stdin = _FakeStdin(_input, _closeStdin);

  final _done = Completer<void>();
  final String out;
  final String err;
  final int? reported;
  final killed = <SSHSignal>[];

  bool get closed => _channel.destroyed > 0;

  @override
  get channel => _channel;

  @override
  Stream<Uint8List> get stdout => answerInput != null
      ? _answer.stream
      : out.isEmpty
      ? const Stream.empty()
      : Stream.value(Uint8List.fromList(out.codeUnits));

  @override
  Stream<Uint8List> get stderr => err.isEmpty
      ? const Stream.empty()
      : Stream.value(Uint8List.fromList(err.codeUnits));

  @override
  Future<void> get done => _done.future;

  @override
  int? get exitCode => reported;

  @override
  StreamSink<Uint8List> get stdin => _stdin;

  @override
  void kill(SSHSignal signal) => killed.add(signal);

  Future<void> _closeStdin() async {
    final answer = answerInput;
    if (answer != null && !_answer.isClosed) {
      final said = answer(utf8.decode(_input.takeBytes()));
      if (said.isNotEmpty) _answer.add(Uint8List.fromList(utf8.encode(said)));
      unawaited(_answer.close());
    }
    if (!_done.isCompleted) _done.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeStdin implements StreamSink<Uint8List> {
  _FakeStdin(this._input, this._close);

  final BytesBuilder _input;
  final Future<void> Function() _close;

  @override
  void add(Uint8List data) => _input.add(data);

  @override
  Future<void> close() => _close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeHost implements SSHClient {
  FakeHost({
    this.authError,
    this.shellError,
    this.execOut = '',
    this.execError = '',
    this.execCode = 0,
  });

  final Object? authError;
  final Object? shellError;
  Object? refuse;
  Completer<void>? authGate;
  Completer<SSHSession>? execGate;
  String execOut;
  String execError;
  int? execCode;
  String Function(String command)? execAnswer;
  int? Function(String command)? execCodeAnswer;

  String Function(String command, String stdin)? execInputAnswer;
  final inputs = <String>[];

  final requests = <String>[];

  FakePty pty = FakePty();
  final _ptys = <FakePty>[];
  bool closed = false;

  FakePty _nextPty() {
    if (_ptys.isNotEmpty) pty = FakePty();
    _ptys.add(pty);
    return pty;
  }

  @override
  Future<void> get authenticated async {
    await authGate?.future;
    final error = authError;
    if (error != null) throw error;
  }

  @override
  Future<SSHSession> execute(
    String command, {
    SSHPtyConfig? pty,
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async {
    if (pty != null) {
      requests.add('run $command ${pty.type} ${pty.width}x${pty.height}');
      final error = shellError;
      if (error != null) throw error;
      return _nextPty();
    }
    requests.add('exec $command');
    final error = refuse;
    if (error != null) throw error;
    final gate = execGate;
    if (gate != null) return gate.future;
    final inputAnswer = execInputAnswer;
    return FakeExec(
      out: execAnswer?.call(command) ?? execOut,
      err: execError,
      reported: execCodeAnswer?.call(command) ?? execCode,
      answerInput: inputAnswer == null
          ? null
          : (stdin) {
              inputs.add(stdin);
              return inputAnswer(command, stdin);
            },
    );
  }

  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty = const SSHPtyConfig(),
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async {
    requests.add('shell ${pty?.type} ${pty?.width}x${pty?.height}');
    final error = shellError;
    if (error != null) throw error;
    return _nextPty();
  }

  final _gone = Completer<void>();

  var answers = true;
  var checks = 0;

  @override
  Future<void> ping() async {
    checks++;
    if (!answers) await Completer<void>().future;
  }

  @override
  bool get isClosed => _gone.isCompleted;

  @override
  Future<void> get done => _gone.future;

  void die() {
    if (!_gone.isCompleted) _gone.complete();
  }

  @override
  Future<void> close() async {
    closed = true;
    die();
    for (final pty in _ptys) {
      pty.lose();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SilentPtyHost extends FakeHost {
  final opening = Completer<SSHSession>();

  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty = const SSHPtyConfig(),
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) => opening.future;
}

class FakeMoshChannel implements MoshChannel {
  final _output = StreamController<Uint8List>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final _echoAcks = StreamController<int>.broadcast();
  final _contacts = StreamController<void>.broadcast();
  final _done = Completer<void>();

  final sent = <Uint8List>[];
  final sizes = <({int columns, int rows})>[];
  var rehomes = 0;
  var suspends = 0;
  var closed = false;

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Stream<Object> get errors => _errors.stream;

  @override
  Stream<int> get echoAcks => _echoAcks.stream;

  @override
  Stream<void> get contacts => _contacts.stream;

  @override
  Future<void> firstContact = Future<void>.value();

  @override
  Future<void> get done => _done.future;

  @override
  int send(Uint8List bytes) {
    sent.add(bytes);
    return sent.length + sizes.length;
  }

  @override
  int resize(int columns, int rows) {
    sizes.add((columns: columns, rows: rows));
    return sent.length + sizes.length;
  }

  @override
  Future<void> rehome() async => rehomes++;

  @override
  Future<void> suspend() async => suspends++;

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    if (!_done.isCompleted) _done.complete();
    await _output.close();
    await _errors.close();
    await _echoAcks.close();
    await _contacts.close();
  }

  void emit(String value) => _output.add(Uint8List.fromList(value.codeUnits));

  void acknowledge(int state) => _echoAcks.add(state);

  void contact() => _contacts.add(null);

  void fallSilent([Duration window = const Duration(milliseconds: 20)]) =>
      firstContact = Future<void>.delayed(
        window,
        () => throw UdpSilent(address: '10.0.0.7', port: 60990, window: window),
      );
}

HostLinks linksOver(
  FutureOr<FakeHost> Function(HostKeyVerifier verifier) next, {
  Duration timeout = const Duration(seconds: 10),
  Object? dialError,
}) {
  final links = HostLinks(
    timeout: timeout,
    keepAlive: const Duration(days: 1),
    linger: Duration.zero,
    dial:
        ({
          required address,
          required port,
          required user,
          required privateKey,
          required verifier,
          onSettling,
        }) async {
          final error = dialError;
          if (error != null) throw error;
          return authenticatedLink(
            FakeExecSocket(),
            await next(verifier),
            () => 0,
            verifier: verifier,
            timeout: timeout,
            onSettling: onSettling,
          );
        },
  );
  addTearDown(links.close);
  return links;
}

ShellTunnel tunnelTo(FakeHost host, {Object? dialError}) =>
    ShellTunnel(links: linksOver((_) => host, dialError: dialError));

ShellTunnel moshTunnelTo(
  FakeHost host,
  FakeMoshChannel channel, {
  Duration timeout = const Duration(seconds: 10),
  bool emitReady = true,
  Duration healthInterval = const Duration(seconds: 3),
  Duration giveUp = const Duration(seconds: 30),
}) => ShellTunnel(
  timeout: timeout,
  moshHealthInterval: healthInterval,
  moshGiveUp: giveUp,
  links: linksOver((_) => host, timeout: timeout),
  moshDialer:
      ({
        required MoshServerConfig server,
        required int columns,
        required int rows,
      }) async {
        if (emitReady) Timer.run(() => channel.emit('\x1b[H\$ '));
        return channel;
      },
);

ShellTunnel moshTunnelOver(
  List<FakeHost> hosts,
  FakeMoshChannel channel,
  int Function() dialled,
) => ShellTunnel(
  links: linksOver((_) => hosts[dialled()]),
  moshDialer:
      ({
        required MoshServerConfig server,
        required int columns,
        required int rows,
      }) async {
        Timer.run(() => channel.emit('\$ '));
        return channel;
      },
);

final pinnedKey = PinnedHostKey(
  type: 'ssh-ed25519',
  fingerprint: 'SHA256:pinned',
  pinnedAt: DateTime(2026),
);

ShellTunnel moshTunnelOffering(
  List<FakeHost> hosts,
  FakeMoshChannel channel,
  List<String?> fingerprints,
  List<HostKeyVerifier> verifiers,
) => ShellTunnel(
  links: linksOver((verifier) async {
    final dial = verifiers.length;
    verifiers.add(verifier);
    final offered = fingerprints[dial];
    if (offered == null ||
        await verifier.verifyFingerprint('ssh-ed25519', offered)) {
      return hosts[dial];
    }
    return FakeHost(
      authError: SSHAuthAbortError(
        'Connection closed before authentication',
        SSHHostkeyError('Hostkey verification failed'),
      ),
    );
  }),
  moshDialer:
      ({
        required MoshServerConfig server,
        required int columns,
        required int rows,
      }) async {
        Timer.run(() => channel.emit('\$ '));
        return channel;
      },
);

Future<ShellConnection> openOn(
  ShellTunnel tunnel, {
  String? command,
  String? tabSession,
  String? persistentSession,
  HostKeyVerifier? verifier,
  void Function(Reconnect retry)? failed,
}) => tunnel.open(
  reason: UserAction(UserIntent.fromGesture()),
  address: 'nyx',
  port: 357,
  user: 'luisnquin',
  privateKey: 'pem',
  columns: 100,
  rows: 40,
  command: command,
  tabSession: tabSession,
  persistentSession: persistentSession,
  verifier: verifier ?? HostKeyVerifier.pinnedOnly(pinnedKey),
  failed: failed,
);

Future<ShellFailureKind> kindOf(Future<void> Function() body) async {
  try {
    await body();
  } on ShellFailure catch (failure) {
    return failure.kind;
  }
  fail('the open was expected to fail');
}

const _tmuxPath = '/nix/store/tmux/bin/tmux';
const _moshPath = '/nix/store/mosh/bin/mosh-server';

String moshHostAnswer(String command, {bool tmux = true}) {
  if (command == durableShellProbeCommand('upgrade123')) {
    return tmux ? 'UPGRADE_TMUX=$_tmuxPath\nUPGRADE_RESUME=0\n' : '';
  }
  if (command == moshServerProbeCommand()) {
    return 'profile noise\nUPGRADE_MOSH=$_moshPath\n';
  }
  if (command.contains('mosh-server') && command.contains(' new ')) {
    return 'MOSH CONNECT 60001 AAECAwQFBgcICQoLDA0ODw\n';
  }
  return '';
}

void main() {
  group('the entry point', () {
    test(
      'asks for a shell on a pty of the view size and nothing else',
      () async {
        final host = FakeHost();
        final connection = await openOn(tunnelTo(host));
        addTearDown(
          () => connection.close(UserClosed(UserIntent.fromGesture())),
        );

        expect(host.requests, ['shell xterm-256color 100x40']);
      },
    );

    test(
      'a command runs on a pty of its own and no shell is asked for',
      () async {
        final host = FakeHost();
        final connection = await openOn(
          tunnelTo(host),
          command: "herdr agent attach 'w22:p1'",
        );
        addTearDown(
          () => connection.close(UserClosed(UserIntent.fromGesture())),
        );

        // The same pty on the same kind of channel, under an exec request instead of a shell
        // request — `ssh -t`.
        expect(host.requests, [
          "run herdr agent attach 'w22:p1' xterm-256color 100x40",
        ]);
      },
    );

    test('a durable tab starts inside its own tmux server', () async {
      const tmux = '/nix/store/tmux/bin/tmux';
      const session = 'upgrade123';
      const command = 'export UPGRADE_TAB=upgrade123; exec \$SHELL -l';
      final host = FakeHost(
        execOut: 'noise\nUPGRADE_TMUX=$tmux\nUPGRADE_RESUME=0\n',
      );

      final connection = await openOn(
        tunnelTo(host),
        command: command,
        persistentSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

      expect(connection.continuity, ShellContinuity.started);
      expect(host.requests, [
        'exec ${durableShellProbeCommand(session)}',
        'run ${durableShellCommand(tmux, session, command)} '
            'xterm-256color 100x40',
      ]);
    });

    test('an existing durable tab is classified as resumed', () async {
      const tmux = '/usr/bin/tmux';
      const session = 'upgrade123';
      final host = FakeHost(execOut: 'UPGRADE_TMUX=$tmux\nUPGRADE_RESUME=1\n');

      final connection = await openOn(
        tunnelTo(host),
        command: 'exec \$SHELL -l',
        persistentSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

      expect(connection.continuity, ShellContinuity.resumed);
    });

    test('a host without tmux keeps the plain SSH command', () async {
      const session = 'upgrade123';
      const command = 'exec \$SHELL -l';
      final host = FakeHost(execCode: 127);

      final connection = await openOn(
        tunnelTo(host),
        command: command,
        persistentSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

      expect(connection.continuity, ShellContinuity.plain);
      expect(host.requests, [
        'exec ${durableShellProbeCommand(session)}',
        'run $command xterm-256color 100x40',
      ]);
    });

    test('Mosh carries a durable shell and rehomes its UDP socket', () async {
      const session = 'upgrade123';
      const command = 'export UPGRADE_TAB=upgrade123; exec \$SHELL -l';
      final host = FakeHost()..execAnswer = moshHostAnswer;
      final channel = FakeMoshChannel();
      final connection = await openOn(
        moshTunnelTo(host, channel),
        command: command,
        tabSession: session,
        persistentSession: session,
      );

      expect(connection, isA<MoshShellConnection>());
      expect(connection.continuity, ShellContinuity.started);
      expect(host.requests, contains('exec ${moshServerProbeCommand()}'));
      expect(
        host.requests,
        contains('exec ${moshServerCleanupCommand(session)}'),
      );
      expect(
        host.requests.where((request) => request.startsWith('run ')),
        isEmpty,
      );
      final launch = host.requests.singleWhere(
        (request) =>
            request.contains('mosh-server') && request.contains(' new '),
      );
      expect(launch, contains("$moshTabVariable='upgrade123'"));
      expect(launch, contains("-- sh -c 'exec '\\''$_tmuxPath'"));

      connection.write(Uint8List.fromList([0x6c, 0x73, 0x0d]));
      connection.resize(91, 37);
      await connection.rehome();
      expect(channel.sent.single, [0x6c, 0x73, 0x0d]);
      expect(channel.sizes, [(columns: 91, rows: 37), (columns: 91, rows: 37)]);
      expect(channel.rehomes, 1);
      await connection.close(UserClosed(UserIntent.fromGesture()));
    });

    test('Mosh sends a resize while an earlier probe is pending', () async {
      const session = 'upgrade123';
      final host = FakeHost()..execAnswer = moshHostAnswer;
      final channel = FakeMoshChannel();
      final connection = await openOn(
        moshTunnelTo(host, channel),
        command: 'exec \$SHELL -l',
        tabSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

      connection.resize(91, 37);
      connection.resize(120, 45);

      expect(channel.sizes, [
        (columns: 91, rows: 37),
        (columns: 120, rows: 45),
      ]);
    });

    test(
      'Mosh health follows acknowledged contact, not session existence',
      () async {
        const session = 'upgrade123';
        final host = FakeHost()..execAnswer = moshHostAnswer;
        final channel = FakeMoshChannel();
        final connection = await openOn(
          moshTunnelTo(
            host,
            channel,
            healthInterval: const Duration(milliseconds: 5),
          ),
          command: 'exec \$SHELL -l',
          tabSession: session,
        );
        addTearDown(
          () => connection.close(UserClosed(UserIntent.fromGesture())),
        );
        final health = <ShellConnectionHealth>[];
        connection.health.listen(health.add);

        await Future<void>.delayed(const Duration(milliseconds: 14));
        expect(health, contains(ShellConnectionHealth.reconnecting));

        await Future<void>.delayed(const Duration(milliseconds: 12));
        expect(health.last, ShellConnectionHealth.disconnected);

        channel.acknowledge(channel.sizes.length);
        await pumpEventQueue();
        expect(health.last, ShellConnectionHealth.connected);
      },
    );

    test(
      'a Mosh packet that carries no screen still counts as contact',
      () async {
        const session = 'upgrade123';
        final host = FakeHost()..execAnswer = moshHostAnswer;
        final channel = FakeMoshChannel();
        final connection = await openOn(
          moshTunnelTo(
            host,
            channel,
            healthInterval: const Duration(milliseconds: 5),
          ),
          command: 'exec \$SHELL -l',
          tabSession: session,
        );
        addTearDown(
          () => connection.close(UserClosed(UserIntent.fromGesture())),
        );
        final health = <ShellConnectionHealth>[];
        connection.health.listen(health.add);

        await Future<void>.delayed(const Duration(milliseconds: 14));
        expect(health.last, ShellConnectionHealth.reconnecting);

        channel.contact();
        await pumpEventQueue();
        expect(health.last, ShellConnectionHealth.connected);
      },
    );

    test(
      'a thawed Mosh tab owes one missed answer, not one per tick',
      () async {
        const session = 'upgrade123';
        final host = FakeHost()..execAnswer = moshHostAnswer;
        final channel = FakeMoshChannel();
        final connection = await openOn(
          moshTunnelTo(
            host,
            channel,
            healthInterval: const Duration(milliseconds: 5),
          ),
          command: 'exec \$SHELL -l',
          tabSession: session,
        );
        addTearDown(
          () => connection.close(UserClosed(UserIntent.fromGesture())),
        );
        final health = <ShellConnectionHealth>[];
        connection.health.listen(health.add);

        final frozen = Stopwatch()..start();
        while (frozen.elapsedMilliseconds < 40) {}
        await pumpEventQueue();

        expect(health, isNot(contains(ShellConnectionHealth.disconnected)));
      },
    );

    test('a Mosh channel that stops answering reaches the reader', () async {
      const session = 'upgrade123';
      final host = FakeHost()..execAnswer = moshHostAnswer;
      final channel = FakeMoshChannel();
      final connection = await openOn(
        moshTunnelTo(
          host,
          channel,
          healthInterval: const Duration(milliseconds: 5),
          giveUp: const Duration(milliseconds: 40),
        ),
        command: 'exec \$SHELL -l',
        tabSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));
      Object? reported;
      connection.output.listen(
        (_) {},
        onError: (Object error) {
          reported ??= error;
        },
      );

      await Future<void>.delayed(const Duration(milliseconds: 90));

      expect(reported, isA<ShellFailure>());
      expect((reported! as ShellFailure).kind, ShellFailureKind.streamClosed);
    });

    test('a suspended Mosh tab goes quiet and rehomes on resume', () async {
      const session = 'upgrade123';
      final hosts = [
        FakeHost()..execAnswer = moshHostAnswer,
        FakeHost()..execAnswer = moshHostAnswer,
      ];
      var dials = 0;
      final channel = FakeMoshChannel();
      final connection = await openOn(
        moshTunnelOver(hosts, channel, () => dials++),
        command: 'exec \$SHELL -l',
        tabSession: session,
        persistentSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

      await connection.suspend(AppSuspended(PlatformSignal.fromPlatform()));
      final probes = channel.sizes.length;
      await connection.rehome();

      expect(channel.suspends, 1);
      expect(channel.rehomes, 0);
      expect(channel.sizes.length, probes);
      await pumpEventQueue();
      expect(hosts.first.closed, isTrue);
      expect(
        await connection.channels.exec('pwd', timeout: remoteCommandDeadline),
        isNull,
      );
      expect(dials, 1);

      await connection.resume(AppResumed(PlatformSignal.fromPlatform()));
      await pumpEventQueue();
      final result = await connection.channels.exec(
        'pwd',
        timeout: remoteCommandDeadline,
      );

      expect(channel.rehomes, 1);
      expect(channel.sizes.length, probes + 1);
      expect(result?.ok, isTrue);
      expect(dials, 2);
    });

    test('a suspended Mosh tab dials no control path', () async {
      const session = 'upgrade123';
      final hosts = [
        FakeHost()..execAnswer = moshHostAnswer,
        FakeHost()..execAnswer = moshHostAnswer,
        FakeHost()..execAnswer = moshHostAnswer,
      ];
      var dials = 0;
      final connection = await openOn(
        moshTunnelOver(hosts, FakeMoshChannel(), () => dials++),
        command: 'exec \$SHELL -l',
        tabSession: session,
        persistentSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

      await connection.rehome(
        network: NetworkChanged(PlatformSignal.fromPlatform()),
      );
      await connection.suspend(AppSuspended(PlatformSignal.fromPlatform()));
      await pumpEventQueue();

      expect(hosts[1].closed, isTrue);
      expect(
        await connection.channels.exec('pwd', timeout: remoteCommandDeadline),
        isNull,
      );
      await connection.rehome(
        network: NetworkChanged(PlatformSignal.fromPlatform()),
      );
      await pumpEventQueue();
      expect(dials, 2);
    });

    test('a network change replaces the SSH control path and a failed command '
        'does not', () async {
      const session = 'upgrade123';
      final hosts = [
        FakeHost()..execAnswer = moshHostAnswer,
        FakeHost()..execAnswer = moshHostAnswer,
      ];
      var dials = 0;
      final channel = FakeMoshChannel();
      final connection = await openOn(
        moshTunnelOver(hosts, channel, () => dials++),
        command: 'exec \$SHELL -l',
        tabSession: session,
        persistentSession: session,
      );

      hosts.first.refuse = StateError('control host failed');
      await expectLater(
        connection.channels.exec('pwd', timeout: remoteCommandDeadline),
        throwsStateError,
      );
      expect(dials, 1);
      expect(hosts.first.closed, isFalse);
      hosts.first.refuse = null;
      await connection.rehome(
        network: NetworkChanged(PlatformSignal.fromPlatform()),
      );
      await pumpEventQueue();
      final result = await connection.channels.exec(
        'pwd',
        timeout: remoteCommandDeadline,
      );

      expect(result?.ok, isTrue);
      expect(dials, 2);
      expect(hosts.first.closed, isTrue);
      expect(hosts.last.requests.last, 'exec pwd');
      await connection.close(UserClosed(UserIntent.fromGesture()));
    });

    test('a probe timeout during channel open never redials', () async {
      const session = 'upgrade123';
      final host = FakeHost()..execAnswer = moshHostAnswer;
      var dials = 0;
      final connection = await openOn(
        moshTunnelOver([host], FakeMoshChannel(), () => dials++),
        command: 'exec \$SHELL -l',
        tabSession: session,
        persistentSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

      final opening = Completer<SSHSession>();
      host.execGate = opening;
      await expectLater(
        connection.channels.exec(
          'pwd',
          timeout: const Duration(milliseconds: 10),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(dials, 1);
      expect(host.closed, isFalse);

      final lateChannel = FakeExec();
      opening.complete(lateChannel);
      await Future<void>.delayed(Duration.zero);
      expect(lateChannel.closed, isTrue);
      expect(dials, 1);
    });

    test(
      'a startup exec that never opens fails the open as a host failure',
      () async {
        const session = 'upgrade123';
        final host = FakeHost()..execGate = Completer<SSHSession>();
        final retries = <Reconnect>[];

        await expectLater(
          openOn(
            moshTunnelTo(
              host,
              FakeMoshChannel(),
              timeout: const Duration(milliseconds: 20),
            ),
            command: 'exec \$SHELL -l',
            tabSession: session,
            persistentSession: session,
            failed: retries.add,
          ),
          throwsA(anything),
        );
        expect(host.requests, ['exec ${durableShellProbeCommand(session)}']);
        expect(retries, hasLength(1));
      },
    );

    test('a pty that never opens fails the open as a host failure', () async {
      final host = _SilentPtyHost();
      final retries = <Reconnect>[];

      await expectLater(
        openOn(
          moshTunnelTo(
            host,
            FakeMoshChannel(),
            timeout: const Duration(milliseconds: 20),
          ),
          failed: retries.add,
        ),
        throwsA(anything),
      );
      expect(retries, hasLength(1));
      host.opening.complete(host.pty);
      await Future<void>.delayed(Duration.zero);
      expect(host.pty.closed, isTrue);
    });

    test('a plain return keeps the SSH control path', () async {
      const session = 'upgrade123';
      final hosts = [
        FakeHost()..execAnswer = moshHostAnswer,
        FakeHost()..execAnswer = moshHostAnswer,
      ];
      var dials = 0;
      final channel = FakeMoshChannel();
      final connection = await openOn(
        moshTunnelOver(hosts, channel, () => dials++),
        command: 'exec \$SHELL -l',
        tabSession: session,
        persistentSession: session,
      );

      await connection.rehome();
      final result = await connection.channels.exec(
        'pwd',
        timeout: remoteCommandDeadline,
      );

      expect(result?.ok, isTrue);
      expect(channel.rehomes, 1);
      expect(dials, 1);
      expect(hosts.first.closed, isFalse);
      expect(hosts.first.requests.last, 'exec pwd');

      hosts.first.refuse = const SocketException('Connection reset by peer');
      await expectLater(
        connection.channels.exec('pwd', timeout: remoteCommandDeadline),
        throwsA(isA<SocketException>()),
      );

      expect(dials, 1);
      expect(hosts.first.closed, isFalse);
      await connection.close(UserClosed(UserIntent.fromGesture()));
    });

    test('a host that dies leaves background reads empty until a gesture '
        'dials it', () async {
      const session = 'upgrade123';
      final hosts = [
        FakeHost()..execAnswer = moshHostAnswer,
        FakeHost()..execAnswer = moshHostAnswer,
      ];
      var dials = 0;
      final connection = await openOn(
        moshTunnelOver(hosts, FakeMoshChannel(), () => dials++),
        command: 'exec \$SHELL -l',
        tabSession: session,
        persistentSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

      hosts.first.die();
      await pumpEventQueue();

      expect(
        await connection.channels.exec('pwd', timeout: remoteCommandDeadline),
        isNull,
      );
      expect(dials, 1);

      final action = UserAction(UserIntent.fromGesture());
      final channels = await connection.channelsFor(action);
      final result = await channels?.exec(
        'pwd',
        timeout: remoteCommandDeadline,
      );

      expect(result?.ok, isTrue);
      expect(dials, 2);
      expect(hosts.last.requests.last, 'exec pwd');
      expect(
        await connection.channels.exec('pwd', timeout: remoteCommandDeadline),
        isNotNull,
      );
    });

    test('two user actions at once dial one host', () async {
      const session = 'upgrade123';
      final hosts = [
        FakeHost()..execAnswer = moshHostAnswer,
        FakeHost()..execAnswer = moshHostAnswer,
        FakeHost()..execAnswer = moshHostAnswer,
      ];
      var dials = 0;
      final connection = await openOn(
        moshTunnelOver(hosts, FakeMoshChannel(), () => dials++),
        command: 'exec \$SHELL -l',
        tabSession: session,
        persistentSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));
      hosts.first.die();
      await pumpEventQueue();

      await Future.wait([
        connection.channelsFor(UserAction(UserIntent.fromGesture())),
        connection.channelsFor(UserAction(UserIntent.fromGesture())),
      ]);

      expect(dials, 2);
    });

    test('a gesture whose dial a network change overtook lands on the host '
        'that change dialled', () async {
      const session = 'upgrade123';
      final hosts = [
        FakeHost()..execAnswer = moshHostAnswer,
        FakeHost()..execAnswer = moshHostAnswer,
        FakeHost()..execAnswer = moshHostAnswer,
      ];
      var dials = 0;
      final connection = await openOn(
        moshTunnelOver(hosts, FakeMoshChannel(), () => dials++),
        command: 'exec \$SHELL -l',
        tabSession: session,
        persistentSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));
      hosts.first.die();
      await pumpEventQueue();
      final gate = Completer<void>();
      hosts[1].authGate = gate;

      final stale = connection.channelsFor(
        UserAction(UserIntent.fromGesture()),
      );
      await connection.rehome(
        network: NetworkChanged(PlatformSignal.fromPlatform()),
      );
      gate.complete();
      await pumpEventQueue();

      final chained = await stale;
      expect(dials, 3);
      expect(hosts[1].closed, isTrue);
      expect(
        (await chained?.exec('whoami', timeout: remoteCommandDeadline))?.ok,
        isTrue,
      );
      expect(hosts.last.requests.last, 'exec whoami');
      expect(
        (await connection.channels.exec(
          'pwd',
          timeout: remoteCommandDeadline,
        ))?.ok,
        isTrue,
      );
      expect(hosts.last.requests.last, 'exec pwd');
    });

    test('a gesture whose overtaken dial throws lands on the host that change '
        'dialled', () async {
      const session = 'upgrade123';
      final hosts = [
        FakeHost()..execAnswer = moshHostAnswer,
        FakeHost(authError: SSHAuthFailError('no more methods')),
        FakeHost()..execAnswer = moshHostAnswer,
      ];
      var dials = 0;
      final connection = await openOn(
        moshTunnelOver(hosts, FakeMoshChannel(), () => dials++),
        command: 'exec \$SHELL -l',
        tabSession: session,
        persistentSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));
      hosts.first.die();
      await pumpEventQueue();
      final gate = Completer<void>();
      hosts[1].authGate = gate;

      final stale = connection.channelsFor(
        UserAction(UserIntent.fromGesture()),
      );
      await connection.rehome(
        network: NetworkChanged(PlatformSignal.fromPlatform()),
      );
      gate.complete();
      await pumpEventQueue();

      final chained = await stale;
      expect(dials, 3);
      expect(
        (await chained?.exec('whoami', timeout: remoteCommandDeadline))?.ok,
        isTrue,
      );
      expect(hosts.last.requests.last, 'exec whoami');
    });

    test('a dead control host is dialled again on its own, and reads stay '
        'empty and stale until it lands', () async {
      const session = 'upgrade123';
      final hosts = [
        FakeHost()..execAnswer = moshHostAnswer,
        FakeHost()..execAnswer = moshHostAnswer,
      ];
      var dials = 0;
      final connection = await openOn(
        moshTunnelOver(hosts, FakeMoshChannel(), () => dials++),
        command: 'exec \$SHELL -l',
        tabSession: session,
        persistentSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));
      final links = <ControlLink>[];
      connection.controlLink.listen(links.add);

      hosts.first.die();
      await pumpEventQueue();

      expect(links, [isA<ControlReconnecting>()]);
      expect(
        await connection.channels.exec('pwd', timeout: remoteCommandDeadline),
        isNull,
      );
      expect(dials, 1);

      await Future<void>.delayed(const Duration(milliseconds: 1200));

      expect(dials, 2);
      expect(links, [isA<ControlReconnecting>(), isA<ControlUp>()]);
      expect(
        (await connection.channels.exec(
          'pwd',
          timeout: remoteCommandDeadline,
        ))?.ok,
        isTrue,
      );
      expect(hosts.last.requests.last, 'exec pwd');
    });

    testWidgets('a resume refused while another dial settles reads stale, '
        'then holds the host once the settle ends', (tester) async {
      const session = 'upgrade123';
      FakeLinkClient answering() =>
          FakeLinkClient()
            ..reply = (command) =>
                (exitCode: 0, stdout: moshHostAnswer(command), stderr: '');
      var dials = 0;
      final links = HostLinks(
        dial:
            ({
              required address,
              required port,
              required user,
              required privateKey,
              required verifier,
              onSettling,
            }) async {
              if (++dials == 2) {
                onSettling?.call(Future<void>.delayed(sshLoginGrace));
                throw TimeoutException('auth stalled');
              }
              return (
                socket: FakeExecSocket(),
                client: answering(),
                received: () => 0,
              );
            },
      );
      final channel = FakeMoshChannel();
      ShellConnection? opened;
      unawaited(
        openOn(
          ShellTunnel(
            links: links,
            moshHealthInterval: const Duration(hours: 1),
            moshGiveUp: const Duration(hours: 1),
            moshDialer:
                ({
                  required MoshServerConfig server,
                  required int columns,
                  required int rows,
                }) async {
                  Timer.run(() => channel.emit('\$ '));
                  return channel;
                },
          ),
          command: 'exec \$SHELL -l',
          tabSession: session,
          persistentSession: session,
        ).then((connection) => opened = connection),
      );
      for (var i = 0; i < 100 && opened == null; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final connection = opened!;
      final events = <ControlLink>[];
      connection.controlLink.listen(events.add);

      await connection.suspend(AppSuspended(PlatformSignal.fromPlatform()));
      links
        ..sleep()
        ..wake();
      await expectLater(
        links.claim(
          address: 'nyx',
          port: 357,
          user: 'luisnquin',
          privateKey: 'pem',
          verifier: HostKeyVerifier.pinnedOnly(pinnedKey),
          use: HostUse.tab,
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(dials, 2);

      unawaited(connection.resume(AppResumed(PlatformSignal.fromPlatform())));
      await tester.pump();
      expect(events.last, isA<ControlReconnecting>());
      expect(
        await connection.channels.exec('pwd', timeout: remoteCommandDeadline),
        isNull,
      );

      await tester.pump(sshLoginGrace);
      await tester.pump();
      expect(dials, 3);
      expect(events.last, isA<ControlUp>());
      expect(
        await connection.channels.exec('pwd', timeout: remoteCommandDeadline),
        isNotNull,
      );
      unawaited(connection.close(UserClosed(UserIntent.fromGesture())));
      await tester.pump(const Duration(seconds: 10));
      links.close();
    });

    test('a gesture during the revive backoff dials now, and the revive dials '
        'nothing after it', () async {
      const session = 'upgrade123';
      final hosts = [
        FakeHost()..execAnswer = moshHostAnswer,
        FakeHost()..execAnswer = moshHostAnswer,
        FakeHost()..execAnswer = moshHostAnswer,
      ];
      var dials = 0;
      final connection = await openOn(
        moshTunnelOver(hosts, FakeMoshChannel(), () => dials++),
        command: 'exec \$SHELL -l',
        tabSession: session,
        persistentSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));
      hosts.first.die();
      await pumpEventQueue();

      final channels = await connection.channelsFor(
        UserAction(UserIntent.fromGesture()),
      );
      expect(dials, 2);
      expect(
        (await channels?.exec('pwd', timeout: remoteCommandDeadline))?.ok,
        isTrue,
      );

      await Future<void>.delayed(const Duration(milliseconds: 1200));

      expect(dials, 2);
      expect(hosts[1].closed, isFalse);
    });

    test('a dead control host whose redial is refused the key is not dialled '
        'again', () async {
      const session = 'upgrade123';
      final hosts = [
        FakeHost()..execAnswer = moshHostAnswer,
        FakeHost(authError: SSHAuthFailError('no more methods')),
        FakeHost()..execAnswer = moshHostAnswer,
      ];
      var dials = 0;
      final connection = await openOn(
        moshTunnelOver(hosts, FakeMoshChannel(), () => dials++),
        command: 'exec \$SHELL -l',
        tabSession: session,
        persistentSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));
      final links = <ControlLink>[];
      connection.controlLink.listen(links.add);

      hosts.first.die();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(dials, 2);
      expect(links.last, isA<ControlGaveUp>());

      await Future<void>.delayed(const Duration(milliseconds: 2200));
      expect(dials, 2);
      expect(
        await connection.channels.exec('pwd', timeout: remoteCommandDeadline),
        isNull,
      );
    });

    test('a dead control host that comes back with another key is not dialled '
        'again', () async {
      const session = 'upgrade123';
      final hosts = [
        FakeHost()..execAnswer = moshHostAnswer,
        FakeHost()..execAnswer = moshHostAnswer,
        FakeHost()..execAnswer = moshHostAnswer,
      ];
      final verifiers = <HostKeyVerifier>[];
      final connection = await openOn(
        moshTunnelOffering(hosts, FakeMoshChannel(), [
          pinnedKey.fingerprint,
          'SHA256:impostor',
          pinnedKey.fingerprint,
        ], verifiers),
        command: 'exec \$SHELL -l',
        tabSession: session,
        persistentSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));
      final links = <ControlLink>[];
      connection.controlLink.listen(links.add);

      hosts.first.die();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(verifiers, hasLength(2));
      expect(verifiers.last.prompt, isNull);
      expect(verifiers.last.refusal, HostKeyRefusal.changed);

      await Future<void>.delayed(const Duration(milliseconds: 2200));
      expect(verifiers, hasLength(2));
      expect(links, [
        isA<ControlReconnecting>(),
        isA<ControlGaveUp>().having(
          (link) => link.error,
          'error',
          isKeyFailure,
        ),
      ]);
      expect(
        await connection.channels.exec('pwd', timeout: remoteCommandDeadline),
        isNull,
      );
    });

    test('a dead control host held without a pin refuses its own redial '
        'rather than trusting it', () async {
      const session = 'upgrade123';
      final hosts = [
        FakeHost()..execAnswer = moshHostAnswer,
        FakeHost()..execAnswer = moshHostAnswer,
      ];
      final verifiers = <HostKeyVerifier>[];
      final connection = await openOn(
        moshTunnelOffering(hosts, FakeMoshChannel(), [
          null,
          'SHA256:anything',
        ], verifiers),
        command: 'exec \$SHELL -l',
        tabSession: session,
        persistentSession: session,
        verifier: HostKeyVerifier.pinnedOnly(null),
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

      hosts.first.die();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(verifiers, hasLength(2));
      expect(verifiers.last.pinned, isNull);
      expect(verifiers.last.prompt, isNull);
      expect(verifiers.last.refusal, HostKeyRefusal.unverified);

      await Future<void>.delayed(const Duration(milliseconds: 2200));
      expect(verifiers, hasLength(2));
      expect(
        await connection.channels.exec('pwd', timeout: remoteCommandDeadline),
        isNull,
      );
    });

    test('a plain SSH tab whose host dies is never dialled again by its '
        'supervisor', () async {
      final hosts = [FakeHost(), FakeHost()];
      var dials = 0;
      final connection = await openOn(
        ShellTunnel(links: linksOver((_) => hosts[dials++])),
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

      hosts.first.die();
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      expect(dials, 1);
    });

    test('a refused channel is never asked for again on the same host, and '
        'the host is left alone', () async {
      const session = 'upgrade123';
      final host = FakeHost()..execAnswer = moshHostAnswer;
      var dials = 0;
      final connection = await openOn(
        moshTunnelOver([host], FakeMoshChannel(), () => dials++),
        command: 'exec \$SHELL -l',
        tabSession: session,
        persistentSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));
      final before = host.requests.length;

      host.refuse = SSHChannelOpenError(4, 'channel open refused');
      await expectLater(
        connection.channels.exec('pwd', timeout: remoteCommandDeadline),
        throwsA(isA<SSHChannelOpenError>()),
      );
      await pumpEventQueue();

      expect(host.requests.sublist(before), ['exec pwd']);
      expect(dials, 1);
      expect(host.closed, isFalse);
    });

    test('the channels a transport hands out are not its supervisor', () async {
      const session = 'upgrade123';
      final host = FakeHost()..execAnswer = moshHostAnswer;
      var dials = 0;
      final connection = await openOn(
        moshTunnelOver([host], FakeMoshChannel(), () => dials++),
        command: 'exec \$SHELL -l',
        tabSession: session,
        persistentSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

      expect(connection.channels, isNot(isA<ConnectionSupervisor>()));
      expect(
        await connection.channelsFor(UserAction(UserIntent.fromGesture())),
        isNot(isA<ConnectionSupervisor>()),
      );
    });

    test('an end another terminal minted closes nothing', () async {
      const session = 'upgrade123';
      final host = FakeHost()..execAnswer = moshHostAnswer;
      var dials = 0;
      final connection = await openOn(
        moshTunnelOver([host], FakeMoshChannel(), () => dials++),
        command: 'exec \$SHELL -l',
        tabSession: session,
        persistentSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

      await expectLater(
        connection.close(ShellEnded.unbound()),
        throwsArgumentError,
      );
      await pumpEventQueue();

      expect(host.closed, isFalse);
      expect(connection.ended, isNull);
      expect(
        (await connection.channels.exec(
          'pwd',
          timeout: remoteCommandDeadline,
        ))?.ok,
        isTrue,
      );
    });

    test('a resume behind a suspend still in flight ends in front', () async {
      const session = 'upgrade123';
      final hosts = [
        FakeHost()..execAnswer = moshHostAnswer,
        FakeHost()..execAnswer = moshHostAnswer,
      ];
      var dials = 0;
      final channel = FakeMoshChannel();
      final connection = await openOn(
        moshTunnelOver(hosts, channel, () => dials++),
        command: 'exec \$SHELL -l',
        tabSession: session,
        persistentSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

      final suspended = connection.suspend(
        AppSuspended(PlatformSignal.fromPlatform()),
      );
      final resumed = connection.resume(
        AppResumed(PlatformSignal.fromPlatform()),
      );
      await Future.wait([suspended, resumed]);
      await pumpEventQueue();

      expect(channel.suspends, 1);
      expect(channel.rehomes, 1);
      expect(hosts.first.closed, isTrue);
      expect(dials, 2);
      expect(
        (await connection.channels.exec(
          'pwd',
          timeout: remoteCommandDeadline,
        ))?.ok,
        isTrue,
      );
      expect(hosts.last.requests.last, 'exec pwd');
    });

    test(
      'a gesture on a plain SSH tab whose host died dials nothing',
      () async {
        final hosts = [FakeHost(), FakeHost()];
        var dials = 0;
        final connection = await openOn(
          ShellTunnel(links: linksOver((_) => hosts[dials++])),
        );
        addTearDown(
          () => connection.close(UserClosed(UserIntent.fromGesture())),
        );

        hosts.first.die();
        await pumpEventQueue();
        final channels = await connection.channelsFor(
          UserAction(UserIntent.fromGesture()),
        );

        expect(
          await channels?.exec('pwd', timeout: remoteCommandDeadline),
          isNull,
        );
        expect(dials, 1);
        expect(hosts.last.requests, isEmpty);
      },
    );

    test('a lease from a replaced host answers nothing', () async {
      const session = 'upgrade123';
      final hosts = [
        FakeHost()..execAnswer = moshHostAnswer,
        FakeHost()..execAnswer = moshHostAnswer,
      ];
      var dials = 0;
      final connection = await openOn(
        moshTunnelOver(hosts, FakeMoshChannel(), () => dials++),
        command: 'exec \$SHELL -l',
        tabSession: session,
        persistentSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));
      final lease = await connection.channelsFor(
        UserAction(UserIntent.fromGesture()),
      );

      await connection.rehome(
        network: NetworkChanged(PlatformSignal.fromPlatform()),
      );
      await pumpEventQueue();

      expect(dials, 2);
      expect(await lease?.exec('pwd', timeout: remoteCommandDeadline), isNull);
      expect(hosts.last.requests, isNot(contains('exec pwd')));
    });

    test('an unreachable Mosh UDP port falls back to SSH', () async {
      const session = 'upgrade123';
      const command = 'exec \$SHELL -l';
      final host = FakeHost()..execAnswer = moshHostAnswer;
      final channel = FakeMoshChannel();
      final connection = await openOn(
        moshTunnelTo(
          host,
          channel,
          timeout: const Duration(milliseconds: 5),
          emitReady: false,
        ),
        command: command,
        tabSession: session,
        persistentSession: session,
      );

      expect(connection, isA<SshShellConnection>());
      expect(channel.closed, isTrue);
      expect(
        host.requests.where(
          (request) => request == 'exec ${moshServerCleanupCommand(session)}',
        ),
        hasLength(2),
      );
      expect(
        host.requests.last,
        'run ${durableShellCommand(_tmuxPath, session, command)} '
        'xterm-256color 100x40',
      );
      await connection.close(UserClosed(UserIntent.fromGesture()));
    });

    test('a failed Mosh bootstrap is cleaned before SSH fallback', () async {
      const session = 'upgrade123';
      const command = 'exec \$SHELL -l';
      final host = FakeHost()
        ..execAnswer = moshHostAnswer
        ..execCodeAnswer = (request) =>
            request.contains('mosh-server') && request.contains(' new ')
            ? 1
            : 0;
      final connection = await openOn(
        moshTunnelTo(host, FakeMoshChannel()),
        command: command,
        tabSession: session,
        persistentSession: session,
      );

      expect(connection, isA<SshShellConnection>());
      expect(
        host.requests.where(
          (request) => request == 'exec ${moshServerCleanupCommand(session)}',
        ),
        hasLength(2),
      );
      expect(
        host.requests.last,
        'run ${durableShellCommand(_tmuxPath, session, command)} '
        'xterm-256color 100x40',
      );
      await connection.close(UserClosed(UserIntent.fromGesture()));
    });

    test('a link that dies under the Mosh bootstrap fails the open and opens '
        'no SSH shell', () async {
      const session = 'upgrade123';
      final host = FakeHost()
        ..execAnswer = (request) {
          if (request.contains('mosh-server') && request.contains(' new ')) {
            throw TimeoutException('link stalled');
          }
          return moshHostAnswer(request);
        };
      final channel = FakeMoshChannel();

      await expectLater(
        openOn(
          moshTunnelTo(host, channel),
          command: 'exec \$SHELL -l',
          tabSession: session,
        ),
        throwsA(anything),
      );
      expect(
        host.requests.where((request) => request.startsWith('run ')),
        isEmpty,
      );
      expect(
        host.requests.where((request) => request.startsWith('shell ')),
        isEmpty,
      );
    });

    test('a Herdr pane uses Mosh without nesting tmux', () async {
      const session = 'upgrade123';
      const command = "env HERDR_SESSION='work' herdr agent attach 'w2a:p3'";
      final host = FakeHost()..execAnswer = moshHostAnswer;
      final channel = FakeMoshChannel();
      final connection = await openOn(
        moshTunnelTo(host, channel),
        command: command,
        tabSession: session,
      );

      expect(connection, isA<MoshShellConnection>());
      expect(
        host.requests,
        isNot(contains('exec ${durableShellProbeCommand(session)}')),
      );
      final launch = host.requests.singleWhere(
        (request) =>
            request.contains('mosh-server') && request.contains(' new '),
      );
      expect(launch, contains(shellQuote(command)));
      expect(
        await connection.terminateRemote(session, durableShell: false),
        isTrue,
      );
      expect(host.requests.last, 'exec ${moshServerCleanupCommand(session)}');
      await connection.close(UserClosed(UserIntent.fromGesture()));
    });
  });

  group('the live session', () {
    test('stdout and stderr arrive merged, in the order they came', () async {
      final host = FakeHost();
      final connection = await openOn(tunnelTo(host));
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

      final seen = <List<int>>[];
      connection.output.listen(seen.add);

      host.pty.out([0x68, 0x69]);
      host.pty.err([0x21]);
      host.pty.out([0x0a]);
      await pumpEventQueue();

      expect(seen, [
        [0x68, 0x69],
        [0x21],
        [0x0a],
      ]);
    });

    test('what the shell printed before anyone listened is not lost', () async {
      final host = FakeHost();
      final connection = await openOn(tunnelTo(host));
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

      host.pty.out([0x24, 0x20]);
      await pumpEventQueue();

      final seen = <List<int>>[];
      connection.output.listen(seen.add);
      await pumpEventQueue();

      expect(seen, [
        [0x24, 0x20],
      ]);
    });

    test('a stream that fails reaches the reader as a reason', () async {
      final host = FakeHost();
      final connection = await openOn(tunnelTo(host));
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

      final errors = <Object>[];
      connection.output.listen((_) {}, onError: errors.add);

      host.pty.fail(SSHStateError('SSH connection closed'));
      await pumpEventQueue();

      expect(errors.single, isA<ShellFailure>());
      expect(
        (errors.single as ShellFailure).kind,
        ShellFailureKind.streamClosed,
      );
    });

    test('typed bytes go to stdin as they were given', () async {
      final host = FakeHost();
      final connection = await openOn(tunnelTo(host));
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

      connection.write(Uint8List.fromList([0x6c, 0x73]));
      connection.write(Uint8List.fromList([0x0d]));

      expect(host.pty.writes, [
        [0x6c, 0x73],
        [0x0d],
      ]);
    });

    test('a resize is one window change with columns then rows', () async {
      final host = FakeHost();
      final connection = await openOn(tunnelTo(host));
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

      connection.resize(120, 45);
      connection.resize(80, 24);

      expect(host.pty.resizes, ['120x45', '80x24']);
    });

    test('the exit code is the one the remote reported', () async {
      final host = FakeHost();
      final connection = await openOn(tunnelTo(host));

      host.pty.exit(130);

      expect(await connection.exitCode, 130);
    });

    test('a channel that closed without a code exits null', () async {
      final host = FakeHost();
      final connection = await openOn(tunnelTo(host));

      host.pty.exit(null);

      expect(await connection.exitCode, isNull);
    });

    test('a link that dies under the pty reaches the reader as a lost stream, '
        'once, before the exit', () async {
      final host = FakeHost();
      final connection = await openOn(tunnelTo(host));
      final seen = <Object>[];
      connection.output.listen((_) {}, onError: seen.add);
      unawaited(connection.exitCode.then((code) => seen.add('exit $code')));

      host.die();
      host.pty.fail(SSHStateError('SSH connection closed'));
      host.pty.lose();
      await pumpEventQueue();

      expect(seen, hasLength(2));
      expect((seen.first as ShellFailure).kind, ShellFailureKind.streamClosed);
      expect(seen.last, 'exit null');
      expect(connection.ended, isNotNull);
    });

    test('a pty that ends on an error keeps it as the detail', () async {
      final host = FakeHost();
      final connection = await openOn(tunnelTo(host));
      final errors = <Object>[];
      connection.output.listen((_) {}, onError: errors.add);

      host.pty.endOn(StateError('channel torn down'));
      await pumpEventQueue();

      expect(
        (errors.single as ShellFailure).detail,
        contains('channel torn down'),
      );
      expect(await connection.exitCode, isNull);
    });

    test('a shell a signal ended is an exit and no failure', () async {
      final host = FakeHost();
      final connection = await openOn(tunnelTo(host));
      final errors = <Object>[];
      connection.output.listen((_) {}, onError: errors.add);

      host.pty.signalled('KILL');
      await pumpEventQueue();

      expect(errors, isEmpty);
      expect(await connection.exitCode, isNull);
      expect(connection.ended, isNotNull);
    });

    test('a code from the remote is an exit and no failure', () async {
      final host = FakeHost();
      final connection = await openOn(tunnelTo(host));
      final errors = <Object>[];
      connection.output.listen((_) {}, onError: errors.add);

      host.pty.exit(0);
      await pumpEventQueue();

      expect(errors, isEmpty);
      expect(await connection.exitCode, 0);
    });

    test('closing the tab is no failure', () async {
      final host = FakeHost();
      final connection = await openOn(tunnelTo(host));
      final errors = <Object>[];
      connection.output.listen((_) {}, onError: errors.add);

      await connection.close(UserClosed(UserIntent.fromGesture()));
      host.pty.lose();
      await pumpEventQueue();

      expect(errors, isEmpty);
    });

    test('closing takes the session and the connection under it', () async {
      final host = FakeHost();
      final connection = await openOn(tunnelTo(host));

      await connection.close(UserClosed(UserIntent.fromGesture()));
      await pumpEventQueue();

      expect(host.pty.closed, isTrue);
      expect(host.closed, isTrue);
      expect(await connection.exitCode, isNull);
    });

    test('ending a durable shell kills only its named tmux session', () async {
      const tmux = '/usr/bin/tmux';
      const session = 'upgrade123';
      final host = FakeHost(execOut: 'UPGRADE_TMUX=$tmux\nUPGRADE_RESUME=1\n');
      final connection = await openOn(
        tunnelTo(host),
        command: 'exec \$SHELL -l',
        persistentSession: session,
      );

      host
        ..execOut = ''
        ..execCode = 0;
      expect(
        await connection.terminateRemote(session, durableShell: true),
        isTrue,
      );

      expect(
        host.requests.last,
        'exec ${durableShellTerminateCommand(tmux, session)}',
      );
      await connection.close(UserClosed(UserIntent.fromGesture()));
    });

    test('a durable shell reports the active pane directory', () async {
      const tmux = '/usr/bin/tmux';
      const session = 'upgrade123';
      final host = FakeHost(execOut: 'UPGRADE_TMUX=$tmux\nUPGRADE_RESUME=1\n');
      final connection = await openOn(
        tunnelTo(host),
        command: 'exec \$SHELL -l',
        persistentSession: session,
      );

      host.execOut = '/srv/upgrade\n';
      expect(await connection.remoteDirectory(session), '/srv/upgrade');
      expect(
        host.requests.last,
        'exec ${durableShellDirectoryCommand(tmux, session)}',
      );
      await connection.close(UserClosed(UserIntent.fromGesture()));
    });
  });

  group('the failure lines', () {
    test('a name that did not resolve', () async {
      final host = FakeHost();
      final tunnel = tunnelTo(
        host,
        dialError: const SocketException('Failed host lookup: nyx'),
      );

      expect(await kindOf(() => openOn(tunnel)), ShellFailureKind.unresolved);
    });

    test('a machine that did not answer', () async {
      final host = FakeHost();

      expect(
        await kindOf(
          () => openOn(
            tunnelTo(
              host,
              dialError: const SocketException('Connection refused'),
            ),
          ),
        ),
        ShellFailureKind.unreachable,
      );
      expect(
        await kindOf(
          () => openOn(tunnelTo(host, dialError: TimeoutException('connect'))),
        ),
        ShellFailureKind.unreachable,
      );
    });

    test('a key the host would not take', () async {
      expect(
        await kindOf(
          () => openOn(
            tunnelTo(FakeHost(authError: SSHAuthFailError('no more methods'))),
          ),
        ),
        ShellFailureKind.keyRejected,
      );
      expect(
        await kindOf(
          () => openOn(
            tunnelTo(FakeHost(authError: SSHKeyDecodeError('not a pem'))),
          ),
        ),
        ShellFailureKind.keyRejected,
      );
    });

    test('a refused host key is a key failure, never a host one', () {
      final refused = SSHHostkeyError('Hostkey verification failed');
      final aborted = SSHAuthAbortError(
        'Connection closed before authentication',
        refused,
      );
      final lost = SSHAuthAbortError(
        'Connection closed before authentication',
        SSHSocketError(const SocketException('Connection reset by peer')),
      );

      expect(isKeyFailure(refused), isTrue);
      expect(isHostFailure(refused), isFalse);
      expect(isKeyFailure(aborted), isTrue);
      expect(isHostFailure(aborted), isFalse);
      expect(isKeyFailure(lost), isFalse);
      expect(isHostFailure(lost), isTrue);
    });

    test('a refused key schedules no reconnect, an unreachable host '
        'does', () async {
      final retries = <Reconnect>[];
      await kindOf(
        () => openOn(
          tunnelTo(FakeHost(authError: SSHAuthFailError('no more methods'))),
          failed: retries.add,
        ),
      );
      await kindOf(
        () => openOn(
          tunnelTo(FakeHost(authError: SSHKeyDecodeError('not a pem'))),
          failed: retries.add,
        ),
      );
      expect(
        await kindOf(
          () => openOn(
            moshTunnelOffering(
              [FakeHost()],
              FakeMoshChannel(),
              ['SHA256:impostor'],
              [],
            ),
            failed: retries.add,
          ),
        ),
        ShellFailureKind.hostKeyChanged,
      );
      expect(retries, isEmpty);

      await kindOf(
        () => openOn(
          tunnelTo(
            FakeHost(),
            dialError: const SocketException('Connection refused'),
          ),
          failed: retries.add,
        ),
      );
      expect(retries, hasLength(1));
    });

    test('a shell the host refused, channel, pty or request', () async {
      expect(
        await kindOf(
          () => openOn(
            tunnelTo(
              FakeHost(
                shellError: SSHChannelOpenError(
                  1,
                  'administratively prohibited',
                ),
              ),
            ),
          ),
        ),
        ShellFailureKind.shellRefused,
      );
      expect(
        await kindOf(
          () => openOn(
            tunnelTo(
              FakeHost(
                shellError: SSHChannelRequestError('Failed to start pty'),
              ),
            ),
          ),
        ),
        ShellFailureKind.shellRefused,
      );
    });

    test('a stream that ended before the login did', () async {
      expect(
        await kindOf(
          () => openOn(
            tunnelTo(
              FakeHost(authError: SSHStateError('SSH connection closed')),
            ),
          ),
        ),
        ShellFailureKind.streamClosed,
      );
      expect(
        await kindOf(
          () => openOn(
            tunnelTo(
              FakeHost(
                authError: SSHAuthAbortError(
                  'Connection closed before authentication',
                ),
              ),
            ),
          ),
        ),
        ShellFailureKind.streamClosed,
      );
    });

    test('auth that broke on the socket reads as the socket', () async {
      expect(
        await kindOf(
          () => openOn(
            tunnelTo(
              FakeHost(
                authError: SSHAuthAbortError(
                  'Connection closed before authentication',
                  SSHSocketError(const SocketException('Connection reset')),
                ),
              ),
            ),
          ),
        ),
        ShellFailureKind.unreachable,
      );
    });

    test('a failure after the connection is up closes it first', () async {
      final host = FakeHost(shellError: SSHChannelRequestError('no pty'));

      await kindOf(() => openOn(tunnelTo(host)));
      await pumpEventQueue();

      expect(host.closed, isTrue);
    });
  });

  test('a dial that fails leaves no unhandled error behind', () async {
    final keys = Ed25519Keys(MemoryPrivateKeyStore());
    await keys.generate(id: 'key-1', name: 'upgrade');
    final privateKey = (await keys.privateKey('key-1'))!;

    final loose = <Object>[];
    final socket = RudeSocket();
    await runZonedGuarded(() async {
      final client = SSHClient(
        socket,
        username: 'luis',
        identities: SSHKeyPair.fromPem(privateKey),
        keepAliveInterval: const Duration(seconds: 15),
      );
      socket.reset();
      await expectLater(client.authenticated, throwsA(anything));
      await closeSettled(client, socket);
    }, (error, _) => loose.add(error));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(loose, isEmpty);
  });

  test('a host that has not authenticated by the deadline is reported as no answer', () async {
    final host = FakeHost()..authGate = Completer<void>();
    const timeout = Duration(milliseconds: 100);
    final tunnel = ShellTunnel(
      timeout: timeout,
      links: linksOver((_) => host, timeout: timeout),
    );

    final kind = await kindOf(() => openOn(tunnel));

    expect(kind, ShellFailureKind.unreachable);
    expect(host.closed, isFalse);
    host.authGate!.complete();
    await pumpEventQueue();
    expect(host.closed, isTrue);
  });

  test(
    'a key sheet held open past the deadline still opens the shell',
    () async {
      final host = FakeHost()..authGate = Completer<void>();
      const timeout = Duration(milliseconds: 100);
      final tunnel = ShellTunnel(
        timeout: timeout,
        links: linksOver((verifier) {
          unawaited(
            verifier
                .verifyFingerprint('ssh-ed25519', 'SHA256:fixture')
                .then((_) => host.authGate!.complete()),
          );
          return host;
        }, timeout: timeout),
      );
      final verifier = HostKeyVerifier(
        prompt: (offer, pinned) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return true;
        },
      );

      await tunnel.open(
        reason: UserAction(UserIntent.fromGesture()),
        address: 'nyx',
        port: 357,
        user: 'luisnquin',
        privateKey: 'pem',
        columns: 100,
        rows: 40,
        verifier: verifier,
      );

      expect(verifier.verified?.fingerprint, 'SHA256:fixture');
      expect(host.closed, isFalse);
    },
  );

  test('closing a host still authenticating waits for it to settle', () async {
    final keys = Ed25519Keys(MemoryPrivateKeyStore());
    await keys.generate(id: 'key-1', name: 'upgrade');
    final privateKey = (await keys.privateKey('key-1'))!;

    final socket = RudeSocket();
    final client = SSHClient(
      socket,
      username: 'luis',
      identities: SSHKeyPair.fromPem(privateKey),
      keepAliveInterval: const Duration(seconds: 15),
    );
    var settled = false;
    final closing = closeSettled(
      client,
      socket,
    ).whenComplete(() => settled = true);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(socket.closed, isFalse);
    expect(settled, isFalse);

    socket.reset();
    await closing.timeout(const Duration(seconds: 1));

    expect(socket.closed, isTrue);
  });

  group('the engine', engineTests);
  group('a plain SSH tab over its link', plainTabTests);
}

class FakeEngineChannel implements EngineChannel {
  final _events = StreamController<EngineEvent>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final _contacts = StreamController<void>.broadcast();

  final sent = <Uint8List>[];
  final sizes = <({int columns, int rows, int widthPx, int heightPx})>[];
  var pokes = 0;
  var rehomes = 0;
  var suspends = 0;
  var closed = false;
  var ended = false;

  @override
  EngineResume? resumable;

  @override
  Stream<EngineEvent> get events => _events.stream;

  @override
  Stream<Object> get errors => _errors.stream;

  @override
  Stream<void> get contacts => _contacts.stream;

  @override
  Future<void> firstContact = Future<void>.value();

  @override
  void send(Uint8List bytes) => sent.add(bytes);

  @override
  void resize(int columns, int rows, {int widthPx = 0, int heightPx = 0}) =>
      sizes.add((
        columns: columns,
        rows: rows,
        widthPx: widthPx,
        heightPx: heightPx,
      ));

  @override
  void poke() => pokes++;

  @override
  Future<void> rehome() async => rehomes++;

  @override
  Future<void> suspend() async => suspends++;

  @override
  Future<void> close({bool end = false}) async {
    ended |= end;
    if (closed) return;
    closed = true;
    await _events.close();
    await _errors.close();
    await _contacts.close();
  }

  void emit(EngineEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void contact() => _contacts.add(null);

  void fallSilent([Duration window = const Duration(milliseconds: 20)]) =>
      firstContact = Future<void>.delayed(
        window,
        () => throw UdpSilent(address: '10.0.0.7', port: 60990, window: window),
      );
}

const _engineKey = 'AAECAwQFBgcICQoLDA0ODw';

String Function(String, String) engineHostAnswer({
  String start =
      '{"ok":true,"result":{"port":60990,"key":"$_engineKey","pid":42}}',
}) => (command, stdin) {
  if (!command.endsWith('upgraded')) return moshHostAnswer(command);
  final request = jsonDecode(stdin) as Map<String, Object?>;
  return switch (request['op']) {
    'start' => start,
    'stop' => '{"ok":true,"result":{"stopped":true}}',
    _ => '',
  };
};

ShellTunnel engineTunnelTo(
  FakeHost host,
  FakeEngineChannel engine,
  FakeMoshChannel mosh, {
  Duration timeout = const Duration(seconds: 10),
  bool emitReady = true,
  List<({String host, int port, String key})>? dialled,
  List<EngineResume?>? resumes,
  UdpVerdicts? verdicts,
  FakeEngineChannel Function()? next,
  FakeHost Function()? nextHost,
  void Function()? onMosh,
}) => ShellTunnel(
  timeout: timeout,
  udpVerdicts: verdicts,
  links: linksOver((_) => nextHost?.call() ?? host, timeout: timeout),
  engineDialer:
      ({
        required String host,
        required int port,
        required String key,
        required int columns,
        required int rows,
        EngineResume? resume,
      }) async {
        dialled?.add((host: host, port: port, key: key));
        resumes?.add(resume);
        final channel = next?.call() ?? engine;
        if (emitReady) {
          Timer.run(() => channel.emit(EnginePty(utf8.encode('\$ '))));
        }
        return channel;
      },
  moshDialer:
      ({
        required MoshServerConfig server,
        required int columns,
        required int rows,
      }) async {
        onMosh?.call();
        Timer.run(() => mosh.emit('\$ '));
        return mosh;
      },
);

List<Map<String, Object?>> engineRequests(FakeHost host) => [
  for (final input in host.inputs)
    if (input.isNotEmpty) jsonDecode(input) as Map<String, Object?>,
];

void engineTests() {
  const session = 'upgrade123';

  test('a failed engine probe never redials the SSH control host', () async {
    final host = FakeHost()..execInputAnswer = engineHostAnswer();
    var sshDials = 0;
    final connection = await openOn(
      engineTunnelTo(
        host,
        FakeEngineChannel(),
        FakeMoshChannel(),
        nextHost: () {
          sshDials++;
          return host;
        },
      ),
      command: 'exec \$SHELL -l',
      tabSession: session,
    );
    addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));
    expect(connection, isA<EngineShellConnection>());
    expect(sshDials, 1);

    host.refuse = StateError('control host failed');
    await expectLater(
      connection.channels.exec('pwd', timeout: remoteCommandDeadline),
      throwsStateError,
    );
    expect(sshDials, 1);
    expect(host.closed, isFalse);
  });

  test('an engine that knows shell/1 carries the tab and Mosh is never '
      'probed', () async {
    final host = FakeHost()..execInputAnswer = engineHostAnswer();
    final engine = FakeEngineChannel();
    final dialled = <({String host, int port, String key})>[];
    final connection = await openOn(
      engineTunnelTo(host, engine, FakeMoshChannel(), dialled: dialled),
      command: 'exec \$SHELL -l',
      tabSession: session,
    );
    addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

    expect(connection, isA<EngineShellConnection>());
    expect(connection.transport, ShellTransport.engine);
    expect(host.requests, ["exec $moshTabVariable='upgrade123' upgraded"]);
    expect(engineRequests(host).single, {
      'service': 'shell/1',
      'op': 'start',
      'owner': 'luisnquin',
      'args': {
        'tab': session,
        'cols': 100,
        'rows': 40,
        'width_px': 0,
        'height_px': 0,
        'term': 'xterm-256color',
        'command': ['sh', '-c', 'exec \$SHELL -l'],
        'resume': true,
      },
    });
    expect(dialled.single, (host: 'nyx', port: 60990, key: _engineKey));

    connection.write(Uint8List.fromList([0x6c, 0x73, 0x0d]));
    connection.resize(91, 37, widthPx: 1820, heightPx: 1554);
    await connection.rehome();
    expect(engine.sent.single, [0x6c, 0x73, 0x0d]);
    expect(engine.sizes.single, (
      columns: 91,
      rows: 37,
      widthPx: 1820,
      heightPx: 1554,
    ));
    expect(engine.rehomes, 1);
  });

  test('a dial back to the same server process carries on where the last '
      'channel left off, and one to another starts over', () async {
    var epoch = 'one';
    String answer(String command, String stdin) => engineHostAnswer(
      start:
          '{"ok":true,"result":{"port":60990,"key":"$_engineKey","pid":42,'
          '"epoch":"$epoch","resumed":true}}',
    )(command, stdin);
    final left = EngineResume(
      keyframe: 7,
      receiver: EngineReceiver(awaitingKeyframe: false),
      outbox: EngineOutbox(),
      emitted: 0,
    );
    final channels = [
      FakeEngineChannel()..resumable = left,
      FakeEngineChannel()..resumable = left,
      FakeEngineChannel(),
    ];
    var dialled = 0;
    final resumes = <EngineResume?>[];
    final tunnel = engineTunnelTo(
      FakeHost()..execInputAnswer = answer,
      channels.first,
      FakeMoshChannel(),
      resumes: resumes,
      next: () => channels[dialled++],
      nextHost: () => FakeHost()..execInputAnswer = answer,
    );
    Future<EngineShellConnection> open() async =>
        await openOn(tunnel, command: 'exec \$SHELL -l', tabSession: session)
            as EngineShellConnection;

    final first = await open();
    expect(first.seamless, isFalse);
    await first.close(UserClosed(UserIntent.fromGesture()));
    final second = await open();
    expect(second.seamless, isTrue);
    await second.close(UserClosed(UserIntent.fromGesture()));
    epoch = 'two';
    final third = await open();
    addTearDown(() => third.close(UserClosed(UserIntent.fromGesture())));
    expect(third.seamless, isFalse);
    expect(resumes, [null, same(left), null]);
  });

  test('a carried channel to an idle shell is ready on first contact, and '
      'one that falls back leaves nothing to carry', () async {
    String answer(String command, String stdin) => engineHostAnswer(
      start:
          '{"ok":true,"result":{"port":60990,"key":"$_engineKey","pid":42,'
          '"epoch":"one","resumed":true}}',
    )(command, stdin);
    final left = EngineResume(
      keyframe: 7,
      receiver: EngineReceiver(awaitingKeyframe: false),
      outbox: EngineOutbox(),
      emitted: 0,
    );
    final talking = FakeEngineChannel()..resumable = left;
    final idle = FakeEngineChannel()..resumable = left;
    final silent = FakeEngineChannel()
      ..resumable = left
      ..fallSilent();
    final last = FakeEngineChannel();
    final channels = [talking, idle, silent, last];
    var dialled = 0;
    final resumes = <EngineResume?>[];
    final tunnel = engineTunnelTo(
      FakeHost()..execInputAnswer = answer,
      talking,
      FakeMoshChannel(),
      emitReady: false,
      timeout: const Duration(seconds: 1),
      verdicts: UdpVerdicts(ttl: Duration.zero),
      resumes: resumes,
      next: () {
        final channel = channels[dialled++];
        Timer.run(
          () => channel == idle
              ? channel.contact()
              : channel.emit(EnginePty(utf8.encode('\$ '))),
        );
        return channel;
      },
      nextHost: () => FakeHost()..execInputAnswer = answer,
    );
    Future<ShellConnection> open() =>
        openOn(tunnel, command: 'exec \$SHELL -l', tabSession: session);

    await (await open()).close(UserClosed(UserIntent.fromGesture()));
    final carried = await open() as EngineShellConnection;
    expect(carried.seamless, isTrue);
    await carried.close(UserClosed(UserIntent.fromGesture()));
    final fallback = await open();
    expect(fallback, isNot(isA<EngineShellConnection>()));
    await fallback.close(UserClosed(UserIntent.fromGesture()));
    final fresh = await open() as EngineShellConnection;
    addTearDown(() => fresh.close(UserClosed(UserIntent.fromGesture())));

    expect(fresh.seamless, isFalse);
    expect(resumes, [null, same(left), same(left), null]);
  });

  test('a durable tab hands its tmux attach to the engine', () async {
    final host = FakeHost()
      ..execAnswer = moshHostAnswer
      ..execInputAnswer = engineHostAnswer();
    final connection = await openOn(
      engineTunnelTo(host, FakeEngineChannel(), FakeMoshChannel()),
      command: 'exec \$SHELL -l',
      tabSession: session,
      persistentSession: session,
    );
    addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

    expect(connection.continuity, ShellContinuity.started);
    final args = engineRequests(host).single['args'] as Map<String, Object?>;
    expect((args['command'] as List<Object?>).last, contains(_tmuxPath));
  });

  for (final (name, start) in [
    ('not installed', ''),
    ('too old to know shell/1', '{"ok":false,"error":{"kind":"unsupported"}}'),
    ('refusing the owner', '{"ok":false,"error":{"kind":"denied"}}'),
    ('answering garbage', 'upgraded: command not found'),
  ]) {
    test('an engine $name falls back to Mosh and stops nothing', () async {
      final host = FakeHost()..execInputAnswer = engineHostAnswer(start: start);
      final engine = FakeEngineChannel();
      final connection = await openOn(
        engineTunnelTo(host, engine, FakeMoshChannel()),
        command: 'exec \$SHELL -l',
        tabSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

      expect(connection, isA<MoshShellConnection>());
      expect(engineRequests(host).map((request) => request['op']), ['start']);
      expect(host.requests, contains('exec ${moshServerProbeCommand()}'));
    });
  }

  test('a link that dies under the engine start fails the open, and neither '
      'Mosh nor SSH is tried', () async {
    final host = FakeHost()
      ..execInputAnswer = (command, stdin) =>
          throw TimeoutException('link stalled');
    await expectLater(
      openOn(
        engineTunnelTo(host, FakeEngineChannel(), FakeMoshChannel()),
        command: 'exec \$SHELL -l',
        tabSession: session,
      ),
      throwsA(anything),
    );
    expect(host.requests, isNot(contains('exec ${moshServerProbeCommand()}')));
    expect(
      host.requests.where(
        (request) => request.startsWith('run ') || request.startsWith('shell '),
      ),
      isEmpty,
    );
  });

  test(
    'a shell that never answers is stopped and Mosh takes the tab',
    () async {
      final host = FakeHost()..execInputAnswer = engineHostAnswer();
      final engine = FakeEngineChannel();
      final connection = await openOn(
        engineTunnelTo(
          host,
          engine,
          FakeMoshChannel(),
          timeout: const Duration(milliseconds: 50),
          emitReady: false,
        ),
        command: 'exec \$SHELL -l',
        tabSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

      expect(connection, isA<MoshShellConnection>());
      expect(engine.closed, isTrue);
      expect(engine.ended, isFalse);
      expect(engineRequests(host).map((request) => request['op']), [
        'start',
        'stop',
      ]);
      expect(engineRequests(host).last['args'], {'tab': session});
    },
  );

  test('a live server for the tab is resumed, and a fallback leaves it running', () async {
    const resumed =
        '{"ok":true,"result":{"port":60991,"key":"$_engineKey","pid":7,"resumed":true}}';
    final host = FakeHost()..execInputAnswer = engineHostAnswer(start: resumed);
    final live = await openOn(
      engineTunnelTo(host, FakeEngineChannel(), FakeMoshChannel()),
      command: 'exec \$SHELL -l',
      tabSession: session,
    );
    addTearDown(() => live.close(UserClosed(UserIntent.fromGesture())));
    expect(live, isA<EngineShellConnection>());
    expect(live.continuity, ShellContinuity.resumed);

    final silent = FakeHost()
      ..execInputAnswer = engineHostAnswer(start: resumed);
    final fallback = await openOn(
      engineTunnelTo(
        silent,
        FakeEngineChannel(),
        FakeMoshChannel(),
        timeout: const Duration(milliseconds: 50),
        emitReady: false,
      ),
      command: 'exec \$SHELL -l',
      tabSession: session,
    );
    addTearDown(() => fallback.close(UserClosed(UserIntent.fromGesture())));
    expect(fallback, isA<MoshShellConnection>());
    expect(engineRequests(silent).map((request) => request['op']), ['start']);
  });

  test('a tab without a session id never asks the engine', () async {
    final host = FakeHost()..execInputAnswer = engineHostAnswer();
    final connection = await openOn(
      engineTunnelTo(host, FakeEngineChannel(), FakeMoshChannel()),
    );
    addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

    expect(connection, isA<SshShellConnection>());
    expect(host.inputs, isEmpty);
  });

  test('snapshots and pty bytes arrive in the order the stream had them, '
      'and an exit ends the shell with its status', () async {
    final host = FakeHost()..execInputAnswer = engineHostAnswer();
    final engine = FakeEngineChannel();
    final connection = await openOn(
      engineTunnelTo(host, engine, FakeMoshChannel()),
      command: 'exec \$SHELL -l',
      tabSession: session,
    );
    addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

    final seen = <String>[];
    connection.snapshots.listen(
      (bytes) => seen.add('snap ${utf8.decode(bytes)}'),
    );
    connection.output.listen((bytes) => seen.add('pty ${utf8.decode(bytes)}'));
    engine
      ..emit(EngineSnapshot(utf8.encode('A')))
      ..emit(EnginePty(utf8.encode('b')))
      ..emit(EngineSnapshot(utf8.encode('C')))
      ..emit(EngineExit(-9));

    expect(await connection.exitCode, -9);
    expect(seen, ['pty \$ ', 'snap A', 'pty b', 'snap C']);
  });

  test('closing the tab stops the shell and sweeps the mark', () async {
    final host = FakeHost()..execInputAnswer = engineHostAnswer();
    final engine = FakeEngineChannel();
    final connection = await openOn(
      engineTunnelTo(host, engine, FakeMoshChannel()),
      command: 'exec \$SHELL -l',
      tabSession: session,
    );

    expect(
      await connection.terminateRemote(session, durableShell: false),
      isTrue,
    );
    expect(engine.ended, isTrue);
    expect(engineRequests(host).last, {
      'service': 'shell/1',
      'op': 'stop',
      'owner': 'luisnquin',
      'args': {'tab': session},
    });
    expect(host.requests.last, 'exec ${moshServerCleanupCommand(session)}');
    await connection.close(UserClosed(UserIntent.fromGesture()));
  });

  test('a retired tab is stopped without touching the live channel', () async {
    final host = FakeHost()..execInputAnswer = engineHostAnswer();
    final engine = FakeEngineChannel();
    final connection = await openOn(
      engineTunnelTo(host, engine, FakeMoshChannel()),
      command: 'exec \$SHELL -l',
      tabSession: session,
    );
    addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

    expect(
      await connection.terminateRemote('upgrade456', durableShell: false),
      isTrue,
    );
    expect(engine.ended, isFalse);
    expect(engineRequests(host).last['args'], {'tab': 'upgrade456'});
  });

  test('a stop the engine refuses falls to the marker sweep', () async {
    final host = FakeHost()..execInputAnswer = engineHostAnswer();
    final connection = await openOn(
      engineTunnelTo(host, FakeEngineChannel(), FakeMoshChannel()),
      command: 'exec \$SHELL -l',
      tabSession: session,
    );
    addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));
    host.execInputAnswer = (command, stdin) => command.endsWith('upgraded')
        ? '{"ok":false,"error":{"kind":"failed","message":"no"}}'
        : '';

    expect(
      await connection.terminateRemote('upgrade456', durableShell: false),
      isTrue,
    );
    expect(
      host.requests.last,
      'exec ${moshServerCleanupCommand('upgrade456')}',
    );

    host.execCodeAnswer = (command) => command.endsWith('upgraded') ? 0 : 1;
    expect(
      await connection.terminateRemote('upgrade456', durableShell: false),
      isFalse,
    );
  });

  test('a silent channel is probed, then reconnecting, then dropped', () async {
    final host = FakeHost()..execInputAnswer = engineHostAnswer();
    final engine = FakeEngineChannel();
    final tunnel = ShellTunnel(
      moshHealthInterval: const Duration(milliseconds: 10),
      moshGiveUp: const Duration(milliseconds: 40),
      links: linksOver((_) => host),
      engineDialer:
          ({
            required String host,
            required int port,
            required String key,
            required int columns,
            required int rows,
            EngineResume? resume,
          }) async {
            Timer.run(() => engine.emit(EnginePty(utf8.encode('\$ '))));
            return engine;
          },
    );
    final connection = await openOn(
      tunnel,
      command: 'exec \$SHELL -l',
      tabSession: session,
    );
    addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));
    final health = <ShellConnectionHealth>[];
    connection.health.listen(health.add);
    final failure = Completer<Object>();
    connection.output.listen((_) {}, onError: failure.complete);

    final error = await failure.future.timeout(const Duration(seconds: 2));
    expect(error, isA<ShellFailure>());
    expect(engine.pokes, greaterThan(1));
    expect(health, contains(ShellConnectionHealth.reconnecting));
    expect(health.last, ShellConnectionHealth.disconnected);
  });

  test('a suspended connection resumes through a rehome', () async {
    final host = FakeHost()..execInputAnswer = engineHostAnswer();
    final engine = FakeEngineChannel();
    final connection = await openOn(
      engineTunnelTo(host, engine, FakeMoshChannel()),
      command: 'exec \$SHELL -l',
      tabSession: session,
    );
    addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

    await connection.suspend(AppSuspended(PlatformSignal.fromPlatform()));
    expect(engine.suspends, 1);
    await pumpEventQueue();
    expect(host.closed, isTrue);
    await connection.resume(AppResumed(PlatformSignal.fromPlatform()));
    expect(engine.rehomes, 1);
  });

  group('a silent UDP path', () {
    var clock = DateTime(2026, 10, 1);
    late UdpVerdicts verdicts;
    setUp(() {
      clock = DateTime(2026, 10, 1);
      verdicts = UdpVerdicts(now: () => clock);
    });

    List<Object?> ops(FakeHost host) => [
      for (final request in engineRequests(host)) request['op'],
    ];

    test('a silent engine skips Mosh and lands on SSH inside the window, '
        'not the dial timeout', () async {
      final host = FakeHost()..execInputAnswer = engineHostAnswer();
      final engine = FakeEngineChannel()..fallSilent();
      var moshed = 0;
      final watch = Stopwatch()..start();
      final connection = await openOn(
        engineTunnelTo(
          host,
          engine,
          FakeMoshChannel(),
          emitReady: false,
          verdicts: verdicts,
          onMosh: () => moshed++,
        ),
        command: 'exec \$SHELL -l',
        tabSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

      expect(connection, isA<SshShellConnection>());
      expect(connection.transport, ShellTransport.ssh);
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(moshed, 0);
      expect(
        host.requests,
        isNot(contains('exec ${moshServerProbeCommand()}')),
      );
      expect(ops(host), ['start', 'stop']);
      expect(engine.closed, isTrue);
      expect(verdicts.silent('nyx'), isTrue);
    });

    test('a refused engine still tries Mosh and leaves no verdict', () async {
      final host = FakeHost()
        ..execInputAnswer = engineHostAnswer(
          start: '{"ok":false,"error":{"kind":"denied"}}',
        );
      final connection = await openOn(
        engineTunnelTo(
          host,
          FakeEngineChannel(),
          FakeMoshChannel(),
          verdicts: verdicts,
        ),
        command: 'exec \$SHELL -l',
        tabSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

      expect(connection, isA<MoshShellConnection>());
      expect(verdicts.silent('nyx'), isFalse);
    });

    test('an engine that answered once and then missed the deadline is not '
        'silent', () async {
      final host = FakeHost()..execInputAnswer = engineHostAnswer();
      final connection = await openOn(
        engineTunnelTo(
          host,
          FakeEngineChannel(),
          FakeMoshChannel(),
          timeout: const Duration(milliseconds: 50),
          emitReady: false,
          verdicts: verdicts,
        ),
        command: 'exec \$SHELL -l',
        tabSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

      expect(connection, isA<MoshShellConnection>());
      expect(verdicts.silent('nyx'), isFalse);
    });

    test(
      'the verdict keeps both UDP transports away until it lapses',
      () async {
        final host = FakeHost()..execInputAnswer = engineHostAnswer();
        final engines = [
          FakeEngineChannel()..fallSilent(),
          FakeEngineChannel(),
        ];
        var dialled = 0;
        var moshed = 0;
        final tunnel = engineTunnelTo(
          host,
          engines.first,
          FakeMoshChannel(),
          verdicts: verdicts,
          next: () => engines[dialled++],
          onMosh: () => moshed++,
        );
        final marks = <(int, int)>[];
        Future<ShellConnection> open() async {
          marks.add((ops(host).length, host.requests.length));
          final connection = await openOn(
            tunnel,
            command: 'exec \$SHELL -l',
            tabSession: session,
          );
          addTearDown(
            () => connection.close(UserClosed(UserIntent.fromGesture())),
          );
          return connection;
        }

        List<Object?> opsOf(int open) => ops(host).sublist(
          marks[open].$1,
          open + 1 < marks.length ? marks[open + 1].$1 : null,
        );

        expect(await open(), isA<SshShellConnection>());
        clock = clock.add(const Duration(minutes: 4, seconds: 59));
        expect(await open(), isA<SshShellConnection>());
        expect(opsOf(0), ['start', 'stop']);
        expect(opsOf(1), isEmpty);
        expect(
          host.requests.sublist(marks[1].$2),
          isNot(contains('exec ${moshServerProbeCommand()}')),
        );
        expect(moshed, 0);

        clock = clock.add(const Duration(seconds: 1));
        expect(await open(), isA<EngineShellConnection>());
        expect(opsOf(2), ['start']);
        expect(dialled, 2);
      },
    );

    test('a UDP transport that comes up clears the verdict', () async {
      final host = FakeHost()..execInputAnswer = engineHostAnswer();
      final engine = FakeEngineChannel();
      final connection = await openOn(
        engineTunnelTo(
          host,
          engine,
          FakeMoshChannel(),
          verdicts: verdicts,
          next: () {
            verdicts.record('nyx');
            return engine;
          },
        ),
        command: 'exec \$SHELL -l',
        tabSession: session,
      );
      addTearDown(() => connection.close(UserClosed(UserIntent.fromGesture())));

      expect(connection, isA<EngineShellConnection>());
      expect(verdicts.silent('nyx'), isFalse);
    });

    test(
      'a silent Mosh after an engine that refused records the verdict',
      () async {
        final host = FakeHost()
          ..execInputAnswer = engineHostAnswer(
            start: '{"ok":false,"error":{"kind":"unsupported"}}',
          );
        final mosh = FakeMoshChannel()..fallSilent();
        final connection = await openOn(
          engineTunnelTo(host, FakeEngineChannel(), mosh, verdicts: verdicts),
          command: 'exec \$SHELL -l',
          tabSession: session,
        );
        addTearDown(
          () => connection.close(UserClosed(UserIntent.fromGesture())),
        );

        expect(connection, isA<SshShellConnection>());
        expect(mosh.closed, isTrue);
        expect(verdicts.silent('nyx'), isTrue);
      },
    );

    test('the verdict is spelled once, with the path and the lease', () {
      expect(
        '${const UdpSilent(address: '10.0.0.7', port: 60990, window: Duration(seconds: 4))}'
            '; ssh for ${UdpSilent.spell(const Duration(minutes: 5))}',
        'udp silent to 10.0.0.7:60990 after 4s; ssh for 5m',
      );
    });
  });
}

final _vm = Host(
  id: 'h1',
  name: 'vm',
  address: '10.0.0.2',
  port: 22,
  user: 'dev',
  keyId: 'key-1',
  hostKey: pinnedKey,
);

({ShellSessions sessions, List<FakeHost> hosts, HostLinks links}) plainTabs() {
  final hosts = <FakeHost>[];
  final links = linksOver((_) {
    final host = FakeHost();
    hosts.add(host);
    return host;
  });
  final tunnel = ShellTunnel(links: links);
  return (
    sessions: ShellSessions(
      readPrivateKey: (_) async => 'PEM',
      pinHostKey: (_, _) async {},
      open: tunnel.open,
    ),
    hosts: hosts,
    links: links,
  );
}

Future<void> _settleTab(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump();
  }
}

Uint8List _keys(String typed) => Uint8List.fromList(utf8.encode(typed));

void plainTabTests() {
  HostLinks? pool;

  Future<({ShellSessions sessions, List<FakeHost> hosts, ShellSession tab})>
  live(WidgetTester tester) async {
    final (:sessions, :hosts, :links) = plainTabs();
    pool = links;
    final tab = sessions.open(intent: UserIntent.fromGesture(), _vm)!;
    await _settleTab(tester);
    expect(tab.state, isA<ShellLive>());
    expect(hosts, hasLength(1));
    return (sessions: sessions, hosts: hosts, tab: tab);
  }

  Future<void> closeTab(ShellSessions sessions, ShellSession tab) async {
    await sessions.close(intent: UserIntent.fromGesture(), _vm.id, tab);
    pool?.close();
  }

  testWidgets('a shell a signal ended exits and is not dialled again', (
    tester,
  ) async {
    final (:sessions, :hosts, :tab) = await live(tester);

    hosts.single.pty.signalled('KILL');
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));

    expect(tab.state, isA<ShellExited>());
    expect((tab.state as ShellExited).code, isNull);
    expect(hosts, hasLength(1));

    await closeTab(sessions, tab);
  });

  testWidgets('a pty that ends with neither code nor signal is a lost link '
      'and dialled again', (tester) async {
    final (:sessions, :hosts, :tab) = await live(tester);

    hosts.single
      ..die()
      ..pty.lose();
    await tester.pump();

    expect(tab.state, isA<ShellDropped>());
    await tester.pump(shellReconnectDelays.first);
    await _settleTab(tester);
    expect(tab.state, isA<ShellLive>());
    expect(hosts, hasLength(2));

    await closeTab(sessions, tab);
  });

  testWidgets('a write into a silent link ends it within the stall window and '
      'its answer, and the tab dials again', (tester) async {
    final (:sessions, :hosts, :tab) = await live(tester);
    final silent = hosts.single..answers = false;

    sessions.send(tab, _keys('ls\r'));
    await tester.pump(SshShellConnection.stallWindow);
    expect(silent.checks, 1);
    expect(tab.state, isA<ShellLive>());

    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(tab.state, isA<ShellDropped>());

    await tester.pump(shellReconnectDelays.first);
    await _settleTab(tester);
    expect(tab.state, isA<ShellLive>());
    expect(hosts, hasLength(2));

    await closeTab(sessions, tab);
  });

  testWidgets('a live link survives writes nothing echoes, with one check '
      'for the lot', (tester) async {
    final (:sessions, :hosts, :tab) = await live(tester);

    for (final key in 'hunter2'.split('')) {
      sessions.send(tab, _keys(key));
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pump(SshShellConnection.stallWindow);

    expect(hosts.single.checks, 1);
    expect(tab.state, isA<ShellLive>());
    expect(hosts, hasLength(1));

    await closeTab(sessions, tab);
  });

  testWidgets('an echo stands the watchdog down', (tester) async {
    final (:sessions, :hosts, :tab) = await live(tester);

    sessions.send(tab, _keys('l'));
    await tester.pump(const Duration(seconds: 1));
    hosts.single.pty.out(utf8.encode('l'));
    await tester.pump(const Duration(seconds: 10));

    expect(hosts.single.checks, 0);

    await closeTab(sessions, tab);
  });

  testWidgets('a network change ends a dead link and the tab dials again', (
    tester,
  ) async {
    final (:sessions, :hosts, :tab) = await live(tester);
    hosts.single.answers = false;

    sessions.wakeAll(PlatformSignal.fromPlatform(), network: true);
    await tester.pump();
    expect(hosts.single.checks, 1);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(tab.state, isA<ShellDropped>());

    await tester.pump(shellReconnectDelays.first);
    await _settleTab(tester);
    expect(tab.state, isA<ShellLive>());
    expect(hosts, hasLength(2));

    await closeTab(sessions, tab);
  });

  testWidgets('a network change leaves a live link as it was', (tester) async {
    final (:sessions, :hosts, :tab) = await live(tester);

    sessions.wakeAll(PlatformSignal.fromPlatform(), network: true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));

    expect(hosts.single.checks, 1);
    expect(hosts.single.closed, isFalse);
    expect(tab.state, isA<ShellLive>());
    expect(hosts, hasLength(1));

    await closeTab(sessions, tab);
  });

  testWidgets('closing the tab takes its watchdog with it', (tester) async {
    final (:sessions, :hosts, :tab) = await live(tester);

    sessions.send(tab, _keys('exit'));
    await closeTab(sessions, tab);
    await tester.pump(const Duration(seconds: 10));

    expect(hosts.single.checks, 0);
  });
}
