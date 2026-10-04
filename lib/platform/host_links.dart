import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'herdr_client.dart';
import 'host_key_dial.dart';
import 'host_keys.dart';
import 'ssh_settle.dart';

typedef SshLink = ({
  SSHSocket socket,
  SSHClient client,
  int Function() received,
});

typedef SshDial = Future<SshLink> Function({
  required String address,
  required int port,
  required String user,
  required String privateKey,
  HostKeyVerifier? verifier,
  void Function(Future<void> settled)? onSettling,
});

class HostLease {
  HostLease(this.client, this._release, [this._suspect = _trusted]);

  final SSHClient client;
  final void Function() _release;
  final Future<void> Function() _suspect;
  var _released = false;

  static Future<void> _trusted() async {}

  Future<void> suspect() => _suspect();

  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

class _Link {
  _Link(this.ssh);

  final SshLink ssh;
  String? key;
  int count = 0;
  Timer? linger;
  DateTime? idleSince;
  Future<void>? vouching;
  bool ended = false;

  SSHClient get client => ssh.client;
}

/// The one place the app opens an ssh connection. Everything else leases the shared link;
/// [own] and [probe] are the only connections that are not it.
class HostLinks {
  HostLinks({
    SshDial? dial,
    this.timeout = const Duration(seconds: 10),
    this.keepAlive = sshKeepAlive,
    this.linger = const Duration(seconds: 30),
    this.answer = const Duration(seconds: 2),
    this.now = DateTime.now,
  }) : _injected = dial;

  final SshDial? _injected;
  late final SshDial _dial = _injected ?? _authenticated;
  final Duration timeout;
  final Duration keepAlive;
  final Duration linger;
  final Duration answer;
  final DateTime Function() now;

  final _links = <String, _Link>{};
  final _dialing = <String, Future<_Link>>{};
  final _settling = <String, Future<void>>{};
  final _all = <_Link>{};
  var _closed = false;

  Future<HostLease> lease({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    HostKeyVerifier? verifier,
  }) async {
    final pinned = verifier?.pinned;
    String keyFor(PinnedHostKey? pin) => [
      user,
      address,
      port,
      pin?.type,
      pin?.fingerprint,
      privateKey.hashCode,
    ].join('\u0000');
    final key = keyFor(pinned);

    if (pinned != null) {
      var live = _links[key];
      if (live?.vouching case final vouching?) {
        await vouching;
        live = _links[key];
      }
      if (live != null) {
        final idle = live.idleSince;
        if (live.client.isClosed ||
            (idle != null && now().difference(idle) >= linger)) {
          _end(live);
        } else {
          return _hold(live);
        }
      }
      final pending = _dialing[key];
      if (pending != null) return _hold(await pending);
    }

    // A failed dial keeps authenticating until sshd lets go and counts against MaxStartups;
    // a second one while it settles is how the user's own gets dropped.
    if (_settling.containsKey(key)) {
      throw const HerdrUnreachable('an earlier dial is still settling');
    }

    final dialing = () async {
      final ssh = await _dial(
        address: address,
        port: port,
        user: user,
        privateKey: privateKey,
        verifier: verifier,
        onSettling: (settled) => _settle(key, settled),
      );
      final link = _Link(ssh);
      _all.add(link);
      if (_closed) {
        _end(link);
        throw const HerdrUnreachable('host links closed');
      }
      final filed = verifier?.verified ?? pinned;
      if (filed != null) {
        final fileKey = keyFor(filed);
        if (!_links.containsKey(fileKey)) {
          _links[fileKey] = link;
          link.key = fileKey;
        }
      }
      ssh.client.done.then((_) => _end(link), onError: (_) => _end(link));
      return link;
    }();
    if (pinned != null) {
      _dialing[key] = dialing;
      dialing.then((_) {}, onError: (_) {}).whenComplete(() {
        if (identical(_dialing[key], dialing)) _dialing.remove(key);
      });
    }
    return _hold(await dialing);
  }

  Future<void> vouch(SSHClient client) async {
    final link = _all
        .where((link) => identical(link.client, client))
        .firstOrNull;
    final key = link?.key;
    if (link == null || key == null || !identical(_links[key], link)) return;
    if (client.isClosed) {
      _end(link);
      return;
    }
    final inFlight = link.vouching;
    if (inFlight != null) return inFlight;
    final ping = () async {
      final seen = link.ssh.received();
      try {
        await client.ping().timeout(answer);
      } on TimeoutException {
        if (link.ssh.received() == seen) _end(link);
      } catch (_) {
        _end(link);
      }
    }();
    link.vouching = ping;
    return ping.whenComplete(() {
      if (identical(link.vouching, ping)) link.vouching = null;
    });
  }

  static Future<SshLink> own({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    required Duration timeout,
    required Duration keepAlive,
    HostKeyVerifier? verifier,
  }) async {
    final socket = _CountingSocket(
      await SSHSocket.connect(address, port, timeout: timeout),
    );
    return (
      socket: socket,
      client: _client(socket, user, privateKey, keepAlive, verifier?.verify),
      received: () => socket.received,
    );
  }

  static Future<void> probe({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    required HostKeyVerifier verifier,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final offered = Completer<void>();
    final decided = Completer<void>();
    final broken = Completer<void>();
    final socket = await SSHSocket.connect(address, port, timeout: timeout);
    final client = _client(socket, user, privateKey, sshKeepAlive, (
      type,
      fingerprint,
    ) async {
      if (!offered.isCompleted) offered.complete();
      try {
        return await verifier.verify(type, fingerprint);
      } finally {
        if (!decided.isCompleted) decided.complete();
      }
    });
    unawaited(
      client.authenticated.then(
        (_) {},
        onError: (Object error, StackTrace stack) {
          if (!broken.isCompleted) broken.completeError(error, stack);
        },
      ),
    );
    try {
      await Future.any([offered.future, broken.future])
          .timeout(timeout, onTimeout: () => throw const HostKeySilent());
      await decided.future;
    } finally {
      unawaited(
        offered.isCompleted
            ? closeSettled(client, socket)
            : closeSsh(client, socket),
      );
    }
  }

  Future<SshLink> _authenticated({
    required String address,
    required int port,
    required String user,
    required String privateKey,
    HostKeyVerifier? verifier,
    void Function(Future<void> settled)? onSettling,
  }) async {
    final socket = _CountingSocket(
      await _guard(
        () => SSHSocket.connect(address, port, timeout: timeout),
        verifier,
      ),
    );
    final client = _client(
      socket,
      user,
      privateKey,
      keepAlive,
      verifier?.verify,
    );
    try {
      await _guard(
        () => authenticatedWithin(client.authenticated, verifier, timeout),
        verifier,
      );
      return (socket: socket, client: client, received: () => socket.received);
    } on HerdrFailure {
      final settled = closeSettled(client, socket);
      onSettling?.call(settled);
      rethrow;
    }
  }

  void close() {
    _closed = true;
    for (final link in [..._all]) {
      _end(link);
    }
    _links.clear();
  }

  HostLease _hold(_Link link) {
    link.linger?.cancel();
    link.linger = null;
    link.idleSince = null;
    link.count++;
    return HostLease(
      link.client,
      () => _release(link),
      () => vouch(link.client),
    );
  }

  void _release(_Link link) {
    if (--link.count > 0 || link.ended) return;
    final key = link.key;
    if (key == null || !identical(_links[key], link)) {
      _end(link);
      return;
    }
    link.idleSince = now();
    link.linger = Timer(linger, () => _end(link));
  }

  void _end(_Link link) {
    final key = link.key;
    if (key != null && identical(_links[key], link)) _links.remove(key);
    link.linger?.cancel();
    link.linger = null;
    _all.remove(link);
    if (link.ended) return;
    link.ended = true;
    unawaited(closeSsh(link.client, link.ssh.socket));
  }

  void _settle(String key, Future<void> settled) {
    _settling[key] = settled;
    settled.whenComplete(() {
      if (identical(_settling[key], settled)) _settling.remove(key);
    });
  }
}

SSHClient _client(
  SSHSocket socket,
  String user,
  String privateKey,
  Duration keepAlive,
  SSHHostkeyVerifyHandler? verify,
) => SSHClient(
  socket,
  username: user,
  identities: SSHKeyPair.fromPem(privateKey),
  keepAliveInterval: keepAlive,
  onVerifyHostKey: verify,
);

Future<T> _guard<T>(
  Future<T> Function() body, [
  HostKeyVerifier? verifier,
]) async {
  try {
    return await body();
  } catch (error) {
    throw asHerdrFailure(error, verifier?.refusal) ?? error;
  }
}

class _CountingSocket implements SSHSocket {
  _CountingSocket(this._inner) {
    stream = _inner.stream.map((bytes) {
      received += bytes.length;
      return bytes;
    });
  }

  final SSHSocket _inner;
  var received = 0;

  @override
  late final Stream<Uint8List> stream;

  @override
  StreamSink<List<int>> get sink => _inner.sink;

  @override
  Future<void> get done => _inner.done;

  @override
  Future<void> close() => _inner.close();

  @override
  void destroy() => _inner.destroy();

  @override
  Future<void> flush() => _inner.flush();
}
