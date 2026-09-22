import 'dart:math';

class Surge {
  const Surge(this.period);

  final double period;

  double get _w => (2 * pi) / max(period, 1e-9);

  double level(double t) {
    final s = 0.5 + 0.5 * sin(_w * t);
    return s * s;
  }

  double integral(double t) {
    final w = _w;
    return 0.375 * t -
        (0.5 / w) * cos(w * t) -
        (0.125 / (2.0 * w)) * sin(2.0 * w * t);
  }

  double phase(double base, double surge, double t) =>
      base * (t + surge * integral(t));
}
