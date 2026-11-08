import 'package:upgrade_luau/data_api.dart';

import 'package:upgrade/data/plugins/manifest.dart';

typedef PluginReach = ({
  String line,
  Set<PluginPermission> grants,
  bool perCommand,
});

String _words(String id) =>
    id.replaceAll(RegExp(r'[._-]+'), ' ').trim().toUpperCase();

List<PluginReach> pluginReach(
  PluginManifest manifest, {
  Map<String, String> names = const {},
}) {
  final lines = <PluginReach>[];
  final covered = <PluginPermission>{};
  void add(String line, Iterable<String> ids, {bool repeat = false}) {
    final wanted = ids.toSet();
    final owned = {
      for (final permission in manifest.permissions)
        if (wanted.contains(permission.id) &&
            (repeat || !covered.contains(permission)))
          permission,
    };
    if (owned.isEmpty) return;
    covered.addAll(owned);
    lines.add((line: line, grants: owned, perCommand: repeat));
  }

  final byTarget = <String, List<PluginCapability>>{};
  for (final capability in manifest.capabilities.values) {
    byTarget.putIfAbsent(capability.target, () => []).add(capability);
  }
  for (final capabilities in byTarget.values) {
    final operations = {for (final c in capabilities) ...c.operations};
    final grants = [
      for (final c in capabilities)
        for (final op in c.operations) c.permission(op).id,
    ];
    final reads = operations.any(
      (op) => op == DataOperation.get || op == DataOperation.query,
    );
    final changes = operations.any(
      (op) => op == DataOperation.put || op == DataOperation.delete,
    );
    final first = capabilities.first;
    if (first.isSelection) {
      final proposes = operations.contains(DataOperation.propose);
      add(switch ((reads, proposes)) {
        (true, true) => 'READ THE SELECTED RECORD AND PROPOSE CHANGES TO IT',
        (false, true) => 'PROPOSE CHANGES TO THE SELECTED RECORD',
        _ => 'READ THE SELECTED RECORD',
      }, grants);
    } else if (first.provider == 'self') {
      final dataset = _words(first.dataset!);
      add(switch ((reads, changes)) {
        (true, true) => 'READ AND CHANGE ITS OWN $dataset',
        (false, true) => 'CHANGE ITS OWN $dataset',
        _ => 'READ ITS OWN $dataset',
      }, grants);
    } else {
      final provider = first.provider!;
      add(
        'READ ${_words(first.dataset!)} FROM '
        '${(names[provider] ?? provider).toUpperCase()}',
        grants,
      );
    }
  }

  final byService = <String, List<PluginHostCapability>>{};
  for (final capability in manifest.hostCapabilities.values) {
    byService.putIfAbsent(capability.service, () => []).add(capability);
  }
  for (final MapEntry(key: service, value: capabilities) in byService.entries) {
    if (service == 'run') {
      for (final capability in capabilities) {
        if (!capability.operations.contains('submit')) continue;
        for (final command in capability.commands.values) {
          add('RUN ON A HOST WHEN YOU TAP: ${command.shown}', [
            capability.permission('submit').id,
          ], repeat: true);
        }
      }
      final rest = [
        for (final c in capabilities)
          for (final op in c.operations)
            if (op != 'submit') (c, op),
      ];
      add(
        'FOLLOW ITS RUNS · ${rest.map((e) => _words(e.$2)).toSet().join(' · ')}',
        [for (final (c, op) in rest) c.permission(op).id],
      );
      continue;
    }
    final operations = [
      for (final c in capabilities)
        for (final op in c.operations) (c, op),
    ];
    add(
      'USE ${_words(service)} ON YOUR HOSTS · '
      '${operations.map((e) => _words(e.$2)).toSet().join(' · ')}',
      [for (final (c, op) in operations) c.permission(op).id],
    );
  }

  for (final name in manifest.services.keys) {
    add('USE ${_words(name)}', ['service.$name']);
  }

  const drawing = {
    'ui.widget': 'DRAW HOME CARDS',
    'ui.page': 'OPEN ITS OWN PAGES',
    'ui.canvas': 'DRAW ON A CANVAS',
    'ui.record_action': 'ADD ACTIONS TO A SELECTED RECORD',
    'ui.keep_awake': 'KEEP THE SCREEN ON WHILE ITS PAGE IS OPEN',
  };
  for (final permission in manifest.permissions) {
    if (drawing[permission.id] case final line?) add(line, [permission.id]);
  }
  for (final widget in manifest.widgets) {
    if (widget.refresh case final every?) {
      add(
        'REFRESH ${widget.title.toUpperCase()} EVERY ${every.inMinutes} MIN '
        'WHILE HOME IS OPEN',
        ['ui.widget.${widget.id}.refresh.${every.inMinutes}'],
      );
    }
  }
  for (final surface in manifest.surfaces) {
    add('ADD TO ${_words(surface)}', ['ui.$surface']);
  }

  for (final permission in manifest.permissions) {
    if (!covered.contains(permission)) {
      lines.add((
        line: permission.description.toUpperCase(),
        grants: {permission},
        perCommand: false,
      ));
    }
  }
  return lines;
}

bool reachIsNew(PluginReach reach, List<PluginReach> old) => !old.any(
  (was) =>
      was.line == reach.line &&
      reach.grants.every(
        (grant) => was.grants.any(
          (had) => had == grant || (reach.perCommand && had.id == grant.id),
        ),
      ),
);
