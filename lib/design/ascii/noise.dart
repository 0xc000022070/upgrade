int hash2(int x, int y) {
  var h = (x * 0x27d4eb2d) ^ (y * 0x85645f9f);
  h &= 0xffffffff;
  h ^= h >>> 15;
  h = (h * 0x2c1b3c6d) & 0xffffffff;
  h ^= h >>> 12;
  h = (h * 0x297a2d39) & 0xffffffff;
  h ^= h >>> 15;
  return h & 0xffffffff;
}

double hash01(int x, int y) => hash2(x, y) / 0xffffffff;

double valueNoise(double x, double y) {
  final xi = x.floorToDouble();
  final yi = y.floorToDouble();
  final xf = x - xi;
  final yf = y - yi;
  final u = xf * xf * (3.0 - 2.0 * xf);
  final v = yf * yf * (3.0 - 2.0 * yf);
  final ix = xi.toInt();
  final iy = yi.toInt();

  final a = hash01(ix, iy);
  final b = hash01(ix + 1, iy);
  final c = hash01(ix, iy + 1);
  final d = hash01(ix + 1, iy + 1);

  return (a * (1.0 - u) + b * u) * (1.0 - v) + (c * (1.0 - u) + d * u) * v;
}

double fbm(double x, double y, int octaves) {
  var sum = 0.0;
  var amp = 0.5;
  var norm = 0.0;
  var px = x;
  var py = y;
  for (var i = 0; i < octaves; i++) {
    sum += amp * valueNoise(px, py);
    norm += amp;
    amp *= 0.5;
    final nx = px * 2.03 + 11.7;
    final ny = py * 2.03 - 5.3;
    px = nx;
    py = ny;
  }
  return norm == 0.0 ? 0.0 : sum / norm;
}

const bayer8 = <int>[
  0, 32, 8, 40, 2, 34, 10, 42, //
  48, 16, 56, 24, 50, 18, 58, 26,
  12, 44, 4, 36, 14, 46, 6, 38,
  60, 28, 52, 20, 62, 30, 54, 22,
  3, 35, 11, 43, 1, 33, 9, 41,
  51, 19, 59, 27, 49, 17, 57, 25,
  15, 47, 7, 39, 13, 45, 5, 37,
  63, 31, 55, 23, 61, 29, 53, 21,
];

double bayer(int x, int y) => (bayer8[(y & 7) * 8 + (x & 7)] + 0.5) / 64.0;
