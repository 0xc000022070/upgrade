import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:dazzle/platform/herdr_client.dart';
import 'package:dazzle/platform/host_keys.dart';
import 'package:dazzle/platform/host_links.dart';
import 'package:dazzle/platform/ssh_settle.dart';

import 'ssh_exec.dart';

final class FakeLinkClient implements SSHClient {
  final gone = Completer<void>();
  var closes = 0;
  var pings = 0;
  Completer<void>? pong;
  Object? pingError;

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
  }) async => FakeExecSession()..input.stream.listen(null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeDial {
  FakeDial({this.refuse = false, this.slowAuth = false});

  final bool refuse;
  final bool slowAuth;
  final clients = <FakeLinkClient>[];
  var dials = 0;
  var settling = 0;
  Completer<void>? gate;
  PinnedHostKey? accept;

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
    clients.add(client);
    return (socket: FakeExecSocket(), client: client);
  }
}
