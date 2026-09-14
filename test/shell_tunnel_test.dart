/// The shell transport: what it asks the host for, what it carries once the
/// shell is up, and which line every failure turns into.
///
/// The socket is the one part a test cannot have, so the dialer is the seam:
/// everything below it is a fake, everything above it is the real code.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_mosh/dart_mosh.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/platform/shell/mosh_channel.dart';
import 'package:dazzle/platform/shell/shell_connection.dart';
import 'package:dazzle/platform/shell/remote_shell.dart';
import 'package:dazzle/platform/shell/shell_tunnel.dart';
import 'package:dazzle/platform/host_keys.dart';
import 'package:dazzle/platform/keys.dart';

/// A socket that answers a dial and then goes away mid-handshake, which is
/// what a host that resets the connection looks like from here. `dart:io`
/// reports a reset on both ends of the socket: the stream the transport reads
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

  /// The host going away under the handshake: the stream the transport reads
  /// errors, and the close that follows fails the way `dart:io` fails the
  /// close of a socket that was reset under it.
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
  FakeExec({this.out = '', this.err = '', this.reported = 0});

  final _done = Completer<void>();
  final String out;
  final String err;
  final int? reported;

  @override
  Stream<Uint8List> get stdout => out.isEmpty
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
  void write(Uint8List bytes) {}

  @override
  Future<void> closeStdin() async {
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
  String execOut;
  String execError;
  int? execCode;
  String Function(String command)? execAnswer;
  int? Function(String command)? execCodeAnswer;

  final requests = <String>[];
  final pty = FakePty();
  bool closed = false;

  @override
  Future<void> get authenticated async {
    final error = authError;
    if (error != null) throw error;
  }

  @override
  Future<ShellExec> execute(String command) async {
    requests.add('exec $command');
    return FakeExec(
      out: execAnswer?.call(command) ?? execOut,
      err: execError,
      reported: execCodeAnswer?.call(command) ?? execCode,
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
  final _done = Completer<void>();

  final sent = <Uint8List>[];
  final sizes = <({int columns, int rows})>[];
  var rehomes = 0;
  var closed = false;

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Stream<Object> get errors => _errors.stream;

  @override
  Stream<int> get echoAcks => _echoAcks.stream;

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
  Future<void> close() async {
    if (closed) return;
    closed = true;
    if (!_done.isCompleted) _done.complete();
    await _output.close();
    await _errors.close();
    await _echoAcks.close();
  }

  void emit(String value) => _output.add(Uint8List.fromList(value.codeUnits));

  void acknowledge(int state) => _echoAcks.add(state);
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
}) => ShellTunnel(
  timeout: timeout,
  moshHealthInterval: healthInterval,
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
  if (command == durableShellProbeCommand('dazzle123')) {
    return tmux ? 'DAZZLE_TMUX=$_tmuxPath\nDAZZLE_RESUME=0\n' : '';
  }
  if (command == moshServerProbeCommand()) {
    return 'profile noise\nDAZZLE_MOSH=$_moshPath\n';
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

        // The same pty on the same kind of channel, under an exec request
        // instead of a shell request — `ssh -t`. Nothing is written at a
        // prompt, because there is no shell in front of the command to have
        // one.
        expect(host.requests, [
          "run herdr agent attach 'w22:p1' xterm-256color 100x40",
        ]);
      },
    );

    test('a durable tab starts inside its own tmux server', () async {
      const tmux = '/nix/store/tmux/bin/tmux';
      const session = 'dazzle123';
      const command = 'export DAZZLE_TAB=dazzle123; exec \$SHELL -l';
      final host = FakeHost(
        execOut: 'noise\nDAZZLE_TMUX=$tmux\nDAZZLE_RESUME=0\n',
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
      const session = 'dazzle123';
      final host = FakeHost(execOut: 'DAZZLE_TMUX=$tmux\nDAZZLE_RESUME=1\n');

      final connection = await openOn(
        tunnelTo(host),
        command: 'exec \$SHELL -l',
        persistentSession: session,
      );
      addTearDown(connection.close);

      expect(connection.continuity, ShellContinuity.resumed);
    });

    test('a host without tmux keeps the plain SSH command', () async {
      const session = 'dazzle123';
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
      const session = 'dazzle123';
      const command = 'export DAZZLE_TAB=dazzle123; exec \$SHELL -l';
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
      expect(launch, contains("$moshTabVariable='dazzle123'"));
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
      const session = 'dazzle123';
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
        const session = 'dazzle123';
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

    test('Mosh redials its SSH control path after a rehome', () async {
      const session = 'dazzle123';
      final hosts = [
        FakeHost()..execAnswer = moshHostAnswer,
        FakeHost()..execAnswer = moshHostAnswer,
      ];
      var dials = 0;
      final channel = FakeMoshChannel();
      final tunnel = ShellTunnel(
        dial: ({
          required String address,
          required int port,
          required String user,
          required String privateKey,
          HostKeyVerifier? verifier,
          required Duration timeout,
          required Duration keepAlive,
        }) async => hosts[dials++],
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
      final connection = await openOn(
        tunnel,
        command: 'exec \$SHELL -l',
        tabSession: session,
        persistentSession: session,
      );

      await connection.rehome();
      final result = await connection.exec('pwd');

      expect(result.ok, isTrue);
      expect(dials, 2);
      expect(hosts.first.closed, isTrue);
      expect(hosts.last.requests.last, 'exec pwd');
      await connection.close();
    });

    test('an unreachable Mosh UDP port falls back to SSH', () async {
      const session = 'dazzle123';
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
      const session = 'dazzle123';
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
      const session = 'dazzle123';
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
      const session = 'dazzle123';
      final host = FakeHost(execOut: 'DAZZLE_TMUX=$tmux\nDAZZLE_RESUME=1\n');
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
      const session = 'dazzle123';
      final host = FakeHost(execOut: 'DAZZLE_TMUX=$tmux\nDAZZLE_RESUME=1\n');
      final connection = await openOn(
        tunnelTo(host),
        command: 'exec \$SHELL -l',
        persistentSession: session,
      );

      host.execOut = '/srv/dazzle\n';
      expect(await connection.remoteDirectory(session), '/srv/dazzle');
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
    await keys.generate(id: 'key-1', name: 'dazzle');
    final privateKey = (await keys.privateKey('key-1'))!;

    final loose = <Object>[];
    final socket = RudeSocket();
    await runZonedGuarded(() async {
      final host = sshHostOver(
        socket,
        user: 'luis',
        privateKey: privateKey,
        timeout: const Duration(seconds: 1),
        keepAlive: const Duration(seconds: 15),
      );
      socket.reset();
      await expectLater(host.authenticated, throwsA(anything));
      // What the tunnel does with a dial that failed: half-open is worse
      // than none.
      await host.close();
    }, (error, _) => loose.add(error));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // The dial threw and the caller worded it. The client finishing its own
    // end with the same error is not a second failure to report.
    expect(loose, isEmpty);
  });
}
