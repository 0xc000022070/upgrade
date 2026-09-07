import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/application/urls.dart';

/// Two rules and one grammar. A title is prose and has to be read as prose; a
/// terminal selection is whatever the user dragged a grip across, and the
/// scheme in front of it is the only thing that says it is a link.
void main() {
  test('a scheme is the whole of what a selected link needs', () {
    expect(explicitUrl('http://100.118.60.77:8080/'), 'http://100.118.60.77:8080/');
    expect(explicitUrl('http://localhost:3000'), 'http://localhost:3000');
    expect(explicitUrl('https://min.io/a?b=1#c'), 'https://min.io/a?b=1#c');
    expect(explicitUrl('  https://min.io  '), 'https://min.io');
  });

  test('nothing is promoted into a link it did not say it was', () {
    expect(explicitUrl('min.io/docs'), isNull);
    expect(explicitUrl('/home/luis/x.dart:42'), isNull);
    expect(explicitUrl('git@github.com:o/r.git'), isNull);
    expect(explicitUrl('mailto:a@b.com'), isNull);
    expect(explicitUrl('file:///etc/hosts'), isNull);
    expect(explicitUrl('http://x.dev and more'), isNull);
    expect(explicitUrl(''), isNull);
  });

  test('a host with no dot is a word in prose and a host in a terminal', () {
    expect(normalizeUrl('http://localhost:3000'), isNull);
    expect(explicitUrl('http://localhost:3000'), 'http://localhost:3000');
  });
}
