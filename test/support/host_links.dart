import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:upgrade/platform/herdr_client.dart';
import 'package:upgrade/platform/host_keys.dart';
import 'package:upgrade/platform/host_links.dart';
import 'package:upgrade/platform/ssh_settle.dart';

import 'ssh_exec.dart';
import 'vnc_channel.dart';

final class FakeLinkClient implements SSHClient {
  final gone = Completer<void>();
  var closes = 0;
  var pings = 0;
  Completer<void>? pong;
  Object? pingError;
  var received = 0;
  final sessions = <FakeExecSession>[];
  final commands = <String>[];
  FakeRunReply? Function(String command)? reply;
  Object? execError;
  Completer<void>? execGate;
  final forwards = <FakeForwardChannel>[];
  Object? forwardError;
  Completer<void>? forwardGate;

  @override
  Future<void> get authenticated => Future.value();

  @override
  bool get isClosed => gone.isCompleted;

  @override
  Future<void> get done => gone.future;

  @override
  Future<void> close() async {
    closes++;
    if (!gone.isCompleted) gone.complete();
  }

  @override
  Future<void> ping() async {
    pings++;
    final error = pingError;
    if (error != null) throw error;
    await pong?.future;
  }

  @override
  Future<SSHSession> execute(
    String command, {
    SSHPtyConfig? pty,
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async {
    commands.add(command);
    await execGate?.future;
    final error = execError;
    if (error != null) throw error;
    final session = FakeExecSession()..input.stream.listen(null);
    sessions.add(session);
    final answer = reply?.call(command);
    if (answer != null) {
      session.out.add(Uint8List.fromList(utf8.encode(answer.stdout)));
      session.err.add(Uint8List.fromList(utf8.encode(answer.stderr)));
      session.code = answer.exitCode;
      unawaited(session.out.close());
      unawaited(session.err.close());
      session.exited.complete();
    }
    return session;
  }

  @override
  Future<SSHForwardChannel> forwardLocal(
    String remoteHost,
    int remotePort, {
    String localHost = 'localhost',
    int localPort = 0,
  }) async {
    await forwardGate?.future;
    final error = forwardError;
    if (error != null) throw error;
    final channel = FakeForwardChannel();
    forwards.add(channel);
    return channel;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<HostLease> leaseOver(SSHClient client) =>
    HostLinks(
      dial: ({
        required address,
        required port,
        required user,
        required privateKey,
        required verifier,
        onSettling,
      }) async => (socket: FakeExecSocket(), client: client, received: () => 0),
      quiet: const Duration(days: 1),
    ).lease(
      address: '10.0.0.2',
      port: 22,
      user: 'dev',
      privateKey: 'key',
      verifier: HostKeyVerifier.pinnedOnly(
        PinnedHostKey(
          type: 'ssh-ed25519',
          fingerprint: 'SHA256:fake',
          pinnedAt: DateTime(2026),
        ),
      ),
      use: HostUse.send,
    );

final class FakeForwardChannel implements SSHForwardChannel {
  final wire = FakeVncChannel();
  var destroyed = 0;

  @override
  Stream<Uint8List> get stream => wire.stream.map(Uint8List.fromList);

  @override
  StreamSink<List<int>> get sink => wire.sink;

  @override
  void destroy() => destroyed++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeDial {
  FakeDial({this.refuse = false, this.slowAuth = false});

  final bool refuse;
  bool slowAuth;
  final clients = <FakeLinkClient>[];
  var dials = 0;
  var settling = 0;
  Completer<void>? gate;
  PinnedHostKey? accept;
  void Function(FakeLinkClient client)? prepare;

  Future<SshLink> call({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    HostKeyVerifier? verifier,
    void Function(Future<void> settled)? onSettling,
  }) async {
    dials++;
    await gate?.future;
    if (refuse) throw const HerdrUnreachable('refused');
    if (slowAuth) {
      await Future<void>.delayed(const Duration(seconds: 10));
      settling++;
      onSettling?.call(
        Future<void>.delayed(sshLoginGrace).whenComplete(() => settling--),
      );
      throw const HerdrUnreachable('no answer in 10s');
    }
    final offered = accept;
    if (verifier != null && offered != null) {
      await verifier.verifyFingerprint(offered.type, offered.fingerprint);
    }
    final client = FakeLinkClient();
    prepare?.call(client);
    clients.add(client);
    return (
      socket: FakeExecSocket(),
      client: client,
      received: () => client.received,
    );
  }
}
