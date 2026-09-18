import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dazzle/application/link_preview.dart';
import 'package:dazzle/platform/link_metadata.dart';

const _openGraph = '''
<!doctype html><html><head>
<meta charset="utf-8">
<meta property="og:site_name" content="Spotify">
<meta property="og:title" content="Nonsense">
<meta property="og:description" content="Sabrina Carpenter &middot; Song &middot; 2024">
<meta property="og:image" content="https://i.scdn.co/image/ab67?w=300&amp;h=300">
<title>Nonsense | Spotify</title>
</head><body>
<meta property="og:title" content="not this one">
</body></html>
''';

const _twitterCard = '''
<html><head>
<meta name=twitter:title content="A Post">
<meta name='twitter:description' content='What it says'>
<meta name="twitter:image" content="/media/card.png">
<meta name="twitter:site" content="@somewhere">
</head></html>
''';

const _plainDocument = '''
<html><head>
<title>  Just   a page
</title>
<meta name="description" content="Nothing fancy here">
</head></html>
''';

const _discovers = '''
<html><head>
<meta property="og:title" content="A Video">
<link rel="alternate" type="application/json+oembed"
      href="/oembed?url=https%3A%2F%2Fvid.example%2Fw%3Fv%3D1&amp;format=json">
</head></html>
''';

/// What x actually serves most of the time: a shell with no metadata in it.
const _shell =
    '<html><head><script src="/main.js"></script></head><body>'
    '<div id="react-root"></div></body></html>';

const _tweetEmbed =
    '{"author_name":"Fazt","provider_name":"X",'
    '"html":"<blockquote class=\\"twitter-tweet\\">'
    '<p lang=\\"es\\" dir=\\"ltr\\">Si tienes que hacer un review, hazlo bien'
    '</p>&mdash; Fazt (@FaztTech) <a href=\\"https://x.com/s\\">'
    'September 13, 2026</a></blockquote>"}';

void main() {
  group('what a page says about itself', () {
    test('open graph is read first, and the body is not read at all', () {
      final preview = previewFromHtml(
        _openGraph,
        url: 'https://open.spotify.com/track/1',
      );
      expect(preview.title, 'Nonsense');
      expect(preview.description, 'Sabrina Carpenter · Song · 2024');
      expect(preview.siteName, 'Spotify');
      expect(preview.imageUrl, 'https://i.scdn.co/image/ab67?w=300&h=300');
    });

    test('twitter names answer when open graph is absent', () {
      final preview = previewFromHtml(
        _twitterCard,
        url: 'https://elsewhere.test/post/9',
      );
      expect(preview.title, 'A Post');
      expect(preview.description, 'What it says');
      expect(preview.imageUrl, 'https://elsewhere.test/media/card.png');
      expect(preview.siteName, isNull);
    });

    test('a page with neither still has a title and a description', () {
      final preview = previewFromHtml(
        _plainDocument,
        url: 'https://plain.test/',
      );
      expect(preview.title, 'Just a page');
      expect(preview.description, 'Nothing fancy here');
      expect(preview.imageUrl, isNull);
    });

    test('a page with nothing is bare', () {
      final preview = previewFromHtml('<html></html>', url: 'https://bare/');
      expect(preview.isBare, isTrue);
    });
  });

  group('oembed', () {
    test('the endpoint is discovered from the page, made absolute', () {
      expect(
        oembedEndpoint(_discovers, url: 'https://vid.example/w?v=1'),
        'https://vid.example/oembed'
        '?url=https%3A%2F%2Fvid.example%2Fw%3Fv%3D1&format=json',
      );
    });

    test('a page that advertises nothing discovers nothing', () {
      expect(
        oembedEndpoint(_openGraph, url: 'https://open.spotify.com/'),
        isNull,
      );
    });

    test('x is known by host, www and mobile included', () {
      expect(
        knownOembedEndpoint('https://x.com/FaztTech/status/1'),
        'https://publish.x.com/oembed'
        '?url=https%3A%2F%2Fx.com%2FFaztTech%2Fstatus%2F1&format=json',
      );
      expect(
        knownOembedEndpoint('https://www.twitter.com/a/status/1'),
        isNotNull,
      );
      expect(knownOembedEndpoint('https://mobile.twitter.com/a'), isNotNull);
      expect(knownOembedEndpoint('https://open.spotify.com/track/1'), isNull);
    });

    test('a post says what it says in its first paragraph, and no more', () {
      final embed = jsonDecode(_tweetEmbed) as Map<String, Object?>;
      final preview = previewWithOembed(
        const LinkPreview(url: 'https://x.com/FaztTech/status/1'),
        embed,
      );
      expect(preview.description, 'Si tienes que hacer un review, hazlo bien');
      expect(preview.author, 'Fazt');
      expect(preview.siteName, 'X');
    });

    test('what the page published is never overwritten', () {
      final page = previewFromHtml(
        _openGraph,
        url: 'https://open.spotify.com/track/1',
      );
      final filled = previewWithOembed(page, {
        'title': 'Something Else',
        'thumbnail_url': 'https://other/image.png',
        'provider_name': 'Elsewhere',
      });
      expect(filled.title, 'Nonsense');
      expect(filled.siteName, 'Spotify');
      expect(filled.imageUrl, 'https://i.scdn.co/image/ab67?w=300&h=300');
    });
  });

  group('the request', () {
    test('a page that publishes everything is one request', () async {
      final client = _FakeHttpClient({
        'https://open.spotify.com/track/1': _Reply.html(_openGraph),
      });
      final preview = await _fetcher(client)
          .fetch('https://open.spotify.com/track/1');
      expect(preview?.title, 'Nonsense');
      expect(client.asked, ['https://open.spotify.com/track/1']);
    });

    test(
      'a missing description is asked for at the advertised endpoint',
      () async {
        final client = _FakeHttpClient({
          'https://vid.example/w?v=1': _Reply.html(_discovers),
          'https://vid.example/oembed'
                  '?url=https%3A%2F%2Fvid.example%2Fw%3Fv%3D1&format=json':
              _Reply.json(
                '{"html":"<p>The words</p>","author_name":"Someone"}',
              ),
        });
        final preview = await _fetcher(client)
            .fetch('https://vid.example/w?v=1');
        expect(preview?.title, 'A Video');
        expect(preview?.description, 'The words');
        expect(preview?.author, 'Someone');
        expect(client.asked.length, 2);
      },
    );

    test(
      'a shell with no metadata falls through to the known endpoint',
      () async {
        const url = 'https://x.com/FaztTech/status/1';
        final client = _FakeHttpClient({
          url: _Reply.html(_shell),
          knownOembedEndpoint(url)!: _Reply.json(_tweetEmbed),
        });
        final preview = await _fetcher(client).fetch(url);
        expect(
          preview?.description,
          'Si tienes que hacer un review, hazlo bien',
        );
        expect(preview?.author, 'Fazt');
      },
    );

    test('a page that will not answer is no card at all', () async {
      final client = _FakeHttpClient({
        'https://gone.test/a': const _Reply(404, 'text/html', 'nope'),
      });
      expect(await _fetcher(client).fetch('https://gone.test/a'), isNull);
    });

    test('a link straight at a file is not decoded as markup', () async {
      final client = _FakeHttpClient({
        'https://pics.test/a.png': const _Reply(200, 'image/png', 'PNG...'),
      });
      expect(await _fetcher(client).fetch('https://pics.test/a.png'), isNull);
    });

    test('anything that is not http is refused without a request', () async {
      final client = _FakeHttpClient({});
      expect(await _fetcher(client).fetch('file:///etc/passwd'), isNull);
      expect(await _fetcher(client).fetch('not a url at all'), isNull);
      expect(client.asked, isEmpty);
    });

    test(
      'the read stops at the end of the head, across a chunk boundary',
      () async {
        final client = _FakeHttpClient({
          'https://long.test/': _Reply.chunks('text/html', [
            '<html><head><meta property="og:title" content="Read">',
            '</he',
            'ad><body>',
            'x' * 4096,
            'x' * 4096,
          ]),
        });
        final preview = await _fetcher(client).fetch('https://long.test/');
        expect(preview?.title, 'Read');
        // The body chunks were never pulled off the socket.
        expect(client.readBytes, lessThan(200));
      },
    );

    test('a body past the cap is cut rather than read to the end', () async {
      final client = _FakeHttpClient({
        'https://huge.test/': _Reply.chunks('text/html', [
          '<html><head><meta property="og:title" content="Read">',
          'y' * LinkMetadataFetcher.pageLimit,
          'y' * LinkMetadataFetcher.pageLimit,
        ]),
      });
      final preview = await _fetcher(client).fetch('https://huge.test/');
      expect(preview?.title, 'Read');
      expect(client.readBytes, lessThan(LinkMetadataFetcher.pageLimit * 2));
    });
  });

  group('what has already been asked', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('dazzle-previews-test');
    });

    tearDown(() => directory.delete(recursive: true));

    test('a preview written is a preview read back, in a new run', () async {
      await LinkPreviewCache.inDirectory(directory).write(
        'https://a.test/',
        const LinkPreview(url: 'https://a.test/', title: 'Held'),
      );
      final reopened = await LinkPreviewCache.inDirectory(directory)
          .read('https://a.test/');
      expect(reopened?.preview?.title, 'Held');
      expect(
        File('${directory.path}/${LinkPreviewCache.fileName}').existsSync(),
        isTrue,
      );
    });

    test(
      'a page that answered with nothing is remembered as nothing',
      () async {
        final cache = LinkPreviewCache.inDirectory(directory);
        await cache.write('https://b.test/', null);
        final held = await cache.read('https://b.test/');
        expect(held, isNotNull);
        expect(held!.preview, isNull);
        expect(await cache.read('https://never-asked.test/'), isNull);
      },
    );

    test('an entry past its window is not read back', () async {
      final stale = DateTime.now().toUtc().subtract(const Duration(days: 30));
      File('${directory.path}/${LinkPreviewCache.fileName}').writeAsStringSync(
        jsonEncode({
          'https://old.test/': {
            'at': stale.toIso8601String(),
            'preview': {'url': 'https://old.test/', 'title': 'Was'},
          },
        }),
      );
      expect(
        await LinkPreviewCache.inDirectory(directory).read('https://old.test/'),
        isNull,
      );
    });

    test('a file that will not parse is an empty cache, not a crash', () async {
      File('${directory.path}/${LinkPreviewCache.fileName}')
          .writeAsStringSync('{{{');
      final cache = LinkPreviewCache.inDirectory(directory);
      expect(await cache.read('https://a.test/'), isNull);
      await cache.write(
        'https://a.test/',
        const LinkPreview(url: 'https://a.test/', title: 'Fresh'),
      );
      expect((await cache.read('https://a.test/'))?.preview?.title, 'Fresh');
    });

    test('the oldest goes once the file is full', () async {
      final cache = LinkPreviewCache.inDirectory(directory);
      for (var i = 0; i <= LinkPreviewCache.maxEntries; i++) {
        await cache.write(
          'https://n.test/$i',
          LinkPreview(url: 'https://n.test/$i', title: '$i'),
        );
      }
      expect(await cache.read('https://n.test/0'), isNull);
      expect(await cache.read('https://n.test/1'), isNotNull);
    });

    test(
      'one request however many cards ask, and none on the second open',
      () async {
        final client = _FakeHttpClient({
          'https://open.spotify.com/track/1': _Reply.html(_openGraph),
        });
        final previews = LinkPreviews(
          fetcher: _fetcher(client),
          cache: LinkPreviewCache.inDirectory(directory),
        );
        final together = await Future.wait([
          previews.of('https://open.spotify.com/track/1'),
          previews.of('https://open.spotify.com/track/1'),
        ]);
        expect(together.map((p) => p?.title), ['Nonsense', 'Nonsense']);
        await previews.of('https://open.spotify.com/track/1');
        expect(client.asked.length, 1);
      },
    );
  });
}

LinkMetadataFetcher _fetcher(_FakeHttpClient client) =>
    LinkMetadataFetcher(httpClientFactory: () => client);

class _Reply {
  const _Reply(this.statusCode, this.contentType, this.body)
    : chunked = const [];

  const _Reply.chunks(this.contentType, this.chunked)
    : statusCode = 200,
      body = '';

  const _Reply.html(String body) : this(200, 'text/html', body);
  const _Reply.json(String body) : this(200, 'application/json', body);

  final int statusCode;
  final String contentType;
  final String body;
  final List<String> chunked;

  List<List<int>> get parts => chunked.isEmpty
      ? [utf8.encode(body)]
      : [for (final chunk in chunked) utf8.encode(chunk)];
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this.replies);

  final Map<String, _Reply> replies;
  final asked = <String>[];

  /// The only way to tell a read that stopped early from one that read the lot and threw it
  /// away.
  var readBytes = 0;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    asked.add(url.toString());
    return _FakeHttpClientRequest(
      this,
      replies[url.toString()] ?? const _Reply(404, 'text/html', ''),
    );
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

class _FakeHttpClientRequest implements HttpClientRequest {
  _FakeHttpClientRequest(this._client, this._reply);

  final _FakeHttpClient _client;
  final _Reply _reply;

  @override
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

  @override
  final HttpHeaders headers = _FakeHttpHeaders();

  @override
  Future<HttpClientResponse> close() async =>
      _FakeHttpClientResponse(_client, _reply);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

class _FakeHttpHeaders implements HttpHeaders {
  ContentType? type;

  @override
  ContentType? get contentType => type;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

class _FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeHttpClientResponse(this._client, this._reply);

  final _FakeHttpClient _client;
  final _Reply _reply;

  @override
  int get statusCode => _reply.statusCode;

  @override
  HttpHeaders get headers =>
      _FakeHttpHeaders()..type = ContentType.parse(_reply.contentType);

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream.fromIterable(_reply.parts)
        .map((chunk) {
          _client.readBytes += chunk.length;
          return chunk;
        })
        .listen(
          onData,
          onError: onError,
          onDone: onDone,
          cancelOnError: cancelOnError,
        );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}
