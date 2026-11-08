import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:upgrade/platform/native_replies.dart';

abstract interface class DaemonLink {
  Future<int> attach({
    required String host,
    required int port,
    required String cert,
    required String token,
    required String tab,
  });

  Future<String> call({
    required String host,
    required int port,
    required String cert,
    required String token,
    required String body,
  });
}

final class DaemonFailed implements Exception {
  const DaemonFailed(this.message, {required this.sent});

  final String message;
  final bool sent;

  @override
  String toString() => 'daemon: $message';
}

typedef _Callback = Void Function(Pointer<Utf8>);
typedef _Request = Void Function(
  Int64,
  Pointer<Utf8>,
  Pointer<NativeFunction<_Callback>>,
);
typedef _RequestDart = void Function(
  int,
  Pointer<Utf8>,
  Pointer<NativeFunction<_Callback>>,
);
typedef _Free = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

class NativeDaemonLink implements DaemonLink {
  late final DynamicLibrary _library = DynamicLibrary.open(
    'libupgrade_quic.so',
  );
  late final _attach = _library.lookupFunction<_Request, _RequestDart>(
    'upgrade_quic_attach',
  );
  late final _call = _library.lookupFunction<_Request, _RequestDart>(
    'upgrade_quic_call',
  );
  late final _free = _library.lookupFunction<_Free, _FreeDart>(
    'upgrade_quic_free',
  );
  late final _callback = NativeCallable<_Callback>.listener(_receive);
  late final _replies = NativeReplies(_free);

  void _receive(Pointer<Utf8> text) {
    final message = _replies.decode(text);
    final pending = _replies.take(message['reply']);
    switch (message) {
      case {'ok': final Object answer}:
        pending?.complete(answer);
      default:
        pending?.completeError(
          DaemonFailed('${message['error']}', sent: message['sent'] != false),
        );
    }
  }

  Future<Object?> _send(_RequestDart send, Map<String, Object?> request) =>
      _replies.send(
        request,
        (id, text) => send(id, text, _callback.nativeFunction),
      );

  @override
  Future<int> attach({
    required String host,
    required int port,
    required String cert,
    required String token,
    required String tab,
  }) async => await _send(_attach, {
    'host': host,
    'port': port,
    'cert': cert,
    'token': token,
    'tab': tab,
  }) as int;

  @override
  Future<String> call({
    required String host,
    required int port,
    required String cert,
    required String token,
    required String body,
  }) async => await _send(_call, {
    'host': host,
    'port': port,
    'cert': cert,
    'token': token,
    'body': body,
  }) as String;
}

typedef _Daemon = ({int port, String cert, String token});

/// Each host's `daemon/1`, kept per `user@address`. A host that has none, or whose
/// daemon could not be reached, is left to ssh for [cooling] before it is asked again.
class EngineDaemons {
  EngineDaemons(
    this.link, {
    this.cooling = const Duration(minutes: 5),
    this.now = DateTime.now,
  });

  static final shared = EngineDaemons(
    Platform.isAndroid ? NativeDaemonLink() : null,
  );

  final DaemonLink? link;
  final Duration cooling;
  final DateTime Function() now;
  final _known = <String, Future<_Daemon?>>{};
  final _cool = <String, DateTime>{};

  /// The loopback port that relays [tab] through the host's daemon, or null when
  /// there is no daemon to go through. [start] asks the host for its daemon over ssh.
  Future<int?> attach({
    required String address,
    required String user,
    required String tab,
    required Duration timeout,
    required Future<Map<String, Object?>?> Function() start,
  }) => _through(
    address,
    user,
    start,
    (link, daemon) => link
        .attach(
          host: address,
          port: daemon.port,
          cert: daemon.cert,
          token: daemon.token,
          tab: tab,
        )
        .timeout(timeout),
  );

  /// The engine's answer to [body], or null when the request did not reach a daemon
  /// and should go over ssh. Throws when it may have run and its answer was lost.
  Future<String?> call({
    required String address,
    required String user,
    required String body,
    required Duration timeout,
    required Future<Map<String, Object?>?> Function() start,
  }) => _through(
    address,
    user,
    start,
    (link, daemon) => link
        .call(
          host: address,
          port: daemon.port,
          cert: daemon.cert,
          token: daemon.token,
          body: body,
        )
        .timeout(timeout),
  );

  Future<T?> _through<T extends Object>(
    String address,
    String user,
    Future<Map<String, Object?>?> Function() start,
    Future<T> Function(DaemonLink link, _Daemon daemon) run,
  ) async {
    final link = this.link;
    if (link == null) return null;
    final host = '$user@$address';
    for (var tries = 0; tries < 2; tries++) {
      final until = _cool[host];
      if (until != null && now().isBefore(until)) return null;
      final asked = !_known.containsKey(host);
      final daemon = await (_known[host] ??= _ask(start));
      if (daemon == null) {
        _cooled(host);
        return null;
      }
      try {
        return await run(link, daemon);
      } on DaemonFailed catch (failure) {
        _known.remove(host);
        if (failure.sent) rethrow;
        if (asked) {
          _cooled(host);
          return null;
        }
      } catch (_) {
        _known.remove(host);
        rethrow;
      }
    }
    return null;
  }

  Future<_Daemon?> _ask(Future<Map<String, Object?>?> Function() start) async {
    try {
      return switch (await start()) {
        {
          'port': final int port,
          'cert': final String cert,
          'token': final String token,
        } =>
          (port: port, cert: cert, token: token),
        _ => null,
      };
    } catch (_) {
      // ignored: a host whose start fails is left to ssh, which reports its own failures.
      return null;
    }
  }

  void _cooled(String host) {
    _known.remove(host);
    _cool[host] = now().add(cooling);
  }
}
