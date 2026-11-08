import 'package:upgrade/data/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/plugin_sdk.dart';

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
          !uiKindProps.containsKey(kind) ||
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
          (parent == 'row'
              ? inRow && flex is num && flex.toInt() > 0
              : bounded);
      if (card &&
          (!uiCardKinds.contains(kind) ||
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
      final drag = props['drag'];
      if (drag != null &&
          (card ||
              !uiKindProps[kind]!.containsKey('drag') ||
              drag is! String ||
              drag.length > 160)) {
        throw const PluginException('Only a box on a page drags');
      }
      final drop = props['onDrop'];
      if (drop != null &&
          (card ||
              uiCommonProps['onDrop']!.notOn.contains(kind) ||
              drop is! String ||
              drop.length > 160)) {
        throw const PluginException('Only a node on a page takes a drop');
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
