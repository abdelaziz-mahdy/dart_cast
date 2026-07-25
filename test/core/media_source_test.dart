import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_cast/src/core/cast_media.dart';
import 'package:dart_cast/src/core/media_proxy.dart';
import 'package:dart_cast/src/core/media_source.dart';
import 'package:dart_cast/src/core/media_transformer.dart';
import 'package:test/test.dart';

/// 1 KiB of recognisable bytes: index modulo 251, so any range can be
/// checked against the offset it claims to start at.
Uint8List _payload(int length) =>
    Uint8List.fromList(List<int>.generate(length, (i) => i % 251));

void main() {
  late MediaProxy proxy;
  late HttpClient client;
  final payload = _payload(1024);

  setUp(() async {
    proxy = MediaProxy();
    await proxy.start();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await proxy.stop();
  });

  Future<HttpClientResponse> fetch(
    String url, {
    String? range,
    String method = 'GET',
  }) async {
    final request = await client.openUrl(method, Uri.parse(url));
    if (range != null) request.headers.set('Range', range);
    return request.close();
  }

  group('MediaSource construction', () {
    test('bytes source reports its own length', () {
      final source = MediaSource.bytes(payload, contentType: 'video/mp4');
      expect(source.length, equals(1024));
      expect(source.contentType, equals('video/mp4'));
    });

    test('file source reads through File.openRead', () async {
      final file = File(
        '${Directory.systemTemp.createTempSync('dart_cast').path}/clip.bin',
      );
      addTearDown(() => file.parent.deleteSync(recursive: true));
      file.writeAsBytesSync(payload);

      final source = await MediaSource.file(file, contentType: 'video/mp4');
      expect(source.length, equals(1024));

      final chunk = await source.read(10, 20).expand((c) => c).toList();
      expect(chunk, equals(payload.sublist(10, 20)));
    });
  });

  group('serving a registered source', () {
    test('serves the whole payload with a correct Content-Length', () async {
      final url = proxy.registerSource(
        MediaSource.bytes(payload, contentType: 'video/mp4'),
        fileExtension: '.mp4',
      );

      final response = await fetch(url);
      final body = await response.fold<List<int>>(
        <int>[],
        (a, b) => a..addAll(b),
      );

      expect(response.statusCode, equals(200));
      expect(response.headers.contentType?.mimeType, equals('video/mp4'));
      expect(body, equals(payload));
    });

    test('appends the file extension renderers sniff', () {
      final url = proxy.registerSource(
        MediaSource.bytes(payload),
        fileExtension: 'mp4',
      );
      // Accepted with or without the leading dot.
      expect(url, endsWith('.mp4'));
      expect(url, contains('/file/'));
    });

    test('answers a byte range with 206 and Content-Range', () async {
      // Seeking is the whole reason ranges matter: a renderer that cannot
      // request a middle byte range cannot scrub.
      final url = proxy.registerSource(
        MediaSource.bytes(payload, contentType: 'video/mp4'),
      );

      final response = await fetch(url, range: 'bytes=100-199');
      final body = await response.fold<List<int>>(
        <int>[],
        (a, b) => a..addAll(b),
      );

      expect(response.statusCode, equals(206));
      expect(body, equals(payload.sublist(100, 200)));
      expect(body, hasLength(100));
    });

    test('an open-ended range runs to the end of the payload', () async {
      final url = proxy.registerSource(MediaSource.bytes(payload));

      final response = await fetch(url, range: 'bytes=1000-');
      final body = await response.fold<List<int>>(
        <int>[],
        (a, b) => a..addAll(b),
      );

      expect(response.statusCode, equals(206));
      expect(body, equals(payload.sublist(1000)));
    });

    test('a suffix range returns the tail', () async {
      final url = proxy.registerSource(MediaSource.bytes(payload));

      final response = await fetch(url, range: 'bytes=-50');
      final body = await response.fold<List<int>>(
        <int>[],
        (a, b) => a..addAll(b),
      );

      expect(response.statusCode, equals(206));
      expect(body, equals(payload.sublist(1024 - 50)));
    });

    test('a range past the end is refused with 416', () async {
      final url = proxy.registerSource(MediaSource.bytes(payload));

      final response = await fetch(url, range: 'bytes=99999-');
      await response.drain<void>();

      expect(response.statusCode, equals(416));
    });

    test('HEAD returns headers without a body', () async {
      final url = proxy.registerSource(
        MediaSource.bytes(payload, contentType: 'video/mp4'),
      );

      final response = await fetch(url, method: 'HEAD');
      final body = await response.fold<List<int>>(
        <int>[],
        (a, b) => a..addAll(b),
      );

      expect(response.statusCode, equals(200));
      expect(body, isEmpty);
    });

    test('reads lazily — nothing is pulled until a request arrives', () async {
      var reads = 0;
      final url = proxy.registerSource(
        MediaSource(
          length: payload.length,
          contentType: 'video/mp4',
          read: (start, end) {
            reads++;
            return Stream.value(payload.sublist(start, end));
          },
        ),
      );

      expect(reads, isZero, reason: 'registering must not read the payload');

      await (await fetch(url, range: 'bytes=0-9')).drain<void>();
      expect(reads, equals(1));
    });

    test('an unregistered token still 404s', () async {
      final response = await fetch('${proxy.baseUrl}/file/nope.mp4');
      await response.drain<void>();
      expect(response.statusCode, equals(404));
    });
  });

  group('CastMedia.source through the transformer', () {
    test('is registered as a served source, not fetched as a URL', () async {
      // This is the path every protocol shares, so getting it right here is
      // what makes Chromecast, DLNA and AirPlay all work with a byte source.
      final media = CastMedia.source(
        MediaSource.bytes(payload, contentType: 'video/mp4'),
        type: CastMediaType.mp4,
        fileExtension: '.mp4',
        title: 'From bytes',
      );

      final transformed = await const DefaultMediaTransformer().transform(
        media,
        proxy,
      );

      expect(transformed.proxyUrl, contains('/file/'));
      expect(transformed.proxyUrl, endsWith('.mp4'));
      expect(transformed.effectiveType, equals(CastMediaType.mp4));

      final response = await fetch(transformed.proxyUrl);
      final body = await response.fold<List<int>>(
        <int>[],
        (a, b) => a..addAll(b),
      );
      expect(body, equals(payload));
    });

    test('a plain remote CastMedia is unaffected', () async {
      const media = CastMedia(
        url: 'http://example.com/video.mp4',
        type: CastMediaType.mp4,
      );

      final transformed = await const DefaultMediaTransformer().transform(
        media,
        proxy,
      );

      expect(transformed.proxyUrl, contains('/stream/'));
    });

    test('subtitles and metadata survive alongside a source', () {
      final media = CastMedia.source(
        MediaSource.bytes(payload),
        type: CastMediaType.mp4,
        title: 'Episode 1',
        startPosition: const Duration(seconds: 30),
        subtitles: const [
          CastSubtitle(
            url: 'file:///tmp/subs.srt',
            label: 'English',
            language: 'en',
            format: 'srt',
          ),
        ],
      );

      expect(media.source, isNotNull);
      expect(media.isLocalFile, isFalse);
      expect(media.title, equals('Episode 1'));
      expect(media.startPosition, equals(const Duration(seconds: 30)));
      expect(media.subtitles, hasLength(1));
    });
  });

  group('an asset-style source', () {
    test('serves bytes held in memory, ranges included', () async {
      // Mirrors reading a Flutter asset via rootBundle and handing over the
      // resulting bytes.
      final assetBytes = utf8.encode('FAKE-MP4-ASSET-BODY' * 100);
      final url = proxy.registerSource(
        MediaSource.bytes(assetBytes, contentType: 'video/mp4'),
        fileExtension: '.mp4',
      );

      final full = await fetch(url);
      expect(
        await full.fold<List<int>>(<int>[], (a, b) => a..addAll(b)),
        equals(assetBytes),
      );

      final partial = await fetch(url, range: 'bytes=5-14');
      expect(
        await partial.fold<List<int>>(<int>[], (a, b) => a..addAll(b)),
        equals(assetBytes.sublist(5, 15)),
      );
    });
  });
}
