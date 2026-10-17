import 'package:flutter/services.dart';

enum LauncherOpen { agents, inputBar, plugins }

LauncherOpen? parseLauncherOpen(Object? raw) =>
    LauncherOpen.values.where((open) => open.name == raw).firstOrNull;

String? launcherBarLabel(String? title, String? summary) {
  if (title == null || title.isEmpty) return null;
  final caps = title.toUpperCase();
  return summary == null || summary.isEmpty ? caps : '$caps · $summary';
}

abstract final class LauncherWidget {
  static const _channel = MethodChannel('dev.luisnquin.striked/launcher');

  static Future<void> setTally(String? line) => _quiet('tally', {'line': line});

  static Future<void> setBar(String? title, String? summary) =>
      _quiet('bar', {'label': launcherBarLabel(title, summary)});

  static Future<LauncherOpen?> take() async {
    try {
      return parseLauncherOpen(await _channel.invokeMethod<String>('take'));
    } on MissingPluginException {
      // ignored: without the bridge no launcher tap can be waiting
      return null;
    }
  }

  static void onOpened(void Function()? opened) =>
      _channel.setMethodCallHandler(
        opened == null
            ? null
            : (call) async {
                if (call.method == 'opened') opened();
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
