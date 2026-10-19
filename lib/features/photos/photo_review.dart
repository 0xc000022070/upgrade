import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'package:striked/design/components/panel.dart';
import 'package:striked/design/icons/striked_icon.dart';
import 'package:striked/design/icons/striked_icons.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/features/photos/photo_cut.dart';

Future<List<ReviewedPhoto>?> reviewPhotos(
  BuildContext context,
  List<String> paths, {
  required String verb,
}) {
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<List<ReviewedPhoto>>(
      opaque: true,
      pageBuilder: (_, _, _) => _PhotoReview(paths: paths, verb: verb),
    ),
  );
}

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

const _whole = Rect.fromLTRB(0, 0, 1, 1);

Rect _scaled(Rect unit, Size size) => Rect.fromLTRB(
  unit.left * size.width,
  unit.top * size.height,
  unit.right * size.width,
  unit.bottom * size.height,
);

bool _isWhole(Rect unit) =>
    unit.left <= 1e-4 &&
    unit.top <= 1e-4 &&
    unit.right >= 1 - 1e-4 &&
    unit.bottom >= 1 - 1e-4;

class _Photo {
  _Photo(this.path);

  final String path;

  double? aspect;

  Rect? keep;

  ImageProvider at(int width) =>
      ResizeImage(FileImage(File(path)), width: width);
}

class _PhotoReview extends StatefulWidget {
  const _PhotoReview({required this.paths, required this.verb});

  final List<String> paths;
  final String verb;

  @override
  State<_PhotoReview> createState() => _PhotoReviewState();
}

class _PhotoReviewState extends State<_PhotoReview> {
  static const _reach = 24.0;
  static const _minSide = 48.0;
  static const _thumb = 48.0;
  static const _thumbPixels = 256;
  static const _ghost = 0.35;

  late final List<_Photo> _photos = [for (final p in widget.paths) _Photo(p)];
  final _pages = PageController();
  final _strip = ScrollController();
  int _at = 0;

  Rect? _draft;
  TrimGrip? _grip;

  @override
  void initState() {
    super.initState();
    for (final photo in _photos) {
      _measure(photo);
    }
  }

  @override
  void dispose() {
    _pages.dispose();
    _strip.dispose();
    super.dispose();
  }

  void _measure(_Photo photo) {
    final stream = photo.at(_thumbPixels).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      final aspect = info.image.width / info.image.height;
      info.dispose();
      stream.removeListener(listener);
      if (mounted) setState(() => photo.aspect = aspect);
    }, onError: (_, _) => stream.removeListener(listener));
    stream.addListener(listener);
  }

  void _turned(int index) {
    setState(() => _at = index);
    if (!_strip.hasClients) return;
    const extent = _thumb + Spacing.sm;
    final position = _strip.position;
    final target = (index * extent - (position.viewportDimension - extent) / 2)
        .clamp(0.0, position.maxScrollExtent);
    _strip.animateTo(
      target,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
    );
  }

  void _jump(int index) => _pages.animateToPage(
    index,
    duration: const Duration(milliseconds: 220),
    curve: Curves.easeOut,
  );

  void _remove() {
    if (_photos.length == 1) {
      Navigator.of(context).pop(const <ReviewedPhoto>[]);
      return;
    }
    setState(() {
      _photos.removeAt(_at);
      _at = math.min(_at, _photos.length - 1);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pages.hasClients) _pages.jumpToPage(_at);
    });
  }

  void _send() =>
      Navigator.of(context)
          .pop([for (final p in _photos) (path: p.path, keep: p.keep)]);

  void _crop() => setState(() => _draft = _photos[_at].keep ?? _whole);

  void _closeCrop({required bool keep}) {
    setState(() {
      final draft = _draft;
      if (keep && draft != null) {
        _photos[_at].keep = _isWhole(draft) ? null : draft;
      }
      _draft = null;
      _grip = null;
    });
  }

  void _grab(Offset at, Size shown) =>
      _grip = gripAt(_scaled(_draft!, shown), at, _reach);

  void _drag(Offset delta, Size shown) {
    final grip = _grip;
    final draft = _draft;
    if (grip == null || draft == null) return;
    final box = dragTrim(
      _scaled(draft, shown),
      grip,
      delta,
      Offset.zero & shown,
      math.min(_minSide, math.min(shown.width, shown.height)),
    );
    setState(
      () => _draft = Rect.fromLTRB(
        box.left / shown.width,
        box.top / shown.height,
        box.right / shown.width,
        box.bottom / shown.height,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cropping = _draft != null;
    final insets = MediaQuery.systemGestureInsetsOf(context);
    final pixels =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context))
            .round();
    return PopScope(
      canPop: !cropping,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeCrop(keep: false);
      },
      child: ColoredBox(
        color: context.tokens.mediaBackdrop,
        child: SafeArea(
          child: Column(
            children: [
              _ghosts(cropping),
              Expanded(
                child: PageView.builder(
                  controller: _pages,
                  physics: cropping
                      ? const NeverScrollableScrollPhysics()
                      : null,
                  itemCount: _photos.length,
                  onPageChanged: _turned,
                  itemBuilder: (context, index) {
                    final here = cropping && index == _at;
                    return Padding(
                      // A side handle inside the system's edge strip is a back swipe.
                      padding: EdgeInsets.symmetric(
                        vertical: Spacing.xxl,
                        horizontal:
                            Spacing.xxl + math.max(insets.left, insets.right),
                      ),
                      child: _Framed(
                        key: ValueKey('review-photo-$index'),
                        photo: _photos[index],
                        keep: here ? _draft : _photos[index].keep,
                        pixels: pixels,
                        cropping: here,
                        onGrab: _grab,
                        onDrag: _drag,
                        onLetGo: () => _grip = null,
                      ),
                    );
                  },
                ),
              ),
              SizedBox(
                height: TapTargets.minHeight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Spacing.screenEdge,
                  ),
                  child: cropping ? _cropBar() : _reviewBar(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ghosts(bool cropping) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.screenEdge,
        Spacing.md,
        Spacing.screenEdge,
        Spacing.md,
      ),
      child: SizedBox(
        height: _thumb,
        child: Row(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _strip,
                scrollDirection: Axis.horizontal,
                itemExtent: _thumb + Spacing.sm,
                itemCount: _photos.length,
                itemBuilder: (context, index) {
                  final current = index == _at;
                  return Padding(
                    padding: const EdgeInsets.only(right: Spacing.sm),
                    child: GestureDetector(
                      key: ValueKey('review-ghost-$index'),
                      behavior: HitTestBehavior.opaque,
                      onTap: cropping || current ? null : () => _jump(index),
                      child: Opacity(
                        opacity: current ? 1 : _ghost,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: current
                                  ? context.tokens.accent
                                  : context.tokens.borderSubtle,
                              width: Borders.hairline,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(Spacing.xs),
                            child: _Framed(
                              photo: _photos[index],
                              keep: current && cropping
                                  ? _draft
                                  : _photos[index].keep,
                              pixels: _thumbPixels,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(width: Spacing.md),
            Text(
              '${_at + 1} / ${_photos.length}',
              key: const ValueKey('review-position'),
              style: context.tokens.label,
            ),
          ],
        ),
      ),
    );
  }

  Widget _reviewBar() {
    final count = _photos.length;
    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: PanelAffordance(
              'CANCEL',
              key: const ValueKey('review-cancel'),
              showIcon: false,
              onTap: () => Navigator.of(context).pop(),
            ),
          ),
        ),
        _Tool(
          StrikedIcons.crop,
          key: const ValueKey('review-crop'),
          onTap: _photos[_at].aspect == null ? null : _crop,
        ),
        _Tool(
          StrikedIcons.close,
          key: const ValueKey('review-remove'),
          onTap: _remove,
        ),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: PanelAffordance(
              count > 1 ? '${widget.verb} $count' : widget.verb,
              key: const ValueKey('review-send'),
              showIcon: false,
              color: context.tokens.accent,
              onTap: _send,
            ),
          ),
        ),
      ],
    );
  }

  Widget _cropBar() {
    return Row(
      children: [
        PanelAffordance(
          'CANCEL',
          key: const ValueKey('crop-cancel'),
          showIcon: false,
          onTap: () => _closeCrop(keep: false),
        ),
        const Spacer(),
        PanelAffordance(
          'DONE',
          key: const ValueKey('crop-done'),
          showIcon: false,
          color: context.tokens.accent,
          onTap: () => _closeCrop(keep: true),
        ),
      ],
    );
  }
}

class _Tool extends StatelessWidget {
  const _Tool(this.icon, {super.key, this.onTap});

  final StrikedIcons icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox.square(
        dimension: TapTargets.minHeight,
        child: Center(
          child: StrikedIcon(
            icon,
            size: IconSizes.toolbar,
            color: onTap == null
                ? context.tokens.textDisabled
                : context.tokens.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _Framed extends StatelessWidget {
  const _Framed({
    super.key,
    required this.photo,
    required this.keep,
    required this.pixels,
    this.cropping = false,
    this.onGrab,
    this.onDrag,
    this.onLetGo,
  });

  final _Photo photo;
  final Rect? keep;
  final int pixels;
  final bool cropping;
  final void Function(Offset at, Size shown)? onGrab;
  final void Function(Offset delta, Size shown)? onDrag;
  final VoidCallback? onLetGo;

  @override
  Widget build(BuildContext context) {
    final aspect = photo.aspect;
    if (aspect == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final space = constraints.biggest;
        final shown = space.width / space.height > aspect
            ? Size(space.height * aspect, space.height)
            : Size(space.width, space.width / aspect);
        Widget framed = SizedBox.fromSize(
          size: shown,
          child: CustomPaint(
            foregroundPainter: _KeepPainter(
              keep: keep,
              cropping: cropping,
              scrim: context.tokens.scrim,
              accent: context.tokens.accent,
            ),
            child: Image(
              image: photo.at(pixels),
              fit: BoxFit.fill,
              gaplessPlayback: true,
            ),
          ),
        );
        if (cropping) {
          framed = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (details) => onGrab?.call(details.localPosition, shown),
            onPanUpdate: (details) => onDrag?.call(details.delta, shown),
            onPanEnd: (_) => onLetGo?.call(),
            onPanCancel: onLetGo,
            child: framed,
          );
        }
        return Center(child: framed);
      },
    );
  }
}

class _KeepPainter extends CustomPainter {
  const _KeepPainter({
    required this.keep,
    required this.cropping,
    required this.scrim,
    required this.accent,
  });

  final Rect? keep;
  final bool cropping;
  final Color scrim;
  final Color accent;

  static const _tick = 12.0;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = keep;
    if (unit == null) return;
    final box = _scaled(unit, size);
    final outside = Path()
      ..addRect(Offset.zero & size)
      ..addRect(box)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(outside, Paint()..color = scrim);
    if (!cropping) return;
    canvas.drawRect(
      box,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = Borders.hairline
        ..color = accent,
    );
    final tick = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = accent;
    for (final (corner, dx, dy) in [
      (box.topLeft, 1.0, 1.0),
      (box.topRight, -1.0, 1.0),
      (box.bottomLeft, 1.0, -1.0),
      (box.bottomRight, -1.0, -1.0),
    ]) {
      canvas.drawPath(
        Path()
          ..moveTo(corner.dx + dx * _tick, corner.dy)
          ..lineTo(corner.dx, corner.dy)
          ..lineTo(corner.dx, corner.dy + dy * _tick),
        tick,
      );
    }
  }

  @override
  bool shouldRepaint(_KeepPainter old) =>
      old.keep != keep ||
      old.cropping != cropping ||
      old.scrim != scrim ||
      old.accent != accent;
}
