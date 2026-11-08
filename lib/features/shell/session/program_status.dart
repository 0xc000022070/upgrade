import 'package:flterm/flterm.dart'
    show
        ProgramStatusKind,
        ProgramStatusState,
        TerminalProgramStatus,
        TerminalProgress,
        TerminalProgressState;

import 'package:upgrade/platform/herdr/agent_kind.dart';

enum ProgramState {
  idle,
  working,
  done,
  blocked,
  error;

  bool get active => this == working || this == blocked;

  String get label => name.toUpperCase();
}

class ProgramRecord {
  const ProgramRecord({
    required this.id,
    required this.state,
    required this.seq,
    this.kind = ProgramStatusKind.none,
    this.app = '',
    this.title = '',
    this.message = '',
  });

  final String id;
  final ProgramState state;
  final ProgramStatusKind kind;

  final String app;
  final String title;
  final String message;

  final int seq;

  String get line {
    if (state == ProgramState.blocked && message.isNotEmpty) return message;
    if (title.isNotEmpty) return title;
    return message;
  }

  bool sameShown(ProgramRecord other) =>
      other.id == id &&
      other.state == state &&
      other.kind == kind &&
      other.app == app &&
      other.title == title &&
      other.message == message;
}

/// OSC 9;4 progress stands in as the root record until the first OSC 7501 report
/// retires it; only a reset gives progress its say back.
class ProgramBoard {
  ProgramBoard({int Function()? clock}) : _clock = clock ?? _nextSeq;

  static var _seq = 0;
  static int _nextSeq() => ++_seq;

  final int Function() _clock;

  final _records = <String, ProgramRecord>{};
  final _sent = <String, String>{};

  var _spoken = false;

  bool get isEmpty => _records.isEmpty;

  Iterable<ProgramRecord> get records => _records.values;

  bool report(TerminalProgramStatus status) {
    var retired = false;
    if (!_spoken) {
      _spoken = true;
      retired = _records.isNotEmpty;
      _records.clear();
    }
    final id = status.id;
    if (status.state == ProgramStatusState.clear) return _clear(id) || retired;
    if (status.app.isEmpty) {
      _sent.remove(id);
    } else {
      _sent[id] = status.app;
    }
    return _put(
      ProgramRecord(
        id: id,
        state: switch (status.state) {
          ProgramStatusState.idle => ProgramState.idle,
          ProgramStatusState.working => ProgramState.working,
          ProgramStatusState.done => ProgramState.done,
          ProgramStatusState.blocked => ProgramState.blocked,
          ProgramStatusState.error ||
          ProgramStatusState.clear => ProgramState.error,
        },
        kind: status.state == ProgramStatusState.blocked
            ? status.kind
            : ProgramStatusKind.none,
        app: _appFor(id),
        title: status.title,
        message: status.message,
        seq: _clock(),
      ),
    );
  }

  bool progress(TerminalProgress report) {
    if (_spoken) return false;
    final state = switch (report.state) {
      TerminalProgressState.remove => null,
      TerminalProgressState.set ||
      TerminalProgressState.indeterminate => ProgramState.working,
      TerminalProgressState.pause => ProgramState.idle,
      TerminalProgressState.error => ProgramState.error,
    };
    if (state == null) return _records.remove('') != null;
    return _put(ProgramRecord(id: '', state: state, seq: _clock()));
  }

  bool ended() {
    final before = _records.length;
    _records.removeWhere((_, record) => record.state.active);
    _sent.removeWhere((id, _) => !_records.containsKey(id));
    return _records.length != before;
  }

  bool reset() {
    final had = _records.isNotEmpty;
    _records.clear();
    _sent.clear();
    _spoken = false;
    return had;
  }

  bool _put(ProgramRecord next) {
    final previous = _records[next.id];
    _records[next.id] = next;
    return previous == null || !previous.sameShown(next);
  }

  bool _clear(String id) {
    if (id.isEmpty) return reset();
    final before = _records.length;
    bool under(String key) => key == id || key.startsWith('$id/');
    _records.removeWhere((key, _) => under(key));
    _sent.removeWhere((key, _) => under(key));
    return _records.length != before;
  }

  String _appFor(String id) {
    var at = id;
    while (true) {
      final app = _sent[at];
      if (app != null) return app;
      if (at.isEmpty) return '';
      final slash = at.lastIndexOf('/');
      at = slash < 0 ? '' : at.substring(0, slash);
    }
  }
}

AgentKind? agentKindOfApp(String app) {
  final kind = AgentKind.lookup(app);
  if (kind != null) return kind;
  final dash = app.indexOf('-');
  return dash > 0 ? AgentKind.lookup(app.substring(0, dash)) : null;
}
