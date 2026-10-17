import 'dart:convert';

import 'package:striked/platform/herdr/engine_agents.dart';
import 'package:striked/platform/herdr/herdr_client.dart';

const _verbs = <String, Map<String, String>>{
  'claude': {
    'Read': 'READ',
    'NotebookRead': 'READ',
    'Edit': 'EDIT',
    'MultiEdit': 'EDIT',
    'NotebookEdit': 'EDIT',
    'Write': 'WRITE',
    'Bash': 'RUN',
    'Grep': 'SEARCH',
    'Glob': 'SEARCH',
    'WebSearch': 'SEARCH',
    'WebFetch': 'FETCH',
    'Task': 'TASK',
    'Agent': 'TASK',
  },
  'codex': {
    'shell': 'RUN',
    'shell_command': 'RUN',
    'exec_command': 'RUN',
    'local_shell': 'RUN',
    'container.exec': 'RUN',
    'apply_patch': 'EDIT',
    'read_file': 'READ',
    'view_image': 'READ',
    'list_dir': 'READ',
    'grep_files': 'SEARCH',
    'web_search': 'SEARCH',
    'web_fetch': 'FETCH',
  },
};

String stepVerb(String agent, String tool) =>
    _verbs[agent]?[tool] ?? tool.toUpperCase();

String stepArgument(String tool, String text) {
  final trimmed = text.trim();
  if (tool == 'apply_patch') {
    final file = RegExp(
      r'^\*\*\* (?:Update|Add|Delete) File: (.+)$',
      multiLine: true,
    ).firstMatch(trimmed);
    if (file != null) return file.group(1)!.trim();
  }
  if (trimmed.startsWith('{')) {
    final command = _command(trimmed);
    if (command != null) return _firstLine(command);
  }
  return _firstLine(trimmed);
}

String? _command(String raw) {
  final Object? json;
  try {
    json = jsonDecode(raw);
  } on FormatException {
    // ignored: non-JSON input is shown as raw text instead
    return null;
  }
  if (json is! Map<String, Object?>) return null;
  final command = json['command'] ?? json['cmd'];
  if (command is String) return command;
  if (command is! List<Object?>) return null;
  final words = [for (final word in command) '$word'];
  if (words.length == 3 && words[1].startsWith('-') && words[1].contains('c')) {
    return words[2];
  }
  return words.join(' ');
}

String _firstLine(String text) {
  for (final line in text.split('\n')) {
    if (line.trim().isNotEmpty) return line.trim();
  }
  return '';
}

String _collapse(String text) => text.trim().replaceAll(RegExp(r'\s+'), ' ');

const promptPrefix = 200;

bool promptMatches(String first, String sent) {
  final wanted = _collapse(sent);
  if (wanted.isEmpty) return false;
  final prefix = wanted.length > promptPrefix
      ? wanted.substring(0, promptPrefix)
      : wanted;
  return _collapse(first).startsWith(prefix);
}

String? firstPrompt(List<TranscriptItem> items) {
  for (final item in items) {
    if (item.kind == 'user') return item.text;
  }
  return null;
}

enum StepGlyph {
  done('+'),
  running('*'),
  waiting('!');

  const StepGlyph(this.mark);

  final String mark;
}

typedef Step = ({String argument, StepGlyph glyph});

sealed class RunLine {
  const RunLine();
}

final class PromptLine extends RunLine {
  const PromptLine(this.text);

  final String text;
}

final class StepsLine extends RunLine {
  const StepsLine(this.verb, this.steps);

  final String verb;
  final List<Step> steps;

  StepGlyph get glyph {
    if (steps.any((step) => step.glyph == StepGlyph.waiting)) {
      return StepGlyph.waiting;
    }
    if (steps.any((step) => step.glyph == StepGlyph.running)) {
      return StepGlyph.running;
    }
    return StepGlyph.done;
  }
}

final class SaidLine extends RunLine {
  const SaidLine(this.text);

  final String text;

  String get first => _firstLine(text);
}

final class LastSaidLine extends RunLine {
  const LastSaidLine(this.text);

  final String text;
}

List<RunLine> runLines(
  List<TranscriptItem> items, {
  required String agent,
  AgentApproval? approval,
  required bool ended,
}) {
  final results = {
    for (final item in items)
      if (item.kind == 'result') ?item.toolId,
  };
  final open = [
    for (final item in items)
      if (item.kind == 'tool' && !results.contains(item.toolId)) item,
  ];
  final waiting = approval == null
      ? null
      : open.where((item) => item.tool == approval.tool).lastOrNull ??
            open.lastOrNull;

  final lines = <RunLine>[];
  var prompted = false;
  for (final item in items) {
    switch (item.kind) {
      case 'user':
        if (prompted) lines.add(PromptLine(item.text));
        prompted = true;
      case 'assistant':
        if (item.text.trim().isNotEmpty) lines.add(SaidLine(item.text));
      case 'tool':
        final tool = item.tool ?? 'tool';
        final verb = stepVerb(agent, tool);
        final Step step = (
          argument: stepArgument(tool, item.text),
          glyph: results.contains(item.toolId)
              ? StepGlyph.done
              : identical(item, waiting)
              ? StepGlyph.waiting
              : StepGlyph.running,
        );
        final last = lines.lastOrNull;
        if (last is StepsLine && last.verb == verb) {
          lines[lines.length - 1] = StepsLine(verb, [...last.steps, step]);
        } else {
          lines.add(StepsLine(verb, [step]));
        }
    }
  }
  if (lines.lastOrNull case final SaidLine said when ended) {
    lines[lines.length - 1] = LastSaidLine(said.text);
  }
  return lines;
}
