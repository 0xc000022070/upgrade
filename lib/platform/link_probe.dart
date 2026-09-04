import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// What a host said when the app knocked, and how long it took to say it.
enum LinkStatus {
  /// Never probed.
  unknown,

  /// A probe is in flight.
  probing,

  /// The machine answered with its identification line.
  up,

  /// Nothing came back before the deadline: no route to it, or a firewall
  /// dropping the packets rather than refusing them.
  noRoute,

  /// The name does not resolve.
  unresolved,

  /// Something answered the port and closed it.
  refused,

  /// The port accepted and then said nothing. A tarpit, not a shell.
  noBanner,
}

/// One probe's answer.
class LinkResult {
  const LinkResult(this.status, {this.software, this.latency});

  const LinkResult.unknown() : this(LinkStatus.unknown);
  const LinkResult.probing() : this(LinkStatus.probing);

  final LinkStatus status;

  /// The software token off the identification line, `OpenSSH_9.9`. Null for
  /// every status but [LinkStatus.up].
  final String? software;

  final Duration? latency;
}

/// The row's words for a probe. `OPENSSH_9.9 · 120 MS` when the machine
/// answered, one word when it did not.
String linkWord(LinkResult result) => switch (result.status) {
  LinkStatus.unknown => '—',
  LinkStatus.probing => 'PROBING',
  LinkStatus.up =>
    '${result.software?.toUpperCase() ?? 'UP'} · '
        '${result.latency?.inMilliseconds ?? 0} MS',
  LinkStatus.noRoute => 'NO ROUTE',
  LinkStatus.unresolved => 'UNRESOLVED',
  LinkStatus.refused => 'REFUSED',
  LinkStatus.noBanner => 'NO BANNER',
};

/// Whether the word belongs in warning. Everything that is not an answer does.
bool linkFailed(LinkResult result) =>
    result.status != LinkStatus.unknown &&
    result.status != LinkStatus.probing &&
    result.status != LinkStatus.up;

/// How long a probe may take, connection and banner together.
const linkProbeDeadline = Duration(seconds: 4);

/// Reads the ssh identification line and hangs up. No key, no handshake and
/// nothing on the host's side but a connection in its log.
///
/// The line is what makes this worth more than a connect: a port that accepts
/// and then stalls answers a TCP probe exactly as a shell does, and the user
/// has one of those on a LAN address.
Future<LinkResult> probeLink(
  String address,
  int port, {
  Duration deadline = linkProbeDeadline,
}) async {
  final clock = Stopwatch()..start();
  Socket? socket;
  try {
    socket = await Socket.connect(address, port, timeout: deadline);
    final left = deadline - clock.elapsed;
    final line = await socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(left.isNegative ? Duration.zero : left);
    clock.stop();
    final software = identificationSoftware(line);
    if (software == null) return const LinkResult(LinkStatus.noBanner);
    return LinkResult(
      LinkStatus.up,
      software: software,
      latency: clock.elapsed,
    );
  } on SocketException catch (error) {
    return LinkResult(_socketStatus(error));
  } on TimeoutException {
    // The connection was made, so the deadline was spent waiting for a line
    // that never came.
    return LinkResult(
      socket == null ? LinkStatus.noRoute : LinkStatus.noBanner,
    );
  } on StateError {
    // The stream ended before a line did: the port accepted and closed.
    return const LinkResult(LinkStatus.refused);
  } finally {
    socket?.destroy();
  }
}

/// `SSH-2.0-OpenSSH_9.9 Debian-1` becomes `OpenSSH_9.9`. Null for anything
/// that is not an ssh identification line, which is what the port answering
/// with something else looks like from here.
String? identificationSoftware(String line) {
  const prefix = 'SSH-';
  if (!line.startsWith(prefix)) return null;
  final version = line.substring(prefix.length);
  final dash = version.indexOf('-');
  if (dash < 0) return null;
  final software = version.substring(dash + 1).split(' ').first.trim();
  return software.isEmpty ? null : software;
}

LinkStatus _socketStatus(SocketException error) {
  if (error.message.contains('Failed host lookup')) {
    return LinkStatus.unresolved;
  }
  // 111 on Linux and Android, 61 on the darwin hosts the app is developed on.
  final code = error.osError?.errorCode;
  if (code == 111 || code == 61) return LinkStatus.refused;
  return LinkStatus.noRoute;
}
