enum HostSystem {
  nixos('nixos'),

  darwin('darwin'),

  ubuntu('ubuntu'),

  arch('arch'),

  alpine('alpine'),

  linux('linux'),

  other('other');

  const HostSystem(this.wire);

  final String wire;

  /// Null for a word this build does not know, so a row a newer build wrote reads as not
  /// yet probed instead of throwing.
  static HostSystem? fromWire(String? value) {
    for (final system in values) {
      if (system.wire == value) return system;
    }
    return null;
  }
}
