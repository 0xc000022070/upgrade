import 'dart:math';
import 'dart:typed_data';

const _camZ = 3.0;
const _fov = 0.45;

const kittenYaw = 0.20;
const kittenYawRate = 0.013;

const _maxSteps = 128;
const _maxDist = 6.5;
const _surfEps = 0.0015;
const _bound = 1.65;

const _stepScale = 0.68;

const _aoStep = 0.045;
const _aoRatio = 2.10;
const _aoTaps = 5;
const _aoFalloff = 0.75;
const _aoGain = 0.6;
const _aoSpread = 0.75;
const _aoTurn = 2.399963;

const _shadowSteps = 28;
const _shadowNear = 0.02;
const _shadowFar = 1.6;
const _shadowK = 12.0;
const _shadowMin = 0.10;

const _toneBias = 0.35;
const _toneGain = 4.2;

const _grow = 1.57;
const _lift = -0.505;

const _eyeAtX = 0.182;
const _eyeAtY = 0.010;
const _eyeAtZ = 0.330;
const _eyeHalfX = 0.126;
const _eyeHalfY = 0.086;

/// Deeper than the head is thick: the face is cut through, so what reads as an
/// eye is the ground behind the figure, not a pocket the key light relights.
const _eyeHalfZ = 0.90;

const _eyeTiltSin = 0.29552021;
const _eyeTiltCos = 0.95533649;

double _smin(double a, double b, double k) {
  final h = (0.5 + 0.5 * (b - a) / k).clamp(0.0, 1.0);
  return b * (1.0 - h) + a * h - k * h * (1.0 - h);
}

double _smax(double a, double b, double k) => -_smin(-a, -b, k);

double _ellipsoid(
  double px,
  double py,
  double pz,
  double rx,
  double ry,
  double rz,
) {
  final qx = px / rx;
  final qy = py / ry;
  final qz = pz / rz;
  final k0 = sqrt(qx * qx + qy * qy + qz * qz);
  if (k0 == 0.0) return -min(rx, min(ry, rz));
  final wx = qx / rx;
  final wy = qy / ry;
  final wz = qz / rz;
  final k1 = sqrt(wx * wx + wy * wy + wz * wz);
  if (k1 == 0.0) return 0.0;
  return k0 * (k0 - 1.0) / k1;
}

double _roundBox(
  double px,
  double py,
  double pz,
  double bx,
  double by,
  double bz,
  double r,
) {
  final qx = px.abs() - bx;
  final qy = py.abs() - by;
  final qz = pz.abs() - bz;
  final ox = max(qx, 0.0);
  final oy = max(qy, 0.0);
  final oz = max(qz, 0.0);
  final outside = sqrt(ox * ox + oy * oy + oz * oz);
  final inside = min(max(qx, max(qy, qz)), 0.0);
  return outside + inside - r;
}

double _sphere(double px, double py, double pz, double r) =>
    sqrt(px * px + py * py + pz * pz) - r;

double _roundCone(
  double px,
  double py,
  double pz,
  double ax,
  double ay,
  double az,
  double bx,
  double by,
  double bz,
  double r1,
  double r2,
) {
  final bax = bx - ax;
  final bay = by - ay;
  final baz = bz - az;
  final l2 = bax * bax + bay * bay + baz * baz;
  final pax = px - ax;
  final pay = py - ay;
  final paz = pz - az;
  if (l2 == 0.0) {
    return sqrt(pax * pax + pay * pay + paz * paz) - max(r1, r2);
  }
  final rr = r1 - r2;
  final a2 = l2 - rr * rr;
  final il2 = 1.0 / l2;

  final y = pax * bax + pay * bay + paz * baz;
  final z = y - l2;
  final xx = pax * l2 - bax * y;
  final xy = pay * l2 - bay * y;
  final xz = paz * l2 - baz * y;
  final x2 = xx * xx + xy * xy + xz * xz;
  final y2 = y * y * l2;
  final z2 = z * z * l2;

  final k = rr.sign * rr * rr * x2;
  if (z.sign * a2 * z2 > k) return sqrt(x2 + z2) * il2 - r2;
  if (y.sign * a2 * y2 < k) return sqrt(x2 + y2) * il2 - r1;
  return (sqrt(x2 * a2 * il2) + y * rr) * il2 - r1;
}

double _flatCone(
  double px,
  double py,
  double pz,
  double ax,
  double ay,
  double az,
  double bx,
  double by,
  double bz,
  double r1,
  double r2,
  double flat,
) =>
    _roundCone(
      px,
      py,
      pz / flat,
      ax,
      ay,
      az / flat,
      bx,
      by,
      bz / flat,
      r1,
      r2,
    ) *
    flat;

double _ears(double px, double py, double pz) {
  final left = _flatCone(
    px,
    py,
    pz,
    -0.205,
    0.155,
    0.020,
    -0.315,
    1.050,
    -0.010,
    0.130,
    0.008,
    0.46,
  );
  final right = _flatCone(
    px,
    py,
    pz,
    0.185,
    0.140,
    0.020,
    0.400,
    0.920,
    -0.010,
    0.215,
    0.010,
    0.46,
  );
  return min(left, right);
}

double _head(double px, double py, double pz) {
  final cranium = _ellipsoid(px, py - 0.055, pz, 0.450, 0.255, 0.370);
  final jowls = _ellipsoid(px, py + 0.115, pz - 0.030, 0.520, 0.205, 0.360);
  var d = _smin(cranium, jowls, 0.160);
  final chin = _ellipsoid(px, py + 0.290, pz - 0.050, 0.260, 0.125, 0.250);
  return _smin(d, chin, 0.130);
}

double _whiskers(double px, double py, double pz) {
  var d = _sphere(px + 0.610, py + 0.070, pz - 0.090, 0.034);
  d = min(d, _sphere(px + 0.700, py + 0.150, pz - 0.060, 0.029));
  d = min(d, _sphere(px + 0.575, py + 0.225, pz - 0.085, 0.031));
  d = min(d, _sphere(px - 0.640, py + 0.290, pz - 0.070, 0.032));
  return min(d, _sphere(px - 0.725, py + 0.370, pz - 0.045, 0.027));
}

double _eyeVoid(
  double ox,
  double oy,
  double oz,
  double tilt,
  double hx,
  double hy,
) {
  final rx = ox * _eyeTiltCos - oy * _eyeTiltSin * tilt;
  final ry = ox * _eyeTiltSin * tilt + oy * _eyeTiltCos;
  return _ellipsoid(rx, ry, oz, hx, hy, _eyeHalfZ);
}

double _face(double px, double py, double pz) {
  var d = _eyeVoid(px + 0.175, py - 0.005, pz, -1.0, 0.120, 0.082);
  d = min(
    d,
    _eyeVoid(px - _eyeAtX, py - _eyeAtY, pz, 1.0, _eyeHalfX, _eyeHalfY),
  );
  final bridge = _roundBox(px, py + 0.108, pz, 0.038, 0.066, _eyeHalfZ, 0.010);
  d = min(d, bridge);
  final mouth = _roundBox(px, py + 0.240, pz, 0.170, 0.028, _eyeHalfZ, 0.008);
  return min(d, mouth);
}

double _shape(double px, double py, double pz) {
  var d = _smin(_head(px, py, pz), _ears(px, py, pz), 0.055);
  d = _smax(d, -_face(px, py, pz), 0.016);
  return min(d, _whiskers(px, py, pz));
}

double kittenMap(double px, double py, double pz) =>
    _shape(px / _grow, (py - _lift) / _grow, pz / _grow) * _grow;

class KittenPose {
  const KittenPose({
    this.dx = 0.0,
    this.dy = 0.0,
    this.scale = 1.0,
    this.yaw = 0.0,
    this.tick = 0.0,
    this.light = 1.0,
  });

  final double dx;
  final double dy;
  final double scale;

  final double yaw;
  final double tick;

  final double light;
}

class KittenFrame {
  const KittenFrame({
    required this.width,
    required this.height,
    required this.shade,
    required this.spark,
  });

  final int width;
  final int height;
  final Float64List shade;

  final Point<int>? spark;
}

void _normal(double px, double py, double pz, Float64List out) {
  const e = 0.002;
  final nx = kittenMap(px + e, py, pz) - kittenMap(px - e, py, pz);
  final ny = kittenMap(px, py + e, pz) - kittenMap(px, py - e, pz);
  final nz = kittenMap(px, py, pz + e) - kittenMap(px, py, pz - e);
  final l = sqrt(nx * nx + ny * ny + nz * nz);
  if (l == 0.0) {
    out[0] = 0.0;
    out[1] = 0.0;
    out[2] = 1.0;
    return;
  }
  out[0] = nx / l;
  out[1] = ny / l;
  out[2] = nz / l;
}

double _occlusion(
  double px,
  double py,
  double pz,
  double nx,
  double ny,
  double nz,
) {
  final sx = nz.abs() < 0.9 ? 0.0 : 1.0;
  final sz = nz.abs() < 0.9 ? 1.0 : 0.0;
  var tx = -sz * ny;
  var ty = sz * nx - sx * nz;
  var tz = sx * ny;
  final tl = sqrt(tx * tx + ty * ty + tz * tz);
  if (tl == 0.0) return 1.0;
  tx /= tl;
  ty /= tl;
  tz /= tl;
  final bx = ny * tz - nz * ty;
  final by = nz * tx - nx * tz;
  final bz = nx * ty - ny * tx;

  var occ = 0.0;
  var total = 0.0;
  var weight = 1.0;
  var h = _aoStep;
  for (var i = 1; i <= _aoTaps; i++) {
    final a = i * _aoTurn;
    final s = sin(a);
    final c = cos(a);
    final r = _aoSpread * h;
    final qx = px + nx * h + tx * c * r + bx * s * r;
    final qy = py + ny * h + ty * c * r + by * s * r;
    final qz = pz + nz * h + tz * c * r + bz * s * r;
    occ += weight * ((h - kittenMap(qx, qy, qz)) / h).clamp(0.0, 1.0);
    total += weight;
    weight *= _aoFalloff;
    h *= _aoRatio;
  }
  return (1.0 - _aoGain * occ / total).clamp(0.0, 1.0);
}

double _shadow(
  double px,
  double py,
  double pz,
  double lx,
  double ly,
  double lz,
) {
  var res = 1.0;
  var t = _shadowNear;
  for (var i = 0; i < _shadowSteps; i++) {
    final h = kittenMap(px + lx * t, py + ly * t, pz + lz * t);
    if (h < _surfEps) return _shadowMin;
    res = min(res, _shadowK * h / t);
    t += h;
    if (t > _shadowFar) break;
  }
  return _shadowMin + (1.0 - _shadowMin) * res.clamp(0.0, 1.0);
}

KittenFrame renderKitten({
  required int width,
  required int height,
  required double rowPitch,
  required KittenPose pose,
  int samples = 2,
}) {
  final shade = Float64List(width * height);
  if (width == 0 || height == 0) {
    return KittenFrame(width: width, height: height, shade: shade, spark: null);
  }

  final span = height * 0.5 * rowPitch;
  final cx = (width - 1) * 0.5 + pose.dx * span;
  final cy = (height - 1) * 0.5 + pose.dy * span / rowPitch;
  final unit = span * max(pose.scale, 1e-9);
  final angle = kittenYaw * sin(pose.tick * kittenYawRate) + pose.yaw;

  final ca = cos(-angle);
  final sa = sin(-angle);
  final rox = _camZ * sa;
  final roz = _camZ * ca;
  const l0x = 0.0;
  const l0y = 0.30;
  const l0z = 0.95;
  final l0l = sqrt(l0x * l0x + l0y * l0y + l0z * l0z);
  final lnx = l0x / l0l;
  final lny = l0y / l0l;
  final lnz = l0z / l0l;
  final lx = lnx * ca + lnz * sa;
  final ly = lny;
  final lz = -lnx * sa + lnz * ca;

  final n = Float64List(3);
  final step = 1.0 / samples;
  final weight = 1.0 / (samples * samples);

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      var acc = 0.0;
      for (var sy = 0; sy < samples; sy++) {
        final fy = y + (sy + 0.5) * step - 0.5;
        final uy = (fy - cy) * rowPitch / unit;
        for (var sx = 0; sx < samples; sx++) {
          final fx = x + (sx + 0.5) * step - 0.5;
          final ux = (fx - cx) / unit;

          var rdx = ux * _fov;
          var rdy = -uy * _fov;
          var rdz = -1.0;
          final rl = sqrt(rdx * rdx + rdy * rdy + rdz * rdz);
          rdx /= rl;
          rdy /= rl;
          rdz /= rl;
          final wx = rdx * ca + rdz * sa;
          final wy = rdy;
          final wz = -rdx * sa + rdz * ca;

          final b = rox * wx + roz * wz;
          final c = rox * rox + roz * roz - _bound * _bound;
          final disc = b * b - c;
          if (disc < 0.0) continue;
          var t = max(-b - sqrt(disc), 0.0);

          var hit = false;
          for (var i = 0; i < _maxSteps; i++) {
            final d = kittenMap(rox + wx * t, wy * t, roz + wz * t);
            if (d < _surfEps) {
              hit = true;
              break;
            }
            t += d * _stepScale;
            if (t > _maxDist) break;
          }
          if (!hit) continue;

          final hx = rox + wx * t;
          final hy = wy * t;
          final hz = roz + wz * t;
          _normal(hx, hy, hz, n);
          final ao = _occlusion(hx, hy, hz, n[0], n[1], n[2]);
          final sh = _shadow(
            hx + n[0] * _surfEps * 6.0,
            hy + n[1] * _surfEps * 6.0,
            hz + n[2] * _surfEps * 6.0,
            lx,
            ly,
            lz,
          );
          final diff = 0.5 + 0.5 * (n[0] * lx + n[1] * ly + n[2] * lz);
          final facing = max(-(n[0] * wx + n[1] * wy + n[2] * wz), 0.0);
          final rim = pow(1.0 - facing, 4).toDouble();
          final lit = (0.64 + 0.36 * diff) * ao * sh + 0.18 * rim * ao;
          var v = ((lit - _toneBias) * _toneGain).clamp(0.0, 1.0);
          v = v * v * (3.0 - 2.0 * v);
          acc += v * weight;
        }
      }
      if (acc > 0) shade[y * width + x] = (acc * pose.light).clamp(0.0, 1.0);
    }
  }

  return KittenFrame(
    width: width,
    height: height,
    shade: shade,
    spark: _project(
      _eyeAtX * _grow,
      _eyeAtY * _grow + _lift,
      _eyeAtZ * _grow,
      angle: angle,
      cx: cx,
      cy: cy,
      unit: unit,
      rowPitch: rowPitch,
      width: width,
      height: height,
    ),
  );
}

Point<int>? _project(
  double wx,
  double wy,
  double wz, {
  required double angle,
  required double cx,
  required double cy,
  required double unit,
  required double rowPitch,
  required int width,
  required int height,
}) {
  final ca = cos(angle);
  final sa = sin(angle);
  final vx = wx * ca + wz * sa;
  final vy = wy;
  final vz = -wx * sa + wz * ca;

  final depth = _camZ - vz;
  if (depth <= 0.0) return null;

  final ux = vx / (_fov * depth);
  final uy = -vy / (_fov * depth);
  final sx = (cx + ux * unit).round();
  final sy = (cy + uy * unit / rowPitch).round();
  if (sx < 0 || sx >= width || sy < 0 || sy >= height) return null;

  final reach = sqrt(vx * vx + vy * vy + depth * depth);
  final dx = vx / reach;
  final dy = vy / reach;
  final dz = -depth / reach;
  final ox = -_camZ * sa;
  final oz = _camZ * ca;
  final rdx = dx * ca - dz * sa;
  final rdz = dx * sa + dz * ca;

  var t = 0.0;
  for (var i = 0; i < _maxSteps; i++) {
    final d = kittenMap(ox + rdx * t, dy * t, oz + rdz * t);
    if (d < _surfEps) return null;
    t += d * _stepScale;
    if (t >= reach) return Point(sx, sy);
  }
  return Point(sx, sy);
}
