import 'package:dart_cast/src/core/hls_parser.dart';
import 'package:test/test.dart';

void main() {
  group('HlsParser', () {
    group('isMasterPlaylist', () {
      test('returns true when content contains #EXT-X-STREAM-INF', () {
        const content =
            '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720\n'
            '720p/playlist.m3u8\n';
        expect(HlsParser.isMasterPlaylist(content), isTrue);
      });

      test('returns false for a media playlist with #EXTINF', () {
        const content =
            '#EXTM3U\n'
            '#EXT-X-TARGETDURATION:10\n'
            '#EXTINF:9.009,\n'
            'segment000.ts\n'
            '#EXT-X-ENDLIST\n';
        expect(HlsParser.isMasterPlaylist(content), isFalse);
      });

      test('returns true when content contains #EXT-X-I-FRAME-STREAM-INF', () {
        const content =
            '#EXTM3U\n'
            '#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=900000,URI="720p/iframes.m3u8"\n';
        expect(HlsParser.isMasterPlaylist(content), isTrue);
      });
    });

    group('resolveUrl', () {
      test('returns absolute URL unchanged', () {
        expect(
          HlsParser.resolveUrl(
            'https://other.cdn.com/720p/playlist.m3u8',
            'https://cdn.example.com/streams/master.m3u8',
          ),
          'https://other.cdn.com/720p/playlist.m3u8',
        );
      });

      test('resolves protocol-relative URL', () {
        expect(
          HlsParser.resolveUrl(
            '//other.cdn.com/720p/playlist.m3u8',
            'https://cdn.example.com/streams/master.m3u8',
          ),
          'https://other.cdn.com/720p/playlist.m3u8',
        );
      });

      test('resolves absolute path URL', () {
        expect(
          HlsParser.resolveUrl(
            '/live/720p/playlist.m3u8',
            'https://cdn.example.com/streams/master.m3u8',
          ),
          'https://cdn.example.com/live/720p/playlist.m3u8',
        );
      });

      test('resolves relative path URL', () {
        expect(
          HlsParser.resolveUrl(
            '720p/playlist.m3u8',
            'https://cdn.example.com/streams/master.m3u8',
          ),
          'https://cdn.example.com/streams/720p/playlist.m3u8',
        );
      });

      test('resolves relative path with parent directory (..)', () {
        expect(
          HlsParser.resolveUrl(
            '../other/playlist.m3u8',
            'https://cdn.example.com/streams/master.m3u8',
          ),
          'https://cdn.example.com/other/playlist.m3u8',
        );
      });

      test('resolves http URL unchanged', () {
        expect(
          HlsParser.resolveUrl(
            'http://cdn.example.com/seg.ts',
            'https://cdn.example.com/streams/master.m3u8',
          ),
          'http://cdn.example.com/seg.ts',
        );
      });
    });

    group('rewritePlaylist', () {
      const baseUrl = 'https://cdn.example.com/streams/master.m3u8';
      const proxyBaseUrl = 'http://192.168.1.5:8234';
      const token = 'abc123';

      test('rewrites master playlist variant URIs (Pattern A)', () {
        const content =
            '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720\n'
            '720p/playlist.m3u8\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080\n'
            '1080p/playlist.m3u8\n';

        final result = HlsParser.rewritePlaylist(
          content,
          baseUrl,
          proxyBaseUrl,
          token,
        );
        final lines = result.split('\n');

        // Line 0: #EXTM3U
        expect(lines[0], '#EXTM3U');
        // Line 1: #EXT-X-STREAM-INF unchanged
        expect(lines[1], startsWith('#EXT-X-STREAM-INF:'));
        // Line 2: rewritten variant URI
        expect(lines[2], startsWith('$proxyBaseUrl/stream/$token?url='));
        expect(
          lines[2],
          contains(
            Uri.encodeComponent(
              'https://cdn.example.com/streams/720p/playlist.m3u8',
            ),
          ),
        );
        // Line 4: rewritten 1080p variant URI
        expect(
          lines[4],
          contains(
            Uri.encodeComponent(
              'https://cdn.example.com/streams/1080p/playlist.m3u8',
            ),
          ),
        );
      });

      test('rewrites media playlist segment URIs (Pattern A)', () {
        const content =
            '#EXTM3U\n'
            '#EXT-X-TARGETDURATION:10\n'
            '#EXTINF:9.009,\n'
            'segment000.ts\n'
            '#EXTINF:9.009,\n'
            'segment001.ts\n'
            '#EXT-X-ENDLIST\n';

        final mediaBaseUrl =
            'https://cdn.example.com/streams/720p/playlist.m3u8';
        final result = HlsParser.rewritePlaylist(
          content,
          mediaBaseUrl,
          proxyBaseUrl,
          token,
        );
        final lines = result.split('\n');

        // Segment URLs carry a synthetic `/seg<index>.ts` suffix so
        // strict TS demuxers (notably Chromecast / Shaka) get a `.ts`
        // path extension during MediaCapabilities probing even when
        // the upstream URL ends in `.jpg` or another non-media ext.
        expect(
          lines[3],
          startsWith('$proxyBaseUrl/stream/$token/seg1.ts?url='),
        );
        expect(
          lines[3],
          contains(
            Uri.encodeComponent(
              'https://cdn.example.com/streams/720p/segment000.ts',
            ),
          ),
        );
        expect(
          lines[5],
          contains(
            Uri.encodeComponent(
              'https://cdn.example.com/streams/720p/segment001.ts',
            ),
          ),
        );
      });

      test('rewrites #EXT-X-KEY URI attribute (Pattern B)', () {
        const content =
            '#EXTM3U\n'
            '#EXT-X-TARGETDURATION:10\n'
            '#EXT-X-KEY:METHOD=AES-128,URI="https://keys.cdn.com/key1.bin",IV=0x00000001\n'
            '#EXTINF:9.009,\n'
            'segment000.ts\n'
            '#EXT-X-ENDLIST\n';

        final result = HlsParser.rewritePlaylist(
          content,
          baseUrl,
          proxyBaseUrl,
          token,
        );

        expect(result, contains('URI="$proxyBaseUrl/stream/$token?url='));
        expect(
          result,
          contains(Uri.encodeComponent('https://keys.cdn.com/key1.bin')),
        );
        // IV should be preserved
        expect(result, contains('IV=0x00000001'));
        expect(result, contains('METHOD=AES-128'));
      });

      test('rewrites #EXT-X-MAP URI attribute (Pattern B)', () {
        const content =
            '#EXTM3U\n'
            '#EXT-X-TARGETDURATION:10\n'
            '#EXT-X-MAP:URI="init.mp4"\n'
            '#EXTINF:9.009,\n'
            'segment000.m4s\n'
            '#EXT-X-ENDLIST\n';

        final mediaBaseUrl =
            'https://cdn.example.com/streams/720p/playlist.m3u8';
        final result = HlsParser.rewritePlaylist(
          content,
          mediaBaseUrl,
          proxyBaseUrl,
          token,
        );

        expect(result, contains('URI="$proxyBaseUrl/stream/$token?url='));
        expect(
          result,
          contains(
            Uri.encodeComponent(
              'https://cdn.example.com/streams/720p/init.mp4',
            ),
          ),
        );
      });

      test('rewrites #EXT-X-MEDIA URI attribute (Pattern B)', () {
        const content =
            '#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="English",URI="audio/en/playlist.m3u8"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=2000000,AUDIO="aac"\n'
            '720p/playlist.m3u8\n';

        final result = HlsParser.rewritePlaylist(
          content,
          baseUrl,
          proxyBaseUrl,
          token,
        );

        expect(result, contains('URI="$proxyBaseUrl/stream/$token?url='));
        expect(
          result,
          contains(
            Uri.encodeComponent(
              'https://cdn.example.com/streams/audio/en/playlist.m3u8',
            ),
          ),
        );
      });

      test('rewrites #EXT-X-I-FRAME-STREAM-INF URI attribute', () {
        const content =
            '#EXTM3U\n'
            '#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=900000,URI="720p/iframes.m3u8"\n';

        final result = HlsParser.rewritePlaylist(
          content,
          baseUrl,
          proxyBaseUrl,
          token,
        );

        expect(result, contains('URI="$proxyBaseUrl/stream/$token?url='));
        expect(
          result,
          contains(
            Uri.encodeComponent(
              'https://cdn.example.com/streams/720p/iframes.m3u8',
            ),
          ),
        );
      });

      test('preserves non-URI lines unchanged', () {
        const content =
            '#EXTM3U\n'
            '#EXT-X-VERSION:3\n'
            '#EXT-X-TARGETDURATION:10\n'
            '#EXT-X-MEDIA-SEQUENCE:0\n'
            '#EXT-X-PLAYLIST-TYPE:VOD\n'
            '#EXTINF:9.009,\n'
            'segment000.ts\n'
            '#EXT-X-ENDLIST\n';

        final mediaBaseUrl =
            'https://cdn.example.com/streams/720p/playlist.m3u8';
        final result = HlsParser.rewritePlaylist(
          content,
          mediaBaseUrl,
          proxyBaseUrl,
          token,
        );
        final lines = result.split('\n');

        expect(lines[0], '#EXTM3U');
        expect(lines[1], '#EXT-X-VERSION:3');
        expect(lines[2], '#EXT-X-TARGETDURATION:10');
        expect(lines[3], '#EXT-X-MEDIA-SEQUENCE:0');
        expect(lines[4], '#EXT-X-PLAYLIST-TYPE:VOD');
        expect(lines[7], '#EXT-X-ENDLIST');
      });

      test('handles absolute segment URLs', () {
        const content =
            '#EXTM3U\n'
            '#EXT-X-TARGETDURATION:10\n'
            '#EXTINF:9.009,\n'
            'https://cdn2.example.com/seg000.ts\n'
            '#EXT-X-ENDLIST\n';

        final result = HlsParser.rewritePlaylist(
          content,
          baseUrl,
          proxyBaseUrl,
          token,
        );

        expect(
          result,
          contains(Uri.encodeComponent('https://cdn2.example.com/seg000.ts')),
        );
      });

      test('handles #EXT-X-BYTERANGE between #EXTINF and segment URI', () {
        const content =
            '#EXTM3U\n'
            '#EXT-X-TARGETDURATION:10\n'
            '#EXTINF:9.009,\n'
            '#EXT-X-BYTERANGE:500000@0\n'
            'combined.ts\n'
            '#EXT-X-ENDLIST\n';

        final mediaBaseUrl =
            'https://cdn.example.com/streams/720p/playlist.m3u8';
        final result = HlsParser.rewritePlaylist(
          content,
          mediaBaseUrl,
          proxyBaseUrl,
          token,
        );
        final lines = result.split('\n');

        // #EXT-X-BYTERANGE should be preserved
        expect(lines[3], '#EXT-X-BYTERANGE:500000@0');
        // The URI after byterange should be rewritten with the
        // segment-style `/seg<n>.ts` suffix.
        expect(
          lines[4],
          startsWith('$proxyBaseUrl/stream/$token/seg1.ts?url='),
        );
      });

      test('handles #EXT-X-MEDIA without URI attribute', () {
        const content =
            '#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc",NAME="English"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=2000000\n'
            '720p/playlist.m3u8\n';

        final result = HlsParser.rewritePlaylist(
          content,
          baseUrl,
          proxyBaseUrl,
          token,
        );

        // The #EXT-X-MEDIA line without URI should remain unchanged
        expect(
          result,
          contains(
            '#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc",NAME="English"',
          ),
        );
      });

      test('rewrites #EXT-X-KEY with relative URI', () {
        const content =
            '#EXTM3U\n'
            '#EXT-X-TARGETDURATION:10\n'
            '#EXT-X-KEY:METHOD=AES-128,URI="keys/enc.key"\n'
            '#EXTINF:9.009,\n'
            'segment000.ts\n'
            '#EXT-X-ENDLIST\n';

        final mediaBaseUrl =
            'https://cdn.example.com/streams/720p/playlist.m3u8';
        final result = HlsParser.rewritePlaylist(
          content,
          mediaBaseUrl,
          proxyBaseUrl,
          token,
        );

        expect(
          result,
          contains(
            Uri.encodeComponent(
              'https://cdn.example.com/streams/720p/keys/enc.key',
            ),
          ),
        );
      });

      test('handles empty lines gracefully', () {
        const content =
            '#EXTM3U\n'
            '\n'
            '#EXT-X-TARGETDURATION:10\n'
            '\n'
            '#EXTINF:9.009,\n'
            'segment000.ts\n'
            '\n'
            '#EXT-X-ENDLIST\n';

        final mediaBaseUrl =
            'https://cdn.example.com/streams/720p/playlist.m3u8';
        final result = HlsParser.rewritePlaylist(
          content,
          mediaBaseUrl,
          proxyBaseUrl,
          token,
        );

        // Should not throw and should contain a rewritten segment URL
        // — which now uses the `/seg<n>.ts` path-extension form.
        expect(result, contains('$proxyBaseUrl/stream/$token/seg1.ts?url='));
      });
    });

    group('RFC 8216 compliance', () {
      const proxyBaseUrl = 'http://192.168.1.5:8234';
      const token = 'tok';
      const base = 'http://cdn.example.com/hls/index.m3u8';

      test('a tag between #EXTINF and its URI does not orphan the segment', () {
        const playlist =
            '#EXTM3U\n#EXT-X-TARGETDURATION:6\n'
            '#EXTINF:6,\n#EXT-X-PROGRAM-DATE-TIME:2026-01-01T00:00:00Z\n'
            'seg1.ts\n'
            '#EXT-X-DISCONTINUITY\n#EXTINF:6,\n# a comment\nseg2.ts\n'
            '#EXT-X-ENDLIST\n';
        final rewritten = HlsParser.rewritePlaylist(
          playlist,
          base,
          proxyBaseUrl,
          token,
        );
        expect(
          rewritten,
          contains(
            '$proxyBaseUrl/stream/$token/seg1.ts?url='
            '${Uri.encodeComponent('http://cdn.example.com/hls/seg1.ts')}',
          ),
        );
        expect(rewritten, contains('$proxyBaseUrl/stream/$token/seg2.ts?url='));
        expect(rewritten.split('\n'), isNot(contains('seg1.ts')));
        expect(HlsParser.extractSegmentUrls(playlist, base), [
          'http://cdn.example.com/hls/seg1.ts',
          'http://cdn.example.com/hls/seg2.ts',
        ]);
      });

      test('data: and skd:// key URIs pass through untouched', () {
        const playlist =
            '#EXTM3U\n'
            '#EXT-X-KEY:METHOD=SAMPLE-AES,URI="data:text/plain;base64,AAAA",'
            'KEYFORMAT="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"\n'
            '#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://key42"\n'
            '#EXTINF:6,\nseg1.ts\n';
        final rewritten = HlsParser.rewritePlaylist(
          playlist,
          base,
          proxyBaseUrl,
          token,
        );
        expect(rewritten, contains('URI="data:text/plain;base64,AAAA"'));
        expect(rewritten, contains('URI="skd://key42"'));
      });

      test('Low-Latency HLS part, preload hint and report URIs are proxied', () {
        const playlist =
            '#EXTM3U\n'
            '#EXT-X-PART:DURATION=1.0,URI="part1.mp4"\n'
            '#EXT-X-PRELOAD-HINT:TYPE=PART,URI="part2.mp4"\n'
            '#EXT-X-RENDITION-REPORT:URI="../alt/index.m3u8",LAST-MSN=3\n';
        final rewritten = HlsParser.rewritePlaylist(
          playlist,
          base,
          proxyBaseUrl,
          token,
        );
        for (final upstream in [
          'http://cdn.example.com/hls/part1.mp4',
          'http://cdn.example.com/hls/part2.mp4',
          'http://cdn.example.com/alt/index.m3u8',
        ]) {
          expect(
            rewritten,
            contains(
              '$proxyBaseUrl/stream/$token?url=${Uri.encodeComponent(upstream)}',
            ),
          );
        }
      });

      test('absolute-path URIs keep IPv6 brackets and userinfo', () {
        expect(
          HlsParser.resolveUrl('/a.ts', 'http://[::1]:8080/x/index.m3u8'),
          'http://[::1]:8080/a.ts',
        );
        expect(
          HlsParser.resolveUrl('/a.ts', 'http://user@host/x/index.m3u8'),
          'http://user@host/a.ts',
        );
      });

      test('BANDWIDTH is not read from AVERAGE-BANDWIDTH', () {
        const master =
            '#EXTM3U\n'
            '#EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=100,BANDWIDTH=900,'
            'CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1920x1080\n'
            'hi.m3u8\n'
            '#EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=800,BANDWIDTH=200\n'
            'lo.m3u8\n';
        final variants = HlsParser.extractVariantStreams(master, base);
        expect(variants.first.url, 'http://cdn.example.com/hls/hi.m3u8');
        expect(variants.first.bandwidth, 900);
        expect(variants.first.codecs, 'avc1.640028,mp4a.40.2');
        expect(variants.first.resolution, '1920x1080');
      });

      test('EXT-X-BYTERANGE sub-ranges are reported with implicit offsets', () {
        const playlist =
            '#EXTM3U\n#EXT-X-VERSION:4\n'
            '#EXTINF:2,\n#EXT-X-BYTERANGE:188@0\nall.ts\n'
            '#EXTINF:2,\n#EXT-X-BYTERANGE:376\nall.ts\n'
            '#EXTINF:2,\n#EXT-X-BYTERANGE:188@1000\nall.ts\n'
            '#EXT-X-ENDLIST\n';
        final segments = HlsParser.extractMediaSegments(playlist, base);
        expect(segments.map((s) => s.rangeHeader), [
          'bytes=0-187',
          'bytes=188-563',
          'bytes=1000-1187',
        ]);
      });

      test('detects encrypted and fMP4 playlists', () {
        expect(
          HlsParser.isEncrypted('#EXT-X-KEY:METHOD=AES-128,URI="k"\n'),
          isTrue,
        );
        expect(HlsParser.isEncrypted('#EXT-X-KEY:METHOD=NONE\n'), isFalse);
        expect(
          HlsParser.hasInitializationSection('#EXT-X-MAP:URI="init.mp4"\n'),
          isTrue,
        );
      });

      test('segment path hints keep real media extensions', () {
        String rewrite(String playlist) =>
            HlsParser.rewritePlaylist(playlist, base, proxyBaseUrl, token);
        expect(
          rewrite('#EXTM3U\n#EXTINF:4,\na.m4s\n#EXTINF:4,\nb.aac\n'),
          allOf(
            contains('/stream/$token/seg1.m4s?url='),
            contains('/stream/$token/seg2.aac?url='),
          ),
        );
        // Obfuscated TS keeps the .ts hint the receiver's probe needs.
        expect(
          rewrite('#EXTM3U\n#EXTINF:4,\nframe001.jpg\n'),
          contains('/stream/$token/seg1.ts?url='),
        );
        // Obfuscated fMP4 gets an fMP4 hint instead.
        expect(
          rewrite(
            '#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:4,\nframe001.jpg\n',
          ),
          contains('/stream/$token/seg1.m4s?url='),
        );
      });

      test('attribute lists keep commas inside quoted strings', () {
        expect(
          HlsParser.parseAttributeList(
            'TYPE=AUDIO,GROUP-ID="a",NAME="English, Commentary",DEFAULT=YES',
          ),
          {
            'TYPE': 'AUDIO',
            'GROUP-ID': 'a',
            'NAME': 'English, Commentary',
            'DEFAULT': 'YES',
          },
        );
      });
    });
  });
}
