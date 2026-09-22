const asciiRamp = ' .:!+c?oXm#%MW\$';

const asciiLevels = asciiRamp.length;

const _ditherSpread = 1.0 / (asciiLevels - 1);

int asciiGlyph(double shade, double dither) {
  final v = shade + (dither - 0.5) * _ditherSpread;
  if (v <= 0) return 0;
  if (v >= 1) return asciiLevels - 1;
  return (v * (asciiLevels - 1)).round();
}
