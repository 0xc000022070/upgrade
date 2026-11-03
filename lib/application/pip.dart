import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/platform/pip.dart';
import 'package:upgrade/application/agents/agents.dart';

class PipSurface {
  const PipSurface();

  Future<bool> available() => Pip.available();

  Future<bool> enter({Size? aspect}) => Pip.enter(aspect: aspect);

  Stream<bool> mode() => Pip.mode();
}

class AbsentPip implements PipSurface {
  const AbsentPip();

  @override
  Future<bool> available() async => false;

  @override
  Future<bool> enter({Size? aspect}) async => false;

  @override
  Stream<bool> mode() => const Stream.empty();
}

final pipSurfaceProvider = Provider<PipSurface>((ref) => const AbsentPip());

final pipAvailableProvider = FutureProvider<bool>(
  (ref) => ref.watch(pipSurfaceProvider).available(),
);

final pipModeProvider = StreamProvider<bool>(
  (ref) => ref.watch(pipSurfaceProvider).mode(),
);

enum PipAction { absent, quiet, live }

final pipActionProvider = Provider<PipAction>((ref) {
  if (ref.watch(pipAvailableProvider).value != true) {
    return PipAction.absent;
  }
  final agents = ref.watch(agentsFeedProvider).value;
  if (agents == null || agents.noHost) return PipAction.absent;
  if (!ref.watch(agentsFeedLiveProvider) || agents.tally.isEmpty) {
    return PipAction.quiet;
  }
  return PipAction.live;
});
