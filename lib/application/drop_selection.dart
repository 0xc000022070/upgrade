import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// SPEC.md §39.13: a long press on a drop puts its panel into selection mode.
/// The state lives outside the panel because the bar that acts on it replaces
/// the capture bar, which is the panel's sibling and not its child.
///
/// [scope] names the panel that owns the mode — `home`, or a project's id. One
/// scope at a time: entering the mode anywhere leaves it everywhere else, which
/// is what keeps a selection from following the user to another screen.
class DropSelection {
  const DropSelection(this.scope, this.ids);
  const DropSelection.off() : scope = null, ids = const {};

  final String? scope;
  final Set<String> ids;

  static const homeScope = 'home';

  bool get active => scope != null;
  bool ownedBy(String scope) => this.scope == scope;
  int get count => ids.length;
  bool holds(String id) => ids.contains(id);
}

class DropSelectionNotifier extends Notifier<DropSelection> {
  var _gone = false;

  @override
  DropSelection build() {
    ref.onDispose(() => _gone = true);
    return const DropSelection.off();
  }

  void begin(String scope, String id) => state = DropSelection(scope, {id});

  /// §39.25: holding a fresh row checks every fresh row of that panel in the
  /// one gesture. The ids are the panel's own, already pruned to what it shows,
  /// so the batch can never act on a row that left it.
  void beginMany(String scope, Set<String> ids) =>
      state = DropSelection(scope, {...ids});

  /// §39.15: `SELECT` on the header strip enters the same mode with nothing
  /// checked. It is a separate entry point rather than [begin] with a null id
  /// because the long press is a gesture *on a row* and always has one.
  void beginEmpty(String scope) => state = DropSelection(scope, const {});

  /// Emptying the set does not leave the mode: un-checking the last row leaves
  /// the panel selectable with the two verbs disabled. Leaving is the `x` on
  /// the strip, the back gesture, or finishing an action.
  void toggle(String id) {
    if (!state.active) return;
    final ids = {...state.ids};
    if (!ids.remove(id)) ids.add(id);
    state = DropSelection(state.scope, ids);
  }

  void clear() {
    if (state.active) state = const DropSelection.off();
  }

  /// The panel's teardown path, for the case the tab shell cannot see: a
  /// pushed screen popped while its DROPS panel held a selection.
  ///
  /// It is a microtask because a widget's `dispose` runs while Flutter is
  /// finalizing the tree, and a provider written there would ask an ancestor
  /// that is already deactivated to rebuild. By the time the microtask runs the
  /// tree is settled — or the whole container is gone, which is what [_gone]
  /// answers, since a dead provider cannot be written to.
  void clearScopeLater(String scope) {
    scheduleMicrotask(() {
      if (_gone) return;
      if (state.ownedBy(scope)) state = const DropSelection.off();
    });
  }

  /// The rows a panel is showing are the only ones that can stay selected: an
  /// item deleted or moved from somewhere else must not be acted on by a batch
  /// that can no longer see it.
  void prune(String scope, Set<String> present) {
    if (!state.ownedBy(scope)) return;
    final kept = state.ids.where(present.contains).toSet();
    if (kept.length != state.ids.length) {
      state = DropSelection(state.scope, kept);
    }
  }
}

final dropSelectionProvider =
    NotifierProvider<DropSelectionNotifier, DropSelection>(
      DropSelectionNotifier.new,
    );
