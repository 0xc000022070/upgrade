import 'package:flutter_test/flutter_test.dart';
import 'package:spectacle/application/urls.dart';

/// Two rules and one grammar. A title is prose and has to be read as prose; a
/// terminal selection is whatever the user dragged a grip across, and the
/// scheme in front of it is the only thing that says it is a link.
void main() {
  test('a scheme is the whole of what a selected link needs', () {
    expect(
      explicitUrl('http://100.118.60.77:8080/'),
      'http://100.118.60.77:8080/',
    );
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

  test('a campaign stamped on a shared link does not survive the paste', () {
    expect(
      normalizeUrl(
        'https://store.example.com/p/42'
        '?utm_source=newsletter&utm_medium=email&utm_campaign=spring'
        '&gclid=EAIaIQobChMI&fbclid=IwAR0abc&mc_eid=9f1',
      ),
      'https://store.example.com/p/42',
    );
  });

  test('what the page needs is left alone', () {
    expect(
      normalizeUrl(
        'https://store.example.com/s?q=pgbouncer&utm_source=x&page=2',
      ),
      'https://store.example.com/s?q=pgbouncer&page=2',
    );
    expect(
      normalizeUrl('https://min.io/a?b=1&utm_term=c#anchor'),
      'https://min.io/a?b=1#anchor',
    );
    expect(
      normalizeUrl('https://shop.example.com/x?tag=luis-20&ref=home'),
      'https://shop.example.com/x?tag=luis-20&ref=home',
    );
  });

  test('the query goes with the last field that was in it', () {
    expect(
      normalizeUrl('https://x.dev/a?utm_source=x#frag'),
      'https://x.dev/a#frag',
    );
    expect(normalizeUrl('https://x.dev/a?igshid=1'), 'https://x.dev/a');
  });

  test('a field is cut by its name, however it is written', () {
    expect(
      normalizeUrl('https://x.dev/a?FBCLID=1&ok=2'),
      'https://x.dev/a?ok=2',
    );
    expect(
      normalizeUrl('https://x.dev/a?utm_source&ok=2'),
      'https://x.dev/a?ok=2',
    );
    expect(
      normalizeUrl('https://x.dev/a?ok=utm_source'),
      'https://x.dev/a?ok=utm_source',
    );
  });

  test('a fragment routes on its own and is not read as a query', () {
    expect(
      explicitUrl('https://x.dev/#/report?utm_source=x'),
      'https://x.dev/#/report?utm_source=x',
    );
  });

  test('a link selected in a terminal is cleaned the same way', () {
    expect(
      explicitUrl('http://localhost:3000/dash?utm_campaign=x&tab=logs'),
      'http://localhost:3000/dash?tab=logs',
    );
  });
}
