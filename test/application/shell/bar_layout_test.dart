import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/shell/bar_layout.dart';

void main() {
  test('no row and a row that does not parse are both the house layout', () {
    expect(BarLayout.decode(null), BarLayout.house);
    expect(BarLayout.decode('{nope'), BarLayout.house);
    expect(BarLayout.decode('[1, 2]'), BarLayout.house);
    expect(BarLayout.house.isHouse, isTrue);
  });

  test('a layout comes back from its row as it went in', () {
    final layout = BarLayout.house
        .hide(BarItem.voice)
        .place(BarItem.esc, pinned: true, index: 0)
        .withStick(false);
    expect(BarLayout.decode(layout.encode()), layout);
    expect(layout.isHouse, isFalse);
  });

  test('a row drops unknown names and repeats and puts the keyboard back', () {
    final layout = BarLayout.decode(
      '{"keys":["esc","warp","esc"],"pinned":["esc","tab"],"arrows":"cells"}',
    );
    expect(layout.keys, [BarItem.esc]);
    expect(layout.pinned, [BarItem.tab, BarItem.keyboard]);
    expect(layout.stick, isFalse);
  });

  test('placing counts the side as it stands before the item leaves it', () {
    const layout = BarLayout(
      keys: [BarItem.esc, BarItem.tab, BarItem.end],
      pinned: [BarItem.keyboard],
      stick: true,
    );
    expect(layout.place(BarItem.esc, pinned: false, index: 3).keys, [
      BarItem.tab,
      BarItem.end,
      BarItem.esc,
    ]);
    expect(layout.place(BarItem.end, pinned: false, index: 0).keys, [
      BarItem.end,
      BarItem.esc,
      BarItem.tab,
    ]);
    final crossed = layout.place(BarItem.tab, pinned: true, index: 0);
    expect(crossed.keys, [BarItem.esc, BarItem.end]);
    expect(crossed.pinned, [BarItem.tab, BarItem.keyboard]);
  });

  test('the keyboard toggle cannot be hidden', () {
    expect(BarLayout.house.hide(BarItem.keyboard), BarLayout.house);
    expect(BarLayout.house.hidden, isEmpty);
    expect(BarLayout.house.hide(BarItem.voice).hidden, [BarItem.voice]);
  });
}
