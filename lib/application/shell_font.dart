const shellFontSizeDefault = 13.0;
const shellFontSizeMin = 8.0;
const shellFontSizeMax = 24.0;

double pinchedFontSize(double base, double scale) =>
    (base * scale).roundToDouble().clamp(shellFontSizeMin, shellFontSizeMax);
