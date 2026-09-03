import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The pirate mascot's sheets, and the one widget that draws them.
///
/// The sheets are pixel art on a 48px grid, frames left to right at 1x. Nothing
/// here resamples: [FilterQuality.none] at an integer scale is the whole
/// rendering contract, because a fractional scale on a 48px figure puts some
/// source pixels on two device pixels and its neighbours on one, and the
/// silhouette stops being pixel art.

/// One cell's side, in source pixels. The manifest carries the same number and
/// a test asserts the two agree — the constant exists so a [Sprite] has a size
/// before the manifest has been read, which is what keeps the first frame from
/// laying out at zero and then jumping.
const mascotCell = 48;

const mascotManifestAsset = 'assets/sprites/mascot.json';

String mascotSheetAsset(String state) => 'assets/sprites/mascot-$state.png';

/// One state's row in the manifest.
class MascotState {
  const MascotState({
    required this.name,
    required this.frames,
    required this.fps,
    required this.loop,
  });

  final String name;
  final int frames;
  final int fps;
  final bool loop;

  /// How long one play of the sheet takes. For a looping state this is the
  /// period; for a held one it is when the last frame arrives and the ticker
  /// has nothing left to do.
  Duration get length =>
      Duration(microseconds: Duration.microsecondsPerSecond * frames ~/ fps);
}

class MascotManifest {
  const MascotManifest({required this.cell, required this.states});

  final int cell;
  final Map<String, MascotState> states;

  static MascotManifest parse(String source) {
    final root = jsonDecode(source) as Map<String, dynamic>;
    final states = <String, MascotState>{};
    for (final entry in (root['states'] as Map<String, dynamic>).entries) {
      final value = entry.value as Map<String, dynamic>;
      states[entry.key] = MascotState(
        name: entry.key,
        frames: value['frames'] as int,
        fps: value['fps'] as int,
        loop: value['loop'] as bool,
      );
    }
    return MascotManifest(cell: root['cell'] as int, states: states);
  }

  static Future<MascotManifest>? _pending;

  /// Read once per isolate. Every placement asks for the same three numbers,
  /// and a sprite that re-read the bundle would spend an asset round trip on
  /// each mount.
  static Future<MascotManifest> load([AssetBundle? bundle]) =>
      _pending ??= (bundle ?? rootBundle)
          .loadString(mascotManifestAsset)
          .then(MascotManifest.parse);

  @visibleForTesting
  static void resetForTest() => _pending = null;
}

/// Which frame is on screen after [elapsed]. A looping state wraps; a held one
/// stops on the last frame and stays there, which is what the splash's final
/// pose is.
int mascotFrameAt(Duration elapsed, MascotState state) {
  if (elapsed <= Duration.zero) return 0;
  final index =
      elapsed.inMicroseconds * state.fps ~/ Duration.microsecondsPerSecond;
  if (state.loop) return index % state.frames;
  return index >= state.frames ? state.frames - 1 : index;
}

/// The largest integer scale whose cell fits in [available]. Never zero: a
/// height under one cell draws the sprite at 1x and overflows rather than
/// vanishing, because a mascot nobody can see is harder to notice than one that
/// does not fit.
int mascotScaleFor(double available, {int cell = mascotCell}) {
  final scale = available ~/ cell;
  return scale < 1 ? 1 : scale;
}

/// One state of the mascot, at an integer scale.
///
/// Give it [scale] or [height], never both — [height] is the caller saying "as
/// large as fits here" and resolves through [mascotScaleFor]. [frame] pins a
/// single frame and builds no ticker at all, which is what the two static
/// placements use.
class Sprite extends StatefulWidget {
  const Sprite({
    super.key,
    required this.state,
    this.scale,
    this.height,
    this.frame,
    this.onDone,
  }) : assert(
         (scale == null) != (height == null),
         'a sprite takes either a scale or a height',
       ),
       assert(scale == null || scale > 0, 'scale is an integer multiple');

  final String state;
  final int? scale;
  final double? height;

  /// A fixed frame index. The sprite is static and no [Ticker] is created.
  final int? frame;

  /// Fired once when a non-looping state reaches its last frame.
  final VoidCallback? onDone;

  @override
  State<Sprite> createState() => _SpriteState();
}

class _SpriteState extends State<Sprite> with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  MascotState? _state;
  ui.Image? _image;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  int _frame = 0;
  bool _done = false;

  int get _scale => widget.scale ?? mascotScaleFor(widget.height!);

  @override
  void initState() {
    super.initState();
    _frame = widget.frame ?? 0;
    _loadManifest();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveSheet();
  }

  @override
  void didUpdateWidget(Sprite old) {
    super.didUpdateWidget(old);
    if (widget.frame != null && widget.frame != _frame) {
      _frame = widget.frame!;
    }
    if (widget.state != old.state) {
      _done = false;
      _frame = widget.frame ?? 0;
      _state = null;
      _loadManifest();
      _resolveSheet();
    }
  }

  Future<void> _loadManifest() async {
    final manifest = await MascotManifest.load();
    if (!mounted) return;
    final state = manifest.states[widget.state];
    assert(state != null, 'no sprite state named ${widget.state}');
    if (state == null) return;
    setState(() => _state = state);
    _startTicker();
  }

  void _startTicker() {
    // A pinned frame and a one-frame sheet both have nothing to advance, and a
    // ticker for either would ask the engine for a frame every 16ms to redraw
    // the same pixels.
    if (widget.frame != null || _state!.frames < 2 || _ticker != null) return;
    _ticker = createTicker(_tick)..start();
  }

  void _tick(Duration elapsed) {
    final state = _state!;
    final frame = mascotFrameAt(elapsed, state);
    if (frame != _frame) setState(() => _frame = frame);
    // Not `frame == frames - 1`: the last frame is reached a whole frame's
    // worth of time before the sheet has finished playing, and a caller told
    // "done" then would cut that frame short.
    if (state.loop || _done || elapsed < state.length) return;
    // The held pose is drawn from here on; the ticker would only keep
    // recomputing the same index.
    _done = true;
    _ticker?.stop();
    widget.onDone?.call();
  }

  void _resolveSheet() {
    final provider = AssetImage(mascotSheetAsset(widget.state));
    final stream = provider.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _dropStream();
    _listener = ImageStreamListener((image, _) {
      if (!mounted) return;
      setState(() => _image = image.image);
    });
    _stream = stream..addListener(_listener!);
  }

  void _dropStream() {
    if (_listener != null) _stream?.removeListener(_listener!);
    _listener = null;
    _stream = null;
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _dropStream();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final side = (mascotCell * _scale).toDouble();
    final image = _image;
    return SizedBox(
      width: side,
      height: side,
      child: image == null
          ? null
          : CustomPaint(
              painter: _SpritePainter(
                sheet: image,
                frame: _frame,
                cell: mascotCell,
              ),
            ),
    );
  }
}

class _SpritePainter extends CustomPainter {
  const _SpritePainter({
    required this.sheet,
    required this.frame,
    required this.cell,
  });

  final ui.Image sheet;
  final int frame;
  final int cell;

  @override
  void paint(Canvas canvas, Size size) {
    final left = (frame * cell).toDouble();
    canvas.drawImageRect(
      sheet,
      Rect.fromLTWH(left, 0, cell.toDouble(), cell.toDouble()),
      Offset.zero & size,
      Paint()
        ..filterQuality = FilterQuality.none
        ..isAntiAlias = false,
    );
  }

  @override
  bool shouldRepaint(_SpritePainter old) =>
      old.frame != frame || !identical(old.sheet, sheet) || old.cell != cell;
}
