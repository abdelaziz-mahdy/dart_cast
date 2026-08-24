import 'package:test/test.dart';
import 'package:dart_cast/dart_cast.dart';

void main() {
  group('CastMediaType', () {
    test('has expected values', () {
      expect(CastMediaType.values, contains(CastMediaType.hls));
      expect(CastMediaType.values, contains(CastMediaType.mp4));
      expect(CastMediaType.values, contains(CastMediaType.mpegTs));
    });
  });

  group('CastSubtitle', () {
    test('creation with all fields', () {
      final sub = CastSubtitle(
        url: 'https://example.com/subs.vtt',
        label: 'English',
        language: 'en',
        format: 'vtt',
      );
      expect(sub.url, 'https://example.com/subs.vtt');
      expect(sub.label, 'English');
      expect(sub.language, 'en');
      expect(sub.format, 'vtt');
    });
  });

  group('CastMedia', () {
    test('creation with required fields only', () {
      final media = CastMedia(
        url: 'https://example.com/video.m3u8',
        type: CastMediaType.hls,
      );
      expect(media.url, 'https://example.com/video.m3u8');
      expect(media.type, CastMediaType.hls);
      expect(media.httpHeaders, isEmpty);
      expect(media.title, isNull);
      expect(media.imageUrl, isNull);
      expect(media.startPosition, isNull);
      expect(media.subtitles, isEmpty);
    });

    test('creation with all fields', () {
      final subtitle = CastSubtitle(
        url: 'https://example.com/subs.vtt',
        label: 'English',
        language: 'en',
        format: 'vtt',
      );
      final media = CastMedia(
        url: 'https://example.com/video.mp4',
        type: CastMediaType.mp4,
        httpHeaders: {'Authorization': 'Bearer token'},
        title: 'My Video',
        imageUrl: 'https://example.com/thumb.jpg',
        startPosition: Duration(seconds: 30),
        subtitles: [subtitle],
      );
      expect(media.url, 'https://example.com/video.mp4');
      expect(media.type, CastMediaType.mp4);
      expect(media.httpHeaders, {'Authorization': 'Bearer token'});
      expect(media.title, 'My Video');
      expect(media.imageUrl, 'https://example.com/thumb.jpg');
      expect(media.startPosition, Duration(seconds: 30));
      expect(media.subtitles, hasLength(1));
      expect(media.subtitles.first.label, 'English');
    });

    test('copyWith overrides startPosition and keeps everything else', () {
      const subtitle = CastSubtitle(
        url: 'https://example.com/subs.vtt',
        label: 'English',
        language: 'en',
        format: 'vtt',
      );
      const media = CastMedia(
        url: 'https://example.com/video.mp4',
        type: CastMediaType.mp4,
        httpHeaders: {'Authorization': 'Bearer token'},
        title: 'My Video',
        imageUrl: 'https://example.com/thumb.jpg',
        startPosition: Duration(seconds: 30),
        subtitles: [subtitle],
        defaultSubtitle: subtitle,
      );

      final resumed = media.copyWith(
        startPosition: const Duration(minutes: 12),
      );

      expect(resumed.url, media.url);
      expect(resumed.type, media.type);
      expect(resumed.httpHeaders, media.httpHeaders);
      expect(resumed.title, media.title);
      expect(resumed.imageUrl, media.imageUrl);
      expect(resumed.subtitles, media.subtitles);
      expect(resumed.defaultSubtitle, media.defaultSubtitle);
      expect(resumed.startPosition, const Duration(minutes: 12));
      expect(resumed.isLocalFile, isFalse);
    });

    test('copyWith preserves local-file identity', () {
      const media = CastMedia.file(
        filePath: '/videos/movie.mkv',
        type: CastMediaType.mkv,
        title: 'Movie',
      );

      final resumed = media.copyWith(startPosition: const Duration(minutes: 3));

      expect(resumed.url, '/videos/movie.mkv');
      expect(resumed.isLocalFile, isTrue);
      expect(resumed.startPosition, const Duration(minutes: 3));
      expect(resumed.type, CastMediaType.mkv);
    });

    test('enum values are distinct', () {
      expect(CastMediaType.hls, isNot(CastMediaType.mp4));
      expect(CastMediaType.mp4, isNot(CastMediaType.mpegTs));
      expect(CastMediaType.mkv, isNot(CastMediaType.mp4));
      expect(CastMediaType.values, hasLength(4));
    });
  });
}
