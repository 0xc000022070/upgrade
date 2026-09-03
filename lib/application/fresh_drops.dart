import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'agents.dart';

/// SPEC.md §39.25: a drop captured from a screen's own capture bar is *fresh*
/// on that screen until the user leaves it. It is UI state and nothing else —
/// no column, no row, nothing that survives a restart — so it lives here beside
/// [DropSelection], which it feeds.
///
/// [scope] names the panel the set belongs to, the same string the selection
/// uses. One scope at a time: a capture aimed at another screen is a screen the
/// user has already walked to, and the set it replaces was going to clear on
/// the way there anyway.
class FreshDrops {
  const FreshDrops(this.scope, this.ids);
  const FreshDrops.none() : scope = null, ids = const {};

  final String? scope;
  final Set<String> ids;

  bool ownedBy(String scope) => this.scope == scope;

  /// The two questions a panel asks, both answered against its own scope so a
  /// project's rows are never lit by HOME's captures.
  bool holds(String scope, String id) => ownedBy(scope) && ids.contains(id);
  Set<String> idsIn(String scope) => ownedBy(scope) ? ids : const {};
}

class FreshDropsNotifier extends Notifier<FreshDrops> {
  var _gone = false;

  @override
  FreshDrops build() {
    ref.onDispose(() => _gone = true);
    // §39.25: the app leaving the foreground is the user leaving the screen.
    // The gate is read here rather than in the panel so backgrounding clears
    // the set once, whichever screen is up.
    ref.listen<bool>(appForegroundProvider, (_, foreground) {
      if (!foreground) clear();
    });
    return const FreshDrops.none();
  }

  void add(String scope, String id) {
    state = state.ownedBy(scope)
        ? FreshDrops(scope, {...state.ids, id})
        : FreshDrops(scope, {id});
  }

  void clear() {
    if (state.scope != null) state = const FreshDrops.none();
  }

  /// The panel's teardown path, for the screen popped out from under its own
  /// DROPS. A microtask for the same reason [DropSelectionNotifier] uses one:
  /// `dispose` runs while the tree is being finalized.
  void clearScopeLater(String scope) {
    scheduleMicrotask(() {
      if (_gone) return;
      if (state.ownedBy(scope)) state = const FreshDrops.none();
    });
  }

  /// §39.25: the set clears when a batch takes the last fresh row out of the
  /// panel. Dropping what went and letting an empty scope fall away is one rule
  /// for a move, a delete, and a row the quick view filed elsewhere.
  ///
  /// §39.27: [removed] is what the panel showed and stopped showing, not what
  /// it is missing. The bar marks a row fresh the moment the write returns,
  /// which is a frame or more before the stream delivers it; pruning against
  /// absence took that row's highlight away before it was ever drawn, and
  /// whether the stream won the race decided which rows in a fast sequence lit
  /// up.
  void forget(String scope, Set<String> removed) {
    if (!state.ownedBy(scope)) return;
    final kept = state.ids.where((id) => !removed.contains(id)).toSet();
    if (kept.length == state.ids.length) return;
    state = kept.isEmpty ? const FreshDrops.none() : FreshDrops(scope, kept);
  }
}

final freshDropsProvider = NotifierProvider<FreshDropsNotifier, FreshDrops>(
  FreshDropsNotifier.new,
);
