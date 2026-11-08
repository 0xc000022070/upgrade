import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/legacy.dart';

class AppLifecycleReading extends StateNotifier<bool>
    with WidgetsBindingObserver {
  AppLifecycleReading(this.reads)
    : super(reads(WidgetsBinding.instance.lifecycleState ?? _resumed)) {
    WidgetsBinding.instance.addObserver(this);
  }

  static const _resumed = AppLifecycleState.resumed;

  final bool Function(AppLifecycleState state) reads;

  Stream<bool> get readings async* {
    yield state;
    yield* stream;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    this.state = reads(state);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

final appForegroundProvider = StateNotifierProvider<AppLifecycleReading, bool>(
  (ref) => AppLifecycleReading((state) => state == AppLifecycleState.resumed),
);

final appVisibleProvider = StateNotifierProvider<AppLifecycleReading, bool>(
  (ref) => AppLifecycleReading(
    (state) =>
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive,
  ),
);
