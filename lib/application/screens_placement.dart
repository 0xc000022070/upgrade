import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/providers.dart';
import 'package:upgrade/data/repositories/settings_repository.dart';

const browserBesideWidth = 720.0;

final screensHostProvider = StreamProvider<String?>(
  (ref) => ref
      .watch(settingsRepositoryProvider)
      .watchRaw(SettingsRepository.screensHost),
);

final rememberScreensHostProvider = Provider<Future<void> Function(String)>(
  (ref) =>
      (hostId) => ref
          .read(settingsRepositoryProvider)
          .setText(SettingsRepository.screensHost, hostId),
);

typedef ScreensRest = ({bool right, double top});

final screensRestProvider = FutureProvider<ScreensRest?>((ref) async {
  final raw = await ref
      .read(settingsRepositoryProvider)
      .text(SettingsRepository.screensRest, orElse: '');
  final at = raw.indexOf(':');
  if (at < 0) return null;
  final side = raw.substring(0, at);
  final top = double.tryParse(raw.substring(at + 1));
  if (top == null || !top.isFinite || (side != 'right' && side != 'left')) {
    return null;
  }
  return (right: side == 'right', top: top);
});

final rememberScreensRestProvider =
    Provider<Future<void> Function(ScreensRest)>(
      (ref) =>
          (rest) => ref
              .read(settingsRepositoryProvider)
              .setText(
                SettingsRepository.screensRest,
                '${rest.right ? 'right' : 'left'}:${rest.top}',
              ),
    );
