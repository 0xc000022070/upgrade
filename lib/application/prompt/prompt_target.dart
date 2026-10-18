import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:striked/application/agents/agent_kind.dart';
import 'package:striked/application/agents/agents.dart';
import 'package:striked/application/agents/send.dart';
import 'package:striked/application/providers.dart';
import 'package:striked/data/repositories/host_repository.dart';
import 'package:striked/data/repositories/path_repository.dart';
import 'package:striked/data/repositories/settings_repository.dart';

class PromptTarget {
  const PromptTarget({required this.pathId, required this.agent, this.model});

  PromptTarget.of(SendChoice choice)
    : pathId = choice.target.path.id,
      agent = choice.kind.name,
      model = choice.model;

  final String pathId;
  final String agent;
  final String? model;

  String encode() => jsonEncode({
    'path': pathId,
    'agent': agent,
    if (model != null) 'model': model,
  });

  static PromptTarget? decode(String? raw) {
    if (raw == null) return null;
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      // ignored: a corrupt row only costs the chip its target; the steps pick anew.
      return null;
    }
    if (json is! Map<String, Object?>) return null;
    final path = json['path'];
    final agent = json['agent'];
    final model = json['model'];
    if (path is! String || agent is! String) return null;
    return PromptTarget(
      pathId: path,
      agent: agent,
      model: model is String ? model : null,
    );
  }

  SendChoice? resolve(List<PathTarget> offered) {
    final kind = AgentKind.lookup(agent);
    final target = offered.where((t) => t.path.id == pathId).firstOrNull;
    if (kind == null || target == null) return null;
    return SendChoice(target: target, kind: kind, model: model);
  }
}

List<PathTarget> promptOffered(
  List<PathTarget> targets,
  List<Host> multiplexed,
) {
  final ids = {for (final host in multiplexed) host.id};
  return [
    for (final target in targets)
      if (ids.contains(target.host.id)) target,
  ];
}

String promptTargetLabel(
  SendChoice choice, [
  List<PathTarget> offered = const [],
]) => [
  choice.target.host.name,
  promptDirectoryLabel(choice.target, offered),
  choice.kind.name,
  ?choice.model,
].join(' · ');

String promptDirectoryLabel(PathTarget target, List<PathTarget> offered) {
  final path = target.path;
  if (path.label != defaultPathLabel(path.directory)) return path.label;
  final shared = offered.any(
    (other) => other.path.id != path.id && other.path.label == path.label,
  );
  if (!shared) return path.label;
  final trimmed = path.directory.replaceFirst(RegExp(r'/+$'), '');
  final cut = trimmed.lastIndexOf('/');
  if (cut <= 0) return path.label;
  final parent = defaultPathLabel(trimmed.substring(0, cut));
  return parent.isEmpty ? path.label : '$parent/${path.label}';
}

final promptTargetProvider = StreamProvider<PromptTarget?>(
  (ref) => ref
      .watch(settingsRepositoryProvider)
      .watchRaw(SettingsRepository.promptTarget)
      .map(PromptTarget.decode),
);

final promptOfferedProvider = Provider<List<PathTarget>>(
  (ref) => promptOffered(
    ref.watch(pathTargetsProvider).valueOrNull ?? const [],
    ref.watch(herdrHostsProvider).valueOrNull ?? const [],
  ),
  dependencies: [pathTargetsProvider],
);

/// The saved target, else the newest send's whose host, directory and agent are still offered.
final promptChoiceProvider = Provider<SendChoice?>((ref) {
  final offered = ref.watch(promptOfferedProvider);
  final saved = ref.watch(promptTargetProvider).valueOrNull?.resolve(offered);
  if (saved != null) return saved;
  for (final send in ref.watch(sendsProvider).valueOrNull ?? const []) {
    final choice = PromptTarget(
      pathId: send.pathId,
      agent: send.agent,
      model: send.model,
    ).resolve(offered);
    if (choice != null) return choice;
  }
  return null;
}, dependencies: [promptOfferedProvider, sendsProvider]);

final promptSummaryProvider = Provider<String?>((ref) {
  final choice = ref.watch(promptChoiceProvider);
  return choice == null
      ? null
      : promptTargetLabel(choice, ref.watch(promptOfferedProvider));
}, dependencies: [promptChoiceProvider, promptOfferedProvider]);

typedef LauncherTarget = ({String directory, String detail});

final launcherTargetProvider = Provider<LauncherTarget?>((ref) {
  final choice = ref.watch(promptChoiceProvider);
  if (choice == null) return null;
  return (
    directory: promptDirectoryLabel(
      choice.target,
      ref.watch(promptOfferedProvider),
    ),
    detail: [
      choice.kind.name,
      ?choice.model,
      choice.target.host.name,
    ].join(' · '),
  );
}, dependencies: [promptChoiceProvider, promptOfferedProvider]);

Future<void> savePromptTarget(SettingsRepository settings, SendChoice choice) =>
    settings.setText(
      SettingsRepository.promptTarget,
      PromptTarget.of(choice).encode(),
    );
