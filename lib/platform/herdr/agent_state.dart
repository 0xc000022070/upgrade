sealed class AgentState {
  const AgentState();

  static const all = <AgentState>[
    WorkingState(),
    BlockedState(),
    IdleState(),
    DoneState(),
  ];

  factory AgentState.of(String word) {
    final wanted = word.trim().toLowerCase();
    for (final state in all) {
      if (state.word == wanted) return state;
    }
    return UnknownState(wanted);
  }

  String get word;

  String get label => word.toUpperCase();

  bool get active => false;

  bool get resting => false;

  bool get blocked => false;

  bool get done => false;
}

class WorkingState extends AgentState {
  const WorkingState();

  @override
  String get word => 'working';

  @override
  bool get active => true;
}

class BlockedState extends AgentState {
  const BlockedState();

  @override
  String get word => 'blocked';

  @override
  bool get active => true;

  @override
  bool get blocked => true;
}

class IdleState extends AgentState {
  const IdleState();

  @override
  String get word => 'idle';

  @override
  bool get resting => true;
}

class DoneState extends AgentState {
  const DoneState();

  @override
  String get word => 'done';

  @override
  bool get resting => true;

  @override
  bool get done => true;
}

class UnknownState extends AgentState {
  const UnknownState(this.word);

  @override
  final String word;

  @override
  bool operator ==(Object other) => other is UnknownState && other.word == word;

  @override
  int get hashCode => word.hashCode;
}
