import 'dart:math' as math;
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:striked/design/tokens.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/platform/workspace/workspace_model.dart';

import 'package:striked/features/code/diff_jump.dart';
import 'package:striked/features/code/diff_map.dart';
import 'package:striked/features/code/diff_read.dart';
import 'package:striked/features/code/hunk_pin.dart';
import 'package:striked/features/code/intraline.dart';
import 'package:striked/features/code/structural.dart';
import 'package:striked/features/code/syntax.dart';
import 'package:striked/features/code/syntax_style.dart';

class _Rail extends StatelessWidget {
  const _Rail({
    required this.shift,
    required this.travel,
    required this.room,
    required this.lead,
  });

  final ValueListenable<double> shift;
  final double travel;
  final double room;
  final double lead;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: lead, top: Spacing.xs, bottom: Spacing.xs),
      child: SizedBox(
        height: Borders.hairline * 2,
        child: ValueListenableBuilder<double>(
          valueListenable: shift,
          builder: (context, at, _) {
            final thumb = math.max(room * room / (room + travel), Spacing.xl);
            final travelled = math.min(at, travel) / travel;
            return Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(color: context.tokens.borderSubtle),
                ),
                Positioned(
                  left: travelled * (room - thumb),
                  width: thumb,
                  top: 0,
                  bottom: 0,
                  child: ColoredBox(color: context.tokens.textDisabled),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class DiffStat extends StatelessWidget {
  const DiffStat({
    super.key,
    required this.added,
    required this.removed,
    this.files,
  });

  final int added;
  final int removed;
  final int? files;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (files case final count?) ...[
          Text(
            '$count ${count == 1 ? 'FILE' : 'FILES'}',
            style: context.tokens.panelHeader,
          ),
          const SizedBox(width: Spacing.lg),
        ],
        Text.rich(
          countSpan('+$added', context.tokens.accent, added),
          style: context.tokens.panelHeader,
        ),
        const SizedBox(width: Spacing.md),
        Text.rich(
          countSpan('−$removed', context.tokens.warning, removed),
          style: context.tokens.panelHeader,
        ),
      ],
    );
  }
}

class DiffBody extends StatefulWidget {
  const DiffBody({
    super.key,
    required this.path,
    required this.doc,
    required this.jumps,
    required this.picked,
    required this.onPick,
    required this.onFold,
    this.language,
    this.query,
    this.onGoto,
    this.onEdge,
    this.wrap = false,
  });

  final String path;

  final DiffDoc doc;

  final DiffJumps jumps;

  final SyntaxLanguage? language;

  final int? picked;

  final void Function(int row, {required bool old}) onPick;

  final ValueChanged<int> onFold;

  final String? query;

  final ValueChanged<DiffGoto>? onGoto;

  final ValueChanged<int>? onEdge;

  final bool wrap;

  static double rowHeight(BuildContext context) =>
      MediaQuery.textScalerOf(context)
              .scale(context.tokens.noteBody.fontSize!) *
          context.tokens.noteBody.height! +
      linePadding * 2;

  static const linePadding = 1.0;

  @override
  State<DiffBody> createState() => _DiffBodyState();
}

class _DiffBodyState extends State<DiffBody>
    with SingleTickerProviderStateMixin {
  final ValueNotifier<double> _shift = ValueNotifier(0);

  late final AnimationController _glide = AnimationController.unbounded(
    vsync: this,
  )..addListener(_glided);

  double _travel = 0;

  void _glided() {
    final at = _glide.value.clamp(0.0, _travel);
    _shift.value = at;
    if (at != _glide.value) _glide.stop();
  }

  double _over = 0;

  static const _edgeReach = 96.0;

  int _edgeFrom = 0;

  void _dragged(DragUpdateDetails drag) {
    final want = _shift.value - drag.delta.dx;
    final at = want.clamp(0.0, _travel);
    _over += want - at;
    if (want == at) _over = 0;
    _shift.value = at;
  }

  void _fling(DragEndDetails end) {
    final over = _over;
    _over = 0;
    final edge = widget.onEdge;
    final from = _edgeFrom;
    _edgeFrom = 0;
    final towards = over.sign.toInt();
    final allowed = from == 2 || from == towards;
    if (edge != null && allowed && over.abs() >= _edgeReach) {
      edge(over.sign.toInt());
      return;
    }
    final velocity = -(end.primaryVelocity ?? 0);
    if (velocity == 0 || _travel == 0) return;
    _glide
      ..value = _shift.value
      ..animateWith(
        ClampingScrollSimulation(position: _shift.value, velocity: velocity),
      );
  }

  int? _lineAt(double offset) {
    final rows = widget.doc.rows;
    for (
      var row = (offset / DiffBody.rowHeight(context)).floor();
      row < rows.length;
      row++
    ) {
      if (row < 0) continue;
      final line = rows[row].line;
      final number = line.newLine ?? line.oldLine;
      if (number != null) return number;
    }
    return null;
  }

  final Map<ShownRow, DiffCell> _cells = Map.identity();

  List<DiffStreak> _streaks = const [];

  List<int> _hunks = const [];

  int _widest = 0;
  int _highest = 0;

  @override
  void initState() {
    super.initState();
    _read();
  }

  @override
  void didUpdateWidget(covariant DiffBody old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      _glide.stop();
      _shift.value = 0;
    }
    if (!identical(old.doc, widget.doc)) _read();
  }

  void _read() {
    _cells.clear();
    _widest = 0;
    _highest = 0;
    final lines = <DiffLine>[];
    for (final row in widget.doc.rows) {
      for (final side in [row.across, row.left, row.right]) {
        if (side == null) continue;
        final cell = _cells[side] ??= _cell(side);
        if (cell.text.length > _widest) _widest = cell.text.length;
        final old = side.line.oldLine ?? 0;
        final now = side.line.newLine ?? 0;
        if (old > _highest) _highest = old;
        if (now > _highest) _highest = now;
      }
      lines.add(row.line);
    }
    _streaks = diffStreaks(lines);
    _hunks = hunkRows(lines);
  }

  DiffCell _cell(ShownRow row) {
    final drawn = row.drawn;
    if (drawn != null) {
      return DiffCell(drawn, row.moved ? const [] : row.runs, row.spans);
    }
    final line = row.line;
    final fold = row.fold;
    if (fold != null && row.wrapOf != null) {
      return DiffCell(_foldWords(fold), const [], null);
    }
    final text = switch (line.kind) {
      DiffLineKind.hunk => hunkHeadline(line.text),
      DiffLineKind.fold => fold?.head ?? '',
      _ => line.text,
    };
    final open = openTabs(
      text,
      row.moved ? const [] : row.runs,
      widget.doc.spansOf(row),
    );
    return DiffCell(open.text, open.runs, open.spans);
  }

  @override
  void dispose() {
    _glide.dispose();
    _shift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.doc;
    final advance = diffCharAdvance(context);
    final row = DiffBody.rowHeight(context);
    final gutter = diffGutterWidth(_highest, advance);
    final halves = doc.split;
    final lead = DiffRow.lead(gutter, advance, single: doc.single || halves);
    final text = _widest * advance + Spacing.panelPadding;
    return LayoutBuilder(
      builder: (context, constraints) {
        final mapped =
            _streaks.isNotEmpty &&
            doc.rows.length * row > constraints.maxHeight;
        final width = constraints.maxWidth - (mapped ? DiffMap.width : 0);
        final room = math.max(
          0.0,
          (halves ? (width - Borders.hairline) / 2 : width) - lead,
        );
        final travel = widget.wrap ? 0.0 : math.max(0.0, text - room);
        _travel = travel;
        final swipes = travel > 0 || widget.onEdge != null;
        Widget side(ShownRow? shown, {required bool old}) {
          if (shown == null) return const SizedBox.shrink();
          final line = shown.line;
          return DiffRow(
            line: DiffLine(
              line.kind,
              line.text,
              oldLine: old ? line.oldLine : null,
              newLine: old ? null : line.newLine,
            ),
            cell: _cells[shown]!,
            moved: shown.moved,
            block: shown.block,
            gutter: gutter,
            single: true,
            language: widget.language,
            shift: _shift,
            travel: travel,
            query: widget.query,
          );
        }

        Widget rowAt(int index) {
          final at = doc.rows[index];
          final across = at.across;
          if (across != null) {
            final fold = across.fold;
            if (fold != null) {
              return _FoldLine(
                fold: fold,
                cell: _cells[across]!,
                lead: lead,
                language: widget.language,
                shift: _shift,
                travel: travel,
                tail: across.wrapOf != null,
                query: widget.query,
                onTap: () => widget.onFold(fold.key),
              );
            }
            final goto = across.goto;
            if (goto != null) {
              return _NoteLine(
                text: across.line.text,
                lead: lead,
                onTap: widget.onGoto == null
                    ? null
                    : () => widget.onGoto!(goto),
              );
            }
            return DiffRow(
              line: across.line,
              cell: _cells[across]!,
              moved: across.moved,
              block: across.block,
              gutter: gutter,
              single: doc.single,
              language: widget.language,
              shift: _shift,
              travel: travel,
              picked: widget.picked == index,
              query: widget.query,
              carried: across.wrapOf != null && across.line.text.isEmpty,
            );
          }
          final pair = Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: side(at.left, old: true)),
              Container(
                width: Borders.hairline,
                color: context.tokens.borderNormal,
              ),
              Expanded(child: side(at.right, old: false)),
            ],
          );
          return widget.picked == index ? _Picked(child: pair) : pair;
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        GestureDetector(
                          dragStartBehavior: DragStartBehavior.down,
                          onHorizontalDragDown: swipes
                              ? (_) {
                                  _glide.stop();
                                  _over = 0;
                                  _edgeFrom = _travel == 0
                                      ? 2
                                      : _shift.value <= 0
                                      ? -1
                                      : _shift.value >= _travel
                                      ? 1
                                      : 0;
                                }
                              : null,
                          onHorizontalDragUpdate: swipes ? _dragged : null,
                          onHorizontalDragEnd: swipes ? _fling : null,
                          child: ListView.builder(
                            controller: widget.jumps.scroll,
                            padding: EdgeInsets.zero,
                            itemExtent: row,
                            itemCount: doc.rows.length,
                            itemBuilder: (context, index) {
                              final line = doc.rows[index].line;
                              return GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onLongPressStart:
                                    line.kind == DiffLineKind.capped ||
                                        line.kind == DiffLineKind.fold ||
                                        doc.rows[index].across?.goto != null
                                    ? null
                                    : (details) => widget.onPick(
                                        index,
                                        old:
                                            details.localPosition.dx <
                                            width / 2,
                                      ),
                                child: rowAt(index),
                              );
                            },
                          ),
                        ),
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: HunkPin(
                            rows: _hunks,
                            jumps: widget.jumps,
                            rowHeight: row,
                            rowAt: rowAt,
                          ),
                        ),
                        DiffReturn(jumps: widget.jumps, lineAt: _lineAt),
                      ],
                    ),
                  ),
                  if (mapped)
                    DiffMap(
                      streaks: _streaks,
                      rows: doc.rows.length,
                      jumps: widget.jumps,
                    ),
                ],
              ),
            ),
            if (travel > 0)
              Padding(
                padding: EdgeInsets.only(right: mapped ? DiffMap.width : 0),
                child: _Rail(
                  shift: _shift,
                  travel: travel,
                  room: room,
                  lead: lead,
                ),
              ),
          ],
        );
      },
    );
  }
}

class DiffCell {
  const DiffCell(this.text, this.runs, this.spans);

  final String text;
  final List<IntralineSpan> runs;
  final List<SyntaxSpan>? spans;
}

double diffCharAdvance(BuildContext context) {
  final scaler = MediaQuery.textScalerOf(context);
  final size = scaler.scale(context.tokens.noteBody.fontSize!);
  final known = _advance;
  if (known != null && _advanceAt == size) return known;
  final painter = TextPainter(
    text: TextSpan(text: _ruler, style: context.tokens.noteBody),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
  )..layout();
  final advance = painter.width / _ruler.length;
  painter.dispose();
  _advanceAt = size;
  return _advance = advance;
}

double? _advance;

double? _advanceAt;
const _ruler = '0123456789';

double diffGutterWidth(int highest, double advance) =>
    (highest < 100 ? 2 : highest.toString().length) * advance + Spacing.md;

class _Picked extends StatelessWidget {
  const _Picked({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: Spacing.xs,
          child: ColoredBox(color: context.tokens.accent),
        ),
      ],
    );
  }
}

String _foldWords(FoldRow fold) =>
    '⋯ ${fold.count} unchanged ${fold.count == 1 ? 'line' : 'lines'}';

class _NoteLine extends StatelessWidget {
  const _NoteLine({required this.text, required this.lead, this.onTap});

  final String text;
  final double lead;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.only(
          left: math.min(lead, Spacing.panelPadding),
          top: DiffBody.linePadding,
          bottom: DiffBody.linePadding,
          right: Spacing.panelPadding,
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            onTap == null ? '↕ $text' : '↕ $text  ›',
            style: context.tokens.noteBody.copyWith(
              color: context.tokens.accentMuted,
            ),
            maxLines: 1,
            softWrap: false,
          ),
        ),
      ),
    );
  }
}

class _FoldLine extends StatelessWidget {
  const _FoldLine({
    required this.fold,
    required this.cell,
    required this.lead,
    required this.onTap,
    required this.shift,
    required this.travel,
    this.language,
    this.tail = false,
    this.query,
  });

  final FoldRow fold;
  final DiffCell cell;
  final double lead;
  final VoidCallback onTap;
  final SyntaxLanguage? language;
  final bool tail;
  final String? query;

  final ValueListenable<double> shift;
  final double travel;

  @override
  Widget build(BuildContext context) {
    final muted = context.tokens.noteBody.copyWith(
      color: context.tokens.textMuted,
    );
    final head = tail ? null : fold.head;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        color: context.tokens.surfacePrimary,
        padding: const EdgeInsets.only(
          top: DiffBody.linePadding,
          bottom: DiffBody.linePadding,
          right: Spacing.panelPadding,
        ),
        child: Row(
          children: [
            SizedBox(
              width: lead,
              child: head == null
                  ? null
                  : Padding(
                      padding: const EdgeInsets.only(right: Spacing.md),
                      child: FittedBox(
                        alignment: Alignment.centerRight,
                        fit: BoxFit.scaleDown,
                        child: Text('${fold.headLine ?? ''}', style: muted),
                      ),
                    ),
            ),
            Expanded(
              child: head == null
                  ? Text(
                      _foldWords(fold),
                      style: muted,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                    )
                  : ClipRect(
                      child: ValueListenableBuilder<double>(
                        valueListenable: shift,
                        builder: (context, at, painted) => Transform.translate(
                          offset: Offset(-math.min(at, travel), 0),
                          child: painted,
                        ),
                        child: OverflowBox(
                          alignment: Alignment.centerLeft,
                          maxWidth: double.infinity,
                          child: Text.rich(
                            _codeSpan(
                              context,
                              cell,
                              language,
                              DiffLineKind.context,
                              query,
                            ),
                            style: context.tokens.noteBody.copyWith(
                              color: context.tokens.textSecondary,
                            ),
                            maxLines: 1,
                            softWrap: false,
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class DiffRow extends StatelessWidget {
  const DiffRow({
    super.key,
    required this.line,
    required this.cell,
    required this.gutter,
    required this.shift,
    required this.travel,
    this.language,
    this.moved = false,
    this.block = false,
    this.picked = false,
    this.single = false,
    this.query,
    this.carried = false,
  });

  final DiffLine line;
  final DiffCell cell;
  final double gutter;
  final bool single;
  final SyntaxLanguage? language;

  final bool moved;
  final bool block;

  final ValueListenable<double> shift;

  final double travel;

  final bool picked;

  final String? query;

  final bool carried;

  static double lead(double gutter, double advance, {bool single = false}) =>
      (single ? gutter + Spacing.md * 2 : gutter * 2 + Spacing.md * 3) +
      Borders.hairline +
      advance +
      Spacing.sm;

  @override
  Widget build(BuildContext context) {
    var (marker, text, mark, ground) = switch (line.kind) {
      DiffLineKind.added => (
        '+',
        context.tokens.textPrimary,
        context.tokens.accent,
        context.tokens.diffAddedGround,
      ),
      DiffLineKind.removed => (
        '−',
        context.tokens.textSecondary,
        context.tokens.danger,
        context.tokens.diffRemovedGround,
      ),
      DiffLineKind.hunk => (
        ' ',
        context.tokens.textMuted,
        context.tokens.textDisabled,
        context.tokens.surfacePrimary,
      ),
      DiffLineKind.meta || DiffLineKind.fold => (
        ' ',
        context.tokens.textDisabled,
        context.tokens.textDisabled,
        null,
      ),
      DiffLineKind.context => (
        ' ',
        context.tokens.textSecondary,
        context.tokens.textDisabled,
        null,
      ),
      DiffLineKind.capped => (
        '…',
        context.tokens.warning,
        context.tokens.warning,
        context.tokens.diffCappedGround,
      ),
    };
    if (single || carried) marker = ' ';
    if (moved) {
      if (marker != ' ') marker = block ? '↕' : '·';
      text = context.tokens.textSecondary;
      mark = context.tokens.textDisabled;
      ground = null;
    }
    final numbers = context.tokens.noteBody.copyWith(
      color: context.tokens.textDisabled,
    );
    final row = Container(
      color: ground,
      padding: const EdgeInsets.symmetric(vertical: DiffBody.linePadding),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!single) ...[
            SizedBox(
              width: gutter,
              child: Text(
                '${line.oldLine ?? ''}',
                style: numbers,
                textAlign: TextAlign.right,
                maxLines: 1,
              ),
            ),
            const SizedBox(width: Spacing.md),
          ],
          SizedBox(
            width: gutter,
            child: Text(
              '${(single ? line.newLine ?? line.oldLine : line.newLine) ?? ''}',
              style: numbers,
              textAlign: TextAlign.right,
              maxLines: 1,
            ),
          ),
          const SizedBox(width: Spacing.md),
          Container(
            width: Borders.hairline,
            height: DiffBody.rowHeight(context) - DiffBody.linePadding * 2,
            color: context.tokens.borderSubtle,
          ),
          const SizedBox(width: Spacing.md),
          Text(
            marker,
            style: context.tokens.noteBody.copyWith(color: mark),
            maxLines: 1,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: ClipRect(
              child: ValueListenableBuilder<double>(
                valueListenable: shift,
                builder: (context, at, painted) => Transform.translate(
                  offset: Offset(-math.min(at, travel), 0),
                  child: painted,
                ),
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  maxWidth: double.infinity,
                  child: RepaintBoundary(
                    child: Padding(
                      padding: const EdgeInsets.only(
                        right: Spacing.panelPadding,
                      ),
                      child: Text.rich(
                        _codeSpan(context, cell, language, line.kind, query),
                        style: context.tokens.noteBody.copyWith(color: text),
                        maxLines: 1,
                        softWrap: false,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    if (!picked) return row;
    return _Picked(child: row);
  }
}

InlineSpan _codeSpan(
  BuildContext context,
  DiffCell cell,
  SyntaxLanguage? language,
  DiffLineKind kind,
  String? query,
) {
  final text = cell.text;
  final words =
      kind == DiffLineKind.hunk ||
      kind == DiffLineKind.meta ||
      kind == DiffLineKind.capped;
  final spans = words
      ? [(text: text, token: SyntaxToken.plain)]
      : cell.spans ??
            (language == null
                ? [(text: text, token: SyntaxToken.plain)]
                : highlight(text, language));
  final ground = switch (kind) {
    DiffLineKind.added => context.tokens.diffAddedRun,
    DiffLineKind.removed => context.tokens.diffRemovedRun,
    _ => null,
  };
  final runs = ground == null ? const <IntralineSpan>[] : cell.runs;
  final hits = _hits(text, query);
  final children = <TextSpan>[];
  var at = 0;
  var next = 0;
  void piece(int from, int to, TextStyle? style) {
    while (from < to) {
      while (next < runs.length && runs[next].end <= from) {
        next++;
      }
      final lit = next < runs.length && runs[next].start <= from;
      final end = lit
          ? math.min(to, runs[next].end)
          : next < runs.length
          ? math.min(to, runs[next].start)
          : to;
      _addHit(
        children,
        text,
        from,
        end,
        lit
            ? (style ?? const TextStyle()).copyWith(backgroundColor: ground)
            : style,
        hits,
        context,
      );
      from = end;
    }
  }

  for (final span in spans) {
    final end = math.min(at + span.text.length, text.length);
    piece(at, end, syntaxStyle(context, span.token));
    at = end;
  }
  if (at < text.length) piece(at, text.length, null);
  return TextSpan(children: children);
}

List<IntralineSpan> _hits(String text, String? query) {
  if (query == null || query.isEmpty) return const [];
  final hay = text.toLowerCase();
  final needle = query.toLowerCase();
  final hits = <IntralineSpan>[];
  for (
    var at = hay.indexOf(needle);
    at >= 0;
    at = hay.indexOf(needle, at + 1)
  ) {
    hits.add((start: at, end: at + needle.length));
  }
  return hits;
}

void _addHit(
  List<TextSpan> children,
  String text,
  int from,
  int to,
  TextStyle? style,
  List<IntralineSpan> hits,
  BuildContext context,
) {
  if (hits.isEmpty) {
    children.add(TextSpan(text: text.substring(from, to), style: style));
    return;
  }
  final lit = (style ?? const TextStyle()).copyWith(
    backgroundColor: context.tokens.accent,
    color: context.tokens.backgroundPrimary,
  );
  var at = from;
  for (final hit in hits) {
    if (hit.end <= at || hit.start >= to) continue;
    if (hit.start > at) {
      children.add(TextSpan(text: text.substring(at, hit.start), style: style));
      at = hit.start;
    }
    final end = math.min(hit.end, to);
    children.add(TextSpan(text: text.substring(at, end), style: lit));
    at = end;
  }
  if (at < to) {
    children.add(TextSpan(text: text.substring(at, to), style: style));
  }
}

List<TextSpan> fileCountSpans(BuildContext context, WorkspaceFile file) {
  if (file.binary) return [TextSpan(text: file.untracked ? 'NEW' : 'BINARY')];
  return [
    countSpan('+${file.added}', context.tokens.accent, file.added),
    const TextSpan(text: ' '),
    countSpan('−${file.removed}', context.tokens.warning, file.removed),
  ];
}

TextSpan countSpan(String text, Color lit, int? count) => TextSpan(
  text: text,
  style: (count ?? 0) == 0 ? null : TextStyle(color: lit),
);

class DiffImages extends StatelessWidget {
  const DiffImages({super.key, required this.images});

  final FileImages images;

  @override
  Widget build(BuildContext context) {
    Widget side(String label, String? data, Color tone) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: context.tokens.panelHeader.copyWith(color: tone)),
          const SizedBox(height: Spacing.sm),
          Expanded(
            child: data == null
                ? Center(child: Text('none', style: context.tokens.rowSubtitle))
                : Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: tone, width: Borders.hairline),
                    ),
                    child: Image.memory(
                      base64Decode(data),
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      errorBuilder: (context, _, _) => Center(
                        child: Text(
                          'could not draw it',
                          style: context.tokens.rowSubtitle,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.all(Spacing.panelPadding),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          side('BEFORE', images.old, context.tokens.danger),
          const SizedBox(width: Spacing.md),
          side('AFTER', images.now, context.tokens.accent),
        ],
      ),
    );
  }
}
