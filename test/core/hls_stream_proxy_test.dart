import 'dart:io';

import 'package:dart_cast/src/core/hls_parser.dart';
import 'package:dart_cast/src/core/hls_stream_proxy.dart';
import 'package:dart_cast/src/core/http10_file_server.dart';
import 'package:dart_cast/src/core/media_proxy.dart';
import 'package:test/test.dart';

import 'ts_fixtures.dart';

/// Sample master playlist that mirrors the real-world krussdomi.com layout
/// (alternate audio renditions in their own playlists, video-only variants).
/// Used by the alt-audio tests below.
const _altAudioMaster =
    '#EXTM3U\n'
    '#EXT-X-INDEPENDENT-SEGMENTS\n'
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="stereo",NAME="Japanese",'
    'DEFAULT=YES,LANGUAGE="jpn",CHANNELS="2",URI="audio-jpn.m3u8"\n'
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="stereo",NAME="English",'
    'LANGUAGE="eng",CHANNELS="2",URI="audio-eng.m3u8"\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=8000000,CODECS="avc1.4D4828,mp4a.40.2",'
    'RESOLUTION=1920x1080,AUDIO="stereo"\n'
    'video-1080p.m3u8\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=4000000,CODECS="avc1.4D401F,mp4a.40.2",'
    'RESOLUTION=1280x720,AUDIO="stereo"\n'
    'video-720p.m3u8\n';

/// Sample master playlist with muxed audio + video (legacy / "normal" HLS).
/// No `EXT-X-MEDIA:TYPE=AUDIO` and no `AUDIO=` attribute on the variants.
const _muxedAudioMaster =
    '#EXTM3U\n'
    '#EXT-X-INDEPENDENT-SEGMENTS\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=8000000,CODECS="avc1.4D4828,mp4a.40.2",'
    'RESOLUTION=1920x1080\n'
    '1080p.m3u8\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=4000000,CODECS="avc1.4D401F,mp4a.40.2",'
    'RESOLUTION=1280x720\n'
    '720p.m3u8\n';

void main() {
  group('HlsParser.extractSegmentUrls', () {
    test('parses segment URLs from a media playlist', () {
      const content =
          '#EXTM3U\n'
          '#EXT-X-TARGETDURATION:10\n'
          '#EXTINF:9.009,\n'
          'segment000.ts\n'
          '#EXTINF:9.009,\n'
          'segment001.ts\n'
          '#EXTINF:8.341,\n'
          'segment002.ts\n'
          '#EXT-X-ENDLIST\n';

      final urls = HlsParser.extractSegmentUrls(
        content,
        'https://cdn.example.com/streams/720p/playlist.m3u8',
      );

      expect(urls, hasLength(3));
      expect(urls[0], 'https://cdn.example.com/streams/720p/segment000.ts');
      expect(urls[1], 'https://cdn.example.com/streams/720p/segment001.ts');
      expect(urls[2], 'https://cdn.example.com/streams/720p/segment002.ts');
    });

    test('resolves absolute segment URLs', () {
      const content =
          '#EXTM3U\n'
          '#EXT-X-TARGETDURATION:10\n'
          '#EXTINF:9.009,\n'
          'https://cdn2.example.com/seg000.ts\n'
          '#EXT-X-ENDLIST\n';

      final urls = HlsParser.extractSegmentUrls(
        content,
        'https://cdn.example.com/streams/playlist.m3u8',
      );

      expect(urls, hasLength(1));
      expect(urls[0], 'https://cdn2.example.com/seg000.ts');
    });

    test('handles EXT-X-BYTERANGE between EXTINF and segment URI', () {
      const content =
          '#EXTM3U\n'
          '#EXT-X-TARGETDURATION:10\n'
          '#EXTINF:9.009,\n'
          '#EXT-X-BYTERANGE:500000@0\n'
          'combined.ts\n'
          '#EXT-X-ENDLIST\n';

      final urls = HlsParser.extractSegmentUrls(
        content,
        'https://cdn.example.com/streams/playlist.m3u8',
      );

      expect(urls, hasLength(1));
      expect(urls[0], 'https://cdn.example.com/streams/combined.ts');
    });

    test('returns empty list for playlist with no segments', () {
      const content =
          '#EXTM3U\n'
          '#EXT-X-TARGETDURATION:10\n'
          '#EXT-X-ENDLIST\n';

      final urls = HlsParser.extractSegmentUrls(
        content,
        'https://cdn.example.com/playlist.m3u8',
      );

      expect(urls, isEmpty);
    });

    test('handles empty lines between entries', () {
      const content =
          '#EXTM3U\n'
          '\n'
          '#EXT-X-TARGETDURATION:10\n'
          '\n'
          '#EXTINF:9.009,\n'
          'segment000.ts\n'
          '\n'
          '#EXTINF:9.009,\n'
          'segment001.ts\n'
          '#EXT-X-ENDLIST\n';

      final urls = HlsParser.extractSegmentUrls(
        content,
        'https://cdn.example.com/playlist.m3u8',
      );

      expect(urls, hasLength(2));
    });
  });

  group('HlsParser.extractVariants', () {
    test('parses variant streams from a master playlist', () {
      const content =
          '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720\n'
          '720p/playlist.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080\n'
          '1080p/playlist.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\n'
          '360p/playlist.m3u8\n';

      final variants = HlsParser.extractVariants(
        content,
        'https://cdn.example.com/streams/master.m3u8',
      );

      expect(variants, hasLength(3));
      // Sorted by bandwidth descending
      expect(variants[0].bandwidth, 5000000);
      expect(
        variants[0].url,
        'https://cdn.example.com/streams/1080p/playlist.m3u8',
      );
      expect(variants[1].bandwidth, 2000000);
      expect(
        variants[1].url,
        'https://cdn.example.com/streams/720p/playlist.m3u8',
      );
      expect(variants[2].bandwidth, 800000);
      expect(
        variants[2].url,
        'https://cdn.example.com/streams/360p/playlist.m3u8',
      );
    });

    test('handles absolute variant URLs', () {
      const content =
          '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=3000000\n'
          'https://other.cdn.com/720p/playlist.m3u8\n';

      final variants = HlsParser.extractVariants(
        content,
        'https://cdn.example.com/master.m3u8',
      );

      expect(variants, hasLength(1));
      expect(variants[0].url, 'https://other.cdn.com/720p/playlist.m3u8');
      expect(variants[0].bandwidth, 3000000);
    });

    test('returns empty list for media playlist', () {
      const content =
          '#EXTM3U\n'
          '#EXT-X-TARGETDURATION:10\n'
          '#EXTINF:9.009,\n'
          'segment000.ts\n'
          '#EXT-X-ENDLIST\n';

      final variants = HlsParser.extractVariants(
        content,
        'https://cdn.example.com/playlist.m3u8',
      );

      expect(variants, isEmpty);
    });

    test('defaults bandwidth to 0 when missing', () {
      const content =
          '#EXTM3U\n'
          '#EXT-X-STREAM-INF:RESOLUTION=1280x720\n'
          '720p/playlist.m3u8\n';

      final variants = HlsParser.extractVariants(
        content,
        'https://cdn.example.com/master.m3u8',
      );

      expect(variants, hasLength(1));
      expect(variants[0].bandwidth, 0);
    });

    test('captures AUDIO group reference on variants', () {
      final variants = HlsParser.extractVariants(
        _altAudioMaster,
        'https://cdn.example.com/master.m3u8',
      );

      expect(variants, hasLength(2));
      // Highest-bandwidth variant carries the AUDIO=group attribute.
      expect(variants[0].audioGroup, 'stereo');
      expect(variants[1].audioGroup, 'stereo');
    });

    test('audioGroup is null when no AUDIO attribute is present', () {
      final variants = HlsParser.extractVariants(
        _muxedAudioMaster,
        'https://cdn.example.com/master.m3u8',
      );

      expect(variants, hasLength(2));
      expect(variants[0].audioGroup, isNull);
      expect(variants[1].audioGroup, isNull);
    });
  });

  group('HlsParser.extractAudioRenditions', () {
    test('parses TYPE=AUDIO entries with their URIs resolved', () {
      final renditions = HlsParser.extractAudioRenditions(
        _altAudioMaster,
        'https://cdn.example.com/streams/master.m3u8',
      );

      expect(renditions, hasLength(2));
      expect(renditions[0].groupId, 'stereo');
      expect(renditions[0].name, 'Japanese');
      expect(renditions[0].isDefault, isTrue);
      expect(
        renditions[0].uri,
        'https://cdn.example.com/streams/audio-jpn.m3u8',
      );
      expect(renditions[1].groupId, 'stereo');
      expect(renditions[1].name, 'English');
      expect(renditions[1].isDefault, isFalse);
      expect(
        renditions[1].uri,
        'https://cdn.example.com/streams/audio-eng.m3u8',
      );
    });

    test('returns empty list when no EXT-X-MEDIA:TYPE=AUDIO entries exist', () {
      final renditions = HlsParser.extractAudioRenditions(
        _muxedAudioMaster,
        'https://cdn.example.com/master.m3u8',
      );

      expect(renditions, isEmpty);
    });

    test('ignores EXT-X-MEDIA entries with non-AUDIO types', () {
      const content =
          '#EXTM3U\n'
          '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",'
          'URI="subs-eng.m3u8"\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=1000000\n'
          'video.m3u8\n';

      final renditions = HlsParser.extractAudioRenditions(
        content,
        'https://cdn.example.com/master.m3u8',
      );

      expect(renditions, isEmpty);
    });
  });

  group('HlsParser.rewritePlaylist segment URL extension', () {
    test('rewrites segment URLs to end in .ts even when upstream is .jpg', () {
      const content =
          '#EXTM3U\n'
          '#EXT-X-TARGETDURATION:6\n'
          '#EXTINF:6.0,\n'
          'https://cdn.example.com/seg/000.jpg\n'
          '#EXTINF:6.0,\n'
          'https://cdn.example.com/seg/001.jpg\n'
          '#EXT-X-ENDLIST\n';

      final rewritten = HlsParser.rewritePlaylist(
        content,
        'https://cdn.example.com/media.m3u8',
        'http://192.168.1.5:8234',
        'tok123',
      );

      final segLines =
          rewritten
              .split('\n')
              .where((l) => l.startsWith('http://192.168.1.5'))
              .toList();
      expect(segLines, hasLength(2));
      // Path component (before `?`) must end in `.ts`.
      for (final line in segLines) {
        final qIdx = line.indexOf('?');
        final pathPart = qIdx > 0 ? line.substring(0, qIdx) : line;
        expect(
          pathPart,
          endsWith('.ts'),
          reason:
              'segment proxy URL must end in `.ts` so Chromecast/Shaka '
              'capability probe succeeds. Got: $pathPart',
        );
        expect(pathPart, contains('/stream/tok123/seg'));
      }
      // Segment indices increment.
      expect(segLines[0], contains('/seg1.ts'));
      expect(segLines[1], contains('/seg2.ts'));
    });

    test('leaves variant playlist URLs unchanged (no .ts suffix on STREAM-INF '
        'next-line URIs)', () {
      const content =
          '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720\n'
          '720p/playlist.m3u8\n';

      final rewritten = HlsParser.rewritePlaylist(
        content,
        'https://cdn.example.com/master.m3u8',
        'http://192.168.1.5:8234',
        'tok123',
      );

      final variantLine = rewritten
          .split('\n')
          .firstWhere((l) => l.startsWith('http://192.168.1.5'));
      // Variant playlist URLs keep the plain `/stream/<token>` form (no
      // segment index suffix).
      final qIdx = variantLine.indexOf('?');
      final pathPart = qIdx > 0 ? variantLine.substring(0, qIdx) : variantLine;
      expect(pathPart, equals('http://192.168.1.5:8234/stream/tok123'));
      expect(pathPart, isNot(contains('/seg')));
    });

    test('rewrites alt-audio rendition URIs with plain /stream/<token>', () {
      const content =
          '#EXTM3U\n'
          '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="stereo",NAME="Japanese",'
          'DEFAULT=YES,URI="audio.m3u8"\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=1000000,AUDIO="stereo"\n'
          'video.m3u8\n';

      final rewritten = HlsParser.rewritePlaylist(
        content,
        'https://cdn.example.com/master.m3u8',
        'http://192.168.1.5:8234',
        'tok123',
      );

      // EXT-X-MEDIA URI attribute is rewritten via _rewriteUriAttribute which
      // uses the plain proxy URL form (no segment suffix).
      final audioLine = rewritten
          .split('\n')
          .firstWhere((l) => l.startsWith('#EXT-X-MEDIA'));
      expect(audioLine, contains('http://192.168.1.5:8234/stream/tok123?url='));
      expect(audioLine, isNot(contains('/seg')));
    });
  });

  group('MediaProxy /stream/<token>/<extra>.ts routing', () {
    late MediaProxy proxy;
    late HttpServer upstreamServer;
    late String upstreamBaseUrl;

    setUp(() async {
      proxy = MediaProxy();
      upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstreamBaseUrl = 'http://127.0.0.1:${upstreamServer.port}';

      upstreamServer.listen((request) async {
        if (request.uri.path == '/seg.bin') {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType('video', 'mp2t');
          request.response.add([0x47, 0x00, 0x01, 0x02, 0x03]);
          await request.response.close();
        } else {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      });
    });

    tearDown(() async {
      await proxy.stop();
      await upstreamServer.close(force: true);
    });

    test(
      'a request to /stream/<token>/anything.ts routes to the same token',
      () async {
        await proxy.start();
        // Register a remote route so the proxy has the token.
        final baseProxyUrl = proxy.registerMedia('$upstreamBaseUrl/seg.bin');
        // Extract token from the registered URL.
        final tokenMatch =
            RegExp(r'/stream/([^/?]+)').firstMatch(baseProxyUrl)!;
        final token = tokenMatch.group(1)!;

        // Hit the proxy with a `.ts`-suffixed path (what the rewritten HLS
        // playlist would point Chromecast at).
        final segUrl =
            '${proxy.baseUrl}/stream/$token/seg42.ts'
            '?url=${Uri.encodeComponent("$upstreamBaseUrl/seg.bin")}';

        final client = HttpClient();
        try {
          final request = await client.getUrl(Uri.parse(segUrl));
          final response = await request.close();
          final body = await response.fold<List<int>>(
            <int>[],
            (prev, chunk) => prev..addAll(chunk),
          );
          expect(response.statusCode, HttpStatus.ok);
          expect(body, [0x47, 0x00, 0x01, 0x02, 0x03]);
        } finally {
          client.close();
        }
      },
    );
  });

  group('MediaProxy.registerHlsAsStream', () {
    late MediaProxy proxy;
    late HttpServer upstreamServer;
    late String upstreamBaseUrl;

    setUp(() async {
      proxy = MediaProxy();

      // Create upstream server to simulate HLS content
      upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstreamBaseUrl = 'http://127.0.0.1:${upstreamServer.port}';

      upstreamServer.listen((request) async {
        final path = request.uri.path;

        if (path == '/master.m3u8') {
          final content =
              '#EXTM3U\n'
              '#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720\n'
              'media.m3u8\n';
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          request.response.write(content);
          await request.response.close();
        } else if (path == '/media.m3u8') {
          final content =
              '#EXTM3U\n'
              '#EXT-X-TARGETDURATION:2\n'
              '#EXTINF:2.0,\n'
              'seg0.ts\n'
              '#EXTINF:2.0,\n'
              'seg1.ts\n'
              '#EXT-X-ENDLIST\n';
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          request.response.write(content);
          await request.response.close();
        } else if (path == '/seg0.ts') {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType('video', 'mp2t');
          request.response.add([0x47, 0x00, 0x01, 0x02]); // fake TS data
          await request.response.close();
        } else if (path == '/seg1.ts') {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType('video', 'mp2t');
          request.response.add([0x47, 0x03, 0x04, 0x05]); // fake TS data
          await request.response.close();
        } else if (path == '/simple.m3u8') {
          // A simple media playlist (not master)
          final content =
              '#EXTM3U\n'
              '#EXT-X-TARGETDURATION:2\n'
              '#EXTINF:2.0,\n'
              'seg0.ts\n'
              '#EXT-X-ENDLIST\n';
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          request.response.write(content);
          await request.response.close();
        } else {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      });
    });

    tearDown(() async {
      await proxy.stop();
      await upstreamServer.close(force: true);
    });

    test('returns a URL with /ts-stream/ route', () async {
      await proxy.start();
      final url = proxy.registerHlsAsStream('$upstreamBaseUrl/master.m3u8');
      expect(url, contains('/ts-stream/'));
      expect(url, startsWith(proxy.baseUrl!));
    });

    test('serves HLS as continuous MPEG-TS from master playlist', () async {
      await proxy.start();
      final proxyUrl = proxy.registerHlsAsStream(
        '$upstreamBaseUrl/master.m3u8',
      );

      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(proxyUrl));
        final response = await request.close();

        expect(response.statusCode, HttpStatus.ok);
        expect(response.headers.contentType?.mimeType, 'video/mp2t');

        final body = await response.fold<List<int>>(
          <int>[],
          (prev, chunk) => prev..addAll(chunk),
        );
        // Should contain both segments' data concatenated
        expect(body, [0x47, 0x00, 0x01, 0x02, 0x47, 0x03, 0x04, 0x05]);
      } finally {
        client.close();
      }
    });

    test('serves HLS as MPEG-TS from simple media playlist', () async {
      await proxy.start();
      final proxyUrl = proxy.registerHlsAsStream(
        '$upstreamBaseUrl/simple.m3u8',
      );

      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(proxyUrl));
        final response = await request.close();

        expect(response.statusCode, HttpStatus.ok);
        expect(response.headers.contentType?.mimeType, 'video/mp2t');

        final body = await response.fold<List<int>>(
          <int>[],
          (prev, chunk) => prev..addAll(chunk),
        );
        // Only the first segment (simple playlist has just seg0.ts)
        expect(body, [0x47, 0x00, 0x01, 0x02]);
      } finally {
        client.close();
      }
    });

    test('returns 404 for unknown ts-stream token', () async {
      await proxy.start();

      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse('${proxy.baseUrl}/ts-stream/nonexistent'),
        );
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, HttpStatus.notFound);
      } finally {
        client.close();
      }
    });

    test('forwards custom headers to upstream', () async {
      // Replace upstream with a header-checking server
      await upstreamServer.close(force: true);
      upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstreamBaseUrl = 'http://127.0.0.1:${upstreamServer.port}';

      upstreamServer.listen((request) async {
        final path = request.uri.path;
        final referer = request.headers.value('Referer');

        if (referer != 'https://mysite.com') {
          request.response.statusCode = HttpStatus.forbidden;
          await request.response.close();
          return;
        }

        if (path == '/protected.m3u8') {
          final content =
              '#EXTM3U\n'
              '#EXT-X-TARGETDURATION:2\n'
              '#EXTINF:2.0,\n'
              'pseg.ts\n'
              '#EXT-X-ENDLIST\n';
          request.response.statusCode = HttpStatus.ok;
          request.response.write(content);
          await request.response.close();
        } else if (path == '/pseg.ts') {
          request.response.statusCode = HttpStatus.ok;
          request.response.add([0xAA, 0xBB]);
          await request.response.close();
        } else {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      });

      await proxy.start();
      final proxyUrl = proxy.registerHlsAsStream(
        '$upstreamBaseUrl/protected.m3u8',
        headers: {'Referer': 'https://mysite.com'},
      );

      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(proxyUrl));
        final response = await request.close();
        final body = await response.fold<List<int>>(
          <int>[],
          (prev, chunk) => prev..addAll(chunk),
        );
        expect(response.statusCode, HttpStatus.ok);
        expect(body, [0xAA, 0xBB]);
      } finally {
        client.close();
      }
    });
  });

  group('HlsStreamHandler.streamAsTransportStream', () {
    late HttpServer upstream;
    late String upstreamUrl;
    late HttpServer front;
    late HlsStreamHandler handler;
    late List<String> requested;
    late List<String?> requestedRanges;

    /// Route table for the upstream: path → handler.
    late Map<String, Future<void> Function(HttpRequest)> routes;

    /// Options the front server passes to the handler.
    Duration startAt = Duration.zero;

    setUp(() async {
      requested = [];
      requestedRanges = [];
      routes = {};
      startAt = Duration.zero;
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstreamUrl = 'http://127.0.0.1:${upstream.port}';
      upstream.listen((request) async {
        requested.add(request.uri.path);
        requestedRanges.add(request.headers.value('Range'));
        final route = routes[request.uri.path];
        if (route == null) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          await route(request);
        }
        await request.response.close();
      });

      handler = HlsStreamHandler();
      front = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      front.listen((request) async {
        await handler.streamAsTransportStream(
          '$upstreamUrl${request.uri.path}',
          const {},
          request.response,
          startAt: startAt,
          requestHeaders: request.headers,
        );
      });
    });

    tearDown(() async {
      handler.close();
      await front.close(force: true);
      await upstream.close(force: true);
    });

    void playlist(String path, String content) {
      routes[path] = (request) async {
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        request.response.write(content);
      };
    }

    Future<HttpClientResponse> get(
      String path, {
      Map<String, String> headers = const {},
    }) async {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${front.port}$path'),
      );
      headers.forEach(request.headers.set);
      return request.close();
    }

    Future<List<int>> bodyOf(HttpClientResponse response) =>
        response.fold<List<int>>(<int>[], (a, c) => a..addAll(c));

    // Three distinct 188-byte TS packets in one 564-byte file.
    final tsFile = <int>[
      for (var p = 0; p < 3; p++) ...[
        0x47,
        p,
        0x00,
        0x10,
        ...List.filled(184, p),
      ],
    ];

    const byteRangePlaylist =
        '#EXTM3U\n'
        '#EXT-X-VERSION:4\n'
        '#EXT-X-TARGETDURATION:2\n'
        '#EXTINF:2.0,\n'
        '#EXT-X-BYTERANGE:188@0\n'
        'all.ts\n'
        '#EXTINF:2.0,\n'
        '#EXT-X-BYTERANGE:188@188\n'
        'all.ts\n'
        '#EXTINF:2.0,\n'
        '#EXT-X-BYTERANGE:188@376\n'
        'all.ts\n'
        '#EXT-X-ENDLIST\n';

    test('EXT-X-BYTERANGE segments are fetched with Range, not whole '
        '(RFC 8216 §4.3.2.2)', () async {
      playlist('/single.m3u8', byteRangePlaylist);
      routes['/all.ts'] = (request) async {
        // Honours Range like a real CDN; without one the whole file comes
        // back, which is what made the old code pipe it three times over.
        final range = request.headers.value('Range');
        final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range ?? '');
        if (m == null) {
          request.response.add(tsFile);
          return;
        }
        final s = int.parse(m.group(1)!);
        final e = int.parse(m.group(2)!);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          'Content-Range',
          'bytes $s-$e/${tsFile.length}',
        );
        request.response.add(tsFile.sublist(s, e + 1));
      };

      final response = await get('/single.m3u8');
      final body = await bodyOf(response);
      expect(response.statusCode, HttpStatus.ok);
      expect(body.length, 564);
      expect(body, tsFile);
      expect(requestedRanges.whereType<String>(), [
        'bytes=0-187',
        'bytes=188-375',
        'bytes=376-563',
      ]);
    });

    test(
      'a server that ignores Range still yields only the sub-range',
      () async {
        playlist('/single.m3u8', byteRangePlaylist);
        routes['/all.ts'] = (request) async => request.response.add(tsFile);

        final body = await bodyOf(await get('/single.m3u8'));
        expect(body, tsFile);
      },
    );

    test(
      'an encrypted playlist is refused instead of piping ciphertext',
      () async {
        playlist(
          '/enc.m3u8',
          '#EXTM3U\n'
              '#EXT-X-TARGETDURATION:2\n'
              '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
              '#EXTINF:2.0,\n'
              'seg.ts\n'
              '#EXT-X-ENDLIST\n',
        );
        routes['/seg.ts'] = (request) async => request.response.add(tsFile);

        final response = await get('/enc.m3u8');
        await response.drain<void>();
        expect(response.statusCode, HttpStatus.badGateway);
        expect(requested, isNot(contains('/seg.ts')));
      },
    );

    test('an fMP4 (EXT-X-MAP) playlist is refused instead of being '
        'labelled video/mp2t', () async {
      playlist(
        '/cmaf.m3u8',
        '#EXTM3U\n'
            '#EXT-X-TARGETDURATION:2\n'
            '#EXT-X-MAP:URI="init.mp4"\n'
            '#EXTINF:2.0,\n'
            'seg.m4s\n'
            '#EXT-X-ENDLIST\n',
      );
      routes['/seg.m4s'] = (request) async => request.response.add([1, 2]);

      final response = await get('/cmaf.m3u8');
      await response.drain<void>();
      expect(response.statusCode, HttpStatus.badGateway);
      expect(requested, isNot(contains('/seg.m4s')));
    });

    test('relative segment URIs resolve against the URL after redirects '
        '(RFC 3986 §5.1.3)', () async {
      routes['/a/index.m3u8'] = (request) async {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set('Location', '/b/index.m3u8');
      };
      playlist(
        '/b/index.m3u8',
        '#EXTM3U\n'
            '#EXT-X-TARGETDURATION:2\n'
            '#EXTINF:2.0,\n'
            'seg.ts\n'
            '#EXT-X-ENDLIST\n',
      );
      routes['/b/seg.ts'] = (request) async => request.response.add([0x47, 9]);

      final body = await bodyOf(await get('/a/index.m3u8'));
      expect(requested, contains('/b/seg.ts'));
      expect(requested, isNot(contains('/a/seg.ts')));
      expect(body, [0x47, 9]);
    });

    test('redirected master playlists resolve variants against the final '
        'URL', () async {
      routes['/a/master.m3u8'] = (request) async {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set('Location', '/b/master.m3u8');
      };
      playlist(
        '/b/master.m3u8',
        '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=1000\n'
            'v/index.m3u8\n',
      );
      playlist(
        '/b/v/index.m3u8',
        '#EXTM3U\n'
            '#EXT-X-TARGETDURATION:2\n'
            '#EXTINF:2.0,\n'
            'seg.ts\n'
            '#EXT-X-ENDLIST\n',
      );
      routes['/b/v/seg.ts'] =
          (request) async => request.response.add([0x47, 7]);

      final body = await bodyOf(await get('/a/master.m3u8'));
      expect(body, [0x47, 7]);
      expect(
        await handler.probeDuration('$upstreamUrl/a/master.m3u8', const {}),
        const Duration(seconds: 2),
      );
    });

    test('a live playlist still advertises time seek with an unknown '
        'total (npt=<start>-/*)', () async {
      playlist(
        '/live.m3u8',
        '#EXTM3U\n'
            '#EXT-X-TARGETDURATION:2\n'
            '#EXTINF:2.0,\n'
            'seg.ts\n',
      );
      routes['/seg.ts'] = (request) async => request.response.add([0x47]);

      final response = await get('/live.m3u8');
      await response.drain<void>();
      expect(response.headers.value('TimeSeekRange.dlna.org'), 'npt=0.000-/*');
    });

    test('answers DLNA transfer headers when asked (DLNA 7.4.1.3)', () async {
      playlist(
        '/vod.m3u8',
        '#EXTM3U\n'
            '#EXT-X-TARGETDURATION:2\n'
            '#EXTINF:2.0,\n'
            'seg.ts\n'
            '#EXT-X-ENDLIST\n',
      );
      routes['/seg.ts'] = (request) async => request.response.add([0x47]);

      final asked = await get(
        '/vod.m3u8',
        headers: {
          'getcontentFeatures.dlna.org': '1',
          'transferMode.dlna.org': 'Streaming',
        },
      );
      await asked.drain<void>();
      expect(
        asked.headers.value('contentFeatures.dlna.org'),
        DlnaContentFeatures.pipedTransportStream,
      );
      expect(
        asked.headers.value('contentFeatures.dlna.org'),
        contains('DLNA.ORG_OP=10'),
      );
      expect(asked.headers.value('transferMode.dlna.org'), 'Streaming');
      expect(asked.headers.date, isNotNull);

      final notAsked = await get('/vod.m3u8');
      await notAsked.drain<void>();
      expect(notAsked.headers.value('contentFeatures.dlna.org'), isNull);
      expect(notAsked.headers.value('transferMode.dlna.org'), isNull);
    });

    test(
      'alt-audio sources honour startAt and advertise the seek window',
      () async {
        String media(String prefix) {
          final b = StringBuffer('#EXTM3U\n#EXT-X-TARGETDURATION:10\n');
          for (var i = 0; i < 6; i++) {
            b.write('#EXTINF:10.0,\n$prefix$i.ts\n');
          }
          b.write('#EXT-X-ENDLIST\n');
          return b.toString();
        }

        playlist('/master.m3u8', _altAudioMaster);
        playlist('/video-1080p.m3u8', media('v'));
        playlist('/audio-jpn.m3u8', media('a'));
        for (var i = 0; i < 6; i++) {
          routes['/v$i.ts'] = (request) async => request.response.add([0x47]);
          routes['/a$i.ts'] = (request) async => request.response.add([0x47]);
        }

        startAt = const Duration(seconds: 20);
        final response = await get('/master.m3u8');
        await response.drain<void>();

        expect(
          response.headers.value('TimeSeekRange.dlna.org'),
          'npt=20.000-60.000/60.000',
        );
        // 20s lands on the start of segment 2: 0 and 1 are never fetched.
        expect(requested, isNot(contains('/v0.ts')));
        expect(requested, isNot(contains('/v1.ts')));
        expect(requested, isNot(contains('/a0.ts')));
        expect(requested, containsAll(['/v2.ts', '/v5.ts', '/a2.ts']));
      },
    );

    test(
      'muxed alt-audio segments form one stream: continuity counters '
      'run on across segment boundaries (ISO/IEC 13818-1 §2.4.3.3)',
      () async {
        String media(String prefix) {
          final b = StringBuffer('#EXTM3U\n#EXT-X-TARGETDURATION:1\n');
          for (var i = 0; i < 3; i++) {
            b.write('#EXTINF:0.160,\n$prefix$i.ts\n');
          }
          b.write('#EXT-X-ENDLIST\n');
          return b.toString();
        }

        playlist('/master.m3u8', _altAudioMaster);
        playlist('/video-1080p.m3u8', media('v'));
        playlist('/audio-jpn.m3u8', media('a'));
        for (var i = 0; i < 3; i++) {
          routes['/v$i.ts'] =
              (request) async =>
                  request.response.add(tsVideoSegment(90000 + i * 14400));
          routes['/a$i.ts'] =
              (request) async =>
                  request.response.add(tsAudioSegment(90000 + i * 14400));
        }

        final response = await get('/master.m3u8');
        final body = <int>[];
        await for (final chunk in response) {
          body.addAll(chunk);
        }
        expect(body.length % 188, 0);
        final packets = body.length ~/ 188;
        expect(packets, greaterThan(30));

        final last = <int, int>{};
        final broken = <String>[];
        for (var i = 0; i < packets; i++) {
          final pid = tsPid(body, i);
          if (pid == 0x1FFF) continue;
          final hasPayload = (body[i * 188 + 3] >> 4) & 0x1 == 1;
          final cc = tsCc(body, i);
          final previous = last[pid];
          if (previous != null) {
            final expected = hasPayload ? (previous + 1) & 0x0F : previous;
            if (cc != expected) {
              broken.add(
                'packet $i PID 0x${pid.toRadixString(16)}: '
                'cc $cc after $previous',
              );
            }
          }
          last[pid] = cc;
        }
        expect(broken, isEmpty);
      },
    );
  });
}
