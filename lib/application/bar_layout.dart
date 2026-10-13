import 'dart:convert';

import 'package:flutter/foundation.dart';

enum BarItem {
  find('FIND'),
  ctrl('CTRL'),
  alt('ALT'),
  shift('SHIFT'),
  esc('ESC'),
  tab('TAB'),
  arrows('ARROWS'),
  end('END'),
  attach('ATTACH'),
  voice('VOICE'),
  keyboard('KEYBOARD');

  const BarItem(this.label);

  final String label;

  bool get hideable => this != keyboard;
}

@immutable
class BarLayout {
  const BarLayout({
    required this.keys,
    required this.pinned,
    required this.stick,
  });

  static const house = BarLayout(
    keys: [
      BarItem.find,
      BarItem.ctrl,
      BarItem.alt,
      BarItem.shift,
      BarItem.esc,
      BarItem.tab,
      BarItem.end,
    ],
    pinned: [BarItem.arrows, BarItem.attach, BarItem.voice, BarItem.keyboard],
    stick: true,
  );

  final List<BarItem> keys;
  final List<BarItem> pinned;

  final bool stick;

  List<BarItem> get hidden => [
    for (final item in BarItem.values)
      if (!keys.contains(item) && !pinned.contains(item)) item,
  ];

  bool get isHouse => this == house;

  BarLayout withStick(bool stick) =>
      BarLayout(keys: keys, pinned: pinned, stick: stick);

  /// Places [item] in a zone at [index], taking it out of wherever it was first; an index
  /// past the end appends. [index] counts the zone as it stands before the item leaves it.
  BarLayout place(BarItem item, {required bool pinned, required int index}) {
    final source = pinned ? this.pinned : keys;
    final from = source.indexOf(item);
    final at = from >= 0 && from < index ? index - 1 : index;
    final nextKeys = [...keys]..remove(item);
    final nextPinned = [...this.pinned]..remove(item);
    final target = pinned ? nextPinned : nextKeys;
    target.insert(at.clamp(0, target.length), item);
    return BarLayout(keys: nextKeys, pinned: nextPinned, stick: stick);
  }

  BarLayout hide(BarItem item) {
    if (!item.hideable) return this;
    return BarLayout(
      keys: [...keys]..remove(item),
      pinned: [...pinned]..remove(item),
      stick: stick,
    );
  }

  String encode() => jsonEncode({
    'keys': [for (final item in keys) item.name],
    'pinned': [for (final item in pinned) item.name],
    'arrows': stick ? 'stick' : 'cells',
  });

  static BarLayout decode(String? raw) {
    if (raw == null) return house;
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      return house;
    }
    if (json is! Map<String, Object?>) return house;
    final seen = <BarItem>{};
    List<BarItem> items(Object? names) => [
      if (names is List)
        for (final name in names)
          if (BarItem.values.where((item) => item.name == name).firstOrNull
              case final item? when seen.add(item))
            item,
    ];
    final keys = items(json['keys']);
    final pinned = items(json['pinned']);
    if (!seen.contains(BarItem.keyboard)) pinned.add(BarItem.keyboard);
    return BarLayout(
      keys: keys,
      pinned: pinned,
      stick: json['arrows'] != 'cells',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BarLayout &&
      other.stick == stick &&
      listEquals(other.keys, keys) &&
      listEquals(other.pinned, pinned);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(keys), Object.hashAll(pinned), stick);
}
