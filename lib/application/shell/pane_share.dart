import 'package:striked/data/repositories/settings_repository.dart';

enum PaneSeam {
  beside(
    key: SettingsRepository.codeSidebarShare,
    fallback: 0.4,
    min: 0.2,
    max: 0.7,
  ),
  over(
    key: SettingsRepository.codeDrawerShare,
    fallback: 0.85,
    min: 0.5,
    max: 0.9,
  );

  const PaneSeam({
    required this.key,
    required this.fallback,
    required this.min,
    required this.max,
  });

  final String key;

  final double fallback;

  final double min;
  final double max;

  double dragged(double base, double moved, double width) =>
      width <= 0 ? base : (base + moved / width).clamp(min, max);
}
