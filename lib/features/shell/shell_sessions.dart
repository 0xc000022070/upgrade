import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flterm/flterm.dart';

import '../../application/agent_kind.dart';
import '../../application/agent_input.dart';
import '../../application/agents.dart';
import '../../application/pin_alerts.dart';
import '../../application/providers.dart';
import '../../data/enums.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/shell_tab_repository.dart';
import '../../data/shell_snapshot_store.dart';
import '../../design/tokens.dart';
import '../../platform/herdr_client.dart';
import '../../platform/host_keys.dart';
import '../../platform/pin_notifications.dart';
import '../../platform/shell/host_clipboard.dart';
import '../../platform/shell/host_system.dart';
import '../../platform/shell/remote_shell.dart';
import '../../platform/shell/shell_connection.dart';
import '../../platform/shell/shell_launch.dart';
import '../../platform/shell/shell_tunnel.dart';
import '../../platform/shell/strip_bytes.dart';
import '../../platform/shell/udp_path.dart';
import '../../platform/workspace/workspace_commands.dart';
import '../../platform/vnc/keysyms.dart';
import 'private_osc.dart';
import 'shell_engine.dart';

/// A build log on the remote is the case this is sized for.
const shellScrollback = 10000;

/// The tab row numbers them `1`..`9`, and there is neither room nor reason for a tenth.
const maxShellSessions = 9;

sealed class ShellState {
  const ShellState();
}

final class ShellConnecting extends ShellState {
  const ShellConnecting();
}

final class ShellLive extends ShellState {
  const ShellLive([this.transport = ShellTransport.ssh]);

  final ShellTransport transport;
}

/// The transport still owns the remote session but has not received a current
/// acknowledgement. Mosh keeps probing and can recover without a new shell.
final class ShellReconnecting extends ShellState {
  const ShellReconnecting(this.transport);

  final ShellTransport transport;
}

/// The remote session may still exist, but the transport has missed enough
/// acknowledgements that Upgrade has no evidence of a usable connection.
final class ShellDisconnected extends ShellState {
  const ShellDisconnected(this.transport);

  final ShellTransport transport;
}

final class ShellExited extends ShellState {
  const ShellExited(this.code);

  /// Null when the channel closed without one.
  final int? code;
}

/// [attempt] counts from 1 and is what the header reads out.
final class ShellDropped extends ShellState {
  const ShellDropped(this.attempt);

  final int attempt;
}

final class ShellFailed extends ShellState {
  const ShellFailed(this.kind, {this.detail});

  final ShellFailureKind kind;

  /// Null when the failure was the app's own and there is nothing beneath the words.
  final String? detail;
}

/// The schedule is spent and nothing is on a clock. The terminal still holds what the
/// dead shell printed and the tab still carries the command and the pane it attaches to,
/// so the next wake comes back to the same agent rather than to a login. [kind] is what
/// the last dial hit, not the drop that started the schedule.
final class ShellWaiting extends ShellState {
  const ShellWaiting(this.kind, {this.detail});

  final ShellFailureKind kind;

  final String? detail;
}

/// A tab waiting reads under the header the same way a tab that failed does: the link is
/// equally gone, and the only difference is whether anything will dial again.
extension ShellStateFailure on ShellState {
  ({ShellFailureKind kind, String? detail})? get failure => switch (this) {
    ShellFailed(:final kind, :final detail) => (kind: kind, detail: detail),
    ShellWaiting(:final kind, :final detail) => (kind: kind, detail: detail),
    _ => null,
  };
}

extension ShellStateLink on ShellState {
  bool get holdsSession =>
      this is ShellLive ||
      this is ShellReconnecting ||
      this is ShellDisconnected;
}

/// The first two cover a wifi handover; the rest cover a lift ride and a tunnel, after
/// which a phone that still cannot see the host is somewhere the user knows about.
const shellReconnectDelays = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 10),
  Duration(seconds: 20),
  Duration(seconds: 30),
];

/// The network arriving and the resume behind it are one wake-up of the phone, so a second
/// rehome landing inside this of the first is the same moment asking twice.
const shellRehomeSettle = Duration(seconds: 1);

/// Written into the terminal above each new shell. A prompt appearing under a dead
/// shell's output with no mark between them is a lie about what happened, and the dim SGR
/// is what every other tool marks its own lines with.
const shellReconnectMarker = '\r\n\x1b[2m-- reconnected --\x1b[0m\r\n';

/// Turned off above each new shell. A link dropped under a mouse-reporting application
/// otherwise leaves the terminal reporting for as long as the session lives, because the
/// session outlives the connection on purpose and the terminal goes with it: every drag
/// is then forwarded as a wheel report to a shell that ignores it, and every tap is
/// swallowed the same way, so the terminal reads as dead to the touch until the app is
/// restarted. Mouse reporting in the three modes an application can ask for it, the
/// encoding it reports in, and bracketed paste.
const shellModeReset =
    '\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?2004l';

bool isViewReport(Uint8List bytes) {
  if (bytes.length < 3 || bytes[0] != 0x1b || bytes[1] != 0x5b) return false;
  final last = bytes.last;
  if (bytes.length == 3) return last == 0x49 || last == 0x4f;
  if (bytes[2] == 0x4d) return bytes.length == 6;
  return last == 0x4d || (bytes[2] == 0x3c && last == 0x6d);
}

const shellReattachMarker = '\r\n\x1b[2m-- reattached --\x1b[0m\r\n';
const shellRestoreMarker = '\r\n\x1b[2m-- session restored --\x1b[0m\r\n';

typedef VoiceDraft = ({AgentKind agent, String text});

bool clearsVoiceSendSuggestion(Uint8List bytes) => bytes.any(
  (byte) => switch (byte) {
    0x03 || 0x04 || 0x0a || 0x0d || 0x15 => true,
    _ => false,
  },
);

/// A tab that ends on it closes itself, and a tab that ends on anything else is put in
/// front of the user.
const shellCleanExit = 0;

/// An exit code is the user's own `exit`; a rejected key, a refused shell and both host
/// key failures are answers, and dialling again would only get the same one.
bool shellReconnects(ShellFailureKind kind) =>
    kind == ShellFailureKind.streamClosed ||
    kind == ShellFailureKind.unreachable;

/// The private OSC a host's `pinentry-gate` asks a terminal through, and tells it the
/// request was settled elsewhere. Either way the id comes next.
const pinentryOsc = '7771';

String? cwdFromOsc(String payload) {
  final trimmed = payload.trim();
  if (trimmed.startsWith('/')) return trimmed;
  final uri = Uri.tryParse(trimmed);
  if (uri == null || uri.scheme != 'file') return null;
  final segments = uri.pathSegments.where((segment) => segment.isNotEmpty);
  if (segments.isEmpty) return null;
  return '/${segments.join('/')}';
}

/// The fifo an answer is written into is guarded by the fifo being there, so a command
/// that comes back failed is proof the ask was down before the passphrase left the phone:
/// nothing was written and nothing is waiting on it. A channel that never came back is
/// the link going.
enum PinAnswer { sent, expired, lost }

/// A mark no other tab of this run carries, in the alphabet [shellMark] holds a mark to.
/// The clock gives it its uniqueness and the counter covers two tabs opened inside the
/// same microsecond.
int _marks = 0;
String _newMark() =>
    's${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
    '${(_marks++).toRadixString(36)}';

class ShellSession extends ChangeNotifier {
  ShellSession({
    required this.number,
    required TerminalController terminal,
    required this.host,
    this.remoteSession,
    String? mark,
  }) : mark = mark ?? _newMark(),
       _terminal = ValueNotifier(terminal);

  /// Mutable because the store is handed a fresh [Host] on every open and retry, and a
  /// reconnect fired by a timer has nobody to hand it one.
  Host host;

  /// Numbers are handed out in open order and never reused, so closing tab 2 leaves `1 3`
  /// rather than renumbering the tabs under the user's finger.
  final int number;

  /// The terminal and everything about it: grid, scrollback, selection and search. It
  /// outlives every view drawn of it, and a tab with no view still takes output.
  TerminalController get terminal => _terminal.value;

  ValueListenable<TerminalController> get terminals => _terminal;

  final ValueNotifier<TerminalController> _terminal;

  /// One per session and not one for the route: the view opens its text input when its node
  /// takes focus and closes it when the view goes, and two views handed the same node pass
  /// focus between them without a change of focus — the view that came in never sees one,
  /// never opens its input, and the node reads as focused over a keyboard that types into
  /// nothing.
  final FocusNode focusNode = FocusNode(debugLabel: 'shell-terminal');

  final TerminalScrollController scrollController = TerminalScrollController();

  final ValueNotifier<int> output = ValueNotifier(0);

  /// The host's own bytes, not [output], which also counts what the app writes. A tab
  /// restored on its saved screen starts painted.
  final ValueNotifier<bool> painted = ValueNotifier(false);

  bool get awaitingHost =>
      !painted.value && (state is ShellConnecting || state is ShellLive);

  bool get recovering => switch (state) {
    ShellDropped() || ShellReconnecting() || ShellDisconnected() => true,
    _ => false,
  };

  int get rowsBehind {
    final bar = terminal.scrollbar;
    return bar.total - bar.offset - bar.visible;
  }

  void followTail() => terminal.scrollToBottom();

  ShellConnection? connection;
  ShellState state = const ShellConnecting();

  /// For the tab's whole life, so a reconnect comes back to the same agent or the same
  /// directory rather than to a bare prompt. Null is a login shell.
  String? command;

  /// Seeded with the directory the tab was opened at and replaced by whatever the shell
  /// reports beside its prompt. Null on a tab opened at no directory whose shell never says
  /// where it went — which is why the host is asked as well.
  String? cwd;

  /// Null is both an answer the app has not got yet and a directory that is in no checkout
  /// at all, which is why the mark on the header is dimmed until the host has said
  /// otherwise.
  String? repository;

  /// What this tab's shell is marked with, so the host can be asked which of its processes
  /// is this tab and where that process is standing. One per session and never reused.
  final String mark;

  /// Stable identity for this tab. It marks the Mosh server so reconnect and cleanup affect
  /// only this tab. A Herdr tab's process identity stays in [pane].
  final String? remoteSession;

  /// [remoteSession] when the tab has one, the shell's own [mark] otherwise. The Mosh
  /// server is marked with it and a pinentry mark is looked up by it.
  String get tab => remoteSession ?? mark;

  /// Persisted beside the tab so a killed app attaches the same pane rather than opening a
  /// bare shell.
  PaneRef? pane;

  ShellLaunch? launch;

  /// What the bar has armed, waiting for the next key or character. It lives here rather
  /// than in the bar because the IME types straight into the terminal, where the bar is not
  /// in the path, and because switching tabs has to switch the armed set with the session.
  final Set<StickyModifier> sticky = <StickyModifier>{};

  /// One unless the bar's cell was dragged down. Moot while the arming is latched, which no
  /// key counts against.
  int stickyRepeat = 1;

  bool stickyLocked = false;

  /// Drops the arming whole. A count outliving the modifiers it belonged to would be spent
  /// on the next thing armed, and a latch outliving them would arm the next thing forever.
  void disarm() {
    sticky.clear();
    stickyRepeat = 1;
    stickyLocked = false;
  }

  /// Null until it says, which a bare `sh` never does.
  String? title;

  VoiceDraft? voiceDraft;
  bool voiceSendSuggested = false;
  final agentInput = AgentInputActivity();
  bool typedSendReady = false;
  AgentKind? probedAgent;
  bool engineForegroundKnown = false;
  AgentKind? engineAgent;
  Timer? _agentInputTimer;
  var _agentInputEpoch = 0;
  var _agentProbeInFlight = false;

  StreamSubscription<String>? _foregroundProcesses;

  void setEngineForeground(AgentKind? agent) {
    if (engineForegroundKnown && engineAgent?.name == agent?.name) return;
    engineForegroundKnown = true;
    engineAgent = agent;
    changed();
  }

  void clearEngineForeground() {
    if (!engineForegroundKnown && engineAgent == null) return;
    engineForegroundKnown = false;
    engineAgent = null;
    changed();
  }

  int get agentInputRevision => _agentInputEpoch;

  void observeAgentInput(
    Uint8List bytes,
    Future<AgentKind?> Function()? probe,
  ) {
    final wasReady = typedSendReady || probedAgent != null;
    _agentInputTimer?.cancel();
    _agentInputEpoch++;
    agentInput.observe(bytes);
    typedSendReady = false;
    probedAgent = null;
    if (agentInput.hasText && state is ShellLive) {
      final epoch = _agentInputEpoch;
      _agentInputTimer = Timer(agentInputPause, () {
        if (_retired || state is! ShellLive || epoch != _agentInputEpoch) {
          return;
        }
        typedSendReady = true;
        changed();
        if (probe != null) unawaited(_probeAgentInput(probe));
      });
    }
    if (wasReady) changed();
  }

  Future<void> _probeAgentInput(Future<AgentKind?> Function() probe) async {
    if (_agentProbeInFlight) return;
    _agentProbeInFlight = true;
    try {
      while (!_retired &&
          state is ShellLive &&
          typedSendReady &&
          agentInput.hasText) {
        final epoch = _agentInputEpoch;
        final agent = await probe();
        if (_retired || state is! ShellLive) return;
        if (epoch != _agentInputEpoch) continue;
        probedAgent = agent;
        changed();
        return;
      }
    } finally {
      _agentProbeInFlight = false;
    }
  }

  void clearAgentInput() {
    final wasReady = typedSendReady || probedAgent != null;
    _agentInputTimer?.cancel();
    _agentInputTimer = null;
    _agentInputEpoch++;
    agentInput.clear();
    typedSendReady = false;
    probedAgent = null;
    if (wasReady) changed();
  }

  /// Set by the OSC, cleared by the answer, by `done`, and by the link going: a request
  /// outlives none of the connection it arrived on.
  PinRequest? pin;
  var _asking = false;
  var _askAgain = false;
  Timer? _reask;

  void _stopAsking() {
    _reask?.cancel();
    _reask = null;
  }

  /// Null until asked, and dropped with the connection: the answer is about the desktop
  /// session the shell landed in, and a reconnect may land elsewhere.
  HostClipboard? clipboard;
  Future<HostClipboard>? _probing;

  /// Cancelled and dropped on every close and every retry: a stale listener would write a
  /// dead connection's bytes into a live terminal.
  StreamSubscription<Uint8List>? _output;
  StreamSubscription<Uint8List>? _snapshots;
  StreamSubscription<ShellConnectionHealth>? _health;
  StreamSubscription<bool>? _control;

  /// Live terminal, host not held: background reads are stale and the next gesture dials.
  bool controlStale = false;

  String? controlFailure;

  void _unwatch() {
    unawaited(_health?.cancel());
    _health = null;
    unawaited(_control?.cancel());
    _control = null;
    controlStale = false;
    controlFailure = null;
  }

  /// Watches the channel for the pinentry's OSC on its way into the terminal. Null
  /// between connections, so a dead one's bytes are not read for a request.
  PrivateOscScanner? _pinentry;

  bool _feeding = false;

  bool _moshPane = false;

  static final _moshPaneMouse = utf8.encode('\x1b[?1002h\x1b[?1006h');

  void _feed(Uint8List bytes) {
    _pinentry?.add(bytes);
    _feeding = true;
    try {
      terminal.write(bytes);
      if (_moshPane && terminal.mouseTracking == MouseTracking.none) {
        terminal.write(_moshPaneMouse);
      }
    } finally {
      _feeding = false;
    }
    output.value++;
  }

  void _write(String text) => _feed(utf8.encode(text));

  /// The last size sent to the remote, so a resize that changes nothing is not forwarded.
  /// The view reports on every layout, including ones where only the pixel size moved.
  int? _columns;
  int? _rows;

  int _cellWidthPx = 0;
  int _cellHeightPx = 0;

  void measuredCell(int widthPx, int heightPx) {
    if (widthPx == _cellWidthPx && heightPx == _cellHeightPx) return;
    _cellWidthPx = widthPx;
    _cellHeightPx = heightPx;
    final columns = _columns;
    final rows = _rows;
    final link = connection;
    if (link == null || link.transport != ShellTransport.engine) return;
    if (columns != null && rows != null) {
      link.resize(
        columns,
        rows,
        widthPx: columns * widthPx,
        heightPx: rows * heightPx,
      );
    }
  }

  String? _heldMarker;

  /// Held across the waits between dials: a schedule that runs out shows what the last one
  /// hit, not the drop that started it.
  String? _detail;

  /// Taken by every dial that starts and by everything that ends one, so whatever it
  /// replaced goes quiet.
  late _Attempt _attempt = _Attempt._(this);

  /// Set once, by [close]. A closed tab hands its claim to nothing and refuses to hand out
  /// another.
  bool _closed = false;

  /// Only the claim handed back may write state onto this session, and only until the next
  /// call.
  _Attempt _claim() => _attempt = _Attempt._(this);

  /// Takes the tab from whatever dial holds it without giving it to another, so everything
  /// in flight goes quiet and nothing lands until the next dial claims it.
  void _disown() => _claim();

  /// Cancelled by `STOP`, by a retry and by the tab closing, all three of which are the
  /// user deciding what happens next instead of the schedule.
  Timer? _reconnect;
  DateTime? _due;

  bool _rehoming = false;
  bool _rehomeNetwork = false;
  NetworkChanged? _networkOwed;
  Timer? _rehomed;

  bool _retired = false;

  ShellConnection? _asleep;

  DateTime? _unsavedSince;
  Timer? _save;
  Future<void> _saved = Future.value();

  /// What a view left behind on the terminal — a mark, an anchor — is released with the
  /// buffer and must not be released again through a listenable that is gone.
  bool get retired => _retired;

  /// Lets go of what the view is handed rather than makes, the terminal last. Called at
  /// the end of the frame the tab was dropped in, never inside it: a controller disposed
  /// while its view is still attached fails the detach that view is about to be asked for.
  @override
  void dispose() {
    if (_retired) return;
    _retired = true;
    clearAgentInput();
    unawaited(_foregroundProcesses?.cancel());
    _foregroundProcesses = null;
    clearEngineForeground();
    _save?.cancel();
    focusNode.dispose();
    scrollController.dispose();
    output.dispose();
    painted.dispose();
    terminal.dispose();
    _terminal.dispose();
    super.dispose();
  }

  /// None of what a session reports is a fact about the set of tabs, so none of it goes to
  /// the store. Silent once retired: a probe or a title that lands after the tab closed has
  /// nobody left to tell, and the notifier it would tell is disposed.
  void changed() {
    if (_retired) return;
    notifyListeners();
  }
}

/// One dial's claim on its tab. A counter did the same arithmetic, but a number carries
/// no trace of the tab it belongs to — one session's compares equal to another's — and it
/// cannot say that a tab is closed: a dial that took the next number after a close made
/// itself current again and opened a connection nothing was left to close.
class _Attempt {
  _Attempt._(this._session);

  final ShellSession _session;

  bool get isCurrent => !_session._closed && identical(_session._attempt, this);
}

/// Held by a provider that is never disposed, because the sessions are the point: leaving
/// `/ NYX SHELL` and coming back finds the tabs where they were, still running. The route
/// disposing closes nothing.
class ShellSessions extends ChangeNotifier {
  ShellSessions({
    required this.readPrivateKey,
    required this.pinHostKey,
    this.recordSystem,
    this.tabs,
    this.snapshots,
    this.snapshotQuiet = const Duration(seconds: 5),
    this.snapshotCeiling = const Duration(minutes: 1),
    this.sleepGrace = const Duration(seconds: 10),
    ShellOpener? open,
    this.pinRecheck = const Duration(seconds: 5),
    this.pinStale = const Duration(minutes: 5),
    this.pinAnswerWait = const Duration(seconds: 5),
    this.notifier,
    this.now = DateTime.now,
    UdpVerdicts? udpVerdicts,
  }) : _override = open,
       udpVerdicts = udpVerdicts ?? UdpVerdicts();

  final PinNotifier? notifier;

  final DateTime Function() now;

  late final PinShade _shade = PinShade(notifier);

  final Duration pinRecheck;

  /// The pinentry's own default window, which the phone cannot read and does not claim is
  /// the one in force.
  final Duration pinStale;

  /// A fifo left behind by a pinentry that died still passes the answer command's `[ -p ]`
  /// guard, and the write then blocks for as long as the connection lives, since the reader
  /// it waits for is dead.
  final Duration pinAnswerWait;

  final Future<String?> Function(String keyId) readPrivateKey;

  final Future<void> Function(String hostId, PinnedHostKey key) pinHostKey;

  final Future<void> Function(String hostId, HostSystem system)? recordSystem;

  final _systemAsked = <String>{};
  final _answering = <String>{};

  /// Injectable only so the store can be driven without a host to answer it; null
  /// everywhere but a test.
  final ShellOpener? _override;

  late final ShellOpener _open =
      _override ?? ShellTunnel(udpVerdicts: udpVerdicts).open;

  final UdpVerdicts udpVerdicts;

  /// Where the open tabs are written down, so a process that is killed can be dialled back
  /// into the shells it had.
  final ShellTabRepository? tabs;

  final ShellSnapshotStore? snapshots;

  final Duration snapshotQuiet;

  final Duration snapshotCeiling;

  final Duration sleepGrace;

  bool _away = false;
  bool _sleeping = false;
  PlatformSignal? _leftOn;
  Timer? _sleep;

  final _byHost = <String, List<ShellSession>>{};

  /// Separate from the session list because closing every tab must not restart the
  /// numbering while the user is still on the route.
  final _nextNumber = <String, int>{};

  final _active = <String, int>{};

  String? _parkedHostId;

  /// The [Host] a route hands in was read before the sheet said `TRUST`, so without this
  /// the second tab on the same host would ask about the same key again while the hosts
  /// stream catches up.
  final _pinnedThisRun = <String, PinnedHostKey>{};

  bool _restored = false;

  /// How many sheets are up. Nothing is woken while this is above zero.
  int _held = 0;

  List<ShellSession> forHost(String hostId) =>
      List.unmodifiable(_byHost[hostId] ?? const <ShellSession>[]);

  ShellSession? activeFor(String hostId) {
    final sessions = _byHost[hostId];
    if (sessions == null || sessions.isEmpty) return null;
    final number = _active[hostId];
    for (final session in sessions) {
      if (session.number == number) return session;
    }
    return sessions.last;
  }

  ShellSession? get parked {
    final named = activeFor(_parkedHostId ?? '');
    if (named != null) return named;
    for (final hostId in _byHost.keys.toList().reversed) {
      final fallback = activeFor(hostId);
      if (fallback != null) return fallback;
    }
    return null;
  }

  List<(Host, List<ShellSession>)> get openHosts => [
    for (final sessions in _byHost.values)
      if (sessions.isNotEmpty)
        (sessions.first.host, List.unmodifiable(sessions)),
  ];

  int get openCount =>
      _byHost.values.fold(0, (total, sessions) => total + sessions.length);

  void activate(String hostId, ShellSession session) {
    _active[hostId] = session.number;
    _parkedHostId = hostId;
    notifyListeners();
    unawaited(tabs?.activate(hostId, session.number));
  }

  final _folded = <String>{};

  bool isFolded(String hostId) => _folded.contains(hostId);

  void fold(String hostId, {required bool folded}) {
    if (!(folded ? _folded.add(hostId) : _folded.remove(hostId))) return;
    notifyListeners();
  }

  void moveTab(String hostId, int from, int to) {
    final sessions = _byHost[hostId];
    if (sessions == null || from == to) return;
    sessions.insert(to, sessions.removeAt(from));
    _placed();
  }

  void moveGroup(int from, int to) {
    final groups = _byHost.entries.toList();
    if (from == to) return;
    groups.insert(to, groups.removeAt(from));
    _byHost
      ..clear()
      ..addEntries(groups);
    _placed();
  }

  void _placed() {
    notifyListeners();
    unawaited(
      tabs?.order([
        for (final MapEntry(key: hostId, value: sessions) in _byHost.entries)
          for (final session in sessions) (hostId, session.number),
      ]),
    );
  }

  bool canOpen(String hostId) =>
      (_byHost[hostId]?.length ?? 0) < maxShellSessions;

  /// Runs on a second channel of the connection the tab already holds, so the shell on the
  /// pty sees none of it and the user's own line is not disturbed. A tab attached to a
  /// Herdr pane is asked for that pane instead: the attach client stands where it started,
  /// and the shell that has walked elsewhere belongs to the Herdr server rather than to
  /// this connection's process tree. Null when there is no connection to ask on, or when
  /// the host has no `/proc` to answer from.
  Future<String?> cwdFromHost(ShellSession session) async {
    final connection = session.connection;
    if (connection == null) return null;
    try {
      final pane = session.pane;
      var herdrSession = pane?.session;
      String? answer;
      if (herdrSession == null) {
        final probe = await connection.channels.exec(
          shellCwdProbe(session.mark),
        );
        if (probe == null || probe.exitCode != 0) return null;
        final place = parseShellPlace(probe.out);
        herdrSession = place.herdrSession;
        answer = place.cwd;
      }
      if (herdrSession != null && HerdrCommands.isSessionName(herdrSession)) {
        final panes = await connection.channels.exec(
          HerdrCommands.panes(herdrSession),
        );
        if (panes != null && panes.exitCode == 0) {
          answer = HerdrClient.parsePaneCwd(panes.out, pane?.pane) ?? answer;
        }
      }
      if (answer == null || !answer.startsWith('/')) return null;
      if (answer != session.cwd) {
        session.cwd = answer;
        session.changed();
      }
      return answer;
    } on HerdrFailure catch (error) {
      debugPrint(
        'upgrade.shell ${session.host.name}: ${error.detail ?? error}',
      );
      return null;
    }
  }

  Future<AgentKind?> agentFromHost(ShellSession session) async {
    final connection = session.connection;
    if (connection == null || session.state is! ShellLive) return null;
    if (connection.transport == ShellTransport.engine &&
        session.engineForegroundKnown) {
      return session.engineAgent;
    }
    try {
      final result = await connection.channels.exec(
        shellForegroundProcessProbe(session.mark),
        timeout: const Duration(seconds: 3),
      );
      if (result == null ||
          result.exitCode != 0 ||
          session.retired ||
          session.state is! ShellLive ||
          !identical(session.connection, connection)) {
        return null;
      }
      return foregroundAgent(result.out);
    } catch (error) {
      if (!isHostFailure(error) && !isKeyFailure(error)) rethrow;
      debugPrint(
        'upgrade.shell ${session.host.name}: foreground probe: $error',
      );
      return null;
    }
  }

  Future<AgentKind?> agentFromPane(ShellSession session) async {
    final connection = session.connection;
    final pane = session.pane;
    if (connection == null || pane == null || session.state is! ShellLive) {
      return null;
    }
    try {
      final result = await connection.channels.exec(
        HerdrCommands.agents(pane.session),
        timeout: const Duration(seconds: 3),
      );
      if (result == null ||
          result.exitCode != 0 ||
          session.retired ||
          session.state is! ShellLive ||
          !identical(session.connection, connection) ||
          session.pane != pane) {
        return null;
      }
      final agents = HerdrClient.parseCliAgentList(
        result.out,
        session: pane.session,
      );
      for (final agent in agents) {
        if (agent.paneId == pane.pane) return AgentKind.lookup(agent.agent);
      }
    } catch (error) {
      if (!isHostFailure(error) && !isKeyFailure(error)) rethrow;
      debugPrint('upgrade.shell ${session.host.name}: pane agents: $error');
      return null;
    }
    return null;
  }

  /// Where the shell is, then what repository that is part of. Null leaves the mark dimmed.
  Future<String?> repositoryFromHost(ShellSession session) async {
    final connection = session.connection;
    if (connection == null) return null;
    final directory = await cwdFromHost(session) ?? session.cwd;
    if (directory == null) return _repository(session, null);
    final result = await connection.channels.exec(
      WorkspaceCommands.repository(directory),
    );
    final top = result?.out.trim() ?? '';
    if (result == null || result.exitCode != 0 || !top.startsWith('/')) {
      return _repository(session, null);
    }
    return _repository(session, top);
  }

  String? _repository(ShellSession session, String? repository) {
    if (session.repository != repository) {
      session.repository = repository;
      session.changed();
    }
    return repository;
  }

  ShellSession? holding(String hostId, PaneRef pane) {
    for (final session in forHost(hostId)) {
      if (session.pane == pane) return session;
    }
    return null;
  }

  /// The `+` cell is gone at nine, so the refusal here is a guard rather than a path the
  /// user can walk.
  ShellSession? open(
    Host host, {
    required UserIntent intent,
    HostKeyPrompt? prompt,
    String? command,
    String? directory,
    PaneRef? pane,
    ShellLaunch? launch,
  }) {
    if (!canOpen(host.id)) return null;
    final number = _nextNumber[host.id] ?? 1;
    _nextNumber[host.id] = number + 1;
    final remoteSession = _newMark();
    final persisted = tabs?.open(
      host.id,
      number,
      remoteSession: remoteSession,
      herdrSession: pane?.session,
      herdrPane: pane?.pane,
      launch: launch?.tag,
    );
    return _start(
      host,
      number,
      reason: UserAction(intent),
      prompt: prompt,
      command: command ?? launch?.command,
      directory: directory,
      pane: pane,
      launch: launch,
      remoteSession: remoteSession,
      beforeConnect: persisted,
    );
  }

  ShellSession _start(
    Host host,
    int number, {
    required OpenReason reason,
    HostKeyPrompt? prompt,
    String? command,
    String? directory,
    PaneRef? pane,
    ShellLaunch? launch,
    String? remoteSession,
    bool restored = false,
    Future<void>? beforeConnect,
    Uint8List? snapshot,
  }) {
    final session =
        ShellSession(
            number: number,
            terminal: _terminal(host.id, number, snapshot),
            host: host,
            remoteSession: remoteSession,
            mark: remoteSession,
          )
          ..command = command
          ..cwd = directory
          ..pane = pane
          ..launch = launch;
    session.painted.value = snapshot != null;
    answerInColours(session.terminal, UpgradeTokens.house.terminal);
    _byHost.putIfAbsent(host.id, () => []).add(session);
    _active[host.id] = number;
    _parkedHostId = host.id;
    _wireTerminal(session);
    session.output.addListener(() => _outputWhileAway(session));
    notifyListeners();
    unawaited(
      _connectAfterPersistence(
        host,
        session,
        reason: reason,
        prompt: prompt,
        restored: restored,
        persistence: beforeConnect,
      ),
    );
    return session;
  }

  TerminalController _terminal(String hostId, int number, Uint8List? snapshot) {
    if (snapshot != null) {
      try {
        final terminal = TerminalController.fromSnapshot(snapshot);
        unawaited(
          terminal.restored.then(
            (_) {},
            onError: (Object error) {
              if (terminal.restoration != RestorationState.failed) return;
              debugPrint('upgrade.shell snapshot $hostId/$number: $error');
              unawaited(snapshots?.drop(hostId, number));
            },
          ),
        );
        return terminal;
      } catch (error) {
        debugPrint('upgrade.shell snapshot $hostId/$number: $error');
        unawaited(snapshots?.drop(hostId, number));
      }
    }
    return TerminalController(
      config: const TerminalConfig(
        scrollbackMaxBytes: null,
        scrollbackMaxLines: shellScrollback,
      ),
    );
  }

  void _replaceTerminal(ShellSession session, Uint8List bytes) {
    if (session._closed || session.retired) return;
    final TerminalController next;
    try {
      next = TerminalController.fromSnapshot(
        bytes,
        preserveSnapshotColors: false,
      );
    } catch (error) {
      debugPrint('upgrade.shell ${session.host.name}: host snapshot: $error');
      return;
    }
    unawaited(
      next.restored.then(
        (_) {},
        onError: (Object error) => debugPrint(
          'upgrade.shell ${session.host.name}: host snapshot: $error',
        ),
      ),
    );
    final previous = session.terminal
      ..onOutput = null
      ..onTitleChanged = null
      ..onBell = null
      ..onPwdChanged = null
      ..onResize = null;
    answerInColours(next, UpgradeTokens.house.terminal);
    session._terminal.value = next;
    _wireTerminal(session);
    final marker = session._heldMarker;
    session._heldMarker = null;
    if (marker != null) session._write(marker);
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => previous.dispose())
      ..ensureVisualUpdate();
    session.painted.value = true;
    session.output.value++;
  }

  void leave(PlatformSignal signal) {
    _away = true;
    _leftOn = signal;
    for (final sessions in _byHost.values) {
      for (final session in sessions) {
        _saveScreen(session);
      }
    }
    _sleep?.cancel();
    _sleep = Timer(sleepGrace, _fallAsleep);
  }

  void returned(PlatformSignal signal) {
    _away = false;
    _sleeping = false;
    _leftOn = null;
    _sleep?.cancel();
    _sleep = null;
    for (final sessions in _byHost.values) {
      for (final session in sessions) {
        session._save?.cancel();
        session._save = null;
        _wakeUp(session, AppResumed(signal));
      }
    }
  }

  void _fallAsleep() {
    _sleep = null;
    if (!_away) return;
    _sleeping = true;
    for (final sessions in _byHost.values) {
      for (final session in sessions) {
        _suspend(session);
      }
    }
  }

  void _suspend(ShellSession session) {
    final connection = session.connection;
    final signal = _leftOn;
    if (connection == null ||
        signal == null ||
        session._closed ||
        !session.state.holdsSession ||
        identical(session._asleep, connection)) {
      return;
    }
    if (session._unsavedSince != null) _saveScreen(session);
    session._asleep = connection;
    session._stopAsking();
    unawaited(
      connection.suspend(AppSuspended(signal)).catchError((Object error) {
        debugPrint('upgrade.shell ${session.host.name}: suspend: $error');
      }),
    );
  }

  /// Asks pinentry only after the resume reopens the host; before it nothing answers.
  void _wakeUp(ShellSession session, AppResumed reason) {
    final connection = session._asleep;
    session._asleep = null;
    if (connection == null ||
        session._closed ||
        !identical(session.connection, connection)) {
      return;
    }
    session._rehomed?.cancel();
    session._rehomed = Timer(shellRehomeSettle, () => session._rehomed = null);
    unawaited(
      connection
          .resume(reason)
          .catchError((Object error) {
            debugPrint('upgrade.shell ${session.host.name}: resume: $error');
          })
          .then((_) => _askHost(session)),
    );
  }

  void _outputWhileAway(ShellSession session) {
    if (!_away || snapshots == null || session._closed) return;
    final since = session._unsavedSince ??= now();
    session._save?.cancel();
    session._save = Timer(
      now().difference(since) >= snapshotCeiling
          ? Duration.zero
          : snapshotQuiet,
      () => _saveScreen(session),
    );
  }

  void _saveScreen(ShellSession session) {
    final store = snapshots;
    session._save?.cancel();
    session._save = null;
    if (store == null || session._closed || session.retired) return;
    // Older scrollback is still loading, and a snapshot now would keep only what has.
    if (session.terminal.restoration == RestorationState.restoring) return;
    final Uint8List bytes;
    try {
      bytes = session.terminal.snapshot();
    } catch (error) {
      debugPrint('upgrade.shell ${session.host.name}: snapshot: $error');
      return;
    }
    session._unsavedSince = null;
    final hostId = session.host.id;
    session._saved = session._saved.then((_) async {
      if (session._closed) return;
      try {
        await store.write(hostId, session.number, bytes);
      } catch (error) {
        debugPrint('upgrade.shell ${session.host.name}: snapshot: $error');
      }
    });
  }

  Future<void> _connectAfterPersistence(
    Host host,
    ShellSession session, {
    required OpenReason reason,
    required bool restored,
    HostKeyPrompt? prompt,
    Future<void>? persistence,
  }) async {
    try {
      await persistence;
    } catch (error) {
      debugPrint('upgrade.shell ${host.name}: tab save failed: $error');
      if (!session._closed) {
        session.state = ShellFailed(
          ShellFailureKind.streamClosed,
          detail: 'tab save failed: $error',
        );
        session.changed();
      }
      return;
    }
    if (session._closed) {
      await tabs?.close(host.id, session.number);
      return;
    }
    await _connect(
      host,
      session,
      reason: reason,
      prompt: prompt,
      restored: restored,
    );
  }

  /// Reopens the tabs the last run left behind and dials each one. A tab with a remote
  /// session attaches to it; an agent tab reconstructs the attach command from its
  /// validated Herdr session and pane; older rows open a fresh shell because they recorded
  /// neither identity. Unattended, so a host whose key was never pinned is refused here
  /// rather than asking a user who is still looking at the boot log. Runs once: a second
  /// call over live tabs would dial a second shell into every one of them.
  Future<int> restore(
    Future<List<Host>> Function() readHosts,
    AppResumed reason,
  ) async {
    final store = tabs;
    if (store == null || _restored) return 0;
    _restored = true;
    final rows = await store.all();
    if (rows.isEmpty) {
      await snapshots?.keepOnly(const {});
      return 0;
    }
    final kept = <(String, int)>{};
    final hosts = {for (final host in await readHosts()) host.id: host};
    var restored = 0;
    for (final row in rows) {
      final host = hosts[row.hostId];
      // The host was deleted while the app was down. There is no longer an address to
      // dial, and the row would outlive every run.
      if (host == null) {
        unawaited(store.close(row.hostId, row.number));
        continue;
      }
      final remoteSession = row.remoteSession;
      final hasHerdrIdentity =
          row.herdrSession != null || row.herdrPane != null;
      final pane = row.herdrSession != null && row.herdrPane != null
          ? (session: row.herdrSession!, pane: row.herdrPane!)
          : null;
      final launch = ShellLaunch.parse(row.launch);
      if ((remoteSession != null &&
              !durableShellSession.hasMatch(remoteSession)) ||
          (hasHerdrIdentity && (pane == null || !HerdrCommands.isPane(pane))) ||
          (row.launch != null && launch == null)) {
        await store.close(row.hostId, row.number);
        continue;
      }
      final next = _nextNumber[host.id] ?? 1;
      if (row.number >= next) _nextNumber[host.id] = row.number + 1;
      kept.add((host.id, row.number));
      _start(
        host,
        row.number,
        reason: reason,
        command: pane == null ? launch?.command : HerdrCommands.attach(pane),
        pane: pane,
        launch: launch,
        remoteSession: remoteSession,
        restored: true,
        snapshot: await snapshots?.read(host.id, row.number),
      );
      restored++;
    }
    await snapshots?.keepOnly(kept);
    // [_start] leaves the last tab opened active, which is the right answer only for
    // the host whose tab was on screen.
    for (final row in rows.where((row) => row.active)) {
      if (!hosts.containsKey(row.hostId)) continue;
      _active[row.hostId] = row.number;
      _parkedHostId = row.hostId;
    }
    notifyListeners();
    return restored;
  }

  Future<void> close(
    String hostId,
    ShellSession session, {
    required UserIntent intent,
  }) => _close(hostId, session, UserClosed(intent), action: UserAction(intent));

  /// Without an [action] a cleanly exited shell closes its tab with its own [ShellEnded].
  Future<void> _close(
    String hostId,
    ShellSession session,
    DropReason reason, {
    UserAction? action,
  }) async {
    // Taken for good, so neither the exit, nor the output stream of the connection
    // being closed, nor a dial the reconnect schedule is part way through can write
    // onto a session that is already gone.
    session._closed = true;
    session._disown();
    session._reconnect?.cancel();
    session._reconnect = null;
    session._rehomed?.cancel();
    session._rehomed = null;
    session._save?.cancel();
    session._stopAsking();
    session.disarm();
    _byHost[hostId]?.remove(session);
    if (_byHost[hostId]?.isEmpty ?? false) {
      _byHost.remove(hostId);
      _folded.remove(hostId);
    }
    unawaited(
      session._saved.then((_) => snapshots?.drop(hostId, session.number)),
    );
    _tellShade(session.host);
    if (_active[hostId] == session.number) {
      final rest = _byHost[hostId];
      if (rest != null && rest.isNotEmpty) {
        _active[hostId] = rest.last.number;
        unawaited(tabs?.activate(hostId, rest.last.number));
      }
    }
    notifyListeners();
    unawaited(session._output?.cancel());
    session._output = null;
    unawaited(session._snapshots?.cancel());
    session._snapshots = null;
    unawaited(session._foregroundProcesses?.cancel());
    session._foregroundProcesses = null;
    session._unwatch();
    session._pinentry = null;
    _retire(session);
    final connection = session.connection;
    session.connection = null;
    final remoteSession = session.remoteSession;
    if (remoteSession == null) {
      await tabs?.close(hostId, session.number);
      await connection?.close(reason);
      return;
    }
    await tabs?.retire(hostId, session.number);
    var terminated = false;
    try {
      terminated =
          await connection?.terminateRemote(
            remoteSession,
            durableShell: false,
            action: action,
          ) ??
          false;
    } catch (error) {
      debugPrint('upgrade.shell ${session.host.name}: cleanup failed: $error');
    } finally {
      await connection?.close(reason);
    }
    if (terminated) await tabs?.close(hostId, session.number);
  }

  /// Drops the session's controllers once the frame that removed its view has run.
  /// [notifyListeners] is what takes the view out of the tree, and until that rebuild
  /// happens the view is still attached to them.
  void _retire(ShellSession session) {
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => session.dispose())
      // A close nothing else is watching would otherwise leave the callback waiting
      // for a frame that has no reason to come.
      ..ensureVisualUpdate();
  }

  /// Wired before the connection exists so a fast typist's bytes are not dropped between
  /// the tab appearing and the shell answering.
  void _wireTerminal(ShellSession session) {
    final terminal = session.terminal;
    terminal.onOutput = (bytes) {
      if (session._feeding || isViewReport(bytes)) {
        session.connection?.write(bytes);
        return;
      }
      // Everything the user puts in comes through here: the IME's characters, the
      // terminal's own key handling, and a paste. Which is why the armed set is
      // applied and spent here and not where the bar is.
      send(
        session,
        session.sticky.isEmpty
            ? bytes
            : typedBytes(
                utf8.decode(bytes, allowMalformed: true),
                session.sticky,
              ),
      );
    };
    terminal.onTitleChanged = () {
      final title = terminal.title;
      if (title == session.title) return;
      session.title = title;
      session.changed();
    };
    terminal.onBell = () => unawaited(_askHost(session));
    terminal.onPwdChanged = () {
      final cwd = cwdFromOsc(terminal.pwd);
      if (cwd == null || cwd == session.cwd) return;
      session.cwd = cwd;
      session.changed();
    };
    terminal.onResize = (columns, rows) {
      if (columns == session._columns && rows == session._rows) return;
      session._columns = columns;
      session._rows = rows;
      session.connection?.resize(
        columns,
        rows,
        widthPx: columns * session._cellWidthPx,
        heightPx: rows * session._cellHeightPx,
      );
    };
  }

  void _onPinentry(ShellSession session, List<String> args) {
    if (args.length < 2) return;
    switch (args.first) {
      case 'pin' when args.length >= 3:
        final request = PinRequest.decode(args[1], args[2]);
        if (request == null) return;
        _setPin(session, request);
      case 'done':
        if (session.pin?.id != args[1]) return;
        _setPin(session, null);
    }
  }

  /// The armed set is spent here and nowhere else, at the single point every byte passes
  /// through, so the bar's own keys and the characters the IME types straight into the
  /// terminal count the same.
  void send(ShellSession session, Uint8List bytes) {
    if (bytes.isNotEmpty) {
      if (session.state is ShellLive && session.connection != null) {
        session.observeAgentInput(
          bytes,
          session.pane == null ? () => agentFromHost(session) : null,
        );
      } else {
        session.clearAgentInput();
      }
      if (session.voiceSendSuggested && clearsVoiceSendSuggestion(bytes)) {
        session.voiceSendSuggested = false;
        session.changed();
      }
      // A key is not a read: the bar's bytes never pass the view, so a shell asked
      // for something from up in the scrollback would answer off the screen.
      session.followTail();
      session.connection?.write(bytes);
    }
    if (session.sticky.isEmpty) return;
    // A latched arming is not spent, only released: the whole point of holding a
    // modifier down is that the keys under it do not use it up.
    if (session.stickyLocked) return;
    if (session.stickyRepeat > 1) {
      session.stickyRepeat--;
    } else {
      session.disarm();
    }
    session.changed();
  }

  void _learnSystem(Host host, ShellConnection connection) {
    final record = recordSystem;
    if (record == null || !_systemAsked.add(host.id)) return;
    unawaited(() async {
      final HostSystem? system;
      try {
        system = await probeSystem(connection.channels);
      } catch (error) {
        if (!isHostFailure(error) && !isKeyFailure(error)) rethrow;
        debugPrint('upgrade.shell ${host.name}: system probe: $error');
        _systemAsked.remove(host.id);
        return;
      }
      if (system == null) {
        _systemAsked.remove(host.id);
        return;
      }
      if (system != host.system) await record(host.id, system);
    }());
  }

  /// Asked once per connection and kept on it. Every caller in the meantime shares the one
  /// probe in flight.
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
    final HostClipboard? answer;
    try {
      answer = await probeClipboard(connection.channels);
    } catch (error) {
      if (session.connection == connection) session._probing = null;
      if (!isHostFailure(error) && !isKeyFailure(error)) rethrow;
      debugPrint('upgrade.shell ${session.host.name}: clipboard probe: $error');
      return const HostClipboard(ClipboardBackend.none, reason: 'exec refused');
    }
    if (answer == null) {
      // No host held, so nothing was asked: the next caller asks again.
      if (session.connection == connection) session._probing = null;
      return const HostClipboard(ClipboardBackend.none, reason: 'no host');
    }
    // An answer from a connection that has since gone belongs to nobody.
    if (session.connection == connection) {
      session.clipboard = answer;
      session._probing = null;
      session.changed();
    }
    return answer;
  }

  /// Replaces the set rather than merging: the bar draws the whole of what is armed and
  /// hands back the whole of it, the count and the latch included.
  void arm(
    ShellSession session,
    Set<StickyModifier> sticky, {
    int repeat = 1,
    bool locked = false,
  }) {
    session.sticky
      ..clear()
      ..addAll(sticky);
    session.stickyRepeat = sticky.isEmpty ? 1 : repeat;
    session.stickyLocked = sticky.isNotEmpty && locked;
    session.changed();
  }

  /// Tells the host's pinentry that this tab's pty is a place to ask. On the tab's own
  /// connection, so the channel's parent is the sshd session an ssh shell hangs off, and
  /// with the tab's mark, which is how a Mosh shell's server is found. A host without the
  /// pinentry gets a directory nobody reads, and a host whose process table disagrees gets
  /// nothing.
  Future<void> _mark(ShellSession session, ShellConnection connection) async {
    try {
      await connection.channels.exec(pinentryMarkCommand(session.tab));
    } catch (error) {
      if (!isHostFailure(error) && !isKeyFailure(error)) rethrow;
      debugPrint('upgrade.shell ${session.host.name}: pinentry mark: $error');
    }
  }

  void _setPin(ShellSession session, PinRequest? request) {
    session.pin = request;
    if (request == null) session._stopAsking();
    session.changed();
    _tellShade(session.host);
  }

  /// One notification per host: up while any of its tabs holds a request, replaced when the
  /// request is another, down when none does.
  void _tellShade(Host host) {
    PinRequest? held;
    for (final session in forHost(host.id)) {
      held = session.pin;
      if (held != null) break;
    }
    unawaited(_shade.tell(hostId: host.id, hostName: host.name, held: held));
  }

  /// What a bell means to a tab: the host's pinentry may have rung it, so the tab asks the
  /// host what it holds open and takes the answer as its request or as the request's
  /// withdrawal. The OSC says the same thing sooner over ssh; under Mosh only the bell gets
  /// through. Bells that land while the host is being asked fold into one more ask: a
  /// program that beeps ten times costs one exec, not ten. The answer is dropped when the
  /// connection it was asked on is no longer the tab's.
  ///
  /// A tab holding a request asks again after [pinRecheck], for as long as it holds one.
  /// Mosh rings once per frame it ships, so a request and its `done` inside one frame ring
  /// once, and a tab whose only ask landed while the request stood would keep it after the
  /// computer answered.
  Future<void> _askHost(ShellSession session) async {
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
        final ExecResult? result;
        try {
          result = await connection.channels.exec(pinentryOpenCommand());
        } catch (error) {
          if (!isHostFailure(error) && !isKeyFailure(error)) rethrow;
          debugPrint(
            'upgrade.shell ${session.host.name}: pinentry ask: $error',
          );
          return;
        }
        if (result == null ||
            !result.ok ||
            !identical(session.connection, connection)) {
          return;
        }
        final open = PinRequest.decodeOpen(result.out);
        final next = open.isEmpty ? null : open.first;
        if (next?.id != session.pin?.id) {
          _setPin(session, next);
        } else {
          _agePin(session);
        }
      } while (session._askAgain);
    } finally {
      session._asking = false;
      session._askAgain = false;
      if (session.pin != null &&
          session.connection != null &&
          session._asleep == null) {
        session._reask = Timer(pinRecheck, () => unawaited(_askHost(session)));
      }
    }
  }

  /// An ask gets old on the same asking that keeps it alive. The id does not change, so the
  /// sheet stays up and the shade is not rung a second time.
  void _agePin(ShellSession session) {
    final request = session.pin;
    if (request == null || request.stale) return;
    if (DateTime.now().difference(request.since) < pinStale) return;
    _setPin(session, request.aged());
  }

  /// Null is the cancel, which is a decision and reaches every surface; a sheet merely
  /// swiped away calls nothing. The request is dropped before the channel is opened, and
  /// one already being answered is not answered again, so a second tap sends nothing
  /// twice. The fifo is written only while it is there, so what the command comes back
  /// with says whether the answer landed.
  Future<PinAnswer> answerPin(
    ShellSession session,
    String? passphrase,
    UserIntent intent,
  ) async {
    final request = session.pin;
    final connection = session.connection;
    if (request == null) return PinAnswer.lost;
    _setPin(session, null);
    // One request, one fifo: the answer settles it on every tab of the host that
    // heard the same bell, before any of them can ask for it again.
    for (final other in forHost(session.host.id)) {
      if (identical(other, session) || other.pin?.id != request.id) continue;
      _setPin(other, null);
    }
    if (connection == null || !_answering.add(request.id)) {
      return PinAnswer.lost;
    }
    // The passphrase never reached stdin, so the request stays on the tab.
    PinAnswer unsent() {
      if (session.pin == null && !session._closed) _setPin(session, request);
      return PinAnswer.lost;
    }

    try {
      final HostChannels? channels;
      try {
        channels = await connection.channelsFor(UserAction(intent));
      } catch (error) {
        if (!isHostFailure(error) && !isKeyFailure(error)) rethrow;
        debugPrint('upgrade.shell ${session.host.name}: pinentry dial: $error');
        return unsent();
      }
      if (channels == null) return unsent();
      final result = await channels.exec(
        pinentryAnswerCommand(request.id),
        stdin: Uint8List.fromList(utf8.encode('${passphrase ?? ''}\n')),
        timeout: pinAnswerWait,
      );
      if (result == null) return unsent();
      return result.ok ? PinAnswer.sent : PinAnswer.expired;
    } on ChannelOpenTimeout {
      return unsent();
    } on TimeoutException {
      // The channel opened and the write blocked, so the guard found the fifo and
      // nobody is reading it: the request behind it is gone.
      return PinAnswer.expired;
    } catch (error) {
      if (!isHostFailure(error) && !isKeyFailure(error)) rethrow;
      debugPrint('upgrade.shell ${session.host.name}: pinentry answer: $error');
      return PinAnswer.lost;
    } finally {
      _answering.remove(request.id);
    }
  }

  Future<void> _connect(
    Host host,
    ShellSession session, {
    required OpenReason reason,
    HostKeyPrompt? prompt,
    bool reconnected = false,
    bool restored = false,
  }) async {
    final attempt = session._claim();
    if (!attempt.isCurrent) return;
    final privateKey = await readPrivateKey(host.keyId);
    if (!attempt.isCurrent) return;
    if (privateKey == null) {
      // The host names a key whose secret is gone from the store. There is nothing
      // to offer the remote, so this never dials.
      session.disarm();
      session.state = const ShellFailed(ShellFailureKind.keyRejected);
      session.changed();
      return;
    }

    // The size the view has already settled on, when it has: a shell started at the
    // wrong width redraws its prompt at the first resize and the user sees the wrap.
    final columns = session._columns ?? session.terminal.config.cols;
    final rows = session._rows ?? session.terminal.config.rows;

    Reconnect? dialFailed;
    try {
      final connection = await _open(
        reason: reason,
        failed: (retry) => dialFailed = retry,
        address: host.address,
        port: host.port,
        user: host.user,
        privateKey: privateKey,
        columns: columns,
        rows: rows,
        command: shellMarked(session.mark, command: session.command),
        tabSession: session.tab,
        persistentSession: null,
        verifier: verifierFor(
          host,
          // Null on a reconnect and on anything else that arrives without a route in
          // front of the user, which is what makes those refuse an unpinned host
          // instead of asking nobody.
          prompt: prompt,
        ),
      );
      if (!attempt.isCurrent) {
        try {
          if (session._closed && session.remoteSession != null) {
            final terminated = await connection.terminateRemote(
              session.remoteSession!,
              durableShell: false,
            );
            if (terminated) {
              await tabs?.close(host.id, session.number);
            }
          }
        } catch (error) {
          debugPrint('upgrade.shell ${host.name}: cleanup failed: $error');
        } finally {
          await connection.discard();
        }
        return;
      }
      unawaited(session._foregroundProcesses?.cancel());
      session._foregroundProcesses = null;
      session.connection = connection;
      session.clearEngineForeground();
      session._detail = null;
      session.clipboard = null;
      session._probing = null;
      final settledColumns = session._columns ?? columns;
      final settledRows = session._rows ?? rows;
      if (settledColumns != columns ||
          settledRows != rows ||
          session._cellWidthPx != 0) {
        connection.resize(
          settledColumns,
          settledRows,
          widthPx: settledColumns * session._cellWidthPx,
          heightPx: settledRows * session._cellHeightPx,
        );
      }
      session._columns = settledColumns;
      session._rows = settledRows;
      session.state = ShellLive(connection.transport);
      _learnSystem(host, connection);
      session._health = connection.health.listen(
        (health) => _onHealth(session, connection, attempt, health),
      );
      session._control = connection.controlDown.listen((down) {
        if (!attempt.isCurrent || !identical(session.connection, connection)) {
          return;
        }
        session.controlStale = down;
        if (!down) session.controlFailure = null;
        session.changed();
      });
      final marker = _transitionMarker(
        session,
        reconnected: reconnected,
        restored: restored,
      );
      // A pane is the one thing that survives the link, so the program that set the
      // modes is still there and they are still true. Anything else comes back as a
      // new shell that never asked for them.
      final engine = connection.transport == ShellTransport.engine;
      if ((reconnected || restored) && session.pane == null && !engine) {
        session._write(shellModeReset);
        // Leaving the alternate screen restores a cursor that was only saved on the
        // way in, so it is left alone unless the terminal is on it.
        if (session.terminal.activeScreen == TerminalScreen.alternate) {
          session._write('\x1b[?1049l');
        }
      }
      final seamless =
          connection is EngineShellConnection && connection.seamless;
      session._heldMarker = engine && !seamless ? marker : null;
      if (marker != null && !engine) session._write(marker);
      final moshPane =
          connection.transport == ShellTransport.mosh && session.pane != null;
      // A Mosh attach repaints the current screen without replaying the TUI's
      // earlier alternate-buffer transition. Herdr panes are full-screen.
      if (moshPane) session._write('\x1b[?1049h');
      session._moshPane = moshPane;
      session._pinentry = PrivateOscScanner(
        pinentryOsc,
        (args) => _onPinentry(session, args),
      );
      session._snapshots = connection.snapshots.listen(
        (bytes) {
          if (identical(session.connection, connection)) {
            _replaceTerminal(session, bytes);
          }
        },
        onError: (Object error) =>
            debugPrint('upgrade.shell ${host.name}: snapshots: $error'),
      );
      session._foregroundProcesses = connection.foregroundProcesses.listen(
        (processes) {
          if (identical(session.connection, connection)) {
            session.setEngineForeground(foregroundAgent(processes));
          }
        },
        onError: (Object _) {
          if (identical(session.connection, connection)) {
            session.clearEngineForeground();
          }
        },
      );
      session._output = connection.output.listen((bytes) {
        if (identical(session.connection, connection)) {
          session.painted.value = true;
          session._feed(bytes);
        }
      }, onError: (Object error) => _fail(session, error, attempt));
      unawaited(_awaitExit(session, connection, attempt));
      final settled = Future.wait([
        _mark(session, connection),
        _reap(host.id, connection),
      ]);
      if (_sleeping) {
        unawaited(
          settled.whenComplete(() {
            if (_sleeping && identical(session.connection, connection)) {
              _suspend(session);
            }
          }),
        );
      } else {
        // A request made while this tab had no link, before it opened or across a
        // redial, rang no bell it could hear: the tab asks once as it comes up.
        unawaited(_askHost(session));
      }
      session.changed();
    } catch (error) {
      _fail(session, error, attempt, dialFailed);
    }
  }

  String? _transitionMarker(
    ShellSession session, {
    required bool reconnected,
    required bool restored,
  }) {
    if (session.pane != null) {
      if (restored) return shellRestoreMarker;
      if (reconnected) return shellReattachMarker;
      return null;
    }
    return reconnected || restored ? shellReconnectMarker : null;
  }

  Future<void> _reap(String hostId, ShellConnection connection) async {
    final store = tabs;
    if (store == null) return;
    try {
      for (final tab in await store.retired(hostId)) {
        final remoteSession = tab.remoteSession;
        if (remoteSession == null ||
            await connection.terminateRemote(
              remoteSession,
              durableShell: false,
            )) {
          await store.close(tab.hostId, tab.number);
        }
      }
    } catch (error) {
      debugPrint('upgrade.shell $hostId: cleanup failed: $error');
    }
  }

  Future<void> _awaitExit(
    ShellSession session,
    ShellConnection connection,
    _Attempt attempt,
  ) async {
    try {
      final code = await connection.exitCode;
      if (!attempt.isCurrent) return;
      session._unwatch();
      session.disarm();
      session.state = ShellExited(code);
      session.voiceSendSuggested = false;
      session.clearAgentInput();
      session.clearEngineForeground();
      _setPin(session, null);
      // Every other code is the shell saying something went wrong, so that tab stays
      // for its output to be read.
      final ended = connection.ended;
      if (code == shellCleanExit && ended != null) {
        await _close(session.host.id, session, ended);
      }
    } catch (error) {
      _fail(session, error, attempt);
    }
  }

  void _onHealth(
    ShellSession session,
    ShellConnection connection,
    _Attempt attempt,
    ShellConnectionHealth health,
  ) {
    if (!attempt.isCurrent || !identical(session.connection, connection)) {
      return;
    }
    final next = switch (health) {
      ShellConnectionHealth.connected => ShellLive(connection.transport),
      ShellConnectionHealth.reconnecting => ShellReconnecting(
        connection.transport,
      ),
      ShellConnectionHealth.disconnected => ShellDisconnected(
        connection.transport,
      ),
    };
    final current = session.state;
    if (current.runtimeType == next.runtimeType) return;
    session.state = next;
    if (next is! ShellLive) {
      session.voiceSendSuggested = false;
      session.clearAgentInput();
    }
    session.changed();
  }

  /// Anything the transport throws that is not a [ShellFailure] is the connection going
  /// away without a word for it. The schedule only runs on evidence of an end: the dial
  /// that threw, or the terminal the connection carried ending. Without either the tab
  /// waits for the phone or the user.
  void _fail(
    ShellSession session,
    Object error,
    _Attempt attempt, [
    Reconnect? dialFailed,
  ]) {
    if (!attempt.isCurrent) return;
    final retry = dialFailed ?? session.connection?.ended?.reconnect;
    session.voiceSendSuggested = false;
    session.clearAgentInput();
    session.clearEngineForeground();
    session._unwatch();
    session.pin = null;
    session._stopAsking();
    _tellShade(session.host);
    session.disarm();
    final kind = error is ShellFailure
        ? error.kind
        : ShellFailureKind.streamClosed;
    session._detail = _detailOf(session.host, error);
    final was = session.state;
    final dropped = was is ShellDropped ? was.attempt : 0;
    // Every dial the link itself lost, the first one included: there is no button
    // for the user to press, so a host that was not there a second ago is tried
    // again rather than left on screen as a dead tab.
    if (shellReconnects(kind)) {
      if (retry != null && dropped < shellReconnectDelays.length) {
        _drop(session, dropped + 1, retry);
        return;
      }
      // The schedule is spent, and sixty-eight seconds of it may have run in a
      // pocket. Nothing is on a clock from here; the phone coming back in front or a
      // network arriving is what dials again.
      session.state = ShellWaiting(kind, detail: session._detail);
      session.changed();
      return;
    }
    session.state = ShellFailed(kind, detail: session._detail);
    session.changed();
  }

  /// A failure about reaching a machine names the dial the way the host row has it, so the
  /// reader is sent to the port that was dialled. A throw the transport has no reason for
  /// keeps its own words.
  static String? _detailOf(Host host, Object error) {
    if (error is! ShellFailure) return '$error';
    final detail = error.detail;
    if (detail == null || !error.kind.line.names) return detail;
    return '${host.user}@${host.address}:${host.port} · $detail';
  }

  HostKeyVerifier verifierFor(Host host, {HostKeyPrompt? prompt}) =>
      HostKeyVerifier(
        pinned: _pinnedThisRun[host.id] ?? host.hostKey,
        prompt: prompt,
        pin: (key) async {
          _pinnedThisRun[host.id] = key;
          await pinHostKey(host.id, key);
        },
      );

  /// Holds every wake until the returned callback is called. Raised with the passphrase and
  /// host key sheets: a reconnect underneath one would take the shell the question belongs
  /// to out from under the answer. A count, so two sheets at once still leave one hold
  /// standing.
  VoidCallback hold() {
    _held++;
    var released = false;
    return () {
      if (released) return;
      released = true;
      _held--;
    };
  }

  /// The phone is what calls this — coming back in front, or finding a network — and a tab
  /// still inside its schedule has a timer of its own and is left to it, unless that wait
  /// ran out while the phone slept: then it dials now and goes on from the same step.
  void wakeAll(
    PlatformSignal signal, {
    bool network = false,
    bool rehome = true,
  }) {
    final changed = network ? NetworkChanged(signal) : null;
    final OpenReason reason = changed ?? AppResumed(signal);
    if (changed != null) udpVerdicts.clearAll();
    for (final sessions in _byHost.values) {
      for (final session in List.of(sessions)) {
        final connection = session.connection;
        if (connection != null && session.state.holdsSession) {
          if (rehome) _rehome(session, connection, network: changed);
          continue;
        }
        final due = session._due;
        if (session._reconnect != null && due != null && !now().isBefore(due)) {
          session._reconnect?.cancel();
          unawaited(_redial(session, reason));
          continue;
        }
        wake(session, reason);
      }
    }
  }

  void _rehome(
    ShellSession session,
    ShellConnection connection, {
    required NetworkChanged? network,
  }) {
    final settles = network != null && !session._rehomeNetwork;
    if (session._rehoming) {
      if (settles) session._networkOwed = network;
      return;
    }
    if (session._rehomed != null && !settles) return;
    session._rehomed?.cancel();
    session._rehomed = null;
    session._rehoming = true;
    session._rehomeNetwork = network != null;
    unawaited(
      connection
          .rehome(network: network)
          .catchError((Object error) {
            debugPrint(
              'upgrade.shell ${session.host.name}: rehome failed: $error',
            );
          })
          .whenComplete(() {
            session._rehoming = false;
            if (session._closed) return;
            final live = session.connection;
            final owed = session._networkOwed;
            if (owed != null && live != null) {
              session._networkOwed = null;
              _rehome(session, live, network: owed);
              return;
            }
            session._rehomed = Timer(
              shellRehomeSettle,
              () => session._rehomed = null,
            );
          }),
    );
  }

  /// One tab, as the first step of a fresh schedule: a dial that misses waits two seconds
  /// and goes on, rather than running the whole minute out again with nobody looking.
  void wake(ShellSession session, OpenReason reason) {
    if (_held > 0 || session.state is! ShellWaiting) return;
    session.state = const ShellDropped(1);
    session.changed();
    unawaited(_redial(session, reason));
  }

  Future<void> reconnectControl(ShellSession session, UserAction action) async {
    final connection = session.connection;
    if (connection == null) return;
    session.controlFailure = null;
    session.changed();
    try {
      await connection.channelsFor(action);
    } catch (error) {
      if (!isHostFailure(error) && !isKeyFailure(error)) rethrow;
      if (!identical(session.connection, connection)) return;
      session.controlFailure = _detailOf(session.host, error);
      session.changed();
    }
  }

  void stopReconnect(ShellSession session) {
    // A tab mid-schedule is stopped on the drop that started it; a tab waiting is
    // stopped on what its last dial actually hit.
    final kind = switch (session.state) {
      ShellDropped() => ShellFailureKind.streamClosed,
      ShellWaiting(:final kind) => kind,
      _ => null,
    };
    if (kind == null) return;
    session._disown();
    session._reconnect?.cancel();
    session._reconnect = null;
    session._stopAsking();
    session.disarm();
    session.state = ShellFailed(kind, detail: session._detail);
    session.changed();
  }

  void _drop(ShellSession session, int attempt, Reconnect retry) {
    session.state = ShellDropped(attempt);
    session.clearAgentInput();
    session.clearEngineForeground();
    session.changed();
    final delay = shellReconnectDelays[attempt - 1];
    session._due = now().add(delay);
    session._reconnect = Timer(delay, () => unawaited(_redial(session, retry)));
  }

  /// A new shell in the tab whose shell ended, keeping its terminal. The state is left on
  /// [ShellDropped] across it, which is what keeps the header reading `RECONNECTING`.
  /// A connection whose terminal has not ended is never replaced; the tab waits instead.
  Future<void> _redial(ShellSession session, OpenReason reason) async {
    session._reconnect = null;
    session._due = null;
    if (session.state is! ShellDropped) return;
    final previous = session.connection;
    final ended = previous?.ended;
    if (previous != null && ended == null) {
      session.state = ShellWaiting(
        ShellFailureKind.streamClosed,
        detail: session._detail,
      );
      session.changed();
      return;
    }
    // Taken before anything closes: closing the old connection completes its exit
    // future, and an exit belonging to the attempt being replaced would otherwise
    // paint `EXITED` over the dial already under way.
    session._disown();
    // Not awaited, here or in [close]: a cancel takes effect the moment it is
    // called — nothing else arrives from that stream — and the future it hands back
    // belongs to the stream's own zone, which is not always one the caller's is
    // running.
    unawaited(session._output?.cancel());
    session._output = null;
    unawaited(session._snapshots?.cancel());
    session._snapshots = null;
    unawaited(session._foregroundProcesses?.cancel());
    session._foregroundProcesses = null;
    session._unwatch();
    session._pinentry = null;
    session.connection = null;
    // The title belonged to the shell that died. The pane outlives it, because the
    // dial that follows carries the same attach and comes back to the same agent.
    session.title = null;
    session.pin = null;
    session._stopAsking();
    _tellShade(session.host);
    session.disarm();
    session.changed();
    if (ended != null) await previous?.close(ended);
    // No prompt: nothing about a timer firing says the user is looking at the
    // route, so an unpinned host is refused here as it is anywhere else unattended.
    if (session.state is! ShellDropped) return;
    await _connect(session.host, session, reason: reason, reconnected: true);
  }
}

final shellSnapshotStoreProvider = Provider<ShellSnapshotStore?>((ref) => null);

/// Nothing disposes it: a session is meant to outlive the route that opened it, and a
/// provider that let go when its last reader did would close every shell on the way out
/// of the screen.
final shellSessionsProvider = Provider<ShellSessions>((ref) {
  ref.keepAlive();
  return ShellSessions(
    readPrivateKey: ref.watch(ed25519KeysProvider).privateKey,
    pinHostKey: ref.watch(hostRepositoryProvider).pinHostKey,
    recordSystem: ref.watch(hostRepositoryProvider).recordSystem,
    tabs: ref.watch(shellTabRepositoryProvider),
    snapshots: ref.watch(shellSnapshotStoreProvider),
    notifier: const PinNotifications(),
  );
});
