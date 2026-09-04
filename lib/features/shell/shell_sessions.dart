import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../application/agents.dart';
import '../../data/repositories/host_repository.dart';
import '../../platform/shell/shell_connection.dart';
import '../../platform/shell/shell_tunnel.dart';
import '../../platform/shell/strip_bytes.dart';
import '../../platform/vnc/keysyms.dart';

/// How much scrollback a session keeps. A build log on the remote is the case
/// this is sized for.
const shellScrollback = 10000;

/// The most sessions a host may have open at once. The tab row numbers them
/// `1`..`9`, and there is neither room nor reason for a tenth.
const maxShellSessions = 9;

/// Where a session is, which is the whole of what the header can say.
sealed class ShellState {
  const ShellState();
}

final class ShellConnecting extends ShellState {
  const ShellConnecting();
}

final class ShellLive extends ShellState {
  const ShellLive();
}

final class ShellExited extends ShellState {
  const ShellExited(this.code);

  /// Null when the channel closed without one.
  final int? code;
}

final class ShellFailed extends ShellState {
  const ShellFailed(this.kind);

  final ShellFailureKind kind;
}

/// The reason line for a failure, worded the way the screen route words its
/// own, so a host says the same thing about itself wherever it fails.
String shellReason(ShellFailureKind kind, String host) => switch (kind) {
  ShellFailureKind.unreachable => '${host.toLowerCase()} unreachable',
  ShellFailureKind.unresolved => '${host.toLowerCase()} unresolved',
  ShellFailureKind.keyRejected => 'key rejected',
  ShellFailureKind.shellRefused => 'shell refused',
  ShellFailureKind.streamClosed => 'stream closed',
};

/// One shell: its tab number, its terminal, and the connection under it.
///
/// The terminal outlives the connection on purpose. A session that failed or
/// exited keeps every byte it printed, which is the only place the error the
/// remote shell died of can still be read.
class ShellSession {
  ShellSession({required this.number, required this.terminal});

  /// Its place in the tab row, `1`..`9`, fixed for the session's life. Numbers
  /// are handed out in open order and never reused, so closing tab 2 leaves
  /// `1 3` rather than renumbering the tabs under the user's finger.
  final int number;

  final Terminal terminal;

  ShellConnection? connection;
  ShellState state = const ShellConnecting();

  /// What the bar has armed, waiting for the next key or character. It lives
  /// here rather than in the bar because the IME types straight into the
  /// terminal, where the bar is not in the path, and because switching tabs
  /// has to switch the armed set with the session.
  final Set<StickyModifier> sticky = <StickyModifier>{};

  /// What the shell called itself, through the escape sequence a shell uses to
  /// name its window. Null until it says, which a bare `sh` never does.
  String? title;

  /// Cancelled and dropped on every close and every retry: a stale listener
  /// would write a dead connection's bytes into a live terminal.
  StreamSubscription<Uint8List>? _output;

  /// Decodes the channel across chunk boundaries. A plain [utf8.decode] per
  /// chunk would mangle any character whose bytes land either side of one,
  /// which is every read on a busy shell sooner or later.
  ByteConversionSink? _decoder;

  /// The last size sent to the remote, so a resize that changes nothing is not
  /// forwarded. The view reports on every layout, including ones where only
  /// the pixel size moved.
  int? _columns;
  int? _rows;

  /// Guards a retry tapped while an attempt is still in flight, which would
  /// otherwise leave two connections open against one host in one tab.
  int _attempt = 0;
}

/// Every host's shells, for as long as the app is running.
///
/// Held by a provider that is never disposed, because the sessions are the
/// point: leaving `/ NYX SHELL` and coming back finds the tabs where they
/// were, still running. The route disposing closes nothing.
class ShellSessions extends ChangeNotifier {
  ShellSessions({required this.readPrivateKey, ShellOpener? open})
    : _open = open ?? const ShellTunnel().open;

  final Future<String?> Function(String keyId) readPrivateKey;

  /// The transport. Injectable only so the store can be driven without a host
  /// to answer it; null everywhere but a test, which is where [ShellTunnel] is
  /// used.
  final ShellOpener _open;

  final _byHost = <String, List<ShellSession>>{};

  /// The next number to hand out per host. Separate from the session list
  /// because closing every tab must not restart the numbering while the user
  /// is still on the route.
  final _nextNumber = <String, int>{};

  final _active = <String, int>{};

  List<ShellSession> forHost(String hostId) =>
      List.unmodifiable(_byHost[hostId] ?? const <ShellSession>[]);

  /// The session whose terminal is on screen, or null before the first open.
  ShellSession? activeFor(String hostId) {
    final sessions = _byHost[hostId];
    if (sessions == null || sessions.isEmpty) return null;
    final number = _active[hostId];
    for (final session in sessions) {
      if (session.number == number) return session;
    }
    return sessions.last;
  }

  void activate(String hostId, ShellSession session) {
    _active[hostId] = session.number;
    notifyListeners();
  }

  bool canOpen(String hostId) =>
      (_byHost[hostId]?.length ?? 0) < maxShellSessions;

  /// Opens a shell and makes it the active tab. The `+` cell is gone at nine,
  /// so the refusal here is a guard rather than a path the user can walk.
  ShellSession? open(Host host) {
    if (!canOpen(host.id)) return null;
    final number = _nextNumber[host.id] ?? 1;
    _nextNumber[host.id] = number + 1;
    final session = ShellSession(
      number: number,
      terminal: Terminal(maxLines: shellScrollback),
    );
    _byHost.putIfAbsent(host.id, () => []).add(session);
    _active[host.id] = number;
    _wireTerminal(session);
    notifyListeners();
    unawaited(_connect(host, session));
    return session;
  }

  /// Reopens a session in the tab it already holds. Its terminal is kept: what
  /// the last attempt printed before it died is what the user is looking at
  /// when they reach for `RETRY`.
  Future<void> retry(Host host, ShellSession session) async {
    // Bumped before anything closes: closing the old connection completes its
    // exit future, and an exit belonging to the attempt being replaced would
    // otherwise paint `EXITED` over the reconnect already under way.
    session._attempt++;
    await session._output?.cancel();
    session._output = null;
    session._decoder = null;
    final previous = session.connection;
    session.connection = null;
    session._columns = null;
    session._rows = null;
    // The title belonged to the shell that died. A new one that never names
    // itself would otherwise be read under the old one's name.
    session.title = null;
    session.sticky.clear();
    session.state = const ShellConnecting();
    notifyListeners();
    await previous?.close();
    await _connect(host, session);
  }

  /// Closes the connection and drops the tab. The number goes with it and is
  /// not handed out again.
  Future<void> close(String hostId, ShellSession session) async {
    // Bumped so the exit and the output stream of the connection being closed
    // cannot write a state onto a session that is already gone.
    session._attempt++;
    session.sticky.clear();
    _byHost[hostId]?.remove(session);
    if (_active[hostId] == session.number) {
      final rest = _byHost[hostId];
      if (rest != null && rest.isNotEmpty) _active[hostId] = rest.last.number;
    }
    notifyListeners();
    await session._output?.cancel();
    session._output = null;
    session._decoder = null;
    final connection = session.connection;
    session.connection = null;
    await connection?.close();
  }

  /// What the user types goes to the remote, and every size the view settles
  /// on goes once. Wired before the connection exists so a fast typist's bytes
  /// are not dropped between the tab appearing and the shell answering.
  void _wireTerminal(ShellSession session) {
    session.terminal.onOutput = (text) {
      // Everything the user puts in comes through here: the IME's characters,
      // the terminal's own key handling, and a paste. Which is why the armed
      // set is applied and spent here and not where the bar is.
      //
      // A newline goes out as a carriage return. The IME's return key inserts
      // `\n` and a pasted line break is one too, but the byte a terminal sends
      // for a line the shell should act on is `0d`.
      send(session, typedBytes(text.replaceAll('\n', '\r'), session.sticky));
    };
    session.terminal.onTitleChange = (title) {
      session.title = title;
      notifyListeners();
    };
    session.terminal.onResize = (columns, rows, _, _) {
      if (columns == session._columns && rows == session._rows) return;
      session._columns = columns;
      session._rows = rows;
      session.connection?.resize(columns, rows);
    };
  }

  /// The bar's bytes, and the terminal's own once they have been mapped.
  ///
  /// One use is all an armed modifier gets, wherever the key came from, so the
  /// set is spent here at the single point every byte passes through.
  void send(ShellSession session, Uint8List bytes) {
    if (bytes.isNotEmpty) session.connection?.write(bytes);
    if (session.sticky.isEmpty) return;
    session.sticky.clear();
    notifyListeners();
  }

  /// Arms the bar's modifiers for the next key. Replaces the set rather than
  /// merging: the bar draws the whole of what is armed and hands back the whole
  /// of it.
  void arm(ShellSession session, Set<StickyModifier> sticky) {
    session.sticky
      ..clear()
      ..addAll(sticky);
    notifyListeners();
  }

  Future<void> _connect(Host host, ShellSession session) async {
    final attempt = ++session._attempt;
    final privateKey = await readPrivateKey(host.keyId);
    if (attempt != session._attempt) return;
    if (privateKey == null) {
      // The host names a key whose secret is gone from the store. There is
      // nothing to offer the remote, so this never dials.
      session.state = const ShellFailed(ShellFailureKind.keyRejected);
      notifyListeners();
      return;
    }

    // The size the view has already settled on, when it has: a shell started
    // at the wrong width redraws its prompt at the first resize and the user
    // sees the wrap.
    final columns = session._columns ?? session.terminal.viewWidth;
    final rows = session._rows ?? session.terminal.viewHeight;

    try {
      final connection = await _open(
        address: host.address,
        port: host.port,
        user: host.user,
        privateKey: privateKey,
        columns: columns,
        rows: rows,
      );
      if (attempt != session._attempt) {
        await connection.close();
        return;
      }
      session.connection = connection;
      session._columns = columns;
      session._rows = rows;
      session.state = const ShellLive();
      session._decoder = utf8.decoder.startChunkedConversion(
        _TerminalSink(session.terminal),
      );
      session._output = connection.output.listen(
        (bytes) => session._decoder?.add(bytes),
        onError: (Object error) => _fail(session, error, attempt),
      );
      unawaited(_awaitExit(session, connection, attempt));
      notifyListeners();
    } catch (error) {
      _fail(session, error, attempt);
    }
  }

  Future<void> _awaitExit(
    ShellSession session,
    ShellConnection connection,
    int attempt,
  ) async {
    try {
      final code = await connection.exitCode;
      if (attempt != session._attempt) return;
      session.state = ShellExited(code);
      notifyListeners();
    } catch (error) {
      _fail(session, error, attempt);
    }
  }

  /// Anything the transport throws that is not a [ShellFailure] is the
  /// connection going away without a word for it.
  void _fail(ShellSession session, Object error, int attempt) {
    if (attempt != session._attempt) return;
    session.state = ShellFailed(
      error is ShellFailure ? error.kind : ShellFailureKind.streamClosed,
    );
    notifyListeners();
  }
}

/// The chunked decoder's other end: decoded text straight into the terminal.
class _TerminalSink implements Sink<String> {
  _TerminalSink(this.terminal);

  final Terminal terminal;

  @override
  void add(String data) => terminal.write(data);

  @override
  void close() {}
}

/// The store, for the app's lifetime. Nothing disposes it: a session is meant
/// to outlive the route that opened it, and a provider that let go when its
/// last reader did would close every shell on the way out of the screen.
final shellSessionsProvider = Provider<ShellSessions>((ref) {
  ref.keepAlive();
  return ShellSessions(
    readPrivateKey: ref.watch(ed25519KeysProvider).privateKey,
  );
});
