import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

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

List<SharedItem> parseSharedItems(Object? raw) => [
  for (final item in (raw as List<Object?>? ?? const []))
    if (item is Map)
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

class PhoneFiles {
  PhoneFiles({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dev.luisnquin.upgrade/files') {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'shared') _nudges.add(null);
    });
  }

  final MethodChannel _channel;
  final _nudges = StreamController<void>.broadcast();

  Stream<void> get nudges => _nudges.stream;

  Future<List<SharedFile>> pick() async {
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('pick');
      return parseSharedItems(raw).whereType<SharedFile>().toList();
    } on MissingPluginException {
      return const [];
    }
  }

  Future<List<SharedItem>> takeShared() async {
    try {
      return parseSharedItems(
        await _channel.invokeMethod<Object?>('takeShared'),
      );
    } on MissingPluginException {
      return const [];
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
}
