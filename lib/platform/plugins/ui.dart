import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'package:striked/design/components/bracket_label.dart';
import 'package:striked/design/components/action_block.dart';
import 'package:striked/design/components/field_panel.dart';
import 'package:striked/design/components/panel_sheet.dart';
import 'package:striked/design/components/picker_row.dart';
import 'package:striked/design/components/list_row.dart';
import 'package:striked/design/components/panel.dart';
import 'package:striked/design/components/status_tag.dart';
import 'package:striked/design/spacing.dart';
import 'package:striked/design/tokens.dart';
import 'package:striked/design/components/screen_scaffold.dart';
import 'package:striked/platform/plugins/manifest.dart';

class PluginUiNode {
  const PluginUiNode(this.kind, this.props, this.children);
  final String kind;
  final Map<String, Object?> props;
  final List<PluginUiNode> children;
  String get key => props['key']! as String;

  static const _fillingCardKinds = {
    'panel',
    'section',
    'column',
    'box',
    'list_row',
    'bracket_label',
  };

  static const _cardKinds = {
    'panel',
    'section',
    'column',
    'row',
    'box',
    'text',
    'button',
    'list_row',
    'status_tag',
    'bracket_label',
    'spacer',
    'divider',
    'canvas',
  };

  static PluginUiNode parse(
    Object? source, {
    required bool allowCanvas,
    bool card = false,
    bool allowAwake = false,
    Set<String> pages = const {},
  }) {
    var count = 0;
    var drawingCommands = 0;
    final keys = <String>{};
    PluginUiNode read(
      Object? value,
      int depth, {
      String? parent,
      bool bounded = true,
    }) {
      if (++count > (card ? 256 : 2048) ||
          depth > 24 ||
          value is! Map<String, Object?>) {
        throw const PluginException('UI exceeds its node or depth limit');
      }
      final kind = value['kind'];
      final props = value['props'];
      if (kind is! String ||
          !{
            'screen',
            'page',
            'footer',
            'disclosure',
            'choice',
            'column',
            'row',
            'stack',
            'box',
            'text',
            'button',
            'input',
            'select',
            'toggle',
            'list',
            'canvas',
            'spacer',
            'divider',
            'datetime',
            'panel',
            'section',
            'list_row',
            'status_tag',
            'bracket_label',
          }.contains(kind) ||
          props is! Map<String, Object?>) {
        throw const PluginException(
          'Unknown UI primitive or invalid properties',
        );
      }
      final flex = props['flex'];
      final inRow = parent == 'row' && bounded;
      // A card has no height to share and an unflexed row child no width, so
      // anything that fills its parent needs one handed to it.
      final wide =
          props['width'] is num ||
          (parent == 'row' ? inRow && flex is num && flex.toInt() > 0 : bounded);
      if (card &&
          (!_cardKinds.contains(kind) ||
              depth == 0 && kind != 'panel' ||
              flex != null && !inRow ||
              !wide && _fillingCardKinds.contains(kind) ||
              props['interactive'] == true)) {
        throw const PluginException('A card is one panel of display nodes');
      }
      final key = props['key'];
      if (key is! String || key.isEmpty || key.length > 160 || !keys.add(key)) {
        throw const PluginException('UI nodes require unique stable keys');
      }
      for (final field in [
        'text',
        'label',
        'onPress',
        'onChange',
        'mode',
        'align',
        'color',
        'background',
        'border',
        'title',
        'subtitle',
        'caption',
        'hint',
        'breadcrumb',
        'opens',
        'direction',
      ]) {
        if (props[field] != null && props[field] is! String) {
          throw PluginException('Invalid UI $field');
        }
        if (props[field] is String &&
            (props[field]! as String).length > 16384) {
          throw const PluginException('UI text exceeds its limit');
        }
      }
      if (props['opens'] != null &&
          (!{'button', 'list_row', 'box'}.contains(kind) ||
              !pages.contains(props['opens']))) {
        throw const PluginException('UI opens an undeclared page');
      }
      if (props['live'] != null &&
          (props['live'] is! bool || kind != 'input')) {
        throw const PluginException('Only an input is live');
      }
      if (props['awake'] != null && kind != 'page' ||
          props['awake'] == true && !allowAwake) {
        throw const PluginException('Keep-awake permission is not granted');
      }
      if (kind == 'page' &&
          props['fill'] == true &&
          uiList(value['children'])
                  .where(
                    (child) =>
                        child is! Map<String, Object?> ||
                        child['kind'] != 'footer',
                  )
                  .length !=
              1) {
        throw const PluginException('A filling page holds one child');
      }
      if (props['value'] != null &&
          (kind == 'toggle'
              ? props['value'] is! bool
              : props['value'] is! String)) {
        throw const PluginException('Invalid UI field value');
      }
      if (props['value'] is String &&
          (props['value']! as String).length > 16384) {
        throw const PluginException('UI field exceeds its limit');
      }
      for (final field in [
        'width',
        'height',
        'padding',
        'gap',
        'fontSize',
        'flex',
        'lines',
        'left',
        'top',
        'right',
        'bottom',
      ]) {
        final number = props[field];
        if (number != null &&
            (number is! num ||
                !number.isFinite ||
                number < 0 ||
                number > 4096)) {
          throw PluginException('Invalid UI $field');
        }
      }
      if (kind == 'select' || kind == 'choice') {
        final values = <String>{};
        final options = uiList(props['options']);
        if (options.length > 256) {
          throw const PluginException('Too many UI choices');
        }
        for (final option in options) {
          if (option is! Map<String, Object?> ||
              option['value'] is! String ||
              option['label'] is! String ||
              !values.add(option['value']! as String)) {
            throw const PluginException('Invalid or duplicate UI choice');
          }
        }
      }
      if (kind == 'canvas') {
        if (!allowCanvas) {
          throw const PluginException('Canvas permission is not granted');
        }
        final commands = uiList(props['commands']);
        drawingCommands += commands.length;
        if (commands.length > 256 || drawingCommands > 512) {
          throw const PluginException('Canvas command limit exceeded');
        }
        for (final command in commands) {
          if (command is! Map<String, Object?> ||
              !{'rect', 'line', 'circle', 'text'}.contains(command['op'])) {
            throw const PluginException('Unsupported canvas operation');
          }
          if (command['text'] != null && command['text'] is! String ||
              command['color'] != null && command['color'] is! String) {
            throw const PluginException('Invalid canvas text or color');
          }
          for (final field in [
            'x',
            'y',
            'x2',
            'y2',
            'width',
            'height',
            'radius',
            'stroke',
            'size',
          ]) {
            final n = command[field];
            if (n != null && (n is! num || !n.isFinite || n.abs() > 4096)) {
              throw const PluginException('Invalid canvas coordinate');
            }
          }
        }
      }
      final children = [
        for (final child in uiList(value['children']))
          read(child, depth + 1, parent: kind, bounded: wide),
      ];
      return PluginUiNode(
        kind,
        Map.unmodifiable(props),
        List.unmodifiable(children),
      );
    }

    return read(source, 0);
  }
}

List<Object?> uiList(Object? value) {
  if (value == null || value is Map<String, Object?> && value.isEmpty) {
    return const [];
  }
  if (value is List<Object?>) return value;
  throw const PluginException('Expected a UI list');
}

void synchronizePluginFields(
  Map<String, Object?> values,
  PluginUiNode? previous,
  PluginUiNode next,
) {
  Map<String, PluginUiNode> fields(PluginUiNode? root) {
    final result = <String, PluginUiNode>{};
    void visit(PluginUiNode node) {
      if (const {
        'input',
        'select',
        'choice',
        'toggle',
        'datetime',
      }.contains(node.kind)) {
        result[node.key] = node;
      }
      for (final child in node.children) {
        visit(child);
      }
    }

    if (root != null) visit(root);
    return result;
  }

  final old = fields(previous);
  final current = fields(next);
  values.removeWhere((key, _) => !current.containsKey(key));
  for (final entry in current.entries) {
    final before = old[entry.key];
    final after = entry.value;
    if (before == null ||
        before.kind != after.kind ||
        before.props['value'] != after.props['value']) {
      values[entry.key] =
          after.props['value'] ?? (after.kind == 'toggle' ? false : '');
    }
  }
}

Color pluginColor(StrikedTokens tokens, Object? value, [Color? fallback]) {
  return switch (value) {
    'accent' => tokens.accent,
    'muted' => tokens.textMuted,
    'background' => tokens.backgroundPrimary,
    'surface' => tokens.backgroundSecondary,
    'border' => tokens.borderNormal,
    'danger' => tokens.danger,
    'warning' => tokens.warning,
    String() when RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value) => Color(
      0xFF000000 | int.parse(value.substring(1), radix: 16),
    ),
    _ => fallback ?? tokens.textPrimary,
  };
}

class PluginUi extends StatelessWidget {
  const PluginUi({
    super.key,
    required this.node,
    required this.values,
    required this.onEvent,
    this.busy = false,
    this.onBack,
    this.onOpen,
  });
  final PluginUiNode node;
  final Map<String, Object?> values;
  final ValueChanged<Map<String, Object?>> onEvent;
  final bool busy;
  final VoidCallback? onBack;
  final ValueChanged<String>? onOpen;

  @override
  Widget build(BuildContext context) => _build(context, node);

  Widget _build(BuildContext context, PluginUiNode node, {bool fills = false}) {
    final p = node.props;
    double number(String name, double fallback) =>
        (p[name] as num?)?.toDouble() ?? fallback;
    void action(String? id, {Object? value, Offset? position}) {
      if (id == null || busy) return;
      onEvent({
        'type': 'action',
        'id': id,
        'fields': Map<String, Object?>.of(values),
        if (p['args'] != null) 'args': p['args'],
        'value': ?value,
        if (position != null) 'position': {'x': position.dx, 'y': position.dy},
      });
    }

    final opens = p['opens'] as String?;
    final press = opens != null
        ? (busy || onOpen == null ? null : () => onOpen!(opens))
        : p['onPress'] == null || busy
        ? null
        : () => action(p['onPress'] as String?);

    Widget child(PluginUiNode entry, {bool flex = false}) {
      final built = _build(context, entry);
      final amount = (entry.props['flex'] as num?)?.toInt() ?? 0;
      return flex && amount > 0
          ? Expanded(
              key: ValueKey('${entry.key}:flex'),
              flex: amount.clamp(1, 12),
              child: built,
            )
          : built;
    }

    List<Widget> children({bool flex = false, bool horizontal = false}) => [
      for (var i = 0; i < node.children.length; i++) ...[
        if (i > 0 && number('gap', 0) > 0)
          SizedBox(
            width: horizontal ? number('gap', 0).clamp(0, 64) : 0,
            height: horizontal ? 0 : number('gap', 0).clamp(0, 64),
          ),
        child(node.children[i], flex: flex),
      ],
    ];
    final align = switch (p['align']) {
      'center' => CrossAxisAlignment.center,
      'end' => CrossAxisAlignment.end,
      'stretch' => CrossAxisAlignment.stretch,
      _ => CrossAxisAlignment.start,
    };
    Widget result = switch (node.kind) {
      'page' => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ScreenScaffold(
              title: p['title'] as String?,
              breadcrumb: p['breadcrumb'] as String? ?? '/ TOOLS',
              onBack: onBack,
              breadcrumbTrailing: busy
                  ? Text('CONNECTING', style: context.tokens.rowKicker)
                  : null,
              fill: p['fill'] == true,
              children: [
                for (final entry in node.children.where(
                  (entry) => entry.kind != 'footer',
                ))
                  if (p['fill'] == true)
                    _build(context, entry, fills: true)
                  else ...[
                    child(entry),
                    SizedBox(height: number('gap', 16).clamp(0, 64)),
                  ],
              ],
            ),
          ),
          for (final entry in node.children.where(
            (entry) => entry.kind == 'footer',
          ))
            child(entry),
        ],
      ),
      'footer' => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.screenEdge),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children(),
          ),
        ),
      ),
      'disclosure' => _PluginDisclosure(
        key: ValueKey(node.key),
        title: p['title'] as String? ?? '',
        subtitle: p['subtitle'] as String?,
        children: children(),
      ),
      'screen' => SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.all(number('padding', 16).clamp(0, 64)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children(flex: true),
          ),
        ),
      ),
      'column' when fills => LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: _FillColumn(
            viewport: constraints.maxHeight,
            gap: number('gap', 0).clamp(0, 64),
            align: align,
            flexes: [
              for (final entry in node.children)
                ((entry.props['flex'] as num?)?.toInt() ?? 0).clamp(0, 12),
            ],
            children: [
              for (final entry in node.children) _build(context, entry),
            ],
          ),
        ),
      ),
      'column' => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: align,
        children: children(flex: true),
      ),
      'row' => Row(
        crossAxisAlignment: align == CrossAxisAlignment.stretch
            ? CrossAxisAlignment.center
            : align,
        children: children(flex: true, horizontal: true),
      ),
      'stack' => Stack(
        children: [
          for (final entry in node.children)
            if (const [
              'left',
              'top',
              'right',
              'bottom',
            ].any(entry.props.containsKey))
              Positioned(
                key: ValueKey('${entry.key}:position'),
                left: (entry.props['left'] as num?)?.toDouble(),
                top: (entry.props['top'] as num?)?.toDouble(),
                right: (entry.props['right'] as num?)?.toDouble(),
                bottom: (entry.props['bottom'] as num?)?.toDouble(),
                child: child(entry),
              )
            else
              child(entry),
        ],
      ),
      'box' => _pressable(
        press,
        Container(
          padding: EdgeInsets.all(number('padding', 12).clamp(0, 64)),
          decoration: BoxDecoration(
            color: pluginColor(
              context.tokens,
              p['background'],
              context.tokens.backgroundSecondary,
            ),
            border: Border.all(
              color: pluginColor(
                context.tokens,
                p['border'],
                context.tokens.borderNormal,
              ),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children(),
          ),
        ),
      ),
      'text' => Text(
        maxLines: (p['lines'] as num?)?.toInt().clamp(1, 64),
        overflow: p['lines'] == null ? null : TextOverflow.ellipsis,
        p['text'] as String? ?? '',
        style:
            (p['style'] == 'heading'
                    ? context.tokens.screenTitle
                    : context.tokens.rowTitle)
                .copyWith(
                  color: pluginColor(context.tokens, p['color']),
                  fontSize: number('fontSize', 13).clamp(10, 48),
                  fontWeight: p['bold'] == true
                      ? FontWeight.w600
                      : FontWeight.normal,
                ),
      ),
      'button' => Semantics(
        button: true,
        enabled: !busy && p['disabled'] != true && p['enabled'] != false,
        child: ActionBlock(
          label: p['text'] as String? ?? '',
          tone: busy || p['disabled'] == true || p['enabled'] == false
              ? context.tokens.textMuted
              : pluginColor(
                  context.tokens,
                  p['background'] ?? p['color'],
                  context.tokens.textSecondary,
                ),
          filled: p['background'] != null,
          onTap: busy || p['disabled'] == true || p['enabled'] == false
              ? null
              : press ?? () {},
        ),
      ),
      'input' || 'select' || 'choice' || 'toggle' || 'datetime' => _PluginField(
        key: ValueKey(node.key),
        node: node,
        values: values,
        busy: busy,
        onChange: (value) => action(p['onChange'] as String?, value: value),
      ),
      'list' => ListView.separated(
        primary: false,
        scrollDirection: p['direction'] == 'horizontal'
            ? Axis.horizontal
            : Axis.vertical,
        itemCount: node.children.length,
        itemBuilder: (context, index) => child(node.children[index]),
        separatorBuilder: (_, index) => SizedBox(
          width: number('gap', 8).clamp(0, 64),
          height: number('gap', 8).clamp(0, 64),
        ),
      ),
      'canvas' => _canvas(
        node,
        GestureDetector(
          onTapUp: p['onPress'] == null
              ? null
              : (event) => action(
                  p['onPress'] as String?,
                  position: event.localPosition,
                ),
          child: RepaintBoundary(
            child: SizedBox(
              height: number('height', 96).clamp(0, 4096),
              width: number('width', 240).clamp(0, 4096),
              child: CustomPaint(
                painter: _PluginCanvas(uiList(p['commands']), context.tokens),
              ),
            ),
          ),
        ),
      ),
      'spacer' => SizedBox(
        height: number('height', 8),
        width: number('width', 8),
      ),
      'divider' => Divider(color: context.tokens.borderNormal),
      'panel' => Panel(
        title: p['title'] as String?,
        child: node.children.isEmpty
            ? null
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children(),
              ),
      ),
      'section' => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (p['title'] != null) ...[
            Text(
              (p['title']! as String).toUpperCase(),
              style: context.tokens.rowKicker,
            ),
            const SizedBox(height: Spacing.sm),
          ],
          ...children(),
        ],
      ),
      'list_row' => ListRow(
        title: p['title'] as String? ?? '',
        subtitle: p['subtitle'] as String?,
        caption: p['caption'] as String?,
        value: p['value'] as String?,
        node: p['node'] == true,
        onTap: press,
      ),
      'status_tag' => Align(
        alignment: Alignment.centerLeft,
        child: StatusTag(
          p['label'] as String? ?? '',
          color: pluginColor(
            context.tokens,
            p['color'],
            context.tokens.textSecondary,
          ),
        ),
      ),
      'bracket_label' => BracketLabel(
        p['label'] as String? ?? '',
        value: p['value'] as String? ?? '',
        color: p['color'] == null
            ? null
            : pluginColor(context.tokens, p['color']),
      ),
      _ => const SizedBox.shrink(),
    };
    if (node.kind != 'canvas' && (p['height'] != null || p['width'] != null)) {
      result = SizedBox(
        height: (p['height'] as num?)?.toDouble(),
        width: (p['width'] as num?)?.toDouble(),
        child: result,
      );
    }
    return KeyedSubtree(key: ValueKey(node.key), child: result);
  }

  Widget _pressable(VoidCallback? press, Widget child) => press == null
      ? child
      : Semantics(
          button: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: press,
            child: child,
          ),
        );

  Widget _canvas(PluginUiNode node, Widget painting) {
    if (node.props['interactive'] != true) return painting;
    return InteractiveViewer(
      key: ValueKey('${node.key}:viewport'),
      constrained: false,
      minScale: 0.5,
      maxScale: 3,
      child: painting,
    );
  }
}

class _PluginField extends StatefulWidget {
  const _PluginField({
    super.key,
    required this.node,
    required this.values,
    required this.onChange,
    required this.busy,
  });
  final PluginUiNode node;
  final Map<String, Object?> values;
  final ValueChanged<Object?> onChange;
  final bool busy;
  @override
  State<_PluginField> createState() => _PluginFieldState();
}

class _PluginFieldState extends State<_PluginField> {
  late final TextEditingController text;
  Timer? _live;
  Object? _sent;
  String get value => widget.values[widget.node.key]?.toString() ?? '';
  @override
  void initState() {
    super.initState();
    final initial = widget.values.putIfAbsent(
      widget.node.key,
      () => widget.node.props['value'] ?? '',
    );
    text = TextEditingController(text: '$initial');
  }

  @override
  void didUpdateWidget(_PluginField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.node.props['value'] ?? '';
    // A live field's own value coming back must not overwrite what was typed since.
    if (next != (oldWidget.node.props['value'] ?? '') && next != _sent) {
      _live?.cancel();
      widget.values[widget.node.key] = next;
      text.text = '$next';
    }
  }

  void change(Object? value) {
    setState(() => widget.values[widget.node.key] = value);
    widget.onChange(value);
  }

  void send(Object? value) {
    _live?.cancel();
    if (!mounted) return;
    if (widget.busy) {
      _live = Timer(const Duration(milliseconds: 300), () => send(value));
      return;
    }
    _sent = value;
    widget.onChange(value);
  }

  @override
  void dispose() {
    _live?.cancel();
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.node.props;
    final label = p['label'] as String? ?? widget.node.key;
    switch (widget.node.kind) {
      case 'choice':
        return Panel(
          title: label,
          child: Wrap(
            spacing: Spacing.md,
            runSpacing: Spacing.md,
            children: [
              for (final choice in uiList(
                p['options'],
              ).whereType<Map<String, Object?>>())
                Semantics(
                  button: true,
                  selected: choice['value'] == value,
                  child: ActionBlock(
                    label: choice['label']! as String,
                    filled: choice['value'] == value,
                    tone: choice['value'] == value
                        ? context.tokens.accent
                        : null,
                    onTap: widget.busy ? null : () => change(choice['value']),
                  ),
                ),
            ],
          ),
        );
      case 'select':
        final choices = uiList(p['options'])
            .whereType<Map<String, Object?>>()
            .toList();
        final selected = choices
            .where((choice) => choice['value'] == value)
            .firstOrNull;
        return Panel(
          child: ListRow(
            title: label,
            subtitle:
                selected?['label'] as String? ??
                p['hint'] as String? ??
                'Choose',
            node: true,
            onTap: widget.busy
                ? null
                : () async {
                    FocusScope.of(context).unfocus();
                    final picked = await showPanelSheet<String>(
                      context,
                      title: label,
                      builder: (context) => PanelSheetBody(
                        title: label,
                        children: [
                          for (final choice in choices)
                            PickerRow(
                              label: choice['label']! as String,
                              selected: choice['value'] == value,
                              onTap: () => Navigator.pop(
                                context,
                                choice['value']! as String,
                              ),
                            ),
                        ],
                      ),
                    );
                    if (mounted && picked != null) change(picked);
                  },
          ),
        );
      case 'toggle':
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(label, style: context.tokens.rowTitle),
          value: widget.values[widget.node.key] == true,
          onChanged: widget.busy ? null : change,
        );
      case 'datetime':
        return Panel(
          child: ListRow(
            title: label,
            subtitle: value.isEmpty
                ? 'Choose date and time'
                : value.replaceFirst('T', ' · '),
            node: true,
            onTap: widget.busy
                ? null
                : () async {
                    final clockValue = RegExp(r'^([0-2][0-9]):([0-5][0-9])$')
                        .firstMatch(value);
                    final date =
                        (p['mode'] == 'time' &&
                                clockValue != null &&
                                int.parse(clockValue[1]!) < 24
                            ? DateTime(
                                2026,
                                1,
                                1,
                                int.parse(clockValue[1]!),
                                int.parse(clockValue[2]!),
                              )
                            : DateTime.tryParse(value)) ??
                        DateTime.now();
                    DateTime? picked = date;
                    if (p['mode'] != 'time') {
                      picked = await showDatePicker(
                        context: context,
                        initialDate: date,
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2100),
                      );
                    }
                    if (picked == null || !context.mounted) return;
                    final clock = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay.fromDateTime(date),
                    );
                    if (clock == null || !mounted) return;
                    final time =
                        '${clock.hour.toString().padLeft(2, '0')}:${clock.minute.toString().padLeft(2, '0')}';
                    change(
                      p['mode'] == 'time'
                          ? time
                          : '${picked.toIso8601String().substring(0, 10)}T$time',
                    );
                  },
          ),
        );
      default:
        final live = p['live'] == true;
        return FieldPanel(
          enabled: live || !widget.busy,
          maxLength: 16000,
          label: label,
          hint: p['hint'] as String? ?? '',
          controller: text,
          maxLines: (p['lines'] as num?)?.toInt().clamp(1, 8) ?? 1,
          onChanged: (value) {
            widget.values[widget.node.key] = value;
            if (!live) return;
            _live?.cancel();
            _live = Timer(const Duration(milliseconds: 300), () => send(value));
          },
          onSubmitted: live ? send : widget.onChange,
        );
    }
  }
}

class _PluginDisclosure extends StatefulWidget {
  const _PluginDisclosure({
    super.key,
    required this.title,
    this.subtitle,
    required this.children,
  });
  final String title;
  final String? subtitle;
  final List<Widget> children;
  @override
  State<_PluginDisclosure> createState() => _PluginDisclosureState();
}

class _PluginDisclosureState extends State<_PluginDisclosure> {
  bool expanded = false;
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Semantics(
        button: true,
        expanded: expanded,
        child: ListRow(
          title: widget.title,
          subtitle: widget.subtitle,
          value: expanded ? 'LESS' : 'MORE',
          onTap: () => setState(() => expanded = !expanded),
        ),
      ),
      Offstage(
        offstage: !expanded,
        child: TickerMode(
          enabled: expanded,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: widget.children,
          ),
        ),
      ),
    ],
  );
}

class _PluginCanvas extends CustomPainter {
  _PluginCanvas(this.commands, this.tokens) : signature = jsonEncode(commands);
  final List<Object?> commands;
  final StrikedTokens tokens;
  final String signature;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final command in commands.whereType<Map<String, Object?>>()) {
      double number(String key, [double fallback = 0]) =>
          (command[key] as num?)?.toDouble() ?? fallback;
      final paint = Paint()
        ..color = pluginColor(tokens, command['color'])
        ..strokeWidth = number('stroke', 1).clamp(0, 64);
      switch (command['op']) {
        case 'rect':
          canvas.drawRect(
            Rect.fromLTWH(
              number('x'),
              number('y'),
              number('width').clamp(0, 4096),
              number('height').clamp(0, 4096),
            ),
            paint,
          );
        case 'line':
          canvas.drawLine(
            Offset(number('x'), number('y')),
            Offset(number('x2'), number('y2')),
            paint,
          );
        case 'circle':
          canvas.drawCircle(
            Offset(number('x'), number('y')),
            number('radius').clamp(0, 4096),
            paint,
          );
        case 'text':
          final text = TextPainter(
            textDirection: TextDirection.ltr,
            maxLines: 8,
            text: TextSpan(
              text: command['text'] as String? ?? '',
              style: tokens.rowTitle.copyWith(
                color: paint.color,
                fontSize: number('size', 12).clamp(8, 64),
              ),
            ),
          );
          text.layout(maxWidth: size.width);
          text.paint(canvas, Offset(number('x'), number('y')));
          text.dispose();
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PluginCanvas oldDelegate) =>
      signature != oldDelegate.signature || tokens != oldDelegate.tokens;
}

class _FillColumn extends MultiChildRenderObjectWidget {
  const _FillColumn({
    required this.viewport,
    required this.gap,
    required this.align,
    required this.flexes,
    required super.children,
  });

  static const minFill = 240.0;

  final double viewport;
  final double gap;
  final CrossAxisAlignment align;
  final List<int> flexes;

  @override
  _RenderFillColumn createRenderObject(BuildContext context) =>
      _RenderFillColumn(viewport, gap, align, flexes);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFillColumn renderObject,
  ) {
    renderObject
      ..viewport = viewport
      ..gap = gap
      ..align = align
      ..flexes = flexes;
  }
}

class _FillParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderFillColumn extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _FillParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _FillParentData> {
  _RenderFillColumn(this._viewport, this._gap, this._align, this._flexes);

  double _viewport;
  set viewport(double value) {
    if (value == _viewport) return;
    _viewport = value;
    markNeedsLayout();
  }

  double _gap;
  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  CrossAxisAlignment _align;
  set align(CrossAxisAlignment value) {
    if (value == _align) return;
    _align = value;
    markNeedsLayout();
  }

  List<int> _flexes;
  set flexes(List<int> value) {
    if (listEquals(value, _flexes)) return;
    _flexes = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FillParentData) {
      child.parentData = _FillParentData();
    }
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    final stretch = _align == CrossAxisAlignment.stretch;
    final across = stretch
        ? BoxConstraints.tightFor(width: width)
        : BoxConstraints(maxWidth: width);
    final children = getChildrenAsList();
    int flexOf(int index) => index < _flexes.length ? _flexes[index] : 0;
    var taken = children.isEmpty ? 0.0 : _gap * (children.length - 1);
    var shares = 0;
    for (var i = 0; i < children.length; i++) {
      if (flexOf(i) > 0) {
        shares += flexOf(i);
      } else {
        children[i].layout(across, parentUsesSize: true);
        taken += children[i].size.height;
      }
    }
    final room = _viewport.isFinite
        ? (_viewport - taken).clamp(_FillColumn.minFill, double.infinity)
        : _FillColumn.minFill;
    var y = 0.0;
    for (var i = 0; i < children.length; i++) {
      final child = children[i];
      if (flexOf(i) > 0) {
        final height = room * flexOf(i) / shares;
        child.layout(
          across.copyWith(minHeight: height, maxHeight: height),
          parentUsesSize: true,
        );
      }
      final x = switch (_align) {
        CrossAxisAlignment.center => (width - child.size.width) / 2,
        CrossAxisAlignment.end => width - child.size.width,
        _ => 0.0,
      };
      (child.parentData! as _FillParentData).offset = Offset(x, y);
      y += child.size.height + (i < children.length - 1 ? _gap : 0);
    }
    size = constraints.constrain(Size(width, y));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
