import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

abstract interface class TransferStatus {
  void moving(String title, String text, int percent);

  void done(String title);
}

sealed class SharedItem {
  const SharedItem();
}

final class SharedText extends SharedItem {
  const SharedText(this.text);

  final String text;
}

final class SharedFile extends SharedItem {
  const SharedFile({
    required this.path,
    required this.name,
    required this.size,
    required this.mime,
  });

  final String path;
  final String name;
  final int size;
  final String mime;

  bool get image => mime.startsWith('image/');
}

typedef Shared = ({List<SharedItem> items, int unreadable});

int countUnreadable(Object? raw) => [
  for (final item in (raw as List<Object?>? ?? const []))
    if (item is Map && item['kind'] == 'unreadable') item,
].length;

List<SharedItem> parseSharedItems(Object? raw) => [
  for (final item in (raw as List<Object?>? ?? const []))
    if (item is Map && item['kind'] != 'unreadable')
      switch (item['kind']) {
        'text' => SharedText('${item['text'] ?? ''}'),
        _ => SharedFile(
          path: '${item['path']}',
          name: '${item['name']}',
          size: (item['size'] as num?)?.toInt() ?? 0,
          mime: '${item['mime'] ?? 'application/octet-stream'}',
        ),
      },
];

class PhoneFiles implements TransferStatus {
  PhoneFiles({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dev.luisnquin.striked/files') {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'shared':
          _nudges.add(null);
        case 'openTransfers':
          _opens.add(null);
        case 'stopTransfers':
          _stops.add(null);
      }
    });
  }

  final MethodChannel _channel;
  final _nudges = StreamController<void>.broadcast();
  final _opens = StreamController<void>.broadcast();
  final _stops = StreamController<void>.broadcast();

  Stream<void> get nudges => _nudges.stream;

  Stream<void> get opens => _opens.stream;

  Stream<void> get stops => _stops.stream;

  Future<List<SharedFile>> pick() async {
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('pick');
      return parseSharedItems(raw).whereType<SharedFile>().toList();
    } on MissingPluginException {
      return const [];
    }
  }

  Future<Shared> takeShared() async {
    try {
      final raw = await _channel.invokeMethod<Object?>('takeShared');
      return (items: parseSharedItems(raw), unreadable: countUnreadable(raw));
    } on MissingPluginException {
      return (items: const <SharedItem>[], unreadable: 0);
    }
  }

  Future<Directory> outgoing() => _fresh('outgoing');

  Future<Directory> scratch() => _fresh('scratch');

  Future<Directory> _fresh(String which) async {
    final root = await _channel.invokeMethod<String>(which);
    return Directory('$root/${const Uuid().v4()}').create(recursive: true);
  }

  Future<bool> share(List<String> paths) async =>
      await _channel.invokeMethod<bool>('share', {'paths': paths}) ?? false;

  Future<bool> save(String path, String name) async =>
      await _channel.invokeMethod<bool>('save', {'path': path, 'name': name}) ??
      false;

  @override
  void moving(String title, String text, int percent) => unawaited(
    _quiet('transfers', {'title': title, 'text': text, 'percent': percent}),
  );

  @override
  void done(String title) =>
      unawaited(_quiet('transfers', {'title': title, 'done': true}));

  Future<void> _quiet(String method, Map<String, Object> arguments) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // ignored: a phone without the bridge has no status bar to draw on
    } on PlatformException {
      // ignored: the in-app bar still says what is moving
    }
  }
}
