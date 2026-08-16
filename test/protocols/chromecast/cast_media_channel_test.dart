import 'dart:convert';

import 'package:dart_cast/src/protocols/chromecast/cast_media_channel.dart';
import 'package:test/test.dart';

void main() {
  group('CastMediaChannel', () {
    late CastMediaChannel channel;

    setUp(() {
      channel = CastMediaChannel();
    });

    group('constants', () {
      test('mediaNamespace is correct', () {
        expect(
          CastMediaChannel.mediaNamespace,
          'urn:x-cast:com.google.cast.media',
        );
      });
    });

    group('buildLoad', () {
      test('includes contentId and contentType', () {
        final json = channel.buildLoad(
          contentId: 'http://example.com/video.m3u8',
          contentType: 'application/x-mpegURL',
        );
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        expect(decoded['type'], 'LOAD');
        expect(decoded['media']['contentId'], 'http://example.com/video.m3u8');
        expect(decoded['media']['contentType'], 'application/x-mpegURL');
        expect(decoded['autoplay'], true);
        expect(decoded['requestId'], isA<int>());
      });

      test('includes metadata with title and imageUrl', () {
        final json = channel.buildLoad(
          contentId: 'http://example.com/video.mp4',
          contentType: 'video/mp4',
          title: 'My Video',
          imageUrl: 'http://example.com/thumb.jpg',
        );
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        final metadata = decoded['media']['metadata'] as Map<String, dynamic>;
        expect(metadata['metadataType'], 0);
        expect(metadata['title'], 'My Video');
        expect(metadata['images'], isA<List>());
        expect(metadata['images'][0]['url'], 'http://example.com/thumb.jpg');
      });

      test('includes startPosition as currentTime', () {
        final json = channel.buildLoad(
          contentId: 'http://example.com/video.mp4',
          contentType: 'video/mp4',
          startPosition: 120.5,
        );
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        expect(decoded['currentTime'], 120.5);
      });

      test('includes subtitle tracks', () {
        final subtitles = [
          CastMediaTrack(
            trackId: 1,
            url: 'http://example.com/en.vtt',
            name: 'English',
            language: 'en',
          ),
          CastMediaTrack(
            trackId: 2,
            url: 'http://example.com/ar.vtt',
            name: 'Arabic',
            language: 'ar',
          ),
        ];

        final json = channel.buildLoad(
          contentId: 'http://example.com/video.mp4',
          contentType: 'video/mp4',
          subtitles: subtitles,
        );
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        final tracks = decoded['media']['tracks'] as List;
        expect(tracks, hasLength(2));
        expect(tracks[0]['trackId'], 1);
        expect(tracks[0]['type'], 'TEXT');
        expect(tracks[0]['subtype'], 'SUBTITLES');
        expect(tracks[0]['trackContentId'], 'http://example.com/en.vtt');
        expect(tracks[0]['trackContentType'], 'text/vtt');
        expect(tracks[0]['name'], 'English');
        expect(tracks[0]['language'], 'en');

        // No implicit activation: listing tracks must not turn one on.
        // The old "first subtitle by default" behaviour let the track-list
        // order pick the on-screen language.
        expect(decoded.containsKey('activeTrackIds'), isFalse);
      });

      test('activeTrackIds is included only when the caller names tracks', () {
        final subtitles = [
          CastMediaTrack(
            trackId: 1,
            url: 'http://example.com/fr.vtt',
            name: 'French',
            language: 'fr',
          ),
          CastMediaTrack(
            trackId: 2,
            url: 'http://example.com/en.vtt',
            name: 'English',
            language: 'en',
          ),
        ];

        final withActive = jsonDecode(
          channel.buildLoad(
            contentId: 'http://example.com/video.mp4',
            contentType: 'video/mp4',
            subtitles: subtitles,
            activeTrackIds: [2],
          ),
        ) as Map<String, dynamic>;
        expect(withActive['activeTrackIds'], [2]);

        final withEmpty = jsonDecode(
          channel.buildLoad(
            contentId: 'http://example.com/video.mp4',
            contentType: 'video/mp4',
            subtitles: subtitles,
            activeTrackIds: [],
          ),
        ) as Map<String, dynamic>;
        expect(withEmpty.containsKey('activeTrackIds'), isFalse);
      });

      test('includes streamType when specified', () {
        final json = channel.buildLoad(
          contentId: 'http://example.com/live.m3u8',
          contentType: 'application/x-mpegURL',
          streamType: 'LIVE',
        );
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        expect(decoded['media']['streamType'], 'LIVE');
      });

      test('defaults streamType to BUFFERED', () {
        final json = channel.buildLoad(
          contentId: 'http://example.com/video.mp4',
          contentType: 'video/mp4',
        );
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        expect(decoded['media']['streamType'], 'BUFFERED');
      });
    });

    group('buildPlay', () {
      test('includes mediaSessionId', () {
        final json = channel.buildPlay(1);
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        expect(decoded['type'], 'PLAY');
        expect(decoded['mediaSessionId'], 1);
        expect(decoded['requestId'], isA<int>());
      });
    });

    group('buildPause', () {
      test('includes mediaSessionId', () {
        final json = channel.buildPause(1);
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        expect(decoded['type'], 'PAUSE');
        expect(decoded['mediaSessionId'], 1);
        expect(decoded['requestId'], isA<int>());
      });
    });

    group('buildStop', () {
      test('includes mediaSessionId', () {
        final json = channel.buildStop(1);
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        expect(decoded['type'], 'STOP');
        expect(decoded['mediaSessionId'], 1);
        expect(decoded['requestId'], isA<int>());
      });
    });

    group('buildSeek', () {
      test('includes mediaSessionId and currentTime', () {
        final json = channel.buildSeek(1, 120.5);
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        expect(decoded['type'], 'SEEK');
        expect(decoded['mediaSessionId'], 1);
        expect(decoded['currentTime'], 120.5);
        expect(decoded['requestId'], isA<int>());
      });
    });

    group('buildSetVolume', () {
      test('includes volume level and muted', () {
        final json = channel.buildSetVolume(1, level: 0.8, muted: false);
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        expect(decoded['type'], 'SET_VOLUME');
        expect(decoded['mediaSessionId'], 1);
        expect(decoded['volume']['level'], 0.8);
        expect(decoded['volume']['muted'], false);
        expect(decoded['requestId'], isA<int>());
      });
    });

    group('buildGetStatus', () {
      test('produces correct JSON', () {
        final json = channel.buildGetStatus();
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        expect(decoded['type'], 'GET_STATUS');
        expect(decoded['requestId'], isA<int>());
      });
    });

    group('buildEditTracksInfo', () {
      test('includes activeTrackIds', () {
        final json = channel.buildEditTracksInfo(1, [1, 2]);
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        expect(decoded['type'], 'EDIT_TRACKS_INFO');
        expect(decoded['mediaSessionId'], 1);
        expect(decoded['activeTrackIds'], [1, 2]);
        expect(decoded['requestId'], isA<int>());
      });

      test('empty activeTrackIds disables all tracks', () {
        final json = channel.buildEditTracksInfo(1, []);
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        expect(decoded['activeTrackIds'], isEmpty);
      });
    });

    group('parseMediaStatus', () {
      test('extracts all fields from sample MEDIA_STATUS', () {
        final payload = {
          'type': 'MEDIA_STATUS',
          'requestId': 6,
          'status': [
            {
              'mediaSessionId': 1,
              'playerState': 'PLAYING',
              'currentTime': 42.361,
              'volume': {'level': 1.0, 'muted': false},
              'media': {
                'contentId': 'http://example.com/video.m3u8',
                'duration': 1440.5,
              },
            },
          ],
        };

        final status = CastMediaChannel.parseMediaStatus(payload);
        expect(status, isNotNull);
        expect(status!.mediaSessionId, 1);
        expect(status.playerState, 'PLAYING');
        expect(status.currentTime, closeTo(42.361, 0.001));
        expect(status.duration, closeTo(1440.5, 0.1));
        expect(status.volumeLevel, 1.0);
        expect(status.isMuted, false);
      });

      test('handles IDLE state with idleReason', () {
        final payload = {
          'type': 'MEDIA_STATUS',
          'status': [
            {
              'mediaSessionId': 1,
              'playerState': 'IDLE',
              'idleReason': 'FINISHED',
              'currentTime': 0.0,
            },
          ],
        };

        final status = CastMediaChannel.parseMediaStatus(payload);
        expect(status, isNotNull);
        expect(status!.playerState, 'IDLE');
        expect(status.idleReason, 'FINISHED');
      });

      test('returns null when status array is empty', () {
        final payload = {'type': 'MEDIA_STATUS', 'status': []};

        final status = CastMediaChannel.parseMediaStatus(payload);
        expect(status, isNull);
      });

      test('returns null when status is missing', () {
        final payload = {'type': 'MEDIA_STATUS'};
        final status = CastMediaChannel.parseMediaStatus(payload);
        expect(status, isNull);
      });

      test('handles missing duration gracefully', () {
        final payload = {
          'type': 'MEDIA_STATUS',
          'status': [
            {
              'mediaSessionId': 1,
              'playerState': 'PLAYING',
              'currentTime': 10.0,
            },
          ],
        };

        final status = CastMediaChannel.parseMediaStatus(payload);
        expect(status, isNotNull);
        expect(status!.duration, isNull);
      });
    });

    group('requestId auto-increment', () {
      test('requestIds increment across different commands', () {
        final json1 = channel.buildPlay(1);
        final json2 = channel.buildPause(1);
        final json3 = channel.buildStop(1);

        final id1 = (jsonDecode(json1) as Map)['requestId'] as int;
        final id2 = (jsonDecode(json2) as Map)['requestId'] as int;
        final id3 = (jsonDecode(json3) as Map)['requestId'] as int;

        expect(id2, id1 + 1);
        expect(id3, id2 + 1);
      });
    });
  });
}
