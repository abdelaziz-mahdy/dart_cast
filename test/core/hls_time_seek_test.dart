import 'dart:convert';
import 'dart:io';

import 'package:dart_cast/src/core/hls_parser.dart';
import 'package:dart_cast/src/core/media_proxy.dart';
import 'package:test/test.dart';

/// A VOD media playlist: six 10-second segments, 60s total.
const _vodPlaylist =
    '#EXTM3U\n'
    '#EXT-X-TARGETDURATION:10\n'
    '#EXTINF:10.000,\n'
    'seg0.ts\n'
    '#EXTINF:10.000,\n'
    'seg1.ts\n'
    '#EXTINF:10.000,\n'
    'seg2.ts\n'
    '#EXTINF:10.000,\n'
    'seg3.ts\n'
    '#EXTINF:10.000,\n'
    'seg4.ts\n'
    '#EXTINF:10.000,\n'
    'seg5.ts\n'
    '#EXT-X-ENDLIST\n';

/// The same playlist without `#EXT-X-ENDLIST` — a live stream.
const _livePlaylist =
    '#EXTM3U\n'
    '#EXT-X-TARGETDURATION:10\n'
    '#EXTINF:10.000,\n'
    'seg0.ts\n'
    '#EXTINF:10.000,\n'
    'seg1.ts\n';

/// Serves a fixed HLS playlist plus segments whose body names the segment,
/// so a test can tell which segments were streamed.
class _UpstreamServer {
  final HttpServer _server;
  final List<String> requestedPaths = [];

  _UpstreamServer._(this._server);

  int get port => _server.port;
  String get playlistUrl => 'http://127.0.0.1:$port/playlist.m3u8';

  static Future<_UpstreamServer> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final server = _UpstreamServer._(http);
    http.listen((request) async {
      server.requestedPaths.add(request.uri.path);
      if (request.uri.path.endsWith('.m3u8')) {
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        request.response.write(_vodPlaylist);
      } else {
        // Body identifies the segment: "<seg2>"
        final name = request.uri.pathSegments.last.split('.').first;
        request.response.add(utf8.encode('<$name>'));
      }
      await request.response.close();
    });
    return server;
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  group('HlsParser.totalDuration', () {
    test('sums EXTINF values for a complete playlist', () {
      expect(
        HlsParser.totalDuration(_vodPlaylist),
        equals(const Duration(seconds: 60)),
      );
    });

    test('returns null for a live playlist', () {
      // A live playlist's length keeps changing, so advertising it to a
      // renderer would be worse than advertising nothing.
      expect(HlsParser.totalDuration(_livePlaylist), isNull);
    });

    test('returns null when there are no parseable durations', () {
      expect(HlsParser.totalDuration('#EXTM3U\n#EXT-X-ENDLIST\n'), isNull);
    });

    test('isCompletePlaylist keys off EXT-X-ENDLIST', () {
      expect(HlsParser.isCompletePlaylist(_vodPlaylist), isTrue);
      expect(HlsParser.isCompletePlaylist(_livePlaylist), isFalse);
    });
  });

  group('HlsParser.extractSegments', () {
    test('pairs each segment URL with its EXTINF duration', () {
      final segments = HlsParser.extractSegments(
        _vodPlaylist,
        'https://cdn.example.com/v/playlist.m3u8',
      );

      expect(segments, hasLength(6));
      expect(segments.first.url, 'https://cdn.example.com/v/seg0.ts');
      expect(segments.first.duration, closeTo(10.0, 0.001));
      expect(segments.last.url, 'https://cdn.example.com/v/seg5.ts');
    });

    test('stays aligned with extractSegmentUrls', () {
      final urls = HlsParser.extractSegmentUrls(_vodPlaylist, 'https://x/y/');
      final segments = HlsParser.extractSegments(_vodPlaylist, 'https://x/y/');
      expect(segments.map((s) => s.url).toList(), equals(urls));
    });
  });

  group('MediaProxy.parseTimeSeekRange', () {
    test('parses plain seconds', () {
      expect(
        MediaProxy.parseTimeSeekRange('npt=120.5-'),
        equals(const Duration(milliseconds: 120500)),
      );
    });

    test('parses a start-end range', () {
      expect(
        MediaProxy.parseTimeSeekRange('npt=30-300.000'),
        equals(const Duration(seconds: 30)),
      );
    });

    test('parses hh:mm:ss form', () {
      expect(
        MediaProxy.parseTimeSeekRange('npt=0:02:00.500-'),
        equals(const Duration(minutes: 2, milliseconds: 500)),
      );
    });

    test('is case- and whitespace-tolerant', () {
      expect(
        MediaProxy.parseTimeSeekRange('NPT = 45 -'),
        equals(const Duration(seconds: 45)),
      );
    });

    test('falls back to zero for absent or unusable values', () {
      // Anything unparseable must behave exactly as "no seek requested"
      // rather than throwing in the middle of serving a stream.
      expect(MediaProxy.parseTimeSeekRange(null), Duration.zero);
      expect(MediaProxy.parseTimeSeekRange(''), Duration.zero);
      expect(MediaProxy.parseTimeSeekRange('bytes=0-'), Duration.zero);
      expect(MediaProxy.parseTimeSeekRange('npt=-'), Duration.zero);
      expect(MediaProxy.parseTimeSeekRange('npt=abc-'), Duration.zero);
      expect(MediaProxy.parseTimeSeekRange('npt=-10-'), Duration.zero);
    });
  });

  group('piped TS route seeking', () {
    late _UpstreamServer upstream;
    late MediaProxy proxy;
    late HttpClient client;

    setUp(() async {
      upstream = await _UpstreamServer.start();
      proxy = MediaProxy();
      await proxy.start();
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await proxy.stop();
      await upstream.stop();
    });

    Future<HttpClientResponse> get(String url, {String? timeSeekRange}) async {
      final request = await client.getUrl(Uri.parse(url));
      if (timeSeekRange != null) {
        request.headers.set('TimeSeekRange.dlna.org', timeSeekRange);
      }
      return request.close();
    }

    test('streams every segment when no seek is requested', () async {
      final url = proxy.registerHlsAsStream(upstream.playlistUrl);
      final body = await get(url).then((r) => r.transform(utf8.decoder).join());

      expect(body, equals('<seg0><seg1><seg2><seg3><seg4><seg5>'));
    });

    test('TimeSeekRange starts the pipe at the covering segment', () async {
      final url = proxy.registerHlsAsStream(upstream.playlistUrl);

      // 25s lands inside seg2 (20-30s), so seg0 and seg1 are dropped.
      final body = await get(
        url,
        timeSeekRange: 'npt=25.0-',
      ).then((r) => r.transform(utf8.decoder).join());

      expect(body, equals('<seg2><seg3><seg4><seg5>'));
    });

    test(
      'a ?t= query seeks for renderers that never send the header',
      () async {
        // The TCL Google TV only ever sends `Range: bytes=0-`, so the sender
        // re-points it at the same route with the offset in the URL instead.
        final url = proxy.registerHlsAsStream(upstream.playlistUrl);
        final body = await get(
          '$url?t=40',
        ).then((r) => r.transform(utf8.decoder).join());

        expect(body, equals('<seg4><seg5>'));
      },
    );

    test('advertises the seek window and refuses byte ranges', () async {
      final url = proxy.registerHlsAsStream(upstream.playlistUrl);
      final response = await get(url, timeSeekRange: 'npt=20-');

      expect(
        response.headers.value('TimeSeekRange.dlna.org'),
        equals('npt=20.000-60.000/60.000'),
      );
      // The body is generated on demand, so byte offsets are meaningless.
      expect(response.headers.value('Accept-Ranges'), equals('none'));
      await response.drain<void>();
    });

    test(
      'a seek past the end yields an empty body rather than an error',
      () async {
        final url = proxy.registerHlsAsStream(upstream.playlistUrl);
        final response = await get(url, timeSeekRange: 'npt=999-');

        expect(response.statusCode, equals(HttpStatus.ok));
        expect(await response.transform(utf8.decoder).join(), isEmpty);
      },
    );

    test('probeHlsDuration reports the playlist length', () async {
      expect(
        await proxy.probeHlsDuration(upstream.playlistUrl),
        equals(const Duration(seconds: 60)),
      );
    });
  });
}
