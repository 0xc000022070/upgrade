/// The terminal's type size in logical points: what every build drew before
/// the size could be changed, and the two ends a pinch can reach. The phone's
/// own font scale is applied on top of whichever of these is current.
const shellFontSizeDefault = 13.0;
const shellFontSizeMin = 8.0;
const shellFontSizeMax = 24.0;

/// The size a pinch lands on: the size the fingers started from, times how far
/// apart they are now against where they began, rounded to a whole point so
/// the glyphs keep to the pixel grid, and held between the two ends.
double pinchedFontSize(double base, double scale) =>
    (base * scale).roundToDouble().clamp(shellFontSizeMin, shellFontSizeMax);
