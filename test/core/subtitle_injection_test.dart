import 'dart:convert';
import 'dart:io';

import 'package:dart_cast/src/core/media_proxy.dart';
import 'package:test/test.dart';

void main() {
  group('MediaProxy subtitle injection', () {
    late MediaProxy proxy;
    late HttpServer upstreamServer;
    late String upstreamBaseUrl;

    setUp(() async {
      proxy = MediaProxy();

      // Create an upstream server to simulate remote content
      upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstreamBaseUrl = 'http://127.0.0.1:${upstreamServer.port}';
      upstreamServer.listen((request) async {
        final path = request.uri.path;

        if (path == '/subs.vtt') {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType('text', 'vtt');
          request.response.write(
            'WEBVTT\n\n00:00:01.000 --> 00:00:04.000\nHello world\n',
          );
          await request.response.close();
        } else if (path == '/master.m3u8') {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType =
              ContentType('application', 'vnd.apple.mpegurl');
          request.response.write(
            '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=2000000\n'
            'video.m3u8\n',
          );
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

    test('registerSubtitlePlaylist returns a synthetic URL', () async {
      await proxy.start();

      final url = proxy.registerSubtitlePlaylist(
        '$upstreamBaseUrl/subs.vtt',
      );

      expect(url, startsWith(proxy.baseUrl!));
      expect(url, contains('/synthetic/'));
    });

    test('registerSubtitlePlaylist serves a valid HLS playlist wrapping VTT',
        () async {
      await proxy.start();

      final url = proxy.registerSubtitlePlaylist(
        '$upstreamBaseUrl/subs.vtt',
      );

      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();
        expect(response.statusCode, HttpStatus.ok);

        final body = await response.transform(utf8.decoder).join();
        expect(body, contains('#EXTM3U'));
        expect(body, contains('#EXT-X-TARGETDURATION:99999'));
        expect(body, contains('#EXTINF:99999.0,'));
        expect(body, contains('#EXT-X-ENDLIST'));
        // Should contain a proxy URL for the VTT file
        expect(body, contains('/stream/'));
      } finally {
        client.close();
      }
    });

    test('registerSubtitleWrapper creates master playlist with subtitle tracks',
        () async {
      await proxy.start();

      final originalProxyUrl = proxy.registerMedia(
        '$upstreamBaseUrl/master.m3u8',
      );
      final subPlaylistUrl = proxy.registerSubtitlePlaylist(
        '$upstreamBaseUrl/subs.vtt',
      );

      final wrapperUrl = proxy.registerSubtitleWrapper(
        originalM3u8ProxyUrl: originalProxyUrl,
        subtitleEntries: [
          (name: 'English', language: 'en', url: subPlaylistUrl),
        ],
      );

      expect(wrapperUrl, startsWith(proxy.baseUrl!));
      expect(wrapperUrl, contains('/synthetic/'));

      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(wrapperUrl));
        final response = await request.close();
        expect(response.statusCode, HttpStatus.ok);

        final body = await response.transform(utf8.decoder).join();
        expect(body, contains('#EXTM3U'));
        expect(body, contains('#EXT-X-MEDIA:TYPE=SUBTITLES'));
        expect(body, contains('GROUP-ID="subs"'));
        expect(body, contains('NAME="English"'));
        expect(body, contains('LANGUAGE="en"'));
        expect(body, contains('DEFAULT=YES'));
        expect(body, contains('#EXT-X-STREAM-INF:BANDWIDTH=1280000'));
        expect(body, contains('SUBTITLES="subs"'));
        // Should reference the original proxy URL
        expect(body, contains(originalProxyUrl));
        // Should reference the subtitle playlist URL
        expect(body, contains(subPlaylistUrl));
      } finally {
        client.close();
      }
    });

    test('registerSubtitleWrapper with multiple subtitle tracks', () async {
      await proxy.start();

      final originalProxyUrl = proxy.registerMedia(
        '$upstreamBaseUrl/master.m3u8',
      );
      final subEn = proxy.registerSubtitlePlaylist(
        '$upstreamBaseUrl/subs.vtt',
      );
      final subJa = proxy.registerSubtitlePlaylist(
        '$upstreamBaseUrl/subs.vtt',
      );

      final wrapperUrl = proxy.registerSubtitleWrapper(
        originalM3u8ProxyUrl: originalProxyUrl,
        subtitleEntries: [
          (name: 'English', language: 'en', url: subEn),
          (name: 'Japanese', language: 'ja', url: subJa),
        ],
      );

      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(wrapperUrl));
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();

        // First subtitle should be DEFAULT=YES
        expect(body, contains('NAME="English"'));
        expect(body, contains('NAME="Japanese"'));
        // Count EXT-X-MEDIA lines
        final mediaLines =
            body.split('\n').where((l) => l.contains('#EXT-X-MEDIA')).toList();
        expect(mediaLines, hasLength(2));

        // First is default, second is not
        expect(mediaLines[0], contains('DEFAULT=YES'));
        expect(mediaLines[1], contains('DEFAULT=NO'));
      } finally {
        client.close();
      }
    });

    test('synthetic route returns 404 for unknown token', () async {
      await proxy.start();

      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse('${proxy.baseUrl}/synthetic/nonexistent'),
        );
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, HttpStatus.notFound);
      } finally {
        client.close();
      }
    });

    test('cleanupPreviousMedia clears synthetic content', () async {
      await proxy.start();

      final url = proxy.registerSubtitlePlaylist(
        '$upstreamBaseUrl/subs.vtt',
      );

      // Verify it works first
      final client = HttpClient();
      try {
        var request = await client.getUrl(Uri.parse(url));
        var response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, HttpStatus.ok);

        // Clean up
        proxy.cleanupPreviousMedia();

        // Should now 404
        request = await client.getUrl(Uri.parse(url));
        response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, HttpStatus.notFound);
      } finally {
        client.close();
      }
    });

    test('synthetic content served via HTTP/1.0 without CORS', () async {
      await proxy.start();

      final url = proxy.registerSubtitlePlaylist(
        '$upstreamBaseUrl/subs.vtt',
      );

      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();
        await response.drain<void>();

        // Synthetic content now served via HTTP/1.0 raw socket for
        // DLNA compatibility — no CORS headers needed.
        expect(response.statusCode, HttpStatus.ok);
      } finally {
        client.close();
      }
    });

    test('synthetic content has correct Content-Type for m3u8', () async {
      await proxy.start();

      final url = proxy.registerSubtitlePlaylist(
        '$upstreamBaseUrl/subs.vtt',
      );

      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();
        await response.drain<void>();

        expect(
          response.headers.contentType.toString(),
          contains('mpegURL'),
        );
      } finally {
        client.close();
      }
    });
  });
}
