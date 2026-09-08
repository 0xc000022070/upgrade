import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/application/agent_state.dart';

/// What herdr reports a pane's agent to be, and what the screens ask of it.
void main() {
  group('the door from a word', () {
    test('answers the states herdr classifies', () {
      expect(AgentState.of('working'), isA<WorkingState>());
      expect(AgentState.of('blocked'), isA<BlockedState>());
      expect(AgentState.of('idle'), isA<IdleState>());
      expect(AgentState.of('done'), isA<DoneState>());
    });

    test('takes the word as it comes off the wire', () {
      expect(AgentState.of('  BLOCKED '), isA<BlockedState>());
    });

    test('keeps a word it cannot place instead of dropping it', () {
      // herdr's own `unknown`, and anything it grows later: the screen still
      // has a word to print, which is the whole of what it can honestly say.
      expect(AgentState.of('unknown'), const UnknownState('unknown'));
      final grown = AgentState.of('compacting');
      expect(grown, isA<UnknownState>());
      expect(grown.word, 'compacting');
      expect(grown.label, 'COMPACTING');
    });

    test('the word goes back out the way it came in', () {
      for (final state in AgentState.all) {
        expect(AgentState.of(state.word), state);
      }
    });
  });

  group('what the screens ask', () {
    test('the panel puts working and blocked on screen', () {
      expect(
        AgentState.all
            .where((state) => state.active)
            .map((state) => state.word),
        ['working', 'blocked'],
      );
    });

    test('an agent that finished unseen work is resting, not lost', () {
      // `done` is idle with work behind it nobody has looked at. Counting it
      // as neither left it off every list the panel draws.
      expect(const DoneState().resting, isTrue);
      expect(const IdleState().resting, isTrue);
      expect(const DoneState().active, isFalse);
      expect(const WorkingState().resting, isFalse);
    });

    test('only blocked is waiting on an answer', () {
      expect(
        AgentState.all
            .where((state) => state.blocked)
            .map((state) => state.word),
        ['blocked'],
      );
      expect(const DoneState().blocked, isFalse);
    });

    test('a state nobody could classify claims nothing', () {
      const state = UnknownState('compacting');
      expect(state.active, isFalse);
      expect(state.resting, isFalse);
      expect(state.blocked, isFalse);
    });

    test('every state prints the word it came from', () {
      expect(const WorkingState().label, 'WORKING');
      expect(const DoneState().label, 'DONE');
    });
  });
}
