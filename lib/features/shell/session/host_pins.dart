part of 'shell_sessions.dart';

class HostPins {
  HostPins._(this._store, this.hostId);

  final ShellSessions _store;
  final String hostId;
  String? _dismissed;
  final _answering = <String>{};

  List<ShellSession> get _tabs => _store.forHost(hostId);

  ({ShellSession session, PinRequest request})? get current {
    for (final session in [?_store.activeFor(hostId), ..._tabs]) {
      final request = session.pin;
      if (request == null || session.state is! ShellLive) continue;
      if (request.id == _dismissed) continue;
      return (session: session, request: request);
    }
    return null;
  }

  void dismiss(PinRequest request) => _dismissed = request.id;

  PinRequest? get dismissed {
    for (final session in _tabs) {
      final request = session.pin;
      if (request != null &&
          request.id == _dismissed &&
          session.state is ShellLive) {
        return request;
      }
    }
    return null;
  }

  void reopen() => _dismissed = null;

  int tabFor(ShellSession session, PinRequest request) {
    final onScreen = _store.activeFor(hostId);
    if (onScreen != null && onScreen.pin?.id == request.id) {
      return onScreen.number;
    }
    return session.number;
  }

  PinRequest held(ShellSession session, PinRequest request) {
    for (final other in [session, ..._tabs]) {
      final held = other.pin;
      if (held != null && held.id == request.id) return held;
    }
    return request;
  }

  Future<PinAnswer> answer(
    ShellSession session,
    String? passphrase,
    UserIntent intent,
  ) async {
    final request = session.pin;
    final connection = session.connection;
    if (request == null) return PinAnswer.lost;
    for (final tab in [session, ..._tabs]) {
      if (tab.pin?.id == request.id) _set(tab, null);
    }
    if (connection == null || !_answering.add(request.id)) {
      return PinAnswer.lost;
    }
    PinAnswer unsent() {
      if (session.pin == null && !session._closed) _set(session, request);
      return PinAnswer.lost;
    }

    try {
      final HostChannels? channels;
      try {
        channels = await connection.channelsFor(UserAction(intent));
      } catch (error) {
        if (!isHostOrKeyFailure(error)) rethrow;
        debugPrint(
          '$appSlug.shell ${session.host.name}: pinentry dial: $error',
        );
        return unsent();
      }
      if (channels == null) return unsent();
      return await HostQueries(
            channels,
            host: session.host.name,
          ).answerPin(request.id, passphrase, wait: _store.pinAnswerWait) ??
          unsent();
    } finally {
      _answering.remove(request.id);
    }
  }

  Future<void> _mark(ShellSession session, ShellConnection connection) =>
      _store._queries(session, connection).markPinentry(session.tab);

  void _set(ShellSession session, PinRequest? request) {
    session.pin = request;
    if (request == null) session._stopAsking();
    session.changed();
    _tellShade(session.host);
  }

  void _tellShade(Host host) {
    PinRequest? held;
    for (final session in _tabs) {
      held = session.pin;
      if (held != null) break;
    }
    unawaited(
      _store._shade.tell(hostId: host.id, hostName: host.name, held: held),
    );
  }

  Future<void> _ask(ShellSession session) async {
    if (session._asleep != null) return;
    if (session._asking) {
      session._askAgain = true;
      return;
    }
    session._asking = true;
    session._stopAsking();
    try {
      do {
        session._askAgain = false;
        final connection = session.connection;
        if (connection == null) return;
        final open = await _store._queries(session, connection).openPins();
        if (open == null || !identical(session.connection, connection)) return;
        final next = open.isEmpty ? null : open.first;
        if (next?.id != session.pin?.id) {
          _set(session, next);
        } else {
          _age(session);
        }
      } while (session._askAgain);
    } finally {
      session._asking = false;
      final owed = session._askAgain;
      session._askAgain = false;
      if (owed && session.connection != null) {
        unawaited(_ask(session));
      } else if (session.pin != null &&
          session.connection != null &&
          session._asleep == null) {
        session._reask = Timer(
          _store.pinRecheck,
          () => unawaited(_ask(session)),
        );
      }
    }
  }

  void _age(ShellSession session) {
    final request = session.pin;
    if (request == null || request.stale) return;
    if (DateTime.now().difference(request.since) < _store.pinStale) return;
    _set(session, request.aged());
  }
}
