import 'package:flutter/services.dart';

enum LauncherOpen {
  agents,
  inputBar,
  plugins,
  sheet,
  barSheet,
  compose,
  run,
  sent,
  settings,
}

LauncherOpen? parseLauncherOpen(Object? raw) =>
    LauncherOpen.values.where((open) => open.name == raw).firstOrNull;

typedef LauncherTap = ({LauncherOpen open, String? send});

LauncherTap? parseLauncherTap(Object? raw) {
  if (raw is! Map) return null;
  final open = parseLauncherOpen(raw['target']);
  if (open == null) return null;
  final send = raw['send'];
  return (open: open, send: send is String && send.isNotEmpty ? send : null);
}

String? launcherBarLabel(String? title, String? summary) {
  if (title == null || title.isEmpty) return null;
  final caps = title.toUpperCase();
  return summary == null || summary.isEmpty ? caps : '$caps · $summary';
}

typedef LauncherTally = ({int blocked, int working});

enum LauncherSendState { sending, sent, failed }

class LauncherSend {
  const LauncherSend({
    required this.id,
    required this.state,
    required this.title,
    required this.target,
    required this.at,
    this.reason,
    this.host,
    this.session,
    this.pane,
  });

  final String id;
  final LauncherSendState state;
  final String title;
  final String target;
  final DateTime at;
  final String? reason;
  final String? host;
  final String? session;
  final String? pane;

  Map<String, Object?> toJson() => {
    'id': id,
    'state': state.name.toUpperCase(),
    'title': title,
    'target': target,
    'at': at.millisecondsSinceEpoch,
    'reason': ?reason,
    'host': ?host,
    'session': ?session,
    'pane': ?pane,
  };
}

typedef OpenSend = ({String id, String host, String? session, String pane});

List<OpenSend> parseOpenSends(Object? raw) => [
  if (raw is List)
    for (final row in raw)
      if (row is Map &&
          row['id'] is String &&
          row['host'] is String &&
          row['pane'] is String)
        (
          id: row['id'] as String,
          host: row['host'] as String,
          session: row['session'] is String ? row['session'] as String : null,
          pane: row['pane'] as String,
        ),
];

typedef LauncherLive = ({String state, String? line, bool dim});

abstract final class LauncherWidget {
  static const _channel = MethodChannel('dev.luisnquin.striked/launcher');

  static Future<void> setTally(LauncherTally? tally) =>
      _quiet('tally', {'blocked': ?tally?.blocked, 'working': ?tally?.working});

  static Future<void> setBar(String? title, String? summary) =>
      _quiet('bar', {'label': launcherBarLabel(title, summary)});

  static Future<void> setTarget(String? label) =>
      _quiet('target', {'label': label});

  static Future<void> putSend(LauncherSend send) =>
      _quiet('send', send.toJson());

  static Future<void> settleSends(Iterable<String> running) =>
      _quiet('settle', {'running': running.toList()});

  static Future<List<OpenSend>> openSends() async {
    try {
      return parseOpenSends(await _channel.invokeMethod<Object?>('sends'));
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  static Future<void> setLive(Map<String, LauncherLive> live) =>
      _quiet('live', {
        'states': {
          for (final MapEntry(:key, :value) in live.entries)
            key: {'state': value.state, 'line': value.line, 'dim': value.dim},
        },
      });

  static Future<void> composeShown() => _quiet('composeShown', const {});

  static Future<void> closeCompose() => _quiet('closeCompose', const {});

  static Future<void> openApp(LauncherOpen target) =>
      _quiet('openApp', {'target': target.name});

  static Future<LauncherTap?> take() async {
    try {
      return parseLauncherTap(await _channel.invokeMethod<Object?>('take'));
    } on MissingPluginException {
      // ignored: without the bridge no launcher tap can be waiting
      return null;
    }
  }

  static void onOpened(LauncherEvents? events) => _channel.setMethodCallHandler(
    events == null
        ? null
        : (call) async {
            switch (call.method) {
              case 'opened':
                events.opened();
              case 'app':
                events.app();
              case 'composeGone':
                events.composeGone();
            }
          },
  );

  static Future<void> _quiet(
    String method,
    Map<String, Object?> arguments,
  ) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // ignored: a phone without the bridge has no launcher widget to write to
    } on PlatformException {
      // ignored: the shade and the app still say it
    }
  }
}

typedef LauncherEvents = ({
  void Function() opened,
  void Function() app,
  void Function() composeGone,
});
