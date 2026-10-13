import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/agents/agents.dart';

class FreshDrops {
  const FreshDrops(this.scope, this.ids);
  const FreshDrops.none() : scope = null, ids = const {};

  final String? scope;
  final Set<String> ids;

  bool ownedBy(String scope) => this.scope == scope;

  bool holds(String scope, String id) => ownedBy(scope) && ids.contains(id);
  Set<String> idsIn(String scope) => ownedBy(scope) ? ids : const {};
}

class FreshDropsNotifier extends Notifier<FreshDrops> {
  var _gone = false;

  @override
  FreshDrops build() {
    ref.onDispose(() => _gone = true);
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

  /// A microtask for the reason [DropSelectionNotifier] uses one: `dispose` runs while
  /// the tree is being finalized.
  void clearScopeLater(String scope) {
    scheduleMicrotask(() {
      if (_gone) return;
      if (state.ownedBy(scope)) state = const FreshDrops.none();
    });
  }

  /// What the panel stopped showing, never what it is missing: the bar marks a row fresh
  /// a frame or more before the stream delivers it.
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
