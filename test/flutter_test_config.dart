import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

/// Idle tasks run at once: the scheduler defers them while a ticker runs, and under
/// the fake clock a view mid-transition never lets the pump return.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized().schedulingStrategy = ({
    required int priority,
    required SchedulerBinding scheduler,
  }) => true;
  await testMain();
}
