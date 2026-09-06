/// The shell transport: what it asks the host for, what it carries once the
/// shell is up, and which line every failure turns into.
///
/// The socket is the one part a test cannot have, so the dialer is the seam:
/// everything below it is a fake, everything above it is the real code.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/platform/shell/shell_connection.dart';
import 'package:spectacle/platform/shell/shell_tunnel.dart';
import 'package:spectacle/platform/host_keys.dart';
import 'package:spectacle/platform/keys.dart';

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
  final _done = Completer<void>();

  @override
  Stream<Uint8List> get stdout => const Stream.empty();

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  Future<void> get done => _done.future;

  @override
  int? get exitCode => 0;

  @override
  void write(Uint8List bytes) {}

  @override
  Future<void> closeStdin() async {
    if (!_done.isCompleted) _done.complete();
  }
}

class FakeHost implements ShellHost {
  FakeHost({this.authError, this.shellError});

  final Object? authError;
  final Object? shellError;

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
    return FakeExec();
  }

  @override
  Future<ShellPty> shell(SSHPtyConfig config) async {
    requests.add('shell ${config.type} ${config.width}x${config.height}');
    final error = shellError;
    if (error != null) throw error;
    return pty;
  }

  @override
  Future<void> close() async => closed = true;
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

Future<ShellConnection> openOn(ShellTunnel tunnel) => tunnel.open(
  address: 'nyx',
  port: 357,
  user: 'luisnquin',
  privateKey: 'pem',
  columns: 100,
  rows: 40,
);

Future<ShellFailureKind> kindOf(Future<void> Function() body) async {
  try {
    await body();
  } on ShellFailure catch (failure) {
    return failure.kind;
  }
  fail('the open was expected to fail');
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
    await keys.generate(id: 'key-1', name: 'spectacle');
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
