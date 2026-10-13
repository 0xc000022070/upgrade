import 'package:upgrade/platform/vnc/keysyms.dart';

const maxArmingRepeat = 3;

/// Every transition hands back a fresh set: the shell's store empties the set it is
/// given, which would empty the arming it came from as well.
class Arming {
  const Arming({this.sticky = const {}, this.repeat = 1, this.locked = false});

  final Set<StickyModifier> sticky;
  final int repeat;
  final bool locked;

  bool get isEmpty => sticky.isEmpty;

  bool armed(StickyModifier modifier) => sticky.contains(modifier);

  Arming toggle(StickyModifier modifier) {
    final next = Set.of(sticky);
    if (!next.remove(modifier)) next.add(modifier);
    if (next.isEmpty) return const Arming();
    return Arming(sticky: next, repeat: repeat, locked: locked);
  }

  Arming latch(StickyModifier modifier) =>
      Arming(sticky: {...sticky, modifier}, locked: true);

  Arming? flick(StickyModifier modifier, int step) {
    final on = armed(modifier);
    if (locked && on) {
      if (step > 0) return null;
      return _without(modifier);
    }
    if (step > 0) {
      final next = on ? repeat + 1 : 2;
      if (on && next > maxArmingRepeat) return null;
      return Arming(sticky: {...sticky, modifier}, repeat: next);
    }
    if (!on) return null;
    if (repeat > 2) return Arming(sticky: Set.of(sticky), repeat: repeat - 1);
    return _without(modifier);
  }

  Arming spent() {
    if (isEmpty || locked) return this;
    if (repeat > 1) return Arming(sticky: Set.of(sticky), repeat: repeat - 1);
    return const Arming();
  }

  Arming _without(StickyModifier modifier) {
    final next = Set.of(sticky)..remove(modifier);
    return next.isEmpty ? const Arming() : Arming(sticky: next);
  }
}
