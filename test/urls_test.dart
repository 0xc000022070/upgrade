import 'package:flutter_test/flutter_test.dart';
import 'package:upgrade/application/urls.dart';

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

  test('the share sheet id goes and what plays the video stays', () {
    expect(
      normalizeUrl('https://youtu.be/dQw4w9WgXcQ?si=Yl1xK9k2'),
      'https://youtu.be/dQw4w9WgXcQ',
    );
    expect(
      normalizeUrl('https://www.youtube.com/watch?v=dQw4w9WgXcQ&si=Yl1&t=42'),
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42',
    );
    expect(
      normalizeUrl('https://open.spotify.com/track/4cOdK2?si=8f2b1c'),
      'https://open.spotify.com/track/4cOdK2',
    );
  });

  test('a shared video written into a line is cleaned there too', () {
    expect(
      withoutTrackingInText('ver https://youtu.be/dQw4w9WgXcQ?si=Yl1 manana'),
      'ver https://youtu.be/dQw4w9WgXcQ manana',
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

  test('a link written into a line is cleaned where it stands', () {
    expect(
      withoutTrackingInText(
        'leer https://blog.dev/post?utm_source=news&id=42 manana',
      ),
      'leer https://blog.dev/post?id=42 manana',
    );
  });

  test('a line the tracking is the whole of comes back as the bare link', () {
    expect(
      withoutTrackingInText('https://blog.dev/post?utm_source=news&gclid=x'),
      'https://blog.dev/post',
    );
  });

  test('two links in one line are both cleaned', () {
    expect(
      withoutTrackingInText(
        'https://a.dev/?fbclid=1 vs https://b.dev/?utm_medium=x&keep=1',
      ),
      'https://a.dev/ vs https://b.dev/?keep=1',
    );
  });

  test('prose with no link in it is handed back untouched', () {
    expect(
      withoutTrackingInText('revisar pgbouncer utm_source=x'),
      'revisar pgbouncer utm_source=x',
    );
  });

  test('a word that only reads like a host is left alone', () {
    expect(withoutTrackingInText('etc. blog.dev'), 'etc. blog.dev');
  });
}
