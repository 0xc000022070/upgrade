/// What herdr reports a pane's agent to be doing, and everything the app asks
/// of that answer: whether it belongs on the panel, whether it is resting, and
/// whether it is waiting for the user.
///
/// Sealed for the same reason an agent's kind is, and for one that kind does
/// not have: the word arrives off the wire, so naming the cases is not enough
/// — a word this does not know has to be a case too. It becomes
/// [UnknownState], which carries the word and claims nothing about it. The
/// alternative was a `_ =>` arm on every switch, and that is where `done`
/// went: reported by herdr for every agent whose work finished while nobody
/// was looking at the tab, and counted by the panel as neither working, nor
/// idle, nor blocked.
sealed class AgentState {
  const AgentState();

  /// Every state herdr classifies, in no order the screens depend on.
  static const all = <AgentState>[
    WorkingState(),
    BlockedState(),
    IdleState(),
    DoneState(),
  ];

  /// The state [word] stands for, and never null: a word off the wire that is
  /// none of the above is an [UnknownState] holding it.
  factory AgentState.of(String word) {
    final wanted = word.trim().toLowerCase();
    for (final state in all) {
      if (state.word == wanted) return state;
    }
    return UnknownState(wanted);
  }

  /// What herdr calls it, and what goes back out in a snapshot's json.
  String get word;

  /// What a row prints.
  String get label => word.toUpperCase();

  /// Whether it earns a row of its own on the home panel: something is
  /// happening, or something is waiting on the user.
  bool get active => false;

  /// Whether it is ready for input, work behind it or not. This is what the
  /// footer counts as idle.
  bool get resting => false;

  /// Whether it is stopped at a question only the user can answer.
  bool get blocked => false;
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

/// Idle, after work nobody has looked at yet. herdr separates it from a plain
/// idle by whether the tab was seen in its focused UI, which from a phone it
/// never is: this is the state most agents rest in here.
class DoneState extends AgentState {
  const DoneState();

  @override
  String get word => 'done';

  @override
  bool get resting => true;
}

/// A word herdr sent that this does not place — its own `unknown`, meaning an
/// agent is there but could not be classified, and anything a later herdr
/// grows. It answers no to every question, because no is not known to be true
/// either: the word itself is all it has, and printing that is honest.
class UnknownState extends AgentState {
  const UnknownState(this.word);

  @override
  final String word;

  @override
  bool operator ==(Object other) => other is UnknownState && other.word == word;

  @override
  int get hashCode => word.hashCode;
}
