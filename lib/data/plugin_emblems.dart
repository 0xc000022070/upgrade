enum PluginEmblem {
  crate,
  banner,
  gear,
  eye,
  key,
  dish,
  flask,
  compass,
  hammer,
  bolt,
  cubes,
  tower;

  String get asset => 'assets/plugin_emblems/$name.svg';

  static PluginEmblem of(String id, String? declared) {
    for (final emblem in values) {
      if (emblem.name == declared) return emblem;
    }
    final seed = id.codeUnits.fold(
      0,
      (sum, unit) => (sum * 31 + unit) & 0xffff,
    );
    return values[seed % values.length];
  }
}
