import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/providers.dart';
import 'package:upgrade/data/repositories/settings_repository.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';

enum BubbleHolds {
  both('SCREENS AND BROWSER', 'SCREENS · BROWSER', UpgradeIcons.bubble),
  screens('SCREENS', 'SCREENS', UpgradeIcons.screens),
  browser('BROWSER', 'BROWSER', UpgradeIcons.browser),
  off('OFF', '', UpgradeIcons.bubble);

  const BubbleHolds(this.label, this.word, this.icon);

  final String label;
  final String word;
  final UpgradeIcons icon;

  bool get hasScreens => this == both || this == screens;
  bool get hasBrowser => this == both || this == browser;
}

final bubbleHoldsProvider = StreamProvider<BubbleHolds>(
  (ref) => ref
      .watch(settingsRepositoryProvider)
      .watchText(SettingsRepository.bubble, orElse: BubbleHolds.both.name)
      .map(
        (name) => BubbleHolds.values.firstWhere(
          (holds) => holds.name == name,
          orElse: () => BubbleHolds.both,
        ),
      ),
);
