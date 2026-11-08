import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:widgetbook/widgetbook.dart';

import 'package:upgrade/design/components/meta.dart';
import 'package:upgrade/design/tokens.dart';
import 'package:upgrade/features/plugins/plugin_ui.dart';

import 'package:upgrade_widgetbook/frame.dart';

const _plugins = {
  'board': 'Board',
  'kanban': 'Kanban',
  'agent-schedules': 'Agent tasks',
};

const _frames = {
  'board': ['mounted', 'empty-board', 'note-selected', 'linked', 'boards'],
  'kanban': ['waiting', 'board', 'inbox-card'],
  'agent-schedules': ['no-hosts', 'unsupported', 'setup', 'tasks', 'composer'],
};

final pluginComponents = [
  for (final MapEntry(key: id, value: name) in _plugins.entries)
    WidgetbookComponent(
      name: name,
      useCases: [
        for (final frame in _frames[id]!)
          WidgetbookUseCase(
            name: _title(frame),
            builder: (context) => _PluginFrame(plugin: id, frame: frame),
          ),
      ],
    ),
];

String _title(String frame) =>
    '${frame[0].toUpperCase()}${frame.substring(1).replaceAll('-', ' ')}';

final class _Frame {
  _Frame(this.node, {required this.card});

  final PluginUiNode node;
  final bool card;
  final values = <String, Object?>{};
}

Future<_Frame> _load(String plugin, String frame) async {
  final index = jsonDecode(
    await rootBundle.loadString('frames/plugins/index.json'),
  ) as List<Object?>;
  final entry = index.cast<Map<String, Object?>>().firstWhere(
    (entry) => entry['plugin'] == plugin && entry['frame'] == frame,
  );
  final card = entry['card']! as bool;
  final node = PluginUiNode.parse(
    jsonDecode(await rootBundle.loadString(entry['file']! as String)),
    allowCanvas: entry['canvas']! as bool,
    card: card,
    allowAwake: entry['awake']! as bool,
    pages: {...(entry['pages']! as List<Object?>).cast<String>()},
  );
  final loaded = _Frame(node, card: card);
  synchronizePluginFields(loaded.values, null, node);
  return loaded;
}

class _PluginFrame extends StatefulWidget {
  const _PluginFrame({required this.plugin, required this.frame});

  final String plugin;
  final String frame;

  @override
  State<_PluginFrame> createState() => _PluginFrameState();
}

class _PluginFrameState extends State<_PluginFrame> {
  late Future<_Frame> _frame = _load(widget.plugin, widget.frame);

  @override
  void didUpdateWidget(_PluginFrame old) {
    super.didUpdateWidget(old);
    if (old.plugin != widget.plugin || old.frame != widget.frame) {
      _frame = _load(widget.plugin, widget.frame);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _frame,
      builder: (context, snapshot) {
        if (snapshot.error case final error?) {
          return Stage(children: [Meta('$error', maxLines: 8)]);
        }
        final frame = snapshot.data;
        if (frame == null) return const SizedBox.shrink();
        final ui = PluginUi(
          node: frame.node,
          values: frame.values,
          onEvent: (_) {},
          onBack: () {},
          onOpen: (_) {},
        );
        if (frame.card) {
          return Stage(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [ui],
              ),
            ],
          );
        }
        return Scaffold(
          backgroundColor: context.tokens.backgroundPrimary,
          appBar: frame.node.kind == 'page'
              ? null
              : AppBar(
                  toolbarHeight: 44,
                  leading: BackButton(onPressed: () {}),
                  title: Text(
                    _plugins[widget.plugin]!.toUpperCase(),
                    style: context.tokens.breadcrumb,
                  ),
                ),
          body: Column(children: [Expanded(child: ui)]),
        );
      },
    );
  }
}
