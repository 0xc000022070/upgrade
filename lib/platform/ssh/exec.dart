// Part of the SSH connection policy library; read the header in connection_supervisor.dart before editing.
part of 'connection_supervisor.dart';

class ExecResult {
  const ExecResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int? exitCode;
  final Uint8List stdout;
  final Uint8List stderr;

  bool get ok => exitCode == 0;

  String get out => utf8.decode(stdout, allowMalformed: true);
  String get err => utf8.decode(stderr, allowMalformed: true);
}

/// The channel did not open in time. Nothing reached stdin, but the command may have started.
final class ChannelOpenTimeout extends TimeoutException {
  ChannelOpenTimeout(Duration? duration)
    : super('SSH channel did not open in time', duration);
}

/// True when the host or link failed; any other error is a bug. [SSHInternalError] counts:
/// dartssh2 raises it for a packet it could not process, after closing the transport.
bool isHostFailure(Object error) =>
    !isKeyFailure(error) &&
    (error is SSHError || error is TimeoutException || error is IOException);

/// True when our key or the host's key was refused or unreadable, so dialling again never
/// helps. A refused host key reaches `authenticated` wrapped in the abort it caused.
bool isKeyFailure(Object error) => switch (error) {
  SSHAuthFailError() || SSHKeyDecodeError() || SSHHostkeyError() => true,
  SSHAuthAbortError(reason: SSHHostkeyError()) => true,
  _ => false,
};

/// A channel that opens after [timeout] is closed unread. [HostLease.execute] has already
/// moved a channel the host refused for its session limit to the overflow link.
Future<ExecResult> _run(
  HostLease lease,
  String command, {
  Uint8List? stdin,
  required Duration timeout,
  bool upload = false,
}) async {
  SSHSession? channel;
  var expired = false;
  final task = () async {
    final opened = upload
        ? await lease.upload(command)
        : await lease.execute(command);
    if (expired) {
      endExec(opened);
      throw TimeoutException('SSH channel opened after the deadline', timeout);
    }
    channel = opened;
    return _finishExec(opened, stdin: stdin);
  }();
  try {
    return await task.timeout(timeout);
  } on TimeoutException {
    expired = true;
    final opened = channel;
    if (opened == null) throw ChannelOpenTimeout(timeout);
    // Closing the channel is what takes the still-running command down.
    endExec(opened);
    rethrow;
  }
}

Future<ExecResult> _finishExec(SSHSession channel, {Uint8List? stdin}) async {
  final out = BytesBuilder(copy: false);
  final err = BytesBuilder(copy: false);
  final drained = Future.wait([
    channel.stdout.forEach(out.add),
    channel.stderr.forEach(err.add),
  ]);
  if (stdin != null) channel.stdin.add(stdin);
  await channel.stdin.close();
  await channel.done;
  await drained;
  return ExecResult(
    exitCode: channel.exitCode,
    stdout: out.takeBytes(),
    stderr: err.takeBytes(),
  );
}
