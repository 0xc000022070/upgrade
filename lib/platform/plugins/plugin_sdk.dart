import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/ui_tree.dart';
import 'package:upgrade/brand.dart';

const pluginToolSchemaVersion = 1;

const pluginSdkUiApi = 2;

enum UiPropType { string, number, boolean, list, color, value }

final class UiProp {
  const UiProp(
    this.type, {
    this.values,
    this.pageOnly = false,
    this.notOn = const {},
  });

  final UiPropType type;
  final Set<String>? values;
  final bool pageOnly;
  final Set<String> notOn;

  Map<String, Object?> toJson() => {
    'type': type.name,
    if (values != null) 'values': [...values!],
    if (pageOnly) 'page_only': true,
    if (notOn.isNotEmpty) 'not_on': [...notOn],
  };
}

const uiSemanticColors = {
  'text',
  'muted',
  'accent',
  'background',
  'surface',
  'border',
  'danger',
  'warning',
};

const _number = UiProp(UiPropType.number);
const _text = UiProp(UiPropType.string);
const _flag = UiProp(UiPropType.boolean);
const _color = UiProp(UiPropType.color);
const _align = UiProp(
  UiPropType.string,
  values: {'start', 'center', 'end', 'stretch'},
);

const uiCommonProps = <String, UiProp>{
  'key': _text,
  'width': _number,
  'height': _number,
  'flex': _number,
  'left': _number,
  'top': _number,
  'right': _number,
  'bottom': _number,
  'args': UiProp(UiPropType.value),
  'onDrop': UiProp(
    UiPropType.string,
    pageOnly: true,
    notOn: {'page', 'screen', 'footer'},
  ),
};

const uiKindProps = <String, Map<String, UiProp>>{
  'screen': {'padding': _number, 'gap': _number},
  'page': {
    'title': _text,
    'breadcrumb': _text,
    'fill': _flag,
    'gap': _number,
    'awake': _flag,
  },
  'footer': {'gap': _number},
  'disclosure': {'title': _text, 'subtitle': _text, 'gap': _number},
  'column': {'gap': _number, 'align': _align},
  'row': {'gap': _number, 'align': _align},
  'stack': {},
  'box': {
    'padding': _number,
    'gap': _number,
    'background': _color,
    'border': _color,
    'onPress': _text,
    'opens': _text,
    'drag': UiProp(UiPropType.string, pageOnly: true),
  },
  'text': {
    'text': _text,
    'lines': _number,
    'style': UiProp(UiPropType.string, values: {'heading'}),
    'color': _color,
    'fontSize': _number,
    'bold': _flag,
  },
  'button': {
    'text': _text,
    'background': _color,
    'color': _color,
    'disabled': _flag,
    'enabled': _flag,
    'onPress': _text,
    'opens': _text,
  },
  'input': {
    'label': _text,
    'value': _text,
    'hint': _text,
    'lines': _number,
    'live': _flag,
    'onChange': _text,
  },
  'select': {
    'label': _text,
    'value': _text,
    'hint': _text,
    'options': UiProp(UiPropType.list),
    'onChange': _text,
  },
  'choice': {
    'label': _text,
    'value': _text,
    'options': UiProp(UiPropType.list),
    'onChange': _text,
  },
  'toggle': {'label': _text, 'value': _flag, 'onChange': _text},
  'datetime': {
    'label': _text,
    'value': _text,
    'mode': UiProp(UiPropType.string, values: {'time', 'datetime'}),
    'onChange': _text,
  },
  'list': {
    'gap': _number,
    'direction': UiProp(UiPropType.string, values: {'vertical', 'horizontal'}),
  },
  'canvas': {
    'commands': UiProp(UiPropType.list),
    'onPress': _text,
    'interactive': _flag,
  },
  'spacer': {},
  'divider': {},
  'panel': {'title': _text, 'gap': _number},
  'section': {'title': _text, 'gap': _number},
  'list_row': {
    'title': _text,
    'subtitle': _text,
    'caption': _text,
    'value': _text,
    'node': _flag,
    'onPress': _text,
    'opens': _text,
  },
  'status_tag': {'label': _text, 'color': _color},
  'bracket_label': {'label': _text, 'value': _text, 'color': _color},
};

const _apiTwoKinds = {
  'panel',
  'section',
  'list_row',
  'status_tag',
  'bracket_label',
  'page',
  'footer',
  'disclosure',
  'choice',
};

const uiCardKinds = {
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

const uiLineProp = '__line';

final class PluginSource {
  const PluginSource({required this.path, this.line, this.column});

  final String path;
  final int? line;
  final int? column;

  Map<String, Object?> toJson() => {
    'path': path,
    'line': ?line,
    'column': ?column,
  };
}

enum PluginSeverity { error, warning }

final class PluginDiagnostic {
  const PluginDiagnostic({
    required this.code,
    required this.message,
    required this.nextAction,
    this.severity = PluginSeverity.error,
    this.source,
    this.node,
    this.operation,
    this.expected,
    this.actual,
  });

  final String code;
  final PluginSeverity severity;
  final String message;
  final PluginSource? source;

  final String? node;
  final String? operation;
  final String? expected;
  final String? actual;
  final String nextAction;

  bool get blocking => severity == PluginSeverity.error;

  Map<String, Object?> toJson() => {
    'code': code,
    'severity': severity.name,
    'message': message,
    'source': ?source?.toJson(),
    'node': ?node,
    'operation': ?operation,
    'expected': ?expected,
    'actual': ?actual,
    'api_version': PluginManifest.apiVersion.toString(),
    'ui_api': pluginSdkUiApi,
    'next_action': nextAction,
  };

  static PluginDiagnostic fromJson(Map<String, Object?> json) {
    final source = json['source'];
    return PluginDiagnostic(
      code: json['code']! as String,
      severity: json['severity'] == 'warning'
          ? PluginSeverity.warning
          : PluginSeverity.error,
      message: json['message']! as String,
      nextAction: json['next_action'] as String? ?? '',
      source: source is Map<String, Object?>
          ? PluginSource(
              path: source['path']! as String,
              line: source['line'] as int?,
              column: source['column'] as int?,
            )
          : null,
      node: json['node'] as String?,
      operation: json['operation'] as String?,
      expected: json['expected'] as String?,
      actual: json['actual'] as String?,
    );
  }
}

String _shown(Object? value) => switch (value) {
  null => 'nil',
  String() => '"$value"',
  num() || bool() => '$value',
  List<Object?>() => 'list',
  Map<String, Object?>() => 'table',
  _ => value.runtimeType.toString(),
};

String _expected(UiProp prop) => switch (prop.type) {
  UiPropType.string when prop.values != null =>
    prop.values!.map((value) => '"$value"').join(' | '),
  UiPropType.string => 'string',
  UiPropType.number => 'number 0..4096',
  UiPropType.boolean => 'boolean',
  UiPropType.list => 'list',
  UiPropType.color => '${uiSemanticColors.join(' | ')} | #RRGGBB',
  UiPropType.value => 'value',
};

bool _fits(UiProp prop, Object? value) => switch (prop.type) {
  UiPropType.string =>
    value is String && (prop.values == null || prop.values!.contains(value)),
  UiPropType.number =>
    value is num && value.isFinite && value >= 0 && value <= 4096,
  UiPropType.boolean => value is bool,
  UiPropType.list =>
    value is List<Object?> || value is Map<String, Object?> && value.isEmpty,
  UiPropType.color =>
    value is String &&
        (uiSemanticColors.contains(value) ||
            RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)),
  UiPropType.value => true,
};

typedef SourceLocator = PluginSource? Function(int line);

List<PluginDiagnostic> validateUiTree(
  Object? tree, {
  required bool card,
  required int uiApi,
  required SourceLocator locate,
}) {
  final found = <PluginDiagnostic>[];
  final keys = <String>{};
  void visit(Object? value, String parent, int depth) {
    if (value is! Map<String, Object?> || depth > 24) return;
    final kind = value['kind'];
    final props = value['props'];
    final line = props is Map<String, Object?> ? props[uiLineProp] : null;
    final source = line is num ? locate(line.toInt()) : null;
    final key = props is Map<String, Object?> ? props['key'] : null;
    final path = '$parent/${kind is String ? kind : '?'}:${key ?? '?'}';
    void report(
      String code,
      String message,
      String next, {
      String? expected,
      String? actual,
    }) => found.add(
      PluginDiagnostic(
        code: code,
        message: message,
        nextAction: next,
        source: source,
        node: path,
        operation: card ? 'card' : 'frame',
        expected: expected,
        actual: actual,
      ),
    );

    final schema = uiKindProps[kind];
    if (kind is! String || schema == null) {
      report(
        'UI_UNKNOWN_KIND',
        'Unknown UI node kind',
        'Use a constructor listed by `docs`.',
        expected: uiKindProps.keys.join(' | '),
        actual: _shown(kind),
      );
      return;
    }
    if (uiApi < 2 && _apiTwoKinds.contains(kind)) {
      report(
        'UI_KIND_NEEDS_API',
        'ui.$kind needs ui_api = 2',
        'Set ui_api = 2 in upgrade.plugin.toml.',
        expected: 'ui_api 2',
        actual: 'ui_api $uiApi',
      );
    }
    if (card && !uiCardKinds.contains(kind)) {
      report(
        'UI_CARD_KIND',
        'A card holds display nodes only',
        'Move ${kind.toUpperCase()} to a page, or draw it with a display node.',
        expected: uiCardKinds.join(' | '),
        actual: kind,
      );
    }
    if (card && parent.isEmpty && kind != 'panel') {
      report(
        'UI_CARD_ROOT',
        'A card is one panel',
        'Return ui.Panel {...} from the card function.',
        expected: 'panel',
        actual: kind,
      );
    }
    if (props is! Map<String, Object?>) {
      report(
        'UI_INVALID_PROPERTY',
        'Node properties must be a table',
        'Pass a table of properties.',
        expected: 'table',
        actual: _shown(props),
      );
      return;
    }
    if (key is! String || key.isEmpty || key.length > 160) {
      report(
        'UI_MISSING_KEY',
        'Every node needs a stable key',
        'Add key = "<unique name>" to this node.',
        expected: 'string, 1..160 characters',
        actual: _shown(key),
      );
    } else if (!keys.add(key)) {
      report(
        'UI_DUPLICATE_KEY',
        'Node key "$key" is used twice',
        'Give each node a distinct key.',
        expected: 'unique key',
        actual: '"$key"',
      );
    }
    for (final MapEntry(key: name, value: given) in props.entries) {
      if (name == uiLineProp || name == 'key') continue;
      final prop = schema[name] ?? uiCommonProps[name];
      if (prop == null) {
        report(
          'UI_UNKNOWN_PROPERTY',
          'ui.$kind has no property "$name"',
          'Remove "$name" or use one of the listed properties.',
          expected: [
            for (final MapEntry(:key, :value) in {
              ...schema,
              ...uiCommonProps,
            }.entries)
              if (!card || !value.pageOnly) key,
          ].join(' | '),
          actual: name,
        );
      } else if (prop.pageOnly && card) {
        report(
          'UI_INVALID_PROPERTY',
          '"$name" works only on a page',
          'Remove "$name" from the card.',
          expected: 'page node',
          actual: 'card node',
        );
      } else if (prop.notOn.contains(kind)) {
        report(
          'UI_INVALID_PROPERTY',
          '"$name" does not work on ui.$kind',
          'Move "$name" to a node inside the $kind.',
          expected: 'not ${prop.notOn.join(' | ')}',
          actual: kind,
        );
      } else if (!_fits(prop, given)) {
        report(
          'UI_INVALID_PROPERTY',
          'ui.$kind property "$name" has the wrong value',
          'Set "$name" to ${_expected(prop)}.',
          expected: _expected(prop),
          actual: _shown(given),
        );
      }
    }
    final children = value['children'];
    if (children is List<Object?>) {
      for (final child in children) {
        visit(child, path, depth + 1);
      }
    }
  }

  visit(tree, '', 0);
  return found;
}

Object? stripUiLines(Object? tree) {
  if (tree is List<Object?>) {
    return [for (final item in tree) stripUiLines(item)];
  }
  if (tree is! Map<String, Object?>) return tree;
  return {
    for (final MapEntry(:key, :value) in tree.entries)
      if (key != uiLineProp) key: stripUiLines(value),
  };
}

Map<String, Object?> pluginSdkInventory() => {
  'schema_version': pluginToolSchemaVersion,
  'sdk': {
    'upgrade_api': PluginManifest.apiVersion.toString(),
    'manifest_version': PluginManifest.filesManifestVersion,
    'ui_api': [1, pluginSdkUiApi],
    'manifest_file': 'upgrade.plugin.toml',
    'max_manifest_bytes': PluginManifest.maxBytes,
    'max_source_bytes': 64 * 1024,
    'max_package_bytes': 512 * 1024,
    'max_declared_files': PluginManifest.maxDeclaredFiles,
  },
  'supported': {
    'manifest_formats': {
      '2': 'record actions',
      '3': 'native, bundled with $appName only',
      '4': 'Luau UI; ui_api required',
      '5': 'Luau with up to 31 extra .luau files; ui_api optional',
    },
    'runtime': {
      'kind': 'luau',
      'entry': 'ui.app {init, update, view, back, cards = {<widget id> = fn(state)}}',
      'actions': {
        'frame': 'input {state, event} -> {state, view, effects, back}',
        'card': 'input {state, event, widget} -> {state, view, effects}',
      },
      'events': {
        'mount': '{type, page | widget, theme (ui_api 2)}',
        'action': '{type, id, fields, args, value, position, token, now}',
        'refresh': '{type, widget}',
        'result': '{type, id, ok, value | error}',
        'changed': '{type, capability}',
      },
      'limits': {
        'script_ms': 50,
        'heap_bytes': 8 * 1024 * 1024,
        'io_bytes': 256 * 1024,
        'page_nodes': 2048,
        'card_nodes': 256,
        'depth': 24,
        'canvas_commands': 512,
        'choices': 256,
        'effects_per_frame': 4,
      },
    },
    'permissions': {
      'ui': ['record_action', 'page', 'canvas', 'widget', 'keep_awake'],
    },
    'contributions': {
      'pages': '{id, title}',
      'widgets': '{id, title, locations = ["home.card"], default_location, sizes, default_size, fill, refresh_minutes 15..1440}',
      'widget_size': '{id, title, width | min_width + max_width, height}',
      'record_actions': '{id, title}',
    },
    'host_capabilities': {
      'api_version': 1,
      'services': ['hosts', 'scheduler', 'agents', 'run'],
      'run': {
        'operations': ['submit', 'list', 'status', 'output', 'cancel'],
        'commands': '{name = {argv = ["word", "{param}"], cwd?, timeout_seconds 1..3600, choices? = {param = ["word"]}}}',
        'submit': '{host, command, params = {param = word}, id?} from a tap',
        'output': '{host, id, stream?, grep?, ignore_case?, invert?, head?, tail?, limit?}',
      },
    },
    'ui': {
      'kinds': {
        for (final MapEntry(key: kind, value: props) in uiKindProps.entries)
          kind: {
            'ui_api': _apiTwoKinds.contains(kind) ? 2 : 1,
            'card': uiCardKinds.contains(kind),
            'props': {
              for (final MapEntry(:key, :value) in props.entries)
                key: value.toJson(),
            },
          },
      },
      'common_props': {
        for (final MapEntry(:key, :value) in uiCommonProps.entries)
          key: value.toJson(),
      },
      'colors': [...uiSemanticColors, '#RRGGBB'],
      'canvas_ops': {
        'rect': ['x', 'y', 'width', 'height', 'color'],
        'line': ['x', 'y', 'x2', 'y2', 'stroke', 'color'],
        'circle': ['x', 'y', 'radius', 'color'],
        'text': ['x', 'y', 'text', 'size', 'color'],
      },
    },
    'preview': {
      'mode': 'fixtures',
      'fixtures': 'fixtures/*.json: {widget, events = [...], state?}',
      'transport': 'the phone reads the workspace over its SSH host link',
      'result': '.upgrade/preview/latest.json',
    },
  },
  'planned': [
    'live preview mode with real attachments',
    'durable development data in preview',
    'page and host-effect preview',
    'pack, signed releases and install candidate',
    'host-side Luau targets',
    'Android Home widgets',
    'marketplace publication',
  ],
  'diagnostic_codes': pluginDiagnosticCodes,
};

const pluginDiagnosticCodes = {
  'WORKSPACE_TOO_LARGE': 'more workspace files than a check reads',
  'MANIFEST_MISSING': 'no upgrade.plugin.toml at the workspace root',
  'MANIFEST_INVALID': 'the runtime refuses the manifest',
  'MANIFEST_UNSUPPORTED': 'the manifest parses but this app cannot run it',
  'FILE_MISSING': 'the entry or a declared file is absent',
  'PACKAGE_INVALID': 'sources exceed their limits',
  'PREVIEW_TARGET_MISSING': 'no home.card widget to preview',
  'FIXTURE_MISSING': 'no fixture for a widget; a bare mount is used',
  'FIXTURE_INVALID': 'a fixture is not valid JSON of the documented shape',
  'LUAU_ERROR': 'the plugin raised an error or broke a runtime limit',
  'PREVIEW_UNSUPPORTED':
      'the card reads a dataset, which a preview does not run',
  'UI_UNKNOWN_KIND': 'a node kind the renderer does not know',
  'UI_KIND_NEEDS_API': 'a node kind needs a newer ui_api',
  'UI_CARD_KIND': 'a node kind a card cannot hold',
  'UI_CARD_ROOT': 'a card root that is not a panel',
  'UI_MISSING_KEY': 'a node without a stable key',
  'UI_DUPLICATE_KEY': 'two nodes with the same key',
  'UI_UNKNOWN_PROPERTY': 'a property the node does not read',
  'UI_INVALID_PROPERTY': 'a property with the wrong type or value',
  'UI_REJECTED': 'the runtime parse refuses the tree',
  'PREVIEW_PENDING': 'the phone has not rendered this revision yet',
};

PluginUiNode parseCard(Object? tree, PluginManifest manifest) =>
    PluginUiNode.parse(
      tree,
      allowCanvas: manifest.permissions.any(
        (permission) => permission.id == 'ui.canvas',
      ),
      card: true,
      pages: {for (final page in manifest.pages) page.id},
    );
