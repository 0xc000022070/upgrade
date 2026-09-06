import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../application/agents.dart';
import '../../application/providers.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/shell_tab_repository.dart';
import '../../platform/host_keys.dart';
import '../../platform/shell/host_clipboard.dart';
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

/// The link went away under a live shell and the store is bringing it back.
/// [attempt] counts from 1 and is what the header reads out.
final class ShellDropped extends ShellState {
  const ShellDropped(this.attempt);

  final int attempt;
}

final class ShellFailed extends ShellState {
  const ShellFailed(this.kind);

  final ShellFailureKind kind;
}

/// How long the store waits before each reconnect, and so how many it makes.
/// The first two cover a wifi handover; the rest cover a lift ride and a
/// tunnel, after which a phone that still cannot see the host is somewhere the
/// user knows about.
const shellReconnectDelays = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 10),
  Duration(seconds: 20),
  Duration(seconds: 30),
];

/// Written into the terminal above each new shell. A prompt appearing under a
/// dead shell's output with no mark between them is a lie about what happened,
/// and the dim SGR is what every other tool marks its own lines with.
const shellReconnectMarker = '\r\n\x1b[2m-- reconnected --\x1b[0m\r\n';

/// The one exit code that means the user is done: a tab that ends on it closes
/// itself, and a tab that ends on anything else is put in front of the user.
const shellCleanExit = 0;

/// Whether losing the link this way is an accident worth reconnecting from. An
/// exit code is the user's own `exit`; a rejected key, a refused shell and both
/// host key failures are answers, and dialling again would only get the same
/// one.
bool shellReconnects(ShellFailureKind kind) =>
    kind == ShellFailureKind.streamClosed ||
    kind == ShellFailureKind.unreachable;

/// The reason line for a failure, worded the way the screen route words its
/// own, so a host says the same thing about itself wherever it fails.
String shellReason(ShellFailureKind kind, String host) => switch (kind) {
  ShellFailureKind.unreachable => '${host.toLowerCase()} unreachable',
  ShellFailureKind.unresolved => '${host.toLowerCase()} unresolved',
  ShellFailureKind.keyRejected => 'key rejected',
  ShellFailureKind.shellRefused => 'shell refused',
  ShellFailureKind.streamClosed => 'stream closed',
  ShellFailureKind.hostKeyUnverified => hostKeyReason(
    HostKeyRefusal.unverified,
  ),
  ShellFailureKind.hostKeyChanged => hostKeyReason(HostKeyRefusal.changed),
};

/// One shell: its tab number, its terminal, and the connection under it.
///
/// The terminal outlives the connection on purpose. A session that failed or
/// exited keeps every byte it printed, which is the only place the error the
/// remote shell died of can still be read.
class ShellSession {
  ShellSession({
    required this.number,
    required this.terminal,
    required this.host,
  });

  /// The machine this tab is on. Mutable because the store is handed a fresh
  /// [Host] on every open and retry, and a reconnect fired by a timer has
  /// nobody to hand it one.
  Host host;

  /// Its place in the tab row, `1`..`9`, fixed for the session's life. Numbers
  /// are handed out in open order and never reused, so closing tab 2 leaves
  /// `1 3` rather than renumbering the tabs under the user's finger.
  final int number;

  final Terminal terminal;

  /// Owns the selection the view draws, so the copy affordance can read it.
  /// The view makes its own controller when it is not handed one, and a
  /// selection made in that private controller is one nothing else can reach.
  final TerminalController controller = TerminalController();

  /// Owns the focus the view's IME hangs off. One per session and not one for
  /// the route: the view opens its text input when its node takes focus and
  /// closes it when the view goes, and two views handed the same node pass
  /// focus between them without a change of focus. The view that came in
  /// never sees one, never opens its input, and the node reads as focused
  /// over a keyboard that types into nothing.
  final FocusNode focusNode = FocusNode(debugLabel: 'shell-terminal');

  /// Owns the view's scroll, so the copy affordance can follow a selection the
  /// user scrolls away from and back to.
  final ScrollController scrollController = ScrollController();

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

  /// What the host answered about its clipboard on this connection. Null
  /// until asked, and dropped with the connection: the answer is about the
  /// desktop session the shell landed in, and a reconnect may land elsewhere.
  HostClipboard? clipboard;
  Future<HostClipboard>? _probing;

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

  /// The wait before the next reconnect. Cancelled by `STOP`, by a retry and
  /// by the tab closing, all three of which are the user deciding what happens
  /// next instead of the schedule.
  Timer? _reconnect;
}

/// Every host's shells, for as long as the app is running.
///
/// Held by a provider that is never disposed, because the sessions are the
/// point: leaving `/ NYX SHELL` and coming back finds the tabs where they
/// were, still running. The route disposing closes nothing.
class ShellSessions extends ChangeNotifier {
  ShellSessions({
    required this.readPrivateKey,
    required this.pinHostKey,
    this.tabs,
    ShellOpener? open,
  }) : _open = open ?? const ShellTunnel().open;

  final Future<String?> Function(String keyId) readPrivateKey;

  /// Writes a host key the user has just trusted. The store is what has the
  /// answer when the sheet closes, and the repository is the only thing that
  /// can keep it.
  final Future<void> Function(String hostId, PinnedHostKey key) pinHostKey;

  /// The transport. Injectable only so the store can be driven without a host
  /// to answer it; null everywhere but a test, which is where [ShellTunnel] is
  /// used.
  final ShellOpener _open;

  /// Where the open tabs are written down, so a process that is killed can be
  /// dialled back into the shells it had. Null in a test that is not about
  /// what survives a restart.
  final ShellTabRepository? tabs;

  final _byHost = <String, List<ShellSession>>{};

  /// The next number to hand out per host. Separate from the session list
  /// because closing every tab must not restart the numbering while the user
  /// is still on the route.
  final _nextNumber = <String, int>{};

  final _active = <String, int>{};

  /// The host the last opened or activated tab is on, which is the one a way
  /// back off the tabs leads to.
  String? _parkedHostId;

  /// Keys pinned during this run, by host id.
  ///
  /// The [Host] a route hands in was read before the sheet said `TRUST`, so
  /// without this the second tab on the same host would ask about the same key
  /// again while the hosts stream catches up.
  final _pinnedThisRun = <String, PinnedHostKey>{};

  bool _restored = false;

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

  /// The session a way back leads to: the tab last opened or brought forward,
  /// on the host it was on. Null while no host has one.
  ///
  /// Not a history of its own. [activeFor] already says which tab a host is on
  /// and this only remembers which host that was, so closing the tab it names
  /// falls to whatever that host is on now, and closing the host's last tab
  /// falls to another host that still has one.
  ShellSession? get parked {
    final named = activeFor(_parkedHostId ?? '');
    if (named != null) return named;
    for (final hostId in _byHost.keys.toList().reversed) {
      final fallback = activeFor(hostId);
      if (fallback != null) return fallback;
    }
    return null;
  }

  /// Every host that has a shell, in the order it first got one, each with its
  /// tabs. The [Host] is the one its own sessions carry, which is the freshest
  /// the store was handed.
  List<(Host, List<ShellSession>)> get openHosts => [
    for (final sessions in _byHost.values)
      if (sessions.isNotEmpty)
        (sessions.first.host, List.unmodifiable(sessions)),
  ];

  /// Tabs open across every host, which is what a way back has to account for
  /// when it can only name one of them.
  int get openCount =>
      _byHost.values.fold(0, (total, sessions) => total + sessions.length);

  void activate(String hostId, ShellSession session) {
    _active[hostId] = session.number;
    _parkedHostId = hostId;
    notifyListeners();
    unawaited(tabs?.activate(hostId, session.number));
  }

  bool canOpen(String hostId) =>
      (_byHost[hostId]?.length ?? 0) < maxShellSessions;

  /// Opens a shell and makes it the active tab. The `+` cell is gone at nine,
  /// so the refusal here is a guard rather than a path the user can walk.
  ShellSession? open(Host host, {HostKeyPrompt? prompt}) {
    if (!canOpen(host.id)) return null;
    final number = _nextNumber[host.id] ?? 1;
    _nextNumber[host.id] = number + 1;
    final session = _start(host, number, prompt: prompt);
    unawaited(tabs?.open(host.id, number));
    return session;
  }

  /// A tab on a number that has already been decided: by [open], which takes
  /// the next one, or by [restore], which takes the one the tab had before the
  /// process died.
  ShellSession _start(Host host, int number, {HostKeyPrompt? prompt}) {
    final session = ShellSession(
      number: number,
      terminal: Terminal(maxLines: shellScrollback),
      host: host,
    );
    _byHost.putIfAbsent(host.id, () => []).add(session);
    _active[host.id] = number;
    _parkedHostId = host.id;
    _wireTerminal(session);
    notifyListeners();
    unawaited(_connect(host, session, prompt: prompt));
    return session;
  }

  /// Reopens the tabs the last run left behind and dials each one.
  ///
  /// The shells themselves are gone — their channels died with the process that
  /// held them — so what comes back is a fresh shell per tab, on the same host
  /// and under the same number. Unattended, so a host whose key was never
  /// pinned is refused here rather than asking a user who is still looking at
  /// the boot log.
  ///
  /// Runs once, and answers with how many tabs it brought back. A second call
  /// over live tabs would dial a second shell into every one of them.
  Future<int> restore(Future<List<Host>> Function() readHosts) async {
    final store = tabs;
    if (store == null || _restored) return 0;
    _restored = true;
    final rows = await store.all();
    if (rows.isEmpty) return 0;
    final hosts = {for (final host in await readHosts()) host.id: host};
    var restored = 0;
    for (final row in rows) {
      final host = hosts[row.hostId];
      // The host was deleted while the app was down. There is no longer an
      // address to dial, and the row would outlive every run.
      if (host == null) {
        unawaited(store.close(row.hostId, row.number));
        continue;
      }
      final next = _nextNumber[host.id] ?? 1;
      if (row.number >= next) _nextNumber[host.id] = row.number + 1;
      _start(host, row.number);
      restored++;
    }
    // [_start] leaves the last tab opened active, which is the right answer
    // only for the host whose tab was on screen.
    for (final row in rows.where((row) => row.active)) {
      if (!hosts.containsKey(row.hostId)) continue;
      _active[row.hostId] = row.number;
      _parkedHostId = row.hostId;
    }
    notifyListeners();
    return restored;
  }

  /// Closes the connection and drops the tab. The number goes with it and is
  /// not handed out again.
  Future<void> close(String hostId, ShellSession session) async {
    // Bumped so the exit and the output stream of the connection being closed
    // cannot write a state onto a session that is already gone.
    session._attempt++;
    session._reconnect?.cancel();
    session._reconnect = null;
    session.sticky.clear();
    _byHost[hostId]?.remove(session);
    if (_active[hostId] == session.number) {
      final rest = _byHost[hostId];
      if (rest != null && rest.isNotEmpty) {
        _active[hostId] = rest.last.number;
        unawaited(tabs?.activate(hostId, rest.last.number));
      }
    }
    notifyListeners();
    unawaited(tabs?.close(hostId, session.number));
    unawaited(session._output?.cancel());
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

  /// The host's clipboard backend, asked once per connection and kept on it.
  /// Every caller in the meantime shares the one probe in flight.
  Future<HostClipboard> clipboardFor(ShellSession session) {
    final known = session.clipboard;
    if (known != null) return Future.value(known);
    final connection = session.connection;
    if (connection == null) {
      return Future.value(
        const HostClipboard(ClipboardBackend.none, reason: 'no shell'),
      );
    }
    return session._probing ??= _probe(session, connection);
  }

  Future<HostClipboard> _probe(
    ShellSession session,
    ShellConnection connection,
  ) async {
    final answer = await probeClipboard(connection);
    // An answer from a connection that has since gone belongs to nobody.
    if (session.connection == connection) {
      session.clipboard = answer;
      session._probing = null;
      notifyListeners();
    }
    return answer;
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

  Future<void> _connect(
    Host host,
    ShellSession session, {
    HostKeyPrompt? prompt,
    bool reconnected = false,
  }) async {
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
        verifier: HostKeyVerifier(
          pinned: _pinnedThisRun[host.id] ?? host.hostKey,
          // Null on a reconnect and on anything else that arrives without a
          // route in front of the user, which is what makes those refuse an
          // unpinned host instead of asking nobody.
          prompt: prompt,
          pin: (key) async {
            _pinnedThisRun[host.id] = key;
            await pinHostKey(host.id, key);
          },
        ),
      );
      if (attempt != session._attempt) {
        await connection.close();
        return;
      }
      session.connection = connection;
      session.clipboard = null;
      session._probing = null;
      session._columns = columns;
      session._rows = rows;
      session.state = const ShellLive();
      // Before the decoder is wired, so the marker is above the new shell's
      // first byte however fast the remote prints its prompt.
      if (reconnected) session.terminal.write(shellReconnectMarker);
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
      // A shell the user typed `exit` into is finished, and its tab holds
      // nothing they asked to keep. Every other code is the shell saying
      // something went wrong, so that tab stays for its output to be read.
      if (code == shellCleanExit) await close(session.host.id, session);
    } catch (error) {
      _fail(session, error, attempt);
    }
  }

  /// Anything the transport throws that is not a [ShellFailure] is the
  /// connection going away without a word for it.
  void _fail(ShellSession session, Object error, int attempt) {
    if (attempt != session._attempt) return;
    final kind = error is ShellFailure
        ? error.kind
        : ShellFailureKind.streamClosed;
    final was = session.state;
    final dropped = was is ShellDropped ? was.attempt : 0;
    // Every dial the link itself lost, the first one included: there is no
    // button for the user to press, so a host that was not there a second ago
    // is tried again rather than left on screen as a dead tab.
    if (shellReconnects(kind) && dropped < shellReconnectDelays.length) {
      _drop(session, dropped + 1);
      return;
    }
    session.state = ShellFailed(kind);
    notifyListeners();
  }

  /// Parks the schedule where the user stopped it. The session reads as a
  /// dropped link that gave up, which is what it is; the way back into a shell
  /// on this host is a new tab.
  void stopReconnect(ShellSession session) {
    if (session.state is! ShellDropped) return;
    session._attempt++;
    session._reconnect?.cancel();
    session._reconnect = null;
    session.state = const ShellFailed(ShellFailureKind.streamClosed);
    notifyListeners();
  }

  void _drop(ShellSession session, int attempt) {
    session.state = ShellDropped(attempt);
    notifyListeners();
    session._reconnect = Timer(
      shellReconnectDelays[attempt - 1],
      () => unawaited(_redial(session)),
    );
  }

  /// The dial at the end of a wait: a new shell in the tab that already has
  /// one, keeping its terminal, so what the dead shell printed is what the new
  /// one prints under. The state is left on [ShellDropped] across it, which is
  /// what keeps the header reading `RECONNECTING`.
  Future<void> _redial(ShellSession session) async {
    session._reconnect = null;
    if (session.state is! ShellDropped) return;
    // Bumped before anything closes: closing the old connection completes its
    // exit future, and an exit belonging to the attempt being replaced would
    // otherwise paint `EXITED` over the dial already under way.
    session._attempt++;
    // Not awaited, here or in [close]: a cancel takes effect the moment it is
    // called — nothing else arrives from that stream — and the future it hands
    // back belongs to the stream's own zone, which is not always one the
    // caller's is running.
    unawaited(session._output?.cancel());
    session._output = null;
    session._decoder = null;
    final previous = session.connection;
    session.connection = null;
    // The title belonged to the shell that died. A new one that never names
    // itself would otherwise be read under the old one's name.
    session.title = null;
    session.sticky.clear();
    notifyListeners();
    await previous?.close();
    // No prompt: nothing about a timer firing says the user is looking at the
    // route, so an unpinned host is refused here as it is anywhere else
    // unattended.
    if (session.state is! ShellDropped) return;
    await _connect(session.host, session, reconnected: true);
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
    pinHostKey: ref.watch(hostRepositoryProvider).pinHostKey,
    tabs: ref.watch(shellTabRepositoryProvider),
  );
});
