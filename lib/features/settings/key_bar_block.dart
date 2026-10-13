import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:upgrade/application/shell/bar_layout.dart';
import 'package:upgrade/application/providers.dart';
import 'package:upgrade/data/repositories/settings_repository.dart';
import 'package:upgrade/design/components/key_bar.dart';
import 'package:upgrade/design/components/panel.dart';
import 'package:upgrade/design/components/segment_switch.dart';
import 'package:upgrade/design/icons/upgrade_icons.dart';
import 'package:upgrade/design/components/panel_text_action.dart';
import 'package:upgrade/design/spacing.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/platform/vnc/arming.dart';
import 'package:upgrade/features/shell/shell_bar.dart';

const _echoLength = 4;
const _caretWidth = 2.0;
const _edgeZone = 32.0;
const _edgeStep = 6.0;
const _edgeTick = Duration(milliseconds: 16);

class KeyBarSettingsBlock extends ConsumerStatefulWidget {
  const KeyBarSettingsBlock({super.key});

  @override
  ConsumerState<KeyBarSettingsBlock> createState() =>
      _KeyBarSettingsBlockState();
}

class _KeyBarSettingsBlockState extends ConsumerState<KeyBarSettingsBlock> {
  final _scroll = ScrollController();
  var _arranging = false;
  var _arming = const Arming();
  var _keyboard = false;
  var _finding = false;
  final _echo = <String>[];

  BarLayout? _pending;

  Timer? _edge;

  @override
  void dispose() {
    _edge?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _save(BarLayout next) async {
    setState(() => _pending = next);
    final settings = ref.read(settingsRepositoryProvider);
    if (next.isHouse) {
      await settings.clear(SettingsRepository.shellBarLayout);
    } else {
      await settings.setText(SettingsRepository.shellBarLayout, next.encode());
    }
  }

  void _onBytes(Uint8List bytes) => setState(() {
    _echo.add(
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(' '),
    );
    if (_echo.length > _echoLength) _echo.removeAt(0);
    _arming = _arming.spent();
  });

  void _say(String word) => setState(() {
    _echo.add(word);
    if (_echo.length > _echoLength) _echo.removeAt(0);
  });

  void _onDragUpdate(DragUpdateDetails details) {
    if (!_scroll.hasClients) return;
    final box =
        _scroll.position.context.notificationContext?.findRenderObject()
            as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(details.globalPosition);
    final inside = local.dy >= 0 && local.dy <= box.size.height;
    final step = !inside
        ? 0.0
        : local.dx < _edgeZone && local.dx >= 0
        ? -_edgeStep
        : local.dx > box.size.width - _edgeZone && local.dx <= box.size.width
        ? _edgeStep
        : 0.0;
    _edge?.cancel();
    if (step == 0) return;
    _edge = Timer.periodic(_edgeTick, (_) {
      if (!_scroll.hasClients) return;
      final position = _scroll.position;
      _scroll.jumpTo(
        (position.pixels + step).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  void _onDragEnd() {
    _edge?.cancel();
    _edge = null;
  }

  ShellBar _bar(BarLayout layout, {BarArranger? arranger}) => ShellBar(
    layout: layout,
    arranger: arranger,
    scrollController: arranger == null ? null : _scroll,
    sticky: _arming.sticky,
    repeat: _arming.repeat,
    locked: _arming.locked,
    onSticky: (sticky, repeat, locked) => setState(
      () => _arming = Arming(sticky: sticky, repeat: repeat, locked: locked),
    ),
    onBytes: _onBytes,
    keyboardOpen: _keyboard,
    onKeyboard: () => setState(() => _keyboard = !_keyboard),
    searching: _finding,
    onFind: () => setState(() => _finding = !_finding),
    onAttach: () => _say('ATTACH'),
    onVoicePress: () => _say('VOICE'),
  );

  @override
  Widget build(BuildContext context) {
    ref.listen(shellBarLayoutProvider, (_, next) {
      if (next.valueOrNull == _pending) setState(() => _pending = null);
    });
    final layout =
        _pending ??
        ref.watch(shellBarLayoutProvider).valueOrNull ??
        BarLayout.house;
    final tokens = context.tokens;
    final arranger = _arranging
        ? _Arranger(
            layout: layout,
            onPlace: _save,
            onDragUpdate: _onDragUpdate,
            onDragEnd: _onDragEnd,
          )
        : null;

    return Panel(
      title: '[ KEY BAR ]',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentSwitch(
            labels: const ['TRY', 'ARRANGE'],
            currentIndex: _arranging ? 1 : 0,
            onSelected: (index) => setState(() {
              _arranging = index == 1;
              _arming = const Arming();
              _echo.clear();
            }),
          ),
          const SizedBox(height: Spacing.md),
          Text(
            key: const ValueKey('key-bar-echo'),
            _arranging
                ? 'HOLD A CELL AND DRAG IT · ACROSS THE RULE TO PIN · DOWN TO HIDE'
                : _echo.isEmpty
                ? 'TOUCH IT THE WAY YOU WOULD IN A SHELL'
                : _echo.join('  ·  '),
            maxLines: 2,
            style: tokens.label.copyWith(
              color: _echo.isEmpty || _arranging
                  ? tokens.textMuted
                  : tokens.accent,
            ),
          ),
          const SizedBox(height: Spacing.md),
          KeyedSubtree(
            key: const ValueKey('key-bar-preview'),
            child: _bar(layout, arranger: arranger),
          ),
          if (_arranging) ...[
            const SizedBox(height: Spacing.md),
            _HiddenTray(
              layout: layout,
              bar: _bar(layout),
              onPlace: _save,
              onDragUpdate: _onDragUpdate,
              onDragEnd: _onDragEnd,
            ),
          ],
          const SizedBox(height: Spacing.lg),
          Text('ARROWS', style: tokens.rowKicker),
          const SizedBox(height: Spacing.sm),
          Row(
            children: [
              for (final stick in const [true, false]) ...[
                if (!stick) const SizedBox(width: Spacing.md),
                Expanded(
                  child: _ArrowForm(
                    key: ValueKey(
                      'key-bar-arrows-${stick ? 'stick' : 'cells'}',
                    ),
                    label: stick ? 'STICK' : 'CELLS',
                    selected: layout.stick == stick,
                    cells: _bar(layout.withStick(stick))
                        .cellsFor(BarItem.arrows),
                    onTap: () => _save(layout.withStick(stick)),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: Spacing.sm),
          PanelTextAction(
            key: const ValueKey('key-bar-default'),
            label: layout.isHouse ? 'DEFAULT · IN USE' : 'BACK TO DEFAULT',
            icon: UpgradeIcons.sync,
            onTap: layout.isHouse ? null : () => _save(BarLayout.house),
          ),
        ],
      ),
    );
  }
}

typedef _Drop = ({BarItem item, bool before});

class _Arranger implements BarArranger {
  const _Arranger({
    required this.layout,
    required this.onPlace,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final BarLayout layout;
  final ValueChanged<BarLayout> onPlace;
  final DragUpdateCallback onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  Widget item(BarItem item, Widget cells) => _ArrangedCell(
    key: ValueKey('arrange-${item.name}'),
    item: item,
    cells: cells,
    onDragUpdate: onDragUpdate,
    onDragEnd: onDragEnd,
    onDrop: (drop) {
      final pinned = layout.pinned.contains(item);
      final zone = pinned ? layout.pinned : layout.keys;
      final at = zone.indexOf(item) + (drop.before ? 0 : 1);
      onPlace(layout.place(drop.item, pinned: pinned, index: at));
    },
  );

  @override
  Widget zoneEnd({required bool pinned}) => _ZoneEnd(
    key: ValueKey('arrange-end-${pinned ? 'pinned' : 'keys'}'),
    onDrop: (item) => onPlace(
      layout.place(
        item,
        pinned: pinned,
        index: (pinned ? layout.pinned : layout.keys).length,
      ),
    ),
  );
}

Widget _lifted(BuildContext context, Widget cells) => Container(
  height: KeyBar.height,
  decoration: BoxDecoration(
    color: context.tokens.surfacePrimary,
    border: Border.all(color: context.tokens.accent),
  ),
  child: Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [cells],
  ),
);

class _ArrangedCell extends StatefulWidget {
  const _ArrangedCell({
    super.key,
    required this.item,
    required this.cells,
    required this.onDrop,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final BarItem item;
  final Widget cells;
  final ValueChanged<_Drop> onDrop;
  final DragUpdateCallback onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  State<_ArrangedCell> createState() => _ArrangedCellState();
}

class _ArrangedCellState extends State<_ArrangedCell> {
  bool? _before;

  bool _side(Offset global) {
    final box = context.findRenderObject()! as RenderBox;
    return box.globalToLocal(global).dx < box.size.width / 2;
  }

  @override
  Widget build(BuildContext context) {
    final before = _before;
    return LongPressDraggable<BarItem>(
      data: widget.item,
      delay: kLongPressTimeout ~/ 2,
      // The cells under it ignore pointers, so the hold has to be taken by the cell's
      // whole box rather than by whatever the cells would have hit.
      hitTestBehavior: HitTestBehavior.opaque,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: _lifted(context, widget.cells),
      ),
      childWhenDragging: Opacity(opacity: 0.25, child: widget.cells),
      onDragUpdate: widget.onDragUpdate,
      onDragEnd: (_) => widget.onDragEnd(),
      child: DragTarget<BarItem>(
        onWillAcceptWithDetails: (details) => details.data != widget.item,
        onMove: (details) {
          final side = _side(details.offset);
          if (side != _before) setState(() => _before = side);
        },
        onLeave: (_) => setState(() => _before = null),
        onAcceptWithDetails: (details) {
          final side = _side(details.offset);
          setState(() => _before = null);
          widget.onDrop((item: details.data, before: side));
        },
        builder: (context, _, _) => Stack(
          children: [
            widget.cells,
            if (before != null)
              Positioned(
                top: 0,
                bottom: 0,
                left: before ? 0 : null,
                right: before ? null : 0,
                width: _caretWidth,
                child: ColoredBox(color: context.tokens.accent),
              ),
          ],
        ),
      ),
    );
  }
}

class _ZoneEnd extends StatelessWidget {
  const _ZoneEnd({super.key, required this.onDrop});

  final ValueChanged<BarItem> onDrop;

  @override
  Widget build(BuildContext context) => DragTarget<BarItem>(
    onAcceptWithDetails: (details) => onDrop(details.data),
    builder: (context, candidates, _) => SizedBox(
      width: KeyBar.height,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          width: _caretWidth,
          color: candidates.isEmpty ? null : context.tokens.accent,
        ),
      ),
    ),
  );
}

class _HiddenTray extends StatelessWidget {
  const _HiddenTray({
    required this.layout,
    required this.bar,
    required this.onPlace,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final BarLayout layout;
  final ShellBar bar;
  final ValueChanged<BarLayout> onPlace;
  final DragUpdateCallback onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final hidden = layout.hidden;
    return DragTarget<BarItem>(
      key: const ValueKey('key-bar-hidden'),
      onWillAcceptWithDetails: (details) =>
          details.data.hideable && !hidden.contains(details.data),
      onAcceptWithDetails: (details) => onPlace(layout.hide(details.data)),
      builder: (context, candidates, rejected) {
        final refused = rejected.contains(BarItem.keyboard);
        return Container(
          constraints: const BoxConstraints(minHeight: KeyBar.height * 2),
          padding: const EdgeInsets.all(Spacing.md),
          decoration: BoxDecoration(
            border: Border.all(
              color: candidates.isNotEmpty
                  ? tokens.accent
                  : refused
                  ? tokens.danger
                  : tokens.borderSubtle,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                refused
                    ? 'THE KEYBOARD STAYS ON THE BAR'
                    : hidden.isEmpty
                    ? 'HIDDEN · DROP A CELL HERE TO TAKE IT OFF THE BAR'
                    : 'HIDDEN · TAP OR DRAG ONE BACK ONTO THE BAR',
                style: tokens.label,
              ),
              if (hidden.isNotEmpty) ...[
                const SizedBox(height: Spacing.md),
                Wrap(
                  spacing: Spacing.md,
                  runSpacing: Spacing.md,
                  children: [
                    for (final item in hidden)
                      _HiddenCell(
                        key: ValueKey('hidden-${item.name}'),
                        item: item,
                        cells: IgnorePointer(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: bar.cellsFor(item),
                          ),
                        ),
                        onTap: () => onPlace(
                          layout.place(
                            item,
                            pinned: false,
                            index: layout.keys.length,
                          ),
                        ),
                        onDragUpdate: onDragUpdate,
                        onDragEnd: onDragEnd,
                      ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _HiddenCell extends StatelessWidget {
  const _HiddenCell({
    super.key,
    required this.item,
    required this.cells,
    required this.onTap,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final BarItem item;
  final Widget cells;
  final VoidCallback onTap;
  final DragUpdateCallback onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final tile = Container(
      height: KeyBar.height,
      decoration: BoxDecoration(
        border: Border.all(color: context.tokens.borderSubtle),
      ),
      child: Opacity(opacity: 0.5, child: cells),
    );
    return LongPressDraggable<BarItem>(
      data: item,
      delay: kLongPressTimeout ~/ 2,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: _lifted(context, cells),
      ),
      childWhenDragging: Opacity(opacity: 0.25, child: tile),
      onDragUpdate: onDragUpdate,
      onDragEnd: (_) => onDragEnd(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: tile,
      ),
    );
  }
}

class _ArrowForm extends StatelessWidget {
  const _ArrowForm({
    super.key,
    required this.label,
    required this.selected,
    required this.cells,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final List<Widget> cells;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(Spacing.md),
        decoration: BoxDecoration(
          color: selected ? tokens.surfaceSecondary : null,
          border: Border.all(
            color: selected ? tokens.accent : tokens.borderSubtle,
          ),
        ),
        child: Column(
          children: [
            SizedBox(
              height: KeyBar.height,
              child: IgnorePointer(
                child: FittedBox(
                  child: SizedBox(
                    height: KeyBar.height,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: cells,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              label,
              style: tokens.rowKicker.copyWith(
                color: selected ? tokens.accent : tokens.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
