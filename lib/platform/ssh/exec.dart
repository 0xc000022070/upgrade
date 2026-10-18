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
  Stream<Uint8List>? feed,
  void Function(Uint8List chunk)? onStdout,
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
    return _finishExec(opened, stdin: stdin, feed: feed, onStdout: onStdout);
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
  } catch (_) {
    if (channel case final opened?) endExec(opened);
    rethrow;
  }
}

Future<ExecResult> transferExec(
  HostLease lease,
  String command, {
  Stream<Uint8List>? feed,
  void Function(Uint8List chunk)? onStdout,
  required Duration timeout,
}) => _run(
  lease,
  command,
  feed: feed,
  onStdout: onStdout,
  timeout: timeout,
  upload: true,
);

Future<ExecResult> leaseExec(
  HostLease lease,
  String command, {
  Uint8List? stdin,
  required Duration timeout,
}) => _run(lease, command, stdin: stdin, timeout: timeout);

Future<ExecResult> _finishExec(
  SSHSession channel, {
  Uint8List? stdin,
  Stream<Uint8List>? feed,
  void Function(Uint8List chunk)? onStdout,
}) async {
  final output = await drainExec(
    channel,
    stdin: stdin,
    feed: feed,
    onStdout: onStdout,
  );
  return ExecResult(
    exitCode: channel.exitCode,
    stdout: output.stdout,
    stderr: output.stderr,
  );
}
