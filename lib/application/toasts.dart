import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

const toastHold = Duration(seconds: 30);
const toastNotice = Duration(seconds: 4);

const toastRowsShown = 3;

const toastStackLimit = 6;

class Toast {
  const Toast({
    required this.id,
    required this.verb,
    this.subject,
    this.actionLabel,
    this.onAction,
  });

  /// Raising an id that is already up replaces it where it stands, so a state turned over
  /// twice is one row and not two.
  final String id;

  final String verb;

  final String? subject;

  final String? actionLabel;

  /// Handed the container's own [Ref] rather than closing over a widget's: the row outlives
  /// the screen that raised it by up to [toastHold], and a `WidgetRef` read after that
  /// screen is gone throws.
  final Future<void> Function(Ref ref)? onAction;

  bool get actionable => onAction != null && actionLabel != null;

  Duration get dwell => actionable ? toastHold : toastNotice;
}

class ToastQueue extends Notifier<List<Toast>> {
  final _clocks = <String, Timer>{};

  @override
  List<Toast> build() {
    ref.onDispose(_stopAll);
    return const [];
  }

  void _stopAll() {
    for (final clock in _clocks.values) {
      clock.cancel();
    }
    _clocks.clear();
  }

  void raise(Toast toast) {
    _clocks.remove(toast.id)?.cancel();
    final live = [...state.where((other) => other.id != toast.id), toast];
    // The oldest goes rather than the newest being refused: what a row offers is a shortcut
    // to something still reachable without it, so the top of the stack is the cheap end.
    while (live.length > toastStackLimit) {
      _clocks.remove(live.removeAt(0).id)?.cancel();
    }
    state = live;
    _clocks[toast.id] = Timer(toast.dwell, () => dismiss(toast.id));
  }

  void dismiss(String id) {
    _clocks.remove(id)?.cancel();
    state = [...state.where((toast) => toast.id != id)];
  }

  void clear() {
    if (_clocks.isEmpty && state.isEmpty) return;
    _stopAll();
    state = const [];
  }

  Future<void> act(String id) async {
    final toast = _find(id);
    final action = toast?.onAction;
    if (action == null) return;
    dismiss(id);
    await action(ref);
  }

  Toast? _find(String id) {
    for (final toast in state) {
      if (toast.id == id) return toast;
    }
    return null;
  }
}

final toastQueueProvider = NotifierProvider<ToastQueue, List<Toast>>(
  ToastQueue.new,
);
