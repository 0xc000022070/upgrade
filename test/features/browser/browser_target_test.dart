import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/features/browser/browser_prefs.dart';

void main() {
  const engine = SearchEngine.duckduckgo;
  Uri? target(String typed) => browserTarget(typed, engine);

  test('what reads as an address is loaded', () {
    expect(target('example.com'), Uri.parse('http://example.com'));
    expect(target('localhost:3000'), Uri.parse('http://localhost:3000'));
    expect(target('nyx:8080/x'), Uri.parse('http://nyx:8080/x'));
    expect(target('100.64.0.1'), Uri.parse('http://100.64.0.1'));
    expect(target('https://whoami'), Uri.parse('https://whoami'));
    expect(target('nyx:80'), Uri.parse('http://nyx:80'));
    expect(target('example.com.'), Uri.parse('http://example.com.'));
    expect(target('[::1]:3000'), Uri.parse('http://[::1]:3000'));
  });

  test('anything else is searched', () {
    expect(target('whoami'), engine.search('whoami'));
    expect(target('what is ssh -D'), engine.search('what is ssh -D'));
    expect(target('1.5'), engine.search('1.5'));
    expect(target('  '), isNull);
    expect(
      SearchEngine.google.search('a b').toString(),
      'https://www.google.com/search?q=a+b',
    );
  });
}
