import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:upgrade_luau/ui_sdk.dart';
import 'package:toml/toml.dart';

import 'package:upgrade/platform/plugins/contributions.dart';
import 'package:upgrade/platform/plugins/manifest.dart';
import 'package:upgrade/platform/plugins/plugin_sdk.dart';
import 'package:upgrade/platform/plugins/store.dart';
import 'package:upgrade/platform/plugins/ui_tree.dart';
import 'package:upgrade/brand.dart';

const pluginManifestFile = 'upgrade.plugin.toml';
const pluginPreviewResult = '.upgrade/preview/latest.json';
const pluginPreviewAsk = '.upgrade/ask';
const maxWorkspaceFiles = 64;

const maxWorkspaceFileKib = 256;

bool isPluginWorkspaceFile(String path) {
  final parts = path.split('/');
  if (parts.length > 4 || parts.any((part) => part.startsWith('.'))) {
    return false;
  }
  return path == pluginManifestFile ||
      path.endsWith('.luau') ||
      parts.length == 2 && parts.first == 'fixtures' && path.endsWith('.json');
}

String workspaceRevision(Map<String, String> files) {
  final paths = files.keys.where(isPluginWorkspaceFile).toList()..sort();
  return sha256
      .convert(
        utf8.encode(
          jsonEncode([
            for (final p in paths) [p, files[p]],
          ]),
        ),
      )
      .toString()
      .substring(0, 12);
}

typedef PluginInvoke = Future<Object?> Function({
  required String key,
  required String source,
  required String action,
  required Map<String, Object?> input,
});

const fixtureTheme = <String, Object?>{
  'brightness': 'dark',
  'background': '#000000',
  'surface': '#0A0A0A',
  'border': '#2A2A2A',
  'text': '#F2F2F2',
  'muted': '#8A8A8A',
  'accent': '#B7FF2A',
  'danger': '#FF4D4D',
  'warning': '#FFB547',
};

const _fixtureNow = '2026-01-01T09:00:00';

final class PluginRender {
  const PluginRender({
    required this.fixture,
    required this.widget,
    required this.size,
    required this.view,
    required this.effects,
  });

  final String fixture;
  final PluginWidgetContribution widget;
  final PluginWidgetSize size;
  final PluginUiNode view;
  final List<Object?> effects;

  Map<String, Object?> toJson() => {
    'fixture': fixture,
    'widget': widget.id,
    'size': size.id,
    'width': ?width,
    'root': view.key,
    'nodes': _count(view),
    if (effects.isNotEmpty) 'requested_effects': effects,
  };

  double? get width => size.fixedWidth ?? size.minWidth ?? size.maxWidth;

  static int _count(PluginUiNode node) =>
      1 + node.children.fold(0, (sum, child) => sum + _count(child));
}

final class PluginCheck {
  PluginCheck({
    required this.revision,
    required this.diagnostics,
    this.manifest,
    this.package,
    this.renders = const [],
  });

  final String revision;
  final List<PluginDiagnostic> diagnostics;
  final PluginManifest? manifest;
  final PluginPackage? package;
  final List<PluginRender> renders;

  bool get ok => !diagnostics.any((diagnostic) => diagnostic.blocking);

  Map<String, Object?> envelope({
    required String command,
    Map<String, Object?> artifacts = const {},
    Map<String, Object?> context = const {},
  }) => {
    'schema_version': pluginToolSchemaVersion,
    'command': command,
    'ok': ok,
    'diagnostics': [for (final d in diagnostics) d.toJson()],
    'artifacts': {
      'revision': revision,
      'digest': ?package?.digest,
      'renders': [for (final render in renders) render.toJson()],
      ...artifacts,
    },
    'context': {
      'upgrade_api': PluginManifest.apiVersion.toString(),
      'ui_api': pluginSdkUiApi,
      'manifest_version': PluginManifest.filesManifestVersion,
      if (manifest case final manifest?)
        'plugin': {
          'id': manifest.id,
          'version': manifest.version.toString(),
          'ui_api': manifest.uiVersion,
        },
      ...context,
    },
  };
}

final class PluginDevSource {
  PluginDevSource(PluginPackage package) {
    final sdk = _taggedSdk();
    final linked = package.linkedSource;
    text = '$sdk\n$linked';
    final offset = '\n'.allMatches(sdk).length + 1;
    final lines = linked.split('\n');
    var mainAt = 0;
    for (final path in package.files.keys.toList()..sort()) {
      final module = path.substring(0, path.length - '.luau'.length);
      final header = lines.indexOf('__upgrade_modules["$module"] = function()');
      if (header < 0) continue;
      _segments.add((offset + header + 1, path));
      mainAt = header + 1 + package.files[path]!.split('\n').length + 1;
    }
    _segments.add((offset + mainAt, package.manifest.entry));
    _segments.sort((a, b) => a.$1.compareTo(b.$1));
  }

  late final String text;
  final _segments = <(int, String)>[];

  PluginSource? locate(int line) {
    final at = line - 1;
    for (final (start, path) in _segments.reversed) {
      if (at >= start) return PluginSource(path: path, line: at - start + 1);
    }
    return null;
  }

  PluginSource? locateError(String message) {
    final match = _errorLine.firstMatch(message);
    return match == null ? null : locate(int.parse(match.group(1)!));
  }

  String describeError(String message) => message.replaceAllMapped(
    _errorLine,
    (match) => switch (locate(int.parse(match.group(1)!))) {
      PluginSource(:final path, :final line?) => '$path:$line:',
      _ => 'ui sdk:',
    },
  );

  static final _errorLine = RegExp(r'\[string "plugin"\]:(\d+):');

  static String _taggedSdk() {
    const constructor = '        return ui.node(kind, fields, children)';
    const node =
        '    return {kind = kind, props = props or {}, children = children or {}}';
    if (!luauUiSdk.contains(constructor) || !luauUiSdk.contains(node)) {
      throw StateError('The UI SDK no longer matches the dev line tags');
    }
    return luauUiSdk
        .replaceFirst(
          constructor,
          '        fields.$uiLineProp = debug.info(2, "l"); '
          'return ui.node(kind, fields, children)',
        )
        .replaceFirst(
          node,
          '    props = props or {}; if props.$uiLineProp == nil then '
          'props.$uiLineProp = debug.info(2, "l") end; '
          'return {kind = kind, props = props, children = children or {}}',
        );
  }
}

const _manifestFields = {
  'manifest version': 'manifest_version',
  'identifier': 'id',
  '$appName API': 'upgrade_api',
  'default widget size': 'default_size',
  'widget size': 'sizes',
  'default widget location': 'default_location',
  'widget location': 'locations',
  'widget fill': 'fill',
  'refresh': 'refresh_minutes',
  'require ui.': 'ui',
  'UI permission': 'ui',
  'entry': 'entry',
  'additional files': 'files',
  'Native plugins': 'runtime',
  'plugin runtime': 'runtime',
  'UI API version': 'ui_api',
};

int? _lineOf(String text, bool Function(String line) matches) {
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (matches(lines[i])) return i + 1;
  }
  return null;
}

PluginSource _manifestAt(String text, String? field) => PluginSource(
  path: pluginManifestFile,
  line: field == null
      ? null
      : _lineOf(
          text,
          (line) =>
              RegExp(
                '^\\s*(${RegExp.escape(field)}\\s*=|\\[${RegExp.escape(field)}\\])',
              ).hasMatch(line) ||
              line.contains('"$field"'),
        ),
);

Future<PluginCheck> checkPluginWorkspace(
  Map<String, String> files, {
  required PluginInvoke invoke,
  Map<String, Object?> theme = fixtureTheme,
}) async {
  final revision = workspaceRevision(files);
  final found = <PluginDiagnostic>[];
  PluginCheck done({
    PluginManifest? manifest,
    PluginPackage? package,
    List<PluginRender> renders = const [],
  }) => PluginCheck(
    revision: revision,
    diagnostics: found,
    manifest: manifest,
    package: package,
    renders: renders,
  );

  if (files.keys.where(isPluginWorkspaceFile).length > maxWorkspaceFiles) {
    found.add(
      const PluginDiagnostic(
        code: 'WORKSPACE_TOO_LARGE',
        message: 'More than $maxWorkspaceFiles workspace files',
        expected: 'at most $maxWorkspaceFiles files',
        nextAction: 'Move files the plugin does not load out of the workspace.',
      ),
    );
    return done();
  }
  final manifestText = files[pluginManifestFile];
  if (manifestText == null) {
    found.add(
      const PluginDiagnostic(
        code: 'MANIFEST_MISSING',
        message: 'No $pluginManifestFile at the workspace root',
        source: PluginSource(path: pluginManifestFile),
        nextAction: 'Run `init` to start from the template.',
      ),
    );
    return done();
  }
  final PluginManifest manifest;
  try {
    TomlDocument.parse(manifestText);
  } catch (error) {
    final position = RegExp(r'(\d+):(\d+)').firstMatch('$error');
    found.add(
      PluginDiagnostic(
        code: 'MANIFEST_INVALID',
        message: 'TOML does not parse: $error',
        source: PluginSource(
          path: pluginManifestFile,
          line: int.tryParse(position?.group(1) ?? ''),
          column: int.tryParse(position?.group(2) ?? ''),
        ),
        nextAction: 'Fix the TOML syntax.',
      ),
    );
    return done();
  }
  try {
    manifest = PluginManifest.parse(manifestText, retainUnsupported: true);
  } on PluginException catch (error) {
    final field =
        RegExp(r'field: ([a-z_]+)$').firstMatch(error.message)?.group(1) ??
        _manifestFields.entries
            .where((entry) => error.message.contains(entry.key))
            .firstOrNull
            ?.value;
    found.add(
      PluginDiagnostic(
        code: 'MANIFEST_INVALID',
        message: error.message,
        source: _manifestAt(manifestText, field),
        operation: 'manifest',
        nextAction: 'Compare $pluginManifestFile with the manifest in `docs`.',
      ),
    );
    return done();
  }
  if (!manifest.supported) {
    final field = _manifestFields.entries
        .where((entry) => manifest.incompatibility!.contains(entry.key))
        .firstOrNull
        ?.value;
    found.add(
      PluginDiagnostic(
        code: 'MANIFEST_UNSUPPORTED',
        message: manifest.incompatibility!,
        source: _manifestAt(manifestText, field),
        expected: switch (field) {
          'runtime' => 'runtime kind "luau"',
          'ui_api' => 'ui_api 1 or 2',
          'upgrade_api' => 'upgrade_api allowing ${PluginManifest.apiVersion}',
          _ => 'manifest_version <= ${PluginManifest.filesManifestVersion}',
        },
        nextAction: 'Target the versions `docs` prints.',
      ),
    );
    return done(manifest: manifest);
  }
  final source = files[manifest.entry];
  final missing = [
    if (source == null) manifest.entry,
    for (final path in manifest.files)
      if (!files.containsKey(path)) path,
  ];
  for (final path in missing) {
    found.add(
      PluginDiagnostic(
        code: 'FILE_MISSING',
        message: '$path is declared but absent',
        source: _manifestAt(
          manifestText,
          path == manifest.entry ? 'entry' : 'files',
        ),
        actual: path,
        nextAction: 'Create $path or remove it from the manifest.',
      ),
    );
  }
  if (source == null || missing.isNotEmpty) return done(manifest: manifest);
  final PluginPackage package;
  try {
    package = PluginPackage(
      manifest: manifest,
      source: source,
      origin: 'development:${manifest.id}',
      revision: revision,
      files: {for (final path in manifest.files) path: files[path]!},
    );
  } on PluginException catch (error) {
    found.add(
      PluginDiagnostic(
        code: 'PACKAGE_INVALID',
        message: error.message,
        source: PluginSource(path: manifest.entry),
        nextAction: 'Split or shorten sources; `docs` lists the limits.',
      ),
    );
    return done(manifest: manifest);
  }
  final widgets = [
    for (final widget in manifest.widgets)
      if (widget.locations.contains(PluginPlacementLocation.homeCard)) widget,
  ];
  if (widgets.isEmpty) {
    found.add(
      PluginDiagnostic(
        code: 'PREVIEW_TARGET_MISSING',
        severity: PluginSeverity.warning,
        message: 'No home.card widget to preview',
        source: _manifestAt(manifestText, null),
        nextAction:
            'Declare [[contributes.widgets]] with locations = ["home.card"].',
      ),
    );
    return done(manifest: manifest, package: package);
  }

  final fixtures =
      <
        ({
          String name,
          String widget,
          Map<String, Object?>? state,
          List<Map<String, Object?>> events,
        })
      >[];
  for (final path in files.keys.toList()..sort()) {
    if (!path.startsWith('fixtures/') || !path.endsWith('.json')) continue;
    Object? json;
    try {
      json = jsonDecode(files[path]!);
    } on FormatException catch (error) {
      found.add(
        PluginDiagnostic(
          code: 'FIXTURE_INVALID',
          message: 'Not JSON: ${error.message}',
          source: PluginSource(
            path: path,
            line: error.offset == null
                ? null
                : '\n'
                          .allMatches(files[path]!.substring(0, error.offset))
                          .length +
                      1,
          ),
          nextAction: 'Fix the JSON.',
        ),
      );
      continue;
    }
    final widget = json is Map<String, Object?> ? json['widget'] : null;
    final events = json is Map<String, Object?> ? json['events'] ?? [] : null;
    final state = json is Map<String, Object?> ? json['state'] : null;
    if (widget is! String ||
        !widgets.any((entry) => entry.id == widget) ||
        events is! List<Object?> ||
        events.any((event) => event is! Map<String, Object?>) ||
        state != null && state is! Map<String, Object?>) {
      found.add(
        PluginDiagnostic(
          code: 'FIXTURE_INVALID',
          message: 'A fixture is {widget, events, state}',
          source: PluginSource(path: path, line: 1),
          expected:
              '{"widget": ${widgets.map((w) => '"${w.id}"').join(' | ')}, '
              '"events": [{"type": ...}], "state": {...}?}',
          actual: widget is String ? '"$widget"' : 'widget missing',
          nextAction: 'Name a declared widget and list events as objects.',
        ),
      );
      continue;
    }
    fixtures.add((
      name: path.substring('fixtures/'.length, path.length - '.json'.length),
      widget: widget,
      state: state as Map<String, Object?>?,
      events: events.cast<Map<String, Object?>>(),
    ));
  }
  for (final widget in widgets) {
    if (fixtures.any((fixture) => fixture.widget == widget.id)) continue;
    found.add(
      PluginDiagnostic(
        code: 'FIXTURE_MISSING',
        severity: PluginSeverity.warning,
        message: 'No fixture for widget ${widget.id}; previewing a bare mount',
        source: const PluginSource(path: 'fixtures'),
        nextAction: 'Add fixtures/<name>.json with "widget": "${widget.id}".',
      ),
    );
    fixtures.add((
      name: 'mount',
      widget: widget.id,
      state: null,
      events: const [],
    ));
  }

  final dev = PluginDevSource(package);
  final seen = <String>{};
  void add(PluginDiagnostic diagnostic) {
    final identity = jsonEncode(diagnostic.toJson());
    if (seen.add(identity)) found.add(diagnostic);
  }

  final renders = <PluginRender>[];
  for (final fixture in fixtures) {
    final widget = widgets.firstWhere((entry) => entry.id == fixture.widget);
    var state = fixture.state;
    PluginUiNode? view;
    var rejected = false;
    final effects = <Object?>[];
    final events = [
      {
        'type': 'mount',
        'widget': widget.id,
        if (manifest.uiVersion == 2) 'theme': theme,
      },
      ...fixture.events,
    ];
    for (final event in events) {
      final Object? value;
      try {
        value = await invoke(
          key: 'dev:${package.digest}',
          source: dev.text,
          action: 'card',
          input: {
            'state': state,
            'event': {'token': 'fixture', 'now': _fixtureNow, ...event},
            'widget': widget.id,
          },
        );
      } catch (error) {
        final at = dev.locateError('$error');
        final datasets = '$error'.contains('dataset APIs are unavailable');
        add(
          PluginDiagnostic(
            code: datasets ? 'PREVIEW_UNSUPPORTED' : 'LUAU_ERROR',
            message: datasets
                ? 'Datasets do not run in a preview'
                : dev.describeError('$error'),
            source: at ?? PluginSource(path: manifest.entry),
            operation: 'card ${widget.id} · ${event['type']} · ${fixture.name}',
            nextAction: switch ((datasets, at)) {
              (true, _) => 'Preview a card that reads no dataset.',
              (false, null) =>
                'The UI SDK raised this; the message says what it wanted.',
              _ => 'Fix the Luau error at the named line.',
            },
          ),
        );
        view = null;
        break;
      }
      if (value is! Map<String, Object?> ||
          value['state'] is! Map<String, Object?>) {
        add(
          PluginDiagnostic(
            code: 'LUAU_ERROR',
            message: 'The card did not return {state, view}',
            source: PluginSource(path: manifest.entry),
            operation: 'card ${widget.id} · ${event['type']} · ${fixture.name}',
            nextAction: 'Return ui.app {init, update, view, cards = {...}}.',
          ),
        );
        view = null;
        break;
      }
      state = value['state']! as Map<String, Object?>;
      effects.addAll(
        value['effects'] is List<Object?>
            ? value['effects']! as List<Object?>
            : const [],
      );
      final tree = value['view'];
      final problems = validateUiTree(
        tree,
        card: true,
        uiApi: manifest.uiVersion ?? 1,
        locate: dev.locate,
      );
      problems.forEach(add);
      try {
        view = parseCard(stripUiLines(tree), manifest);
      } on PluginException catch (error) {
        if (!problems.any((problem) => problem.blocking)) {
          add(
            PluginDiagnostic(
              code: 'UI_REJECTED',
              message: error.message,
              source: PluginSource(path: manifest.entry),
              operation: 'card ${widget.id} · ${fixture.name}',
              nextAction: 'Compare the card tree with the UI rules in `docs`.',
            ),
          );
        }
        view = null;
      }
      if (problems.any((problem) => problem.blocking)) view = null;
      if (view == null) rejected = true;
    }
    if (rejected || view == null) continue;
    for (final size in widget.sizes) {
      renders.add(
        PluginRender(
          fixture: fixture.name,
          widget: widget,
          size: size,
          view: view,
          effects: effects,
        ),
      );
    }
  }
  return done(manifest: manifest, package: package, renders: renders);
}
