import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/shell/shell_connection.dart';
import 'shell_sessions.dart';

final shellHoldProvider = Provider<Future<void> Function(int count)>(
  (ref) => (_) async {},
);

class ShellHold {
  ShellHold(this._sessions, this._hold) {
    _sessions.addListener(_update);
    _update();
  }

  final ShellSessions _sessions;
  final Future<void> Function(int count) _hold;

  final _watched = <ShellSession>{};
  final _ssh = <ShellSession>{};
  int? _told;

  @visibleForTesting
  int get count => _ssh.length;

  void refresh() {
    _told = null;
    _update();
  }

  void _update() {
    final open = {for (final (_, sessions) in _sessions.openHosts) ...sessions};
    for (final session in _watched.difference(open)) {
      session.removeListener(_update);
    }
    for (final session in open.difference(_watched)) {
      session.addListener(_update);
    }
    _watched
      ..clear()
      ..addAll(open);
    _ssh.retainAll(open);
    for (final session in open) {
      if (session.connection?.transport case final transport?) {
        if (transport == ShellTransport.ssh) {
          _ssh.add(session);
        } else {
          _ssh.remove(session);
        }
      }
      if (session.state case ShellExited() || ShellFailed()) {
        _ssh.remove(session);
      }
    }
    if (_ssh.length == _told) return;
    _told = _ssh.length;
    unawaited(_hold(_ssh.length));
  }

  void dispose() {
    _sessions.removeListener(_update);
    for (final session in _watched) {
      session.removeListener(_update);
    }
    _watched.clear();
  }
}
