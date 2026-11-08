import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/icons/upgrade_icon.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/application/files/photo_cut.dart';
import 'package:upgrade/features/photos/photo_trim.dart';

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

  List<PhotoMark> marks = const [];

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
  static const _shortestMark = 24.0;
  static const _loupeSide = 112.0;
  static const _loupeLift = 72.0;

  late final List<_Photo> _photos = [for (final p in widget.paths) _Photo(p)];
  final _pages = PageController();
  final _strip = ScrollController();
  int _at = 0;

  Rect? _draft;
  TrimGrip? _grip;

  List<PhotoMark>? _marking;
  MarkShape _shape = MarkShape.box;
  PhotoMark? _stroke;

  final _canvas = GlobalKey();
  final _screen = GlobalKey();
  Offset? _loupe;

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

  void _send() => Navigator.of(context).pop([
    for (final p in _photos) (path: p.path, keep: p.keep, marks: p.marks),
  ]);

  void _crop() => setState(() => _draft = _photos[_at].keep ?? _whole);

  void _closeCrop({required bool keep}) {
    setState(() {
      final draft = _draft;
      if (keep && draft != null) {
        _photos[_at].keep = _isWhole(draft) ? null : draft;
      }
      _draft = null;
      _grip = null;
      _loupe = null;
    });
  }

  void _mark() => setState(() => _marking = _photos[_at].marks);

  void _closeMarks({required bool keep}) {
    setState(() {
      final marking = _marking;
      if (keep && marking != null) _photos[_at].marks = marking;
      _marking = null;
      _stroke = null;
      _loupe = null;
    });
  }

  void _undo() =>
      setState(() => _marking = _marking!.sublist(0, _marking!.length - 1));

  Offset? _onScreen(Offset local) {
    final canvas = _canvas.currentContext?.findRenderObject() as RenderBox?;
    final screen = _screen.currentContext?.findRenderObject() as RenderBox?;
    if (canvas == null || screen == null) return null;
    return screen.globalToLocal(canvas.localToGlobal(local));
  }

  void _grab(Offset at, Size shown) {
    final marking = _marking;
    if (marking != null) {
      final point = _unit(at, shown);
      setState(() {
        _stroke = (shape: _shape, from: point, to: point);
        _loupe = _onScreen(_scaledPoint(point, shown));
      });
      return;
    }
    _grip = gripAt(_scaled(_draft!, shown), at, _reach);
    _follow(at, shown);
  }

  void _drag(Offset delta, Offset at, Size shown) {
    final stroke = _stroke;
    if (stroke != null) {
      final point = _unit(at, shown);
      setState(() {
        _stroke = (shape: stroke.shape, from: stroke.from, to: point);
        _loupe = _onScreen(_scaledPoint(point, shown));
      });
      return;
    }
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
    _follow(at, shown);
  }

  /// The loupe sits on the edge or corner held, not under the finger, which is a
  /// reach away from it.
  void _follow(Offset at, Size shown) {
    final grip = _grip;
    final draft = _draft;
    if (grip == null || draft == null || grip == trimBody) return;
    final box = _scaled(draft, shown);
    final point = Offset(
      grip.left
          ? box.left
          : grip.right
          ? box.right
          : at.dx.clamp(box.left, box.right),
      grip.top
          ? box.top
          : grip.bottom
          ? box.bottom
          : at.dy.clamp(box.top, box.bottom),
    );
    setState(() => _loupe = _onScreen(point));
  }

  void _letGo(Size shown) {
    final stroke = _stroke;
    final marking = _marking;
    setState(() {
      if (stroke != null && marking != null) {
        final drawn =
            _scaledPoint(stroke.to, shown) - _scaledPoint(stroke.from, shown);
        if (drawn.distance >= _shortestMark) _marking = [...marking, stroke];
      }
      _stroke = null;
      _grip = null;
      _loupe = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cropping = _draft != null;
    final marking = _marking != null;
    final editing = cropping || marking;
    final insets = MediaQuery.systemGestureInsetsOf(context);
    final pixels =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context))
            .round();
    return PopScope(
      canPop: !editing,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (marking) {
          _closeMarks(keep: false);
        } else {
          _closeCrop(keep: false);
        }
      },
      child: ColoredBox(
        key: _screen,
        color: context.tokens.mediaBackdrop,
        child: Stack(
          children: [
            SafeArea(
              child: Column(
                children: [
                  _ghosts(editing),
                  Expanded(
                    child: PageView.builder(
                      controller: _pages,
                      physics: editing
                          ? const NeverScrollableScrollPhysics()
                          : null,
                      itemCount: _photos.length,
                      onPageChanged: _turned,
                      itemBuilder: (context, index) {
                        final here = editing && index == _at;
                        final stroke = _stroke;
                        return Padding(
                          // A side handle inside the system's edge strip is a back swipe.
                          padding: EdgeInsets.symmetric(
                            vertical: Spacing.xxl,
                            horizontal:
                                Spacing.xxl +
                                math.max(insets.left, insets.right),
                          ),
                          child: _Framed(
                            key: ValueKey('review-photo-$index'),
                            photo: _photos[index],
                            canvasKey: here ? _canvas : null,
                            keep: here && cropping
                                ? _draft
                                : _photos[index].keep,
                            marks: here && marking
                                ? [..._marking!, ?stroke]
                                : _photos[index].marks,
                            pixels: pixels,
                            cropping: here && cropping,
                            editing: here,
                            onGrab: _grab,
                            onDrag: _drag,
                            onLetGo: _letGo,
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
                      child: cropping
                          ? _cropBar()
                          : marking
                          ? _markBar()
                          : _reviewBar(),
                    ),
                  ),
                ],
              ),
            ),
            if (_loupe case final focus?) _loupeAt(focus),
          ],
        ),
      ),
    );
  }

  Widget _loupeAt(Offset focus) {
    const half = _loupeSide / 2;
    final screen = MediaQuery.sizeOf(context);
    final top = MediaQuery.paddingOf(context).top;
    final above = focus.dy - _loupeLift - half;
    final center = Offset(
      focus.dx.clamp(half, math.max(half, screen.width - half)),
      above - half >= top ? above : focus.dy + _loupeLift + half,
    );
    final accent = context.tokens.accent;
    return Positioned(
      key: const ValueKey('review-loupe'),
      left: center.dx - half,
      top: center.dy - half,
      child: IgnorePointer(
        child: RawMagnifier(
          size: const Size.square(_loupeSide),
          magnificationScale: 2.5,
          focalPointOffset: focus - center,
          clipBehavior: Clip.hardEdge,
          decoration: MagnifierDecoration(
            shape: CircleBorder(
              side: BorderSide(color: accent, width: Borders.hairline),
            ),
          ),
          child: CustomPaint(painter: _CrossPainter(accent)),
        ),
      ),
    );
  }

  Widget _ghosts(bool editing) {
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
                      onTap: editing || current ? null : () => _jump(index),
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
                              keep: current && _draft != null
                                  ? _draft
                                  : _photos[index].keep,
                              marks: current && _marking != null
                                  ? _marking!
                                  : _photos[index].marks,
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
          UpgradeIcons.crop,
          key: const ValueKey('review-crop'),
          onTap: _photos[_at].aspect == null ? null : _crop,
        ),
        _Tool(
          UpgradeIcons.mark,
          key: const ValueKey('review-mark'),
          onTap: _photos[_at].aspect == null ? null : _mark,
        ),
        _Tool(
          UpgradeIcons.close,
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

  Widget _markBar() {
    return Row(
      children: [
        PanelAffordance(
          'CANCEL',
          key: const ValueKey('mark-cancel'),
          showIcon: false,
          onTap: () => _closeMarks(keep: false),
        ),
        const Spacer(),
        for (final (shape, icon) in const [
          (MarkShape.box, UpgradeIcons.shapeBox),
          (MarkShape.ring, UpgradeIcons.shapeRing),
          (MarkShape.arrow, UpgradeIcons.shapeArrow),
        ])
          _Tool(
            icon,
            key: ValueKey('mark-${shape.name}'),
            lit: shape == _shape,
            onTap: () => setState(() => _shape = shape),
          ),
        _Tool(
          UpgradeIcons.undo,
          key: const ValueKey('mark-undo'),
          onTap: _marking!.isEmpty ? null : _undo,
        ),
        const Spacer(),
        PanelAffordance(
          'DONE',
          key: const ValueKey('mark-done'),
          showIcon: false,
          color: context.tokens.accent,
          onTap: () => _closeMarks(keep: true),
        ),
      ],
    );
  }
}

Offset _unit(Offset at, Size shown) => Offset(
  (at.dx / shown.width).clamp(0.0, 1.0),
  (at.dy / shown.height).clamp(0.0, 1.0),
);

Offset _scaledPoint(Offset unit, Size size) =>
    Offset(unit.dx * size.width, unit.dy * size.height);

class _Tool extends StatelessWidget {
  const _Tool(this.icon, {super.key, this.lit = false, this.onTap});

  final UpgradeIcons icon;
  final bool lit;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox.square(
        dimension: TapTargets.minHeight,
        child: Center(
          child: UpgradeIcon(
            icon,
            size: IconSizes.toolbar,
            color: onTap == null
                ? context.tokens.textDisabled
                : lit
                ? context.tokens.accent
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
    required this.marks,
    required this.pixels,
    this.canvasKey,
    this.cropping = false,
    this.editing = false,
    this.onGrab,
    this.onDrag,
    this.onLetGo,
  });

  final _Photo photo;
  final Rect? keep;
  final List<PhotoMark> marks;
  final int pixels;
  final Key? canvasKey;
  final bool cropping;
  final bool editing;
  final void Function(Offset at, Size shown)? onGrab;
  final void Function(Offset delta, Offset at, Size shown)? onDrag;
  final void Function(Size shown)? onLetGo;

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
          key: canvasKey,
          size: shown,
          child: CustomPaint(
            foregroundPainter: _KeepPainter(
              keep: keep,
              marks: marks,
              cropping: cropping,
              scrim: context.tokens.scrim,
              accent: context.tokens.accent,
              ink: context.tokens.markInk,
            ),
            child: Image(
              image: photo.at(pixels),
              fit: BoxFit.fill,
              gaplessPlayback: true,
            ),
          ),
        );
        if (editing) {
          framed = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (details) => onGrab?.call(details.localPosition, shown),
            onPanUpdate: (details) =>
                onDrag?.call(details.delta, details.localPosition, shown),
            onPanEnd: (_) => onLetGo?.call(shown),
            onPanCancel: () => onLetGo?.call(shown),
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
    required this.marks,
    required this.cropping,
    required this.scrim,
    required this.accent,
    required this.ink,
  });

  final Rect? keep;
  final List<PhotoMark> marks;
  final bool cropping;
  final Color scrim;
  final Color accent;
  final Color ink;

  static const _tick = 12.0;

  @override
  void paint(Canvas canvas, Size size) {
    paintMarks(canvas, size, marks, color: ink);
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
      old.marks != marks ||
      old.cropping != cropping ||
      old.scrim != scrim ||
      old.accent != accent ||
      old.ink != ink;
}

class _CrossPainter extends CustomPainter {
  const _CrossPainter(this.color);

  final Color color;

  static const _gap = 3.0;
  static const _arm = 6.0;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final paint = Paint()
      ..strokeWidth = Borders.hairline
      ..color = color;
    for (final (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)]) {
      final along = Offset(dx, dy);
      canvas.drawLine(c + along * _gap, c + along * (_gap + _arm), paint);
    }
  }

  @override
  bool shouldRepaint(_CrossPainter old) => old.color != color;
}
