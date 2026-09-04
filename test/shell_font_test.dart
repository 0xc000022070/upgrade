import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/application/shell_font.dart';

void main() {
  test('a pinch lands on a whole point', () {
    expect(pinchedFontSize(13, 1.6), 21);
    expect(pinchedFontSize(13, 0.8), 10);
    expect(pinchedFontSize(13, 1.0), 13);
  });

  test('a pinch stops at the ends', () {
    expect(pinchedFontSize(13, 3.0), shellFontSizeMax);
    expect(pinchedFontSize(13, 0.4), shellFontSizeMin);
    expect(pinchedFontSize(shellFontSizeMax, 1.1), shellFontSizeMax);
    expect(pinchedFontSize(shellFontSizeMin, 0.9), shellFontSizeMin);
  });

  test('the default is between the ends', () {
    expect(shellFontSizeDefault, greaterThan(shellFontSizeMin));
    expect(shellFontSizeDefault, lessThan(shellFontSizeMax));
  });
}
