import 'package:flutter_test/flutter_test.dart';
import 'package:striked/platform/vnc/arming.dart';
import 'package:striked/platform/vnc/keysyms.dart';

const ctrl = StickyModifier.ctrl;
const alt = StickyModifier.alt;

void main() {
  test('a tap arms one key and the key spends it', () {
    final armed = const Arming().toggle(ctrl);
    expect(armed.sticky, {ctrl});
    expect(armed.repeat, 1);
    expect(armed.spent().isEmpty, isTrue);
  });

  test('a count walks down one key at a time', () {
    final two = const Arming().flick(ctrl, 1)!;
    expect(two.repeat, 2);
    final three = two.flick(ctrl, 1)!;
    expect(three.repeat, maxArmingRepeat);
    expect(three.flick(ctrl, 1), isNull);
    expect(three.spent().repeat, 2);
    expect(three.spent().spent().spent().isEmpty, isTrue);
  });

  test('a drag up counts back, then lets it go', () {
    final three = const Arming(sticky: {ctrl}, repeat: 3);
    expect(three.flick(ctrl, -1)!.repeat, 2);
    expect(three.flick(ctrl, -1)!.flick(ctrl, -1)!.isEmpty, isTrue);
    expect(const Arming().flick(ctrl, -1), isNull);
  });

  test('a latch is spent by nothing and a tap lets it go', () {
    final held = const Arming().latch(ctrl);
    expect(held.spent().locked, isTrue);
    expect(held.spent().sticky, {ctrl});
    expect(held.flick(ctrl, 1), isNull);
    expect(held.toggle(ctrl).isEmpty, isTrue);
  });

  test('a modifier tapped on under a latch is latched with it', () {
    final both = const Arming().latch(ctrl).toggle(alt);
    expect(both.sticky, {ctrl, alt});
    expect(both.locked, isTrue);
    expect(both.toggle(ctrl).locked, isTrue);
  });

  test('every transition hands back a set of its own', () {
    final armed = const Arming(sticky: {ctrl}, repeat: 3);
    final next = armed.spent();
    next.sticky.clear();
    expect(armed.sticky, {ctrl});
  });
}
