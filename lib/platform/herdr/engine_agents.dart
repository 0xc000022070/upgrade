import 'dart:convert';

import 'package:upgrade/application/agents/agent_state.dart';
import 'package:upgrade/platform/herdr/herdr_client.dart';

const agentsService = 'agents/1';

class EngineRefused implements Exception {
  const EngineRefused(this.kind, this.message);

  final String kind;
  final String message;

  bool get notFound => kind == 'not_found';

  @override
  String toString() => '$kind: $message';
}

typedef EngineWatch = ({int generation, List<AgentSnapshot> agents});

class TranscriptItem {
  const TranscriptItem({
    required this.index,
    required this.kind,
    required this.text,
    this.tool,
    this.toolId,
    this.error = false,
  });

  final int index;

  final String kind;
  final String text;
  final String? tool;
  final String? toolId;
  final bool error;
}

typedef TranscriptPage = ({List<TranscriptItem> items, int? last});

class HookStatus {
  const HookStatus({
    required this.agent,
    required this.configPath,
    required this.installed,
    required this.writable,
    required this.entries,
  });

  final String agent;
  final String configPath;
  final bool installed;
  final bool writable;

  final String entries;
}

class EngineAgents {
  const EngineAgents(this.session, {required this.owner});

  final HerdrSession session;
  final String owner;

  static const _watchSlack = Duration(seconds: 15);

  Future<Map<String, Object?>> _call(
    String op,
    Map<String, Object?> args, {
    Duration within = const Duration(seconds: 20),
  }) async {
    final reply = await session.engine({
      'service': agentsService,
      'op': op,
      'owner': owner,
      'args': args,
    }, within: within);
    if (reply is! Map<String, Object?>) {
      throw const HerdrProtocolMismatch(null, 'engine reply is not an object');
    }
    if (reply['ok'] != true) {
      final error = reply['error'];
      final failure = error is Map<String, Object?>
          ? error
          : const <String, Object?>{};
      final kind = failure['kind'] is String
          ? failure['kind']! as String
          : 'failed';
      final message = failure['message'] is String
          ? failure['message']! as String
          : '';
      if (kind == 'unsupported' && op == 'watch') throw EngineMissing(message);
      throw EngineRefused(kind, message);
    }
    final result = reply['result'];
    if (result is! Map<String, Object?>) {
      throw const HerdrProtocolMismatch(null, 'engine result is not an object');
    }
    return result;
  }

  Future<EngineWatch> watch({
    int? generation,
    Duration wait = Duration.zero,
  }) async {
    final result = await _call('watch', {
      'generation': ?generation,
      'wait_ms': wait.inMilliseconds,
    }, within: wait + _watchSlack);
    return parseWatch(result);
  }

  Future<void> answer(String id, {required bool allow}) =>
      _call('answer', {'id': id, 'decision': allow ? 'allow' : 'deny'});

  Future<TranscriptPage> transcript(String key, {int? after}) async =>
      parseTranscript(
        await _call('transcript', {'session': key, 'after': ?after}),
      );

  Future<List<HookStatus>> hooks() async =>
      parseHooks(await _call('hooks', {}));

  Future<void> install(String agent) => _call('install', {'agent': agent});

  static EngineWatch parseWatch(Map<String, Object?> result) {
    final generation = result['generation'];
    final sessions = result['sessions'];
    if (generation is! int || sessions is! List<Object?>) {
      throw const HerdrProtocolMismatch(null, 'engine watch has no sessions');
    }
    return (
      generation: generation,
      agents: [
        for (final session in sessions)
          if (session is Map<String, Object?>) ?snapshotOf(session),
      ],
    );
  }

  static AgentSnapshot? snapshotOf(Map<String, Object?> json) {
    String? text(String name) {
      final value = json[name];
      return value is String && value.trim().isNotEmpty ? value : null;
    }

    final key = text('key');
    final agent = text('agent');
    final state = text('state');
    final updated = json['updated'];
    if (key == null || agent == null || state == null || updated is! int) {
      return null;
    }
    if (state == 'ended') return null;
    final message = text('message');
    return AgentSnapshot(
      session: '',
      paneId: key,
      agent: agent,
      state: AgentState.of(state),
      terminalTitleStripped: text('title') ?? text('prompt') ?? message ?? '',
      workspaceId: '',
      cwd: text('cwd') ?? '',
      stateChangeSeq: updated,
      source: AgentSource.engine,
      approval: AgentApproval.fromJson(json['approval']),
      question: text('question'),
      message: message,
      herdrPane: text('herdr_pane'),
    );
  }

  static TranscriptPage parseTranscript(Map<String, Object?> result) {
    final items = result['items'];
    final last = result['last'];
    return (
      items: [
        if (items is List<Object?>)
          for (final item in items)
            if (item case {
              'index': final int index,
              'kind': final String kind,
              'text': final String text,
            })
              TranscriptItem(
                index: index,
                kind: kind,
                text: text,
                tool: item['tool'] is String ? item['tool']! as String : null,
                toolId: item['tool_id'] is String
                    ? item['tool_id']! as String
                    : null,
                error: item['error'] == true,
              ),
      ],
      last: last is int ? last : null,
    );
  }

  static List<HookStatus> parseHooks(Map<String, Object?> result) {
    final agents = result['agents'];
    if (agents is! List<Object?>) return const [];
    return [
      for (final row in agents)
        if (row case {
          'agent': final String agent,
          'config_path': final String path,
          'installed': final bool installed,
          'writable': final bool writable,
        })
          HookStatus(
            agent: agent,
            configPath: path,
            installed: installed,
            writable: writable,
            entries: switch (row['entries']) {
              final String raw => raw,
              final Object? json => prettyJson(json),
            },
          ),
    ];
  }
}

String prettyJson(Object? json) =>
    const JsonEncoder.withIndent('  ').convert(json);
