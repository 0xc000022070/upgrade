import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_mosh/dart_mosh.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/platform/shell/engine_channel.dart';
import 'package:upgrade/platform/shell/mosh_channel.dart';
import 'package:upgrade/platform/shell/shell_connection.dart';
import 'package:upgrade/platform/shell/remote_shell.dart';
import 'package:upgrade/platform/shell/shell_tunnel.dart';
import 'package:upgrade/platform/shell/udp_path.dart';
import 'package:upgrade/platform/host_keys.dart';
import 'package:upgrade/platform/keys.dart';

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

class FakePty implements ShellPty {
  final _stdout = StreamController<Uint8List>();
  final _stderr = StreamController<Uint8List>();
  final _done = Completer<void>();

  final writes = <Uint8List>[];
  final resizes = <String>[];
  bool closed = false;
  int? reported;

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  @override
  Future<void> get done => _done.future;

  @override
  int? get exitCode => reported;

  @override
  void write(Uint8List bytes) => writes.add(bytes);

  @override
  void resizeTerminal(int columns, int rows) => resizes.add('${columns}x$rows');

  @override
  void close() => closed = true;

  void out(List<int> bytes) => _stdout.add(Uint8List.fromList(bytes));

  void err(List<int> bytes) => _stderr.add(Uint8List.fromList(bytes));

  void fail(Object error) => _stdout.addError(error);

  void exit(int? code) {
    reported = code;
    _done.complete();
  }
}

class FakeExec implements ShellExec {
  FakeExec({this.out = '', this.err = '', this.reported = 0, this.answerInput});

  final String Function(String stdin)? answerInput;
  final _input = BytesBuilder();
  final _answer = StreamController<Uint8List>();

  final _done = Completer<void>();
  final String out;
  final String err;
  final int? reported;

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
  void write(Uint8List bytes) => _input.add(bytes);

  @override
  Future<void> closeStdin() async {
    final answer = answerInput;
    if (answer != null && !_answer.isClosed) {
      final said = answer(utf8.decode(_input.takeBytes()));
      if (said.isNotEmpty) _answer.add(Uint8List.fromList(utf8.encode(said)));
      unawaited(_answer.close());
    }
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void close() {
    if (!_done.isCompleted) _done.complete();
  }
}

class FakeHost implements ShellHost {
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
  String execOut;
  String execError;
  int? execCode;
  String Function(String command)? execAnswer;
  int? Function(String command)? execCodeAnswer;

  String Function(String command, String stdin)? execInputAnswer;
  final inputs = <String>[];

  final requests = <String>[];
  final pty = FakePty();
  bool closed = false;

  @override
  Future<void> get authenticated async {
    await authGate?.future;
    final error = authError;
    if (error != null) throw error;
  }

  @override
  Future<ShellExec> execute(String command) async {
    requests.add('exec $command');
    final error = refuse;
    if (error != null) throw error;
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
  Future<ShellPty> shell(SSHPtyConfig config) async {
    requests.add('shell ${config.type} ${config.width}x${config.height}');
    final error = shellError;
    if (error != null) throw error;
    return pty;
  }

  @override
  Future<ShellPty> run(String command, SSHPtyConfig config) async {
    requests.add(
      'run $command ${config.type} ${config.width}x${config.height}',
    );
    final error = shellError;
    if (error != null) throw error;
    return pty;
  }

  @override
  Future<void> close() async => closed = true;
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

ShellTunnel tunnelTo(FakeHost host, {Object? dialError}) => ShellTunnel(
  dial:
      ({
        required String address,
        required int port,
        required String user,
        required String privateKey,
        HostKeyVerifier? verifier,
        required Duration timeout,
        required Duration keepAlive,
      }) async {
        final error = dialError;
        if (error != null) throw error;
        return host;
      },
);

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
  dial: ({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    HostKeyVerifier? verifier,
    required Duration timeout,
    required Duration keepAlive,
  }) async => host,
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
  dial: ({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    HostKeyVerifier? verifier,
    required Duration timeout,
    required Duration keepAlive,
  }) async => hosts[dialled()],
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
}) => tunnel.open(
  address: 'nyx',
  port: 357,
  user: 'luisnquin',
  privateKey: 'pem',
  columns: 100,
  rows: 40,
  command: command,
  tabSession: tabSession,
  persistentSession: persistentSession,
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
        addTearDown(connection.close);

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
        addTearDown(connection.close);

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
      addTearDown(connection.close);

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
      addTearDown(connection.close);

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
      addTearDown(connection.close);

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
      await connection.close();
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
      addTearDown(connection.close);

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
        addTearDown(connection.close);
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
        addTearDown(connection.close);
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
        addTearDown(connection.close);
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
      addTearDown(connection.close);
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
      addTearDown(connection.close);

      await connection.suspend();
      final probes = channel.sizes.length;
      await connection.rehome();

      expect(channel.suspends, 1);
      expect(channel.rehomes, 0);
      expect(channel.sizes.length, probes);
      expect(hosts.first.closed, isTrue);

      await connection.resume();
      final result = await connection.exec('pwd');

      expect(channel.rehomes, 1);
      expect(channel.sizes.length, probes + 1);
      expect(result.ok, isTrue);
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
      addTearDown(connection.close);

      await connection.rehome(network: true);
      final landing = connection.exec('pwd');
      await connection.suspend();

      await expectLater(landing, throwsStateError);
      expect(hosts[1].closed, isTrue);
      await expectLater(connection.exec('pwd'), throwsStateError);
      expect(dials, 2);
    });

    test('Mosh redials its SSH control path after a network change', () async {
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

      await connection.rehome(network: true);
      final result = await connection.exec('pwd');

      expect(result.ok, isTrue);
      expect(dials, 2);
      expect(hosts.first.closed, isTrue);
      expect(hosts.last.requests.last, 'exec pwd');
      await connection.close();
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
      final result = await connection.exec('pwd');

      expect(result.ok, isTrue);
      expect(channel.rehomes, 1);
      expect(dials, 1);
      expect(hosts.first.closed, isFalse);
      expect(hosts.first.requests.last, 'exec pwd');

      hosts.first.refuse = const SocketException('Connection reset by peer');
      final again = await connection.exec('pwd');

      expect(again.ok, isTrue);
      expect(dials, 2);
      expect(hosts.first.closed, isTrue);
      expect(hosts.last.requests.last, 'exec pwd');
      await connection.close();
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
      await connection.close();
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
      await connection.close();
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
      await connection.close();
    });
  });

  group('the live session', () {
    test('stdout and stderr arrive merged, in the order they came', () async {
      final host = FakeHost();
      final connection = await openOn(tunnelTo(host));
      addTearDown(connection.close);

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
      addTearDown(connection.close);

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
      addTearDown(connection.close);

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
      addTearDown(connection.close);

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
      addTearDown(connection.close);

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

    test('closing takes the session and the connection under it', () async {
      final host = FakeHost();
      final connection = await openOn(tunnelTo(host));

      await connection.close();

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
      await connection.close();
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
      await connection.close();
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
      final host = sshHostOver(
        socket,
        SSHClient(
          socket,
          username: 'luis',
          identities: SSHKeyPair.fromPem(privateKey),
          keepAliveInterval: const Duration(seconds: 15),
        ),
      );
      socket.reset();
      await expectLater(host.authenticated, throwsA(anything));
      await host.close();
    }, (error, _) => loose.add(error));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(loose, isEmpty);
  });

  test('a host that has not authenticated by the deadline is reported as no answer', () async {
    final host = FakeHost()..authGate = Completer<void>();
    final tunnel = ShellTunnel(
      timeout: const Duration(milliseconds: 100),
      dial: ({
        required String address,
        required int port,
        required String user,
        required String privateKey,
        HostKeyVerifier? verifier,
        required Duration timeout,
        required Duration keepAlive,
      }) async => host,
    );

    final kind = await kindOf(() => openOn(tunnel));

    expect(kind, ShellFailureKind.unreachable);
    expect(host.closed, isTrue);
  });

  test(
    'a key sheet held open past the deadline still opens the shell',
    () async {
      final host = FakeHost()..authGate = Completer<void>();
      final tunnel = ShellTunnel(
        timeout: const Duration(milliseconds: 100),
        dial:
            ({
              required String address,
              required int port,
              required String user,
              required String privateKey,
              HostKeyVerifier? verifier,
              required Duration timeout,
              required Duration keepAlive,
            }) async {
              unawaited(
                verifier!
                    .verifyFingerprint('ssh-ed25519', 'SHA256:fixture')
                    .then((_) => host.authGate!.complete()),
              );
              return host;
            },
      );
      final verifier = HostKeyVerifier(
        prompt: (offer, pinned) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return true;
        },
      );

      await tunnel.open(
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
    final host = sshHostOver(
      socket,
      SSHClient(
        socket,
        username: 'luis',
        identities: SSHKeyPair.fromPem(privateKey),
        keepAliveInterval: const Duration(seconds: 15),
      ),
    );
    var settled = false;
    final closing = host.close().whenComplete(() => settled = true);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(socket.closed, isFalse);
    expect(settled, isFalse);

    socket.reset();
    await closing.timeout(const Duration(seconds: 1));

    expect(socket.closed, isTrue);
  });

  group('the engine', engineTests);
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

  void emit(EngineEvent event) => _events.add(event);

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
  UdpVerdicts? verdicts,
  FakeEngineChannel Function()? next,
  FakeHost Function()? nextHost,
  void Function()? onMosh,
}) => ShellTunnel(
  timeout: timeout,
  udpVerdicts: verdicts,
  dial: ({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    HostKeyVerifier? verifier,
    required Duration timeout,
    required Duration keepAlive,
  }) async => nextHost?.call() ?? host,
  engineDialer:
      ({
        required String host,
        required int port,
        required String key,
        required int columns,
        required int rows,
      }) async {
        dialled?.add((host: host, port: port, key: key));
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
    addTearDown(connection.close);

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
    addTearDown(connection.close);

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
      addTearDown(connection.close);

      expect(connection, isA<MoshShellConnection>());
      expect(engineRequests(host).map((request) => request['op']), ['start']);
      expect(host.requests, contains('exec ${moshServerProbeCommand()}'));
    });
  }

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
      addTearDown(connection.close);

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
    addTearDown(live.close);
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
    addTearDown(fallback.close);
    expect(fallback, isA<MoshShellConnection>());
    expect(engineRequests(silent).map((request) => request['op']), ['start']);
  });

  test('a tab without a session id never asks the engine', () async {
    final host = FakeHost()..execInputAnswer = engineHostAnswer();
    final connection = await openOn(
      engineTunnelTo(host, FakeEngineChannel(), FakeMoshChannel()),
    );
    addTearDown(connection.close);

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
    addTearDown(connection.close);

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
    await connection.close();
  });

  test('a retired tab is stopped without touching the live channel', () async {
    final host = FakeHost()..execInputAnswer = engineHostAnswer();
    final engine = FakeEngineChannel();
    final connection = await openOn(
      engineTunnelTo(host, engine, FakeMoshChannel()),
      command: 'exec \$SHELL -l',
      tabSession: session,
    );
    addTearDown(connection.close);

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
    addTearDown(connection.close);
    host.execInputAnswer = (command, stdin) => command.endsWith('upgraded')
        ? '{"ok":false,"error":{"kind":"failed","message":"no"}}'
        : '';

    expect(
      await connection.terminateRemote('upgrade456', durableShell: false),
      isTrue,
    );
    expect(host.requests.last, 'exec ${moshServerCleanupCommand('upgrade456')}');

    host.execCodeAnswer = (command) =>
        command.endsWith('upgraded') ? 0 : 1;
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
      dial: ({
        required String address,
        required int port,
        required String user,
        required String privateKey,
        HostKeyVerifier? verifier,
        required Duration timeout,
        required Duration keepAlive,
      }) async => host,
      engineDialer:
          ({
            required String host,
            required int port,
            required String key,
            required int columns,
            required int rows,
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
    addTearDown(connection.close);
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
    addTearDown(connection.close);

    await connection.suspend();
    expect(engine.suspends, 1);
    expect(host.closed, isTrue);
    await connection.resume();
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
      addTearDown(connection.close);

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
      addTearDown(connection.close);

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
      addTearDown(connection.close);

      expect(connection, isA<MoshShellConnection>());
      expect(verdicts.silent('nyx'), isFalse);
    });

    test(
      'the verdict keeps both UDP transports away until it lapses',
      () async {
        final hosts = [
          for (var i = 0; i < 3; i++)
            FakeHost()..execInputAnswer = engineHostAnswer(),
        ];
        var hosted = 0;
        final engines = [
          FakeEngineChannel()..fallSilent(),
          FakeEngineChannel(),
        ];
        var dialled = 0;
        var moshed = 0;
        final tunnel = engineTunnelTo(
          hosts.first,
          engines.first,
          FakeMoshChannel(),
          verdicts: verdicts,
          next: () => engines[dialled++],
          nextHost: () => hosts[hosted++],
          onMosh: () => moshed++,
        );
        Future<ShellConnection> open() async {
          final connection = await openOn(
            tunnel,
            command: 'exec \$SHELL -l',
            tabSession: session,
          );
          addTearDown(connection.close);
          return connection;
        }

        expect(await open(), isA<SshShellConnection>());
        clock = clock.add(const Duration(minutes: 4, seconds: 59));
        expect(await open(), isA<SshShellConnection>());
        expect(ops(hosts[0]), ['start', 'stop']);
        expect(ops(hosts[1]), isEmpty);
        expect(
          hosts[1].requests,
          isNot(contains('exec ${moshServerProbeCommand()}')),
        );
        expect(moshed, 0);

        clock = clock.add(const Duration(seconds: 1));
        expect(await open(), isA<EngineShellConnection>());
        expect(ops(hosts[2]), ['start']);
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
      addTearDown(connection.close);

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
        addTearDown(connection.close);

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
