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

/// Nothing reached stdin, though the host may have started the command before answering.
final class ChannelOpenTimeout extends TimeoutException {
  ChannelOpenTimeout(Duration? duration)
    : super('SSH channel did not open in time', duration);
}

/// The host or the link failed; anything else is a bug. [SSHInternalError] counts: dartssh2
/// raises it for a packet it could not process, after closing the transport.
bool isHostFailure(Object error) =>
    !isKeyFailure(error) &&
    (error is SSHError || error is TimeoutException || error is IOException);

/// The key was refused or unreadable, or the host's key was: dialling again never helps.
/// A refused host key reaches `authenticated` wrapped in the abort it caused.
bool isKeyFailure(Object error) => switch (error) {
  SSHAuthFailError() || SSHKeyDecodeError() || SSHHostkeyError() => true,
  SSHAuthAbortError(reason: SSHHostkeyError()) => true,
  _ => false,
};

/// A channel opening past the deadline is closed unread; one that fails to open is asked
/// for once more, since its command provably never started.
Future<ExecResult> _run(
  ShellHost host,
  String command, {
  Uint8List? stdin,
  Duration? timeout,
}) async {
  ShellExec? channel;
  var expired = false;
  Future<ShellExec> openChannel() async {
    try {
      return await host.execute(command);
    } on SSHChannelOpenError {
      if (expired) rethrow;
      return host.execute(command);
    }
  }

  final task = () async {
    final opened = await openChannel();
    if (expired) {
      opened.close();
      throw TimeoutException('SSH channel opened after the deadline', timeout);
    }
    channel = opened;
    return _finishExec(opened, stdin: stdin);
  }();
  if (timeout == null) return task;
  try {
    return await task.timeout(timeout);
  } on TimeoutException {
    expired = true;
    final opened = channel;
    if (opened == null) throw ChannelOpenTimeout(timeout);
    // Closing the channel is what takes the still-running command down.
    opened.close();
    rethrow;
  }
}

Future<ExecResult> _finishExec(ShellExec channel, {Uint8List? stdin}) async {
  final out = BytesBuilder(copy: false);
  final err = BytesBuilder(copy: false);
  final drained = Future.wait([
    channel.stdout.forEach(out.add),
    channel.stderr.forEach(err.add),
  ]);
  if (stdin != null) channel.write(stdin);
  await channel.closeStdin();
  await channel.done;
  await drained;
  return ExecResult(
    exitCode: channel.exitCode,
    stdout: out.takeBytes(),
    stderr: err.takeBytes(),
  );
}
