import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'package:upgrade/application/agents/agents.dart';
import 'package:upgrade/data/repositories/host_repository.dart';
import 'package:upgrade/platform/herdr/engine_agents.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';
import 'package:upgrade/brand.dart';

typedef SessionKeyResolver = Future<String?> Function(
  EngineAgents engine,
  EngineWatch watched,
);

typedef _Read = ({
  List<TranscriptItem> fresh,
  int? last,
  bool unnamed,
  String? failure,
});

/// With [settles], polling stops once the agent keeps no transcript or the host no
/// longer lists a session it refused; without it only the transcript reads stop.
class AgentSessionFeed extends ChangeNotifier {
  AgentSessionFeed({
    required this._open,
    required this._target,
    required this.interval,
    required this.tag,
    required this._visible,
    this.settles = false,
    this._key,
    this._resolveKey,
    this._session,
  }) : assert(_key != null || _resolveKey != null);

  static const _pageLimit = 200;
  static const _pagesPerTick = 20;
  static const _kept = 400;

  final Duration interval;

  final String tag;
  final bool settles;

  final EngineOpen _open;
  final Future<Host?> Function() _target;
  final SessionKeyResolver? _resolveKey;

  Future<EngineAgents>? _engine;
  Timer? _timer;
  bool _visible;
  bool _onStage = true;
  bool _asking = false;
  bool _disposed = false;

  String? _key;
  AgentSnapshot? _session;
  bool _looked = false;
  final List<TranscriptItem> _items = [];
  bool _cut = false;
  int? _last;
  bool _noTranscript = false;
  bool _unnamed = false;
  bool _sessionGone = false;
  String? _failure;
  String? _answering;
  String? _answerLine;

  String? get key => _key;
  AgentSnapshot? get session => _session;
  bool get looked => _looked;
  List<TranscriptItem> get items => UnmodifiableListView(_items);
  bool get cut => _cut;
  int? get last => _last;
  bool get noTranscript => _noTranscript;
  bool get unnamed => _unnamed;
  bool get sessionGone => _sessionGone;
  String? get failure => _failure;
  String? get answering => _answering;
  String? get answerLine => _answerLine;

  set visible(bool value) {
    _visible = value;
    _sync();
  }

  set onStage(bool value) {
    _onStage = value;
    _sync();
  }

  void seed(TranscriptPage page) {
    _keep(page.items);
    _last = page.last;
  }

  void keepsNoTranscript() => _noTranscript = true;

  void _drop() {
    final engine = _engine;
    _engine = null;
    unawaited(
      engine?.then(
        (engine) => engine.session.close(),
        onError: (_) {
          // ignored: an engine that never opened has nothing to close
        },
      ),
    );
  }

  void _sync() {
    final run = _visible && _onStage;
    if (run == (_timer != null)) return;
    _timer?.cancel();
    _timer = null;
    if (!run) {
      _drop();
      return;
    }
    unawaited(_tick());
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _drop();
    super.dispose();
  }

  Future<void> _tick() async {
    if (_asking || _disposed) return;
    if (settles && (_sessionGone || _noTranscript)) return;
    _asking = true;
    Host? host;
    try {
      host = await _target();
      if (_disposed || host == null) return;
      final engine = await (_engine ??= _open(host));
      if (_disposed) return;
      final watched = await engine.watch();
      final key = _key ?? await _resolveKey!(engine, watched);
      if (_disposed) return;
      if (key == null) {
        _looked = true;
        _changed();
        return;
      }
      _key = key;
      final session = watched.agents
          .where((agent) => agent.paneId == key)
          .firstOrNull;
      final read = await _read(engine, key, listed: session != null);
      if (_disposed) return;
      _looked = true;
      _session = session;
      _last = read.last;
      _unnamed = read.unnamed;
      _keep(read.fresh);
      _failure = read.failure;
      _changed();
    } catch (error) {
      final name = host?.name ?? 'host';
      debugPrint('$appSlug.engine $name $tag: $error');
      _drop();
      if (_disposed) return;
      _failure = switch (error) {
        HostFailure() => error.line.on(name, address: host?.address),
        EngineRefused() => _refusal(error),
        _ => 'failed',
      };
      _changed();
    } finally {
      _asking = false;
    }
  }

  static String _refusal(EngineRefused error) =>
      error.kind.replaceAll('_', ' ');

  void _keep(List<TranscriptItem> fresh) {
    _items.addAll(fresh);
    if (_items.length > _kept) {
      _items.removeRange(0, _items.length - _kept);
      _cut = true;
    }
  }

  Future<_Read> _read(
    EngineAgents engine,
    String key, {
    required bool listed,
  }) async {
    final fresh = <TranscriptItem>[];
    var last = _last;
    if (!settles && _noTranscript) {
      return (fresh: fresh, last: last, unnamed: false, failure: null);
    }
    try {
      for (var page = 0; page < _pagesPerTick; page++) {
        final read = await engine.transcript(key, after: last);
        fresh.addAll(read.items);
        final done = read.last == last || read.items.length < _pageLimit;
        last = read.last;
        if (done) break;
      }
    } on EngineRefused catch (error) {
      _noTranscript = error.kind == 'unsupported';
      _sessionGone = settles && error.notFound && !listed;
      final settled = error.notFound || _noTranscript;
      if (_sessionGone) _drop();
      return (
        fresh: fresh,
        last: last,
        unnamed: error.notFound && (listed || !settles),
        failure: settled ? null : _refusal(error),
      );
    }
    return (fresh: fresh, last: last, unnamed: false, failure: null);
  }

  Future<void> answer(
    Host host,
    AgentApproval approval, {
    required bool allow,
  }) async {
    _answering = approval.id;
    _answerLine = null;
    _changed();
    try {
      final engine = await (_engine ??= _open(host));
      await engine.answer(approval.id, allow: allow);
      _answerLine = allow ? 'ALLOWED' : 'DENIED';
    } on EngineRefused catch (error) {
      _answerLine = error.notFound ? 'ALREADY ANSWERED' : 'REFUSED';
    } catch (error) {
      debugPrint('$appSlug.engine ${host.name} answer: $error');
      _answerLine = 'FAILED';
    } finally {
      _answering = null;
      _changed();
    }
    unawaited(_tick());
  }
}
