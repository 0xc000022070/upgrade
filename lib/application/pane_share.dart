import '../data/repositories/settings_repository.dart';

/// A seam of the explorer the user can move, and how far it goes.
///
/// The two are not one number. A pane the editor sits beside and a drawer that
/// lies over the top of it are different widths for the same tree: a drawer as
/// narrow as a sidebar hides what it is there to show, and a sidebar as wide as
/// a drawer leaves nothing to read next to it. So each seam keeps its own share
/// and its own ends, and neither end lets the other pane be dragged away.
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

  /// The preferences row the share is written to.
  final String key;

  /// The share before anyone has moved the seam: a little under half beside
  /// the editor, since a file's lines are longer than a file's name, and
  /// nearly all of it over the editor, where what is left is the strip that
  /// says the file is still open underneath.
  final double fallback;

  final double min;
  final double max;

  /// Where a drag lands: the share it started from, plus how far the finger
  /// has travelled against the width it is travelling across, held inside the
  /// ends. A width of nothing is a pane not laid out yet, which no drag can
  /// mean anything against.
  double dragged(double base, double moved, double width) =>
      width <= 0 ? base : (base + moved / width).clamp(min, max);
}
