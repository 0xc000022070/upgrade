import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../application/agents.dart';
import '../../application/pin_alerts.dart';
import '../../application/providers.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/shell_tab_repository.dart';
import '../../platform/herdr_client.dart';
import '../../platform/host_keys.dart';
import '../../platform/pin_notifications.dart';
import '../../platform/shell/host_clipboard.dart';
import '../../platform/shell/remote_shell.dart';
import '../../platform/shell/shell_connection.dart';
import '../../platform/shell/shell_tunnel.dart';
import '../../platform/shell/strip_bytes.dart';
import '../../platform/workspace/workspace_commands.dart';
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
/// acknowledgements that Dazzle has no evidence of a usable connection.
final class ShellDisconnected extends ShellState {
  const ShellDisconnected(this.transport);

  final ShellTransport transport;
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
  const ShellFailed(this.kind, {this.detail});

  final ShellFailureKind kind;

  /// What the transport said, under the line the header draws. Null when the
  /// failure was the app's own and there is nothing beneath the words.
  final String? detail;
}

/// The schedule is spent and nothing is on a clock. The terminal still holds
/// what the dead shell printed and the tab still carries the command and the
/// pane it attaches to, so the next wake comes back to the same agent rather
/// than to a login. [kind] is what the last dial hit, not the drop that
/// started the schedule.
final class ShellWaiting extends ShellState {
  const ShellWaiting(this.kind, {this.detail});

  final ShellFailureKind kind;

  final String? detail;
}

/// What the session hit, when it hit something. A tab waiting reads under the
/// header the same way a tab that failed does: the link is equally gone, and
/// the only difference is whether anything will dial again.
extension ShellStateFailure on ShellState {
  ({ShellFailureKind kind, String? detail})? get failure => switch (this) {
    ShellFailed(:final kind, :final detail) => (kind: kind, detail: detail),
    ShellWaiting(:final kind, :final detail) => (kind: kind, detail: detail),
    _ => null,
  };
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

/// Turned off above each new shell. The modes a terminal is in belong to the
/// program that set them, and a new shell means that program is gone. A link
/// dropped under a mouse-reporting application otherwise leaves the terminal
/// reporting for as long as the session lives, because the session outlives
/// the connection on purpose and the terminal goes with it: every drag is then
/// forwarded as a wheel report to a shell that ignores it, and every tap is
/// swallowed the same way, so the terminal reads as dead to the touch until
/// the app is restarted. Mouse reporting in the three modes an application can
/// ask for it, the encoding it reports in, and bracketed paste.
const shellModeReset =
    '\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?2004l';

const shellReattachMarker = '\r\n\x1b[2m-- reattached --\x1b[0m\r\n';
const shellRestoreMarker = '\r\n\x1b[2m-- session restored --\x1b[0m\r\n';

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

/// The private OSC a host's `pinentry-gate` asks a terminal through, and
/// tells it the request was settled elsewhere. Either way the id comes next.
const pinentryOsc = '7771';

/// The OSC a shell reports its working directory on, `file://<host>/<path>`,
/// emitted beside the prompt by a shell configured to and by nothing else. A
/// tab whose shell never says keeps the directory it was opened at.
const cwdOsc = '7';

/// The path out of an OSC 7 payload, or null when it is not one. The host part
/// is dropped: what a host calls itself in a URL is not what the app dialled,
/// and the path is the only field anything here wants.
///
/// The segments are read rather than the path, which is where the escaping a
/// hook writes comes off. A payload that names no segment said nothing — the
/// root reads the same as a bare `file://<host>`, and a checkout at `/` is not
/// a thing a phone opens.
String? cwdFromOsc(String payload) {
  final uri = Uri.tryParse(payload.trim());
  if (uri == null || uri.scheme != 'file') return null;
  final segments = uri.pathSegments.where((segment) => segment.isNotEmpty);
  if (segments.isEmpty) return null;
  return '/${segments.join('/')}';
}

/// What the host's pinentry is asking: the words the agent gave it, decoded
/// off the OSC's payload. `pin` wants a passphrase; `confirm` and `message`
/// want a yes, and carry the agent's own labels for the blocks.
class PinRequest {
  const PinRequest({
    required this.id,
    required this.mode,
    required this.since,
    this.desc = '',
    this.prompt = '',
    this.error = '',
    this.ok = '',
    this.cancel = '',
    this.stale = false,
  });

  /// Null for anything that is not a request: an id that is not one, a
  /// payload that is not base64 or not JSON. A host is trusted to run a shell,
  /// not to shape a command, and the id is the one thing here that reaches one.
  static PinRequest? decode(String id, String payload, {DateTime? at}) {
    if (!pinentryRequestId.hasMatch(id)) return null;
    try {
      final json = jsonDecode(utf8.decode(base64Decode(payload)));
      if (json is! Map<String, Object?>) return null;
      String field(String key) {
        final value = json[key];
        return value is String ? value : '';
      }

      final mode = field('mode');
      return PinRequest(
        id: id,
        mode: mode.isEmpty ? 'pin' : mode,
        since: at ?? DateTime.now(),
        desc: field('desc'),
        prompt: field('prompt'),
        error: field('error'),
        ok: field('ok'),
        cancel: field('cancel'),
      );
    } on FormatException {
      return null;
    }
  }

  /// What the host answered about its open requests: one per line, the id
  /// and the payload with a space between, in the order the host listed them.
  /// A line that is not a request is skipped rather than fatal, because the
  /// list is read off a directory a user's processes share.
  static List<PinRequest> decodeOpen(String listing, {DateTime? at}) {
    final requests = <PinRequest>[];
    for (final line in listing.split('\n')) {
      final space = line.indexOf(' ');
      if (space <= 0) continue;
      final request = decode(
        line.substring(0, space),
        line.substring(space + 1).trim(),
        at: at,
      );
      if (request != null) requests.add(request);
    }
    return requests;
  }

  final String id;
  final String mode;
  final String desc;
  final String prompt;
  final String error;
  final String ok;
  final String cancel;

  /// When the phone first heard this ask. The host says nothing about its own
  /// clock: the payload carries the agent's words and the open listing says a
  /// request stands, never for how much longer. So the count starts where the
  /// tab took it and nowhere else, and it is never counted down to a deadline
  /// the phone would be inventing.
  final DateTime since;

  /// Whether the ask has stood long enough in the phone's hands that the
  /// host's own window may have run out under it. Never a claim that it has:
  /// the host listed it as open on the last ask, and what the phone does not
  /// know is how much of the host's window is left.
  final bool stale;

  /// The same ask, drawn as one that may already be over.
  PinRequest aged() => PinRequest(
    id: id,
    mode: mode,
    since: since,
    desc: desc,
    prompt: prompt,
    error: error,
    ok: ok,
    cancel: cancel,
    stale: true,
  );

  /// The field's label: the agent's prompt without its colon, in the app's
  /// case, or the word the box on the computer uses.
  String get promptLabel => _label(prompt, 'PASSPHRASE');

  /// The affirmative block. `UNLOCK` for a passphrase; a confirm carries the
  /// agent's own word, with pinentry's `_` mnemonic mark taken off.
  String get okLabel => _label(ok, mode == 'pin' ? 'UNLOCK' : 'OK');

  String get cancelLabel => _label(cancel, 'CANCEL');

  static String _label(String text, String fallback) {
    final cleaned = text
        .replaceAll('_', '')
        .trim()
        .replaceAll(RegExp(r':$'), '')
        .toUpperCase();
    return cleaned.isEmpty ? fallback : cleaned;
  }
}

/// What became of an answer the user gave.
///
/// The fifo an answer is written into is guarded by the fifo being there, so a
/// command that comes back failed is proof the ask was down before the
/// passphrase left the phone: nothing was written and nothing is waiting on
/// it. A channel that never came back is the link going, which is a different
/// thing and already has its own word on the route.
enum PinAnswer { sent, expired, lost }

/// One shell: its tab number, its terminal, and the connection under it.
///
/// The terminal outlives the connection on purpose. A session that failed or
/// exited keeps every byte it printed, which is the only place the error the
/// remote shell died of can still be read.
/// A mark no other tab of this run carries, in the alphabet [shellMark] holds
/// a mark to. The clock gives it its uniqueness and the counter covers two
/// tabs opened inside the same microsecond.
int _marks = 0;
String _newMark() =>
    's${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
    '${(_marks++).toRadixString(36)}';

class ShellSession extends ChangeNotifier {
  ShellSession({
    required this.number,
    required this.terminal,
    required this.host,
    this.remoteSession,
    String? mark,
  }) : mark = mark ?? _newMark();

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

  /// Where the view sits in the buffer, and null while there is nothing to
  /// ask: a tab whose view is not attached yet, one being swapped for another,
  /// and a position that has not been through a layout have no answer.
  ScrollPosition? get tailPosition {
    if (scrollController.positions.length != 1) return null;
    final position = scrollController.position;
    if (!position.hasPixels || !position.hasContentDimensions) return null;
    return position;
  }

  /// Puts the view back on the last line, where what the shell is about to say
  /// will be printed. The view follows the output on its own from there.
  void followTail() {
    final position = tailPosition;
    if (position == null) return;
    if (position.pixels < position.maxScrollExtent) {
      position.jumpTo(position.maxScrollExtent);
    }
  }

  ShellConnection? connection;
  ShellState state = const ShellConnecting();

  /// What this tab runs in place of the host's login shell, for the tab's
  /// whole life: a reconnect after the network dropped comes back to the same
  /// agent, or to the same directory, rather than to a bare prompt. Null is a
  /// login shell, which is every tab the user opens by hand.
  String? command;

  /// Where the shell is, as far as the app was told. Seeded with the directory
  /// the tab was opened at and replaced by whatever the shell reports beside
  /// its prompt. Null on a tab opened at no directory whose shell never says
  /// where it went — which is why the host is asked as well.
  String? cwd;

  /// The checkout the tab is standing inside, as the host last answered.
  /// Null is both answers the app has not got yet and a directory that is in
  /// no checkout at all, which is why the mark on the header is dimmed until
  /// the host has said otherwise.
  String? repository;

  /// What this tab's shell is marked with, so the host can be asked which of
  /// its processes is this tab and where that process is standing. One per
  /// session and never reused: two tabs on the same host are two shells.
  final String mark;

  /// Stable identity for this tab. It marks the Mosh server so reconnect and
  /// cleanup affect only this tab. A Herdr tab's process identity stays in
  /// [pane].
  final String? remoteSession;

  /// What the host knows this tab by: [remoteSession] when the tab has one,
  /// the shell's own [mark] otherwise. The Mosh server is marked with it and
  /// a pinentry mark is looked up by it.
  String get tab => remoteSession ?? mark;

  /// The herdr pane [command] attaches this tab to, so a tap on that agent
  /// finds this tab rather than opening another. Persisted beside the tab so
  /// a killed app attaches the same pane rather than opening a bare shell.
  PaneRef? pane;

  /// What the bar has armed, waiting for the next key or character. It lives
  /// here rather than in the bar because the IME types straight into the
  /// terminal, where the bar is not in the path, and because switching tabs
  /// has to switch the armed set with the session.
  final Set<StickyModifier> sticky = <StickyModifier>{};

  /// How many keys the armed set survives. One unless the bar's cell was
  /// dragged down, which is the only way a chord like `CTRL D` twice reaches
  /// a program from a keyboard that cannot hold a key down. Moot while the
  /// arming is latched, which no key counts against.
  int stickyRepeat = 1;

  /// Whether the armed set survives keys at all. A modifier held down on the
  /// bar is armed until it is tapped off: nothing spends it, and no count
  /// stands for how long it lasts.
  bool stickyLocked = false;

  /// Drops the arming whole. A count outliving the modifiers it belonged to
  /// would be spent on the next thing armed, which the user never asked for,
  /// and a latch outliving them would arm the next thing forever.
  void disarm() {
    sticky.clear();
    stickyRepeat = 1;
    stickyLocked = false;
  }

  /// What the shell called itself, through the escape sequence a shell uses to
  /// name its window. Null until it says, which a bare `sh` never does.
  String? title;

  /// What the host's pinentry is asking this tab, while it is asking. Set by
  /// the OSC, cleared by the answer, by `done`, and by the link going: a
  /// request outlives none of the connection it arrived on.
  PinRequest? pin;
  var _asking = false;
  var _askAgain = false;
  Timer? _reask;

  void _stopAsking() {
    _reask?.cancel();
    _reask = null;
  }

  /// What the host answered about its clipboard on this connection. Null
  /// until asked, and dropped with the connection: the answer is about the
  /// desktop session the shell landed in, and a reconnect may land elsewhere.
  HostClipboard? clipboard;
  Future<HostClipboard>? _probing;

  /// Cancelled and dropped on every close and every retry: a stale listener
  /// would write a dead connection's bytes into a live terminal.
  StreamSubscription<Uint8List>? _output;
  StreamSubscription<ShellConnectionHealth>? _health;

  /// Decodes the channel across chunk boundaries. A plain [utf8.decode] per
  /// chunk would mangle any character whose bytes land either side of one,
  /// which is every read on a busy shell sooner or later.
  ByteConversionSink? _decoder;

  /// The last size sent to the remote, so a resize that changes nothing is not
  /// forwarded. The view reports on every layout, including ones where only
  /// the pixel size moved.
  int? _columns;
  int? _rows;

  /// What the last dial failed with, held across the waits between dials: a
  /// schedule that runs out shows what the last one hit, not the drop that
  /// started it. Dropped by a dial that lands.
  String? _detail;

  /// The dial that holds the tab. Taken by every dial that starts and by
  /// everything that ends one, so whatever it replaced goes quiet.
  late _Attempt _attempt = _Attempt._(this);

  /// Set once, by [close]. A closed tab hands its claim to nothing and refuses
  /// to hand out another.
  bool _closed = false;

  /// Hands the tab to a new dial. Only the claim handed back may write state
  /// onto this session, and only until the next call.
  _Attempt _claim() => _attempt = _Attempt._(this);

  /// Takes the tab from whatever dial holds it without giving it to another,
  /// so everything in flight goes quiet and nothing lands until the next dial
  /// claims it.
  void _disown() => _claim();

  /// The wait before the next reconnect. Cancelled by `STOP`, by a retry and
  /// by the tab closing, all three of which are the user deciding what happens
  /// next instead of the schedule.
  Timer? _reconnect;

  bool _retired = false;

  /// Whether the tab has closed and let go of what it owns. What a view left
  /// behind on the terminal — a mark, an anchor — is released with the buffer
  /// and must not be released again through a listenable that is gone.
  bool get retired => _retired;

  /// Lets go of the three listenables the view is handed rather than makes.
  /// The view disposes only what it made itself, so a session that owns them
  /// is the only thing that can, and a tab that has closed is the moment.
  ///
  /// Called at the end of the frame the tab was dropped in, never inside it: a
  /// scroll controller disposed while a [Scrollable] is still attached fails
  /// the detach that view is about to be asked for.
  @override
  void dispose() {
    if (_retired) return;
    _retired = true;
    controller.dispose();
    focusNode.dispose();
    scrollController.dispose();
    super.dispose();
  }

  /// Tells the views drawing this tab that something about it moved: what it
  /// printed, what it is called, what state it is in, what its bar has armed.
  /// None of that is a fact about the set of tabs, so none of it goes to the
  /// store.
  ///
  /// Silent once retired: a probe or a title that lands after the tab closed
  /// has nobody left to tell, and the notifier it would tell is disposed.
  void changed() {
    if (_retired) return;
    notifyListeners();
  }
}

/// One dial's claim on its tab.
///
/// A dial writes state onto its session only while [isCurrent] holds. A retry,
/// the reconnect schedule and the tab closing each take the claim for
/// themselves, and the one they replaced never becomes current again.
///
/// A counter did the same arithmetic, but a number carries no trace of the tab
/// it belongs to — one session's compares equal to another's — and it cannot
/// say that a tab is closed, which is the state that matters: a dial that took
/// the next number after a close made itself current again and opened a
/// connection nothing was left to close.
class _Attempt {
  _Attempt._(this._session);

  final ShellSession _session;

  bool get isCurrent => !_session._closed && identical(_session._attempt, this);
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
    this.pinRecheck = const Duration(seconds: 5),
    this.pinStale = const Duration(minutes: 5),
    this.notifier,
  }) : _open = open ?? const ShellTunnel().open;

  /// The shade, told once per request a host has up and once when it is gone.
  /// Null in a test that is not about the notification.
  final PinNotifier? notifier;

  /// The request id each host's notification is up for, so a second tab
  /// hearing the same request raises nothing and a settled one is withdrawn
  /// exactly once.
  final _notified = <String, String>{};

  /// How long a tab holding a request waits before asking the host again
  /// whether it still stands. Short only in a test.
  final Duration pinRecheck;

  /// How long an ask stands in the phone's hands before the sheet stops
  /// drawing it as one that is certainly still wanted. The pinentry's own
  /// default window, which the phone cannot read and does not claim is the one
  /// in force. Short only in a test.
  final Duration pinStale;

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

  /// How many sheets are up. Nothing is woken while this is above zero.
  int _held = 0;

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

  /// Where [session]'s shell is standing, asked of the host rather than taken
  /// from what the shell has said.
  ///
  /// Runs on a second channel of the connection the tab already holds, so the
  /// shell on the pty sees none of it and the user's own line is not disturbed.
  /// The answer is kept on the session, which is what makes the header's mark
  /// tapped again after a `cd` open somewhere else.
  ///
  /// A tab attached to a Herdr pane is asked for that pane instead. The attach
  /// client stands where it started; the shell that has walked elsewhere is
  /// the pane's, and it belongs to the Herdr server rather than to this
  /// connection's process tree.
  ///
  /// Null when there is no connection to ask on, or when the host has no
  /// `/proc` to answer from. The caller falls back; nothing here overwrites
  /// what the tab already had with nothing.
  Future<String?> cwdFromHost(ShellSession session) async {
    final connection = session.connection;
    if (connection == null) return null;
    try {
      final pane = session.pane;
      var herdrSession = pane?.session;
      String? answer;
      if (herdrSession == null) {
        final probe = await connection.exec(shellCwdProbe(session.mark));
        if (probe.exitCode != 0) return null;
        final place = parseShellPlace(probe.out);
        herdrSession = place.herdrSession;
        answer = place.cwd;
      }
      if (herdrSession != null && HerdrCommands.isSessionName(herdrSession)) {
        final panes = await connection.exec(HerdrCommands.panes(herdrSession));
        if (panes.exitCode == 0) {
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
      debugPrint('dazzle.shell ${session.host.name}: ${error.detail ?? error}');
      return null;
    }
  }

  /// The checkout [session] is standing inside, asked of the host on the same
  /// second channel: where the shell is, then what repository that is part of.
  ///
  /// Kept on the session, because the header draws its mark from it and the
  /// viewer opens on it. Null leaves the mark dimmed — a directory that is in
  /// no checkout has no diff to show, and saying so after a tap would be
  /// spending the tap on what the app could have known.
  Future<String?> repositoryFromHost(ShellSession session) async {
    final connection = session.connection;
    if (connection == null) return null;
    final directory = await cwdFromHost(session) ?? session.cwd;
    if (directory == null) return _repository(session, null);
    final result = await connection.exec(
      WorkspaceCommands.repository(directory),
    );
    final top = result.out.trim();
    if (result.exitCode != 0 || !top.startsWith('/')) {
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

  /// The tab on [hostId] attached to [pane], or null when no tab is.
  ShellSession? holding(String hostId, PaneRef pane) {
    for (final session in forHost(hostId)) {
      if (session.pane == pane) return session;
    }
    return null;
  }

  /// Opens a shell and makes it the active tab. The `+` cell is gone at nine,
  /// so the refusal here is a guard rather than a path the user can walk.
  ShellSession? open(
    Host host, {
    HostKeyPrompt? prompt,
    String? command,
    String? directory,
    PaneRef? pane,
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
    );
    return _start(
      host,
      number,
      prompt: prompt,
      command: command,
      directory: directory,
      pane: pane,
      remoteSession: remoteSession,
      beforeConnect: persisted,
    );
  }

  /// A tab on a number that has already been decided: by [open], which takes
  /// the next one, or by [restore], which takes the one the tab had before the
  /// process died.
  ShellSession _start(
    Host host,
    int number, {
    HostKeyPrompt? prompt,
    String? command,
    String? directory,
    PaneRef? pane,
    String? remoteSession,
    bool restored = false,
    Future<void>? beforeConnect,
  }) {
    final session =
        ShellSession(
            number: number,
            terminal: Terminal(maxLines: shellScrollback),
            host: host,
            remoteSession: remoteSession,
            mark: remoteSession,
          )
          ..command = command
          ..cwd = directory
          ..pane = pane;
    _byHost.putIfAbsent(host.id, () => []).add(session);
    _active[host.id] = number;
    _parkedHostId = host.id;
    _wireTerminal(session);
    notifyListeners();
    unawaited(
      _connectAfterPersistence(
        host,
        session,
        prompt: prompt,
        restored: restored,
        persistence: beforeConnect,
      ),
    );
    return session;
  }

  Future<void> _connectAfterPersistence(
    Host host,
    ShellSession session, {
    required bool restored,
    HostKeyPrompt? prompt,
    Future<void>? persistence,
  }) async {
    try {
      await persistence;
    } catch (error) {
      debugPrint('dazzle.shell ${host.name}: tab save failed: $error');
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
    await _connect(host, session, prompt: prompt, restored: restored);
  }

  /// Reopens the tabs the last run left behind and dials each one.
  ///
  /// A tab with a remote session attaches to it. An agent tab reconstructs the
  /// attach command from its validated Herdr session and pane. Older rows open
  /// a fresh shell because they recorded neither identity.
  /// Unattended, so a host whose key was never pinned is refused here rather
  /// than asking a user who is still looking at the boot log.
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
      final remoteSession = row.remoteSession;
      final hasHerdrIdentity =
          row.herdrSession != null || row.herdrPane != null;
      final pane = row.herdrSession != null && row.herdrPane != null
          ? (session: row.herdrSession!, pane: row.herdrPane!)
          : null;
      if ((remoteSession != null &&
              !durableShellSession.hasMatch(remoteSession)) ||
          (hasHerdrIdentity && (pane == null || !HerdrCommands.isPane(pane)))) {
        await store.close(row.hostId, row.number);
        continue;
      }
      final next = _nextNumber[host.id] ?? 1;
      if (row.number >= next) _nextNumber[host.id] = row.number + 1;
      _start(
        host,
        row.number,
        command: pane == null ? null : HerdrCommands.attach(pane),
        pane: pane,
        remoteSession: remoteSession,
        restored: true,
      );
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
    // Taken for good, so neither the exit, nor the output stream of the
    // connection being closed, nor a dial the reconnect schedule is part way
    // through can write onto a session that is already gone.
    session._closed = true;
    session._disown();
    session._reconnect?.cancel();
    session._reconnect = null;
    session._stopAsking();
    session.disarm();
    _byHost[hostId]?.remove(session);
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
    unawaited(session._health?.cancel());
    session._health = null;
    session._decoder = null;
    _retire(session);
    final connection = session.connection;
    session.connection = null;
    final remoteSession = session.remoteSession;
    if (remoteSession == null) {
      await tabs?.close(hostId, session.number);
      await connection?.close();
      return;
    }
    await tabs?.retire(hostId, session.number);
    var terminated = false;
    try {
      terminated =
          await connection?.terminateRemote(
            remoteSession,
            durableShell: false,
          ) ??
          false;
    } catch (error) {
      debugPrint('dazzle.shell ${session.host.name}: cleanup failed: $error');
    } finally {
      await connection?.close();
    }
    if (terminated) await tabs?.close(hostId, session.number);
  }

  /// Drops the session's controllers once the frame that removed its view has
  /// run. [notifyListeners] is what takes the view out of the tree, and until
  /// that rebuild happens the view is still attached to them.
  void _retire(ShellSession session) {
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => session.dispose())
      // A close nothing else is watching would otherwise leave the callback
      // waiting for a frame that has no reason to come.
      ..ensureVisualUpdate();
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
    session.terminal.onReport = (text) {
      // What the terminal answers on its own: the program asked where the
      // cursor is, what the terminal is, how big it is, or turned mouse
      // reporting on. None of it is a key, so an arming neither applies to it
      // — `ALT` would put an `ESC` in front of a reply and the program would
      // read the wrong answer — nor is spent by it. Claude Code asks for the
      // cursor often enough that an arming meant for two keys would otherwise
      // be down to one before the user pressed anything.
      session.connection?.write(typedBytes(text, const {}));
    };
    session.terminal.onTitleChange = (title) {
      session.title = title;
      session.changed();
    };
    session.terminal.onBell = () => unawaited(_askHost(session));
    session.terminal.onPrivateOSC = (code, args) {
      if (code == cwdOsc) {
        final cwd = args.isEmpty ? null : cwdFromOsc(args.first);
        if (cwd == null || cwd == session.cwd) return;
        session.cwd = cwd;
        session.changed();
        return;
      }
      if (code != pinentryOsc || args.length < 2) return;
      switch (args.first) {
        case 'pin' when args.length >= 3:
          // A second request while one stands replaces it: the fifo the first
          // would be answered on is gone with the request that made it.
          final request = PinRequest.decode(args[1], args[2]);
          if (request == null) return;
          _setPin(session, request);
        case 'done':
          if (session.pin?.id != args[1]) return;
          _setPin(session, null);
      }
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
  /// The armed set is spent here and nowhere else, at the single point every
  /// byte passes through, so the bar's own keys and the characters the IME
  /// types straight into the terminal count the same. One key takes one off
  /// the count; the set goes when the count runs out.
  void send(ShellSession session, Uint8List bytes) {
    if (bytes.isNotEmpty) {
      // A key is not a read: the bar's bytes never pass the view, so a shell
      // asked for something from up in the scrollback would answer off the
      // screen.
      session.followTail();
      session.connection?.write(bytes);
    }
    if (session.sticky.isEmpty) return;
    // A latched arming is not spent, only released: the whole point of holding
    // a modifier down is that the keys under it do not use it up.
    if (session.stickyLocked) return;
    if (session.stickyRepeat > 1) {
      session.stickyRepeat--;
    } else {
      session.disarm();
    }
    session.changed();
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
      session.changed();
    }
    return answer;
  }

  /// Arms the bar's modifiers for the next keys. Replaces the set rather than
  /// merging: the bar draws the whole of what is armed and hands back the whole
  /// of it, the count and the latch included.
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

  /// Tells the host's pinentry that this tab's pty is a place to ask. On the
  /// tab's own connection, so the channel's parent is the sshd session an ssh
  /// shell hangs off, and with the tab's mark, which is how a Mosh shell's
  /// server is found. A host without the pinentry gets a directory nobody
  /// reads, and a host whose process table disagrees gets nothing; neither is
  /// worth a word in the terminal.
  Future<void> _mark(ShellSession session, ShellConnection connection) async {
    try {
      await connection.exec(pinentryMarkCommand(session.tab));
    } catch (_) {}
  }

  /// Every change to what a tab holds goes through here, so the shade is told
  /// after each one and never told twice.
  void _setPin(ShellSession session, PinRequest? request) {
    session.pin = request;
    if (request == null) session._stopAsking();
    session.changed();
    _tellShade(session.host);
  }

  /// One notification per host: up while any of its tabs holds a request,
  /// replaced when the request is another, down when none does.
  void _tellShade(Host host) {
    final notifier = this.notifier;
    if (notifier == null) return;
    PinRequest? held;
    for (final session in forHost(host.id)) {
      held = session.pin;
      if (held != null) break;
    }
    final shown = _notified[host.id];
    if (held == null) {
      if (shown == null) return;
      _notified.remove(host.id);
      unawaited(notifier.withdraw(host.id));
      return;
    }
    if (shown == held.id) return;
    _notified[host.id] = held.id;
    unawaited(
      notifier.raise(
        hostId: host.id,
        text: pinNotificationText(
          host: host.name,
          desc: held.desc,
          prompt: held.prompt,
        ),
      ),
    );
  }

  /// What a bell means to a tab: the host's pinentry may have rung it, so the
  /// tab asks the host what it holds open and takes the answer as its request
  /// or as the request's withdrawal. The OSC says the same thing sooner over
  /// ssh; under Mosh only the bell gets through, so the bell is the signal on
  /// both and the host is the source. A request the tab already holds is not
  /// replaced by itself. Bells that land while the host is being asked fold
  /// into one more ask: a program that beeps ten times costs one exec, not
  /// ten, and a bell that is nobody's costs one that answers nothing. The
  /// answer is dropped when the connection it was asked on is no longer the
  /// tab's — what came back is about a link that is gone.
  ///
  /// A tab holding a request asks again after [pinRecheck], for as long as it
  /// holds one. Mosh rings once per frame it ships, so a request and its
  /// `done` inside one frame ring once, and a tab whose only ask landed while
  /// the request stood would keep it after the computer answered. The extra
  /// asks last exactly as long as the request does.
  Future<void> _askHost(ShellSession session) async {
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
        final ExecResult result;
        try {
          result = await connection.exec(pinentryOpenCommand());
        } catch (_) {
          return;
        }
        if (!result.ok || !identical(session.connection, connection)) return;
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
      if (session.pin != null && session.connection != null) {
        session._reask = Timer(pinRecheck, () => unawaited(_askHost(session)));
      }
    }
  }

  /// An ask gets old on the same asking that keeps it alive: the tab is
  /// already asking the host every [pinRecheck] whether its request stands,
  /// and one that keeps coming back past [pinStale] is drawn from then on as
  /// one the host's own window may have run out under. The id does not change,
  /// so the sheet stays up and the shade is not rung a second time.
  void _agePin(ShellSession session) {
    final request = session.pin;
    if (request == null || request.stale) return;
    if (DateTime.now().difference(request.since) < pinStale) return;
    _setPin(session, request.aged());
  }

  /// Answers the request the tab is holding. Null is the cancel, which is a
  /// decision and reaches every surface; a sheet merely swiped away calls
  /// nothing. The request is dropped before the channel is opened, so a
  /// second tap sends nothing twice.
  ///
  /// The fifo is written only while it is there, so what the command comes
  /// back with says whether the answer landed: a failure is an ask the host
  /// had already taken down, and the phone says so rather than letting the
  /// user believe they unlocked anything.
  Future<PinAnswer> answerPin(ShellSession session, String? passphrase) async {
    final request = session.pin;
    final connection = session.connection;
    if (request == null) return PinAnswer.lost;
    _setPin(session, null);
    // One request, one fifo: the answer settles it on every tab of the host
    // that heard the same bell, before any of them can ask for it again.
    for (final other in forHost(session.host.id)) {
      if (identical(other, session) || other.pin?.id != request.id) continue;
      _setPin(other, null);
    }
    if (connection == null) return PinAnswer.lost;
    try {
      final result = await connection.exec(
        pinentryAnswerCommand(request.id),
        stdin: Uint8List.fromList(utf8.encode('${passphrase ?? ''}\n')),
      );
      return result.ok ? PinAnswer.sent : PinAnswer.expired;
    } catch (_) {
      return PinAnswer.lost;
    }
  }

  Future<void> _connect(
    Host host,
    ShellSession session, {
    HostKeyPrompt? prompt,
    bool reconnected = false,
    bool restored = false,
  }) async {
    final attempt = session._claim();
    if (!attempt.isCurrent) return;
    final privateKey = await readPrivateKey(host.keyId);
    if (!attempt.isCurrent) return;
    if (privateKey == null) {
      // The host names a key whose secret is gone from the store. There is
      // nothing to offer the remote, so this never dials.
      session.disarm();
      session.state = const ShellFailed(ShellFailureKind.keyRejected);
      session.changed();
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
        command: shellMarked(session.mark, command: session.command),
        tabSession: session.tab,
        persistentSession: null,
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
          debugPrint('dazzle.shell ${host.name}: cleanup failed: $error');
        } finally {
          await connection.close();
        }
        return;
      }
      session.connection = connection;
      session._detail = null;
      session.clipboard = null;
      session._probing = null;
      session._columns = columns;
      session._rows = rows;
      session.state = ShellLive(connection.transport);
      session._health = connection.health.listen(
        (health) => _onHealth(session, connection, attempt, health),
      );
      final marker = _transitionMarker(
        session,
        reconnected: reconnected,
        restored: restored,
      );
      // A pane is the one thing that survives the link, so the program that
      // set the modes is still there and they are still true. Anything else
      // comes back as a new shell that never asked for them.
      if ((reconnected || restored) && session.pane == null) {
        session.terminal.write(shellModeReset);
        // Leaving the alternate screen restores a cursor that was only saved
        // on the way in, so it is left alone unless the terminal is on it.
        if (session.terminal.isUsingAltBuffer) {
          session.terminal.write('\x1b[?1049l');
        }
      }
      if (marker != null) session.terminal.write(marker);
      final moshPane =
          connection.transport == ShellTransport.mosh && session.pane != null;
      // A Mosh attach repaints the current screen without replaying the TUI's
      // earlier alternate-buffer transition. Herdr panes are full-screen.
      if (moshPane) session.terminal.write('\x1b[?1049h');
      session._decoder = utf8.decoder.startChunkedConversion(
        _TerminalSink(session.terminal, preserveMouseReporting: moshPane),
      );
      session._output = connection.output.listen(
        (bytes) => session._decoder?.add(bytes),
        onError: (Object error) => _fail(session, error, attempt),
      );
      unawaited(_awaitExit(session, connection, attempt));
      unawaited(_mark(session, connection));
      // A request made while this tab had no link, before it opened or across
      // a redial, rang no bell it could hear: the tab asks once as it comes up.
      unawaited(_askHost(session));
      unawaited(_reap(host.id, connection));
      session.changed();
    } catch (error) {
      _fail(session, error, attempt);
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
      debugPrint('dazzle.shell $hostId: cleanup failed: $error');
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
      unawaited(session._health?.cancel());
      session._health = null;
      session.disarm();
      session.state = ShellExited(code);
      _setPin(session, null);
      // A shell the user typed `exit` into is finished, and its tab holds
      // nothing they asked to keep. Every other code is the shell saying
      // something went wrong, so that tab stays for its output to be read.
      if (code == shellCleanExit) await close(session.host.id, session);
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
    session.changed();
  }

  /// Anything the transport throws that is not a [ShellFailure] is the
  /// connection going away without a word for it.
  void _fail(ShellSession session, Object error, _Attempt attempt) {
    if (!attempt.isCurrent) return;
    unawaited(session._health?.cancel());
    session._health = null;
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
    // Every dial the link itself lost, the first one included: there is no
    // button for the user to press, so a host that was not there a second ago
    // is tried again rather than left on screen as a dead tab.
    if (shellReconnects(kind)) {
      if (dropped < shellReconnectDelays.length) {
        _drop(session, dropped + 1);
        return;
      }
      // The schedule is spent, and sixty-eight seconds of it may have run in
      // a pocket. Nothing is on a clock from here; the phone coming back in
      // front or a network arriving is what dials again.
      session.state = ShellWaiting(kind, detail: session._detail);
      session.changed();
      return;
    }
    session.state = ShellFailed(kind, detail: session._detail);
    session.changed();
  }

  /// The words under the reason line. A failure about reaching a machine
  /// names the dial the way the host row has it, so the reader is sent to the
  /// port that was dialled. A throw the transport has no reason for keeps its
  /// own words: the line reads `stream closed`, which on its own says nothing.
  static String? _detailOf(Host host, Object error) {
    if (error is! ShellFailure) return '$error';
    final detail = error.detail;
    if (detail == null || !error.kind.line.names) return detail;
    return '${host.user}@${host.address}:${host.port} · $detail';
  }

  /// Holds every wake until the returned callback is called. Raised with the
  /// passphrase and host key sheets: answering what the host asked is the
  /// user's turn, and a reconnect underneath it would take the shell the
  /// question belongs to out from under the answer. A count, so two sheets at
  /// once still leave one hold standing.
  VoidCallback hold() {
    _held++;
    var released = false;
    return () {
      if (released) return;
      released = true;
      _held--;
    };
  }

  /// Dials every tab whose schedule ran out. The phone is what calls this —
  /// coming back in front, or finding a network — and a tab still inside its
  /// schedule has a timer of its own and is left to it.
  void wakeAll() {
    for (final sessions in _byHost.values) {
      for (final session in List.of(sessions)) {
        final connection = session.connection;
        if (connection != null &&
            (session.state is ShellLive ||
                session.state is ShellReconnecting ||
                session.state is ShellDisconnected)) {
          unawaited(
            connection.rehome().catchError((Object error) {
              debugPrint(
                'dazzle.shell ${session.host.name}: rehome failed: $error',
              );
            }),
          );
          continue;
        }
        wake(session);
      }
    }
  }

  /// One tab, as the first step of a fresh schedule: a dial that misses waits
  /// two seconds and goes on, rather than running the whole minute out again
  /// with nobody looking.
  void wake(ShellSession session) {
    if (_held > 0 || session.state is! ShellWaiting) return;
    session.state = const ShellDropped(1);
    session.changed();
    unawaited(_redial(session));
  }

  /// Parks the schedule where the user stopped it. The session reads as a
  /// dropped link that gave up, which is what it is; the way back into a shell
  /// on this host is a new tab.
  void stopReconnect(ShellSession session) {
    // A tab mid-schedule is stopped on the drop that started it; a tab waiting
    // is stopped on what its last dial actually hit, which is the line it was
    // already showing.
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

  void _drop(ShellSession session, int attempt) {
    session.state = ShellDropped(attempt);
    session.changed();
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
    // Taken before anything closes: closing the old connection completes its
    // exit future, and an exit belonging to the attempt being replaced would
    // otherwise paint `EXITED` over the dial already under way.
    session._disown();
    // Not awaited, here or in [close]: a cancel takes effect the moment it is
    // called — nothing else arrives from that stream — and the future it hands
    // back belongs to the stream's own zone, which is not always one the
    // caller's is running.
    unawaited(session._output?.cancel());
    session._output = null;
    unawaited(session._health?.cancel());
    session._health = null;
    session._decoder = null;
    final previous = session.connection;
    session.connection = null;
    // The title belonged to the shell that died: a new one that never names
    // itself would otherwise be read under the old one's name. The pane
    // outlives it, because the dial that follows carries the same attach and
    // comes back to the same agent.
    session.title = null;
    session.pin = null;
    session._stopAsking();
    _tellShade(session.host);
    session.disarm();
    session.changed();
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
  _TerminalSink(this.terminal, {required this.preserveMouseReporting});

  final Terminal terminal;
  final bool preserveMouseReporting;

  @override
  void add(String data) {
    terminal.write(data);
    if (!preserveMouseReporting) return;
    terminal
      ..setMouseMode(MouseMode.upDownScrollDrag)
      ..setMouseReportMode(MouseReportMode.sgr);
  }

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
    notifier: const PinNotifications(),
  );
});
