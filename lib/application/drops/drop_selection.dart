import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  void beginMany(String scope, Set<String> ids) =>
      state = DropSelection(scope, {...ids});

  void beginEmpty(String scope) => state = DropSelection(scope, const {});

  void toggle(String id) {
    if (!state.active) return;
    final ids = {...state.ids};
    if (!ids.remove(id)) ids.add(id);
    state = DropSelection(state.scope, ids);
  }

  void clear() {
    if (state.active) state = const DropSelection.off();
  }

  /// A microtask because `dispose` runs while Flutter finalizes the tree, and a provider
  /// written there asks a deactivated ancestor to rebuild.
  void clearScopeLater(String scope) {
    scheduleMicrotask(() {
      if (_gone) return;
      if (state.ownedBy(scope)) state = const DropSelection.off();
    });
  }

  /// What went, never what is missing: a row can be in the set before the stream that
  /// feeds the panel has delivered it.
  void forget(String scope, Set<String> removed) {
    if (!state.ownedBy(scope)) return;
    final kept = state.ids.where((id) => !removed.contains(id)).toSet();
    if (kept.length != state.ids.length) {
      state = DropSelection(state.scope, kept);
    }
  }
}

final dropSelectionProvider =
    NotifierProvider<DropSelectionNotifier, DropSelection>(
      DropSelectionNotifier.new,
    );
