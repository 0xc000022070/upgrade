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

String promptTargetLabel(SendChoice choice) => [
  choice.target.host.name,
  choice.target.path.label,
  choice.kind.name,
  ?choice.model,
].join(' · ');

final promptTargetProvider = StreamProvider<PromptTarget?>(
  (ref) => ref
      .watch(settingsRepositoryProvider)
      .watchRaw(SettingsRepository.promptTarget)
      .map(PromptTarget.decode),
);

final promptChoiceProvider = Provider<SendChoice?>((ref) {
  final saved = ref.watch(promptTargetProvider).valueOrNull;
  if (saved == null) return null;
  return saved.resolve(
    promptOffered(
      ref.watch(pathTargetsProvider).valueOrNull ?? const [],
      ref.watch(herdrHostsProvider).valueOrNull ?? const [],
    ),
  );
}, dependencies: [pathTargetsProvider]);

final promptSummaryProvider = Provider<String?>((ref) {
  final choice = ref.watch(promptChoiceProvider);
  return choice == null ? null : promptTargetLabel(choice);
}, dependencies: [promptChoiceProvider]);

Future<void> savePromptTarget(SettingsRepository settings, SendChoice choice) =>
    settings.setText(
      SettingsRepository.promptTarget,
      PromptTarget.of(choice).encode(),
    );
