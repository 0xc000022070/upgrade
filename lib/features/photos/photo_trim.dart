import 'dart:ui';

typedef TrimGrip = ({bool left, bool top, bool right, bool bottom});

const TrimGrip trimBody = (left: true, top: true, right: true, bottom: true);

TrimGrip? gripAt(Rect box, Offset at, double reach) {
  final across = at.dx >= box.left - reach && at.dx <= box.right + reach;
  final along = at.dy >= box.top - reach && at.dy <= box.bottom + reach;
  if (!across || !along) return null;
  final grip = (
    left: (at.dx - box.left).abs() <= reach,
    top: (at.dy - box.top).abs() <= reach,
    right: (at.dx - box.right).abs() <= reach,
    bottom: (at.dy - box.bottom).abs() <= reach,
  );
  final horizontal = grip.left && grip.right
      ? (at.dx - box.left).abs() <= (at.dx - box.right).abs()
      : null;
  final vertical = grip.top && grip.bottom
      ? (at.dy - box.top).abs() <= (at.dy - box.bottom).abs()
      : null;
  final settled = (
    left: horizontal ?? grip.left,
    top: vertical ?? grip.top,
    right: horizontal == null ? grip.right : !horizontal,
    bottom: vertical == null ? grip.bottom : !vertical,
  );
  if (settled.left || settled.top || settled.right || settled.bottom) {
    return settled;
  }
  return box.contains(at) ? trimBody : null;
}

Rect dragTrim(
  Rect box,
  TrimGrip grip,
  Offset delta,
  Rect bounds,
  double minSide,
) {
  if (grip == trimBody) {
    final dx = delta.dx.clamp(bounds.left - box.left, bounds.right - box.right);
    final dy = delta.dy.clamp(bounds.top - box.top, bounds.bottom - box.bottom);
    return box.shift(Offset(dx, dy));
  }
  return Rect.fromLTRB(
    grip.left
        ? (box.left + delta.dx).clamp(bounds.left, box.right - minSide)
        : box.left,
    grip.top
        ? (box.top + delta.dy).clamp(bounds.top, box.bottom - minSide)
        : box.top,
    grip.right
        ? (box.right + delta.dx).clamp(box.left + minSide, bounds.right)
        : box.right,
    grip.bottom
        ? (box.bottom + delta.dy).clamp(box.top + minSide, bounds.bottom)
        : box.bottom,
  );
}
