import 'dart:io';

import 'package:dart_cast/src/core/media_proxy.dart';
import 'package:dart_cast/src/core/subtitle_converter.dart';
import 'package:test/test.dart';

void main() {
  group('SubtitleConverter', () {
    group('srtToVtt', () {
      test('converts SRT timestamps to VTT format', () {
        const srt = '1\n'
            '00:00:01,000 --> 00:00:04,000\n'
            'Hello world\n'
            '\n'
            '2\n'
            '00:01:30,500 --> 00:01:35,250\n'
            'Second subtitle\n';

        final vtt = SubtitleConverter.srtToVtt(srt);

        expect(vtt, startsWith('WEBVTT\n\n'));
        expect(vtt, contains('00:00:01.000 --> 00:00:04.000'));
        expect(vtt, contains('00:01:30.500 --> 00:01:35.250'));
        expect(vtt, contains('Hello world'));
        expect(vtt, contains('Second subtitle'));
        // Sequence numbers should be stripped
        expect(vtt, isNot(matches(RegExp(r'^\d+\n', multiLine: true))));
      });

      test('produces valid VTT header', () {
        const srt = '1\n'
            '00:00:00,000 --> 00:00:01,000\n'
            'Test\n';

        final vtt = SubtitleConverter.srtToVtt(srt);
        expect(vtt, startsWith('WEBVTT\n\n'));
      });

      test('handles empty input', () {
        final vtt = SubtitleConverter.srtToVtt('');
        expect(vtt, startsWith('WEBVTT'));
      });

      test('preserves multi-line subtitle text', () {
        const srt = '1\n'
            '00:00:01,000 --> 00:00:04,000\n'
            'Line one\n'
            'Line two\n';

        final vtt = SubtitleConverter.srtToVtt(srt);
        expect(vtt, contains('Line one'));
        expect(vtt, contains('Line two'));
      });
    });

    group('vttToSrt', () {
      test('converts VTT to SRT format', () {
        const vtt = 'WEBVTT\n\n'
            '00:00:01.000 --> 00:00:04.000\n'
            'Hello world\n'
            '\n'
            '00:01:30.500 --> 00:01:35.250\n'
            'Second subtitle\n';

        final srt = SubtitleConverter.vttToSrt(vtt);

        expect(srt, contains('1\n00:00:01,000 --> 00:00:04,000'));
        expect(srt, contains('2\n00:01:30,500 --> 00:01:35,250'));
        expect(srt, contains('Hello world'));
        expect(srt, contains('Second subtitle'));
        expect(srt, isNot(contains('WEBVTT')));
      });

      test('strips X-TIMESTAMP-MAP from VTT', () {
        const vtt = 'WEBVTT\n'
            'X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n'
            '00:00:01.000 --> 00:00:04.000\n'
            'Test\n';

        final srt = SubtitleConverter.vttToSrt(vtt);
        expect(srt, isNot(contains('TIMESTAMP')));
        expect(srt, contains('Test'));
      });

      test('handles 2-component MM:SS.mmm timestamps', () {
        const vtt = 'WEBVTT\n\n'
            '01:30.500 --> 01:35.250\n'
            'Short timestamp\n';

        final srt = SubtitleConverter.vttToSrt(vtt);

        expect(srt, contains('00:01:30,500 --> 00:01:35,250'));
        expect(srt, contains('Short timestamp'));
      });

      test('adds sequence numbers', () {
        const vtt = 'WEBVTT\n\n'
            '00:00:01.000 --> 00:00:02.000\n'
            'First\n'
            '\n'
            '00:00:03.000 --> 00:00:04.000\n'
            'Second\n';

        final srt = SubtitleConverter.vttToSrt(vtt);
        expect(srt, contains('1\n'));
        expect(srt, contains('2\n'));
      });
    });

    group('toAss', () {
      test('generates valid ASS header', () {
        const vtt = 'WEBVTT\n\n'
            '00:00:01.000 --> 00:00:04.000\n'
            'Hello\n';

        final ass = SubtitleConverter.toAss(vtt);
        expect(ass, contains('[Script Info]'));
        expect(ass, contains('[V4+ Styles]'));
        expect(ass, contains('[Events]'));
        expect(ass, contains('Style: Default'));
      });

      test('converts VTT cues to ASS dialogues', () {
        const vtt = 'WEBVTT\n\n'
            '00:00:25.250 --> 00:00:32.210\n'
            'Hello world\n';

        final ass = SubtitleConverter.toAss(vtt);
        expect(ass, contains('Dialogue:'));
        expect(ass, contains('Hello world'));
        expect(ass, contains('0:00:25'));
        expect(ass, contains('0:00:32'));
      });

      test('converts SRT input to ASS', () {
        const srt = '1\n'
            '00:00:01,000 --> 00:00:04,000\n'
            'From SRT\n';

        final ass = SubtitleConverter.toAss(srt);
        expect(ass, contains('Dialogue:'));
        expect(ass, contains('From SRT'));
      });

      test('respects custom fontSize', () {
        const vtt = 'WEBVTT\n\n'
            '00:00:01.000 --> 00:00:02.000\n'
            'Test\n';

        final ass = SubtitleConverter.toAss(vtt, fontSize: 36);
        expect(ass, contains(',36,'));
      });
    });

    group('isSrt', () {
      test('detects SRT format', () {
        const srt = '1\n'
            '00:00:01,000 --> 00:00:04,000\n'
            'Hello\n';
        expect(SubtitleConverter.isSrt(srt), isTrue);
      });

      test('detects SRT with leading whitespace', () {
        const srt = '  1\n'
            '00:00:01,000 --> 00:00:04,000\n'
            'Hello\n';
        expect(SubtitleConverter.isSrt(srt), isTrue);
      });

      test('returns false for VTT content', () {
        const vtt = 'WEBVTT\n\n'
            '00:00:01.000 --> 00:00:04.000\n'
            'Hello\n';
        expect(SubtitleConverter.isSrt(vtt), isFalse);
      });

      test('returns false for empty content', () {
        expect(SubtitleConverter.isSrt(''), isFalse);
      });

      test('returns false for random text', () {
        expect(SubtitleConverter.isSrt('Hello world'), isFalse);
      });
    });
  });

  group('MediaProxy.registerSubtitle', () {
    late MediaProxy proxy;

    setUp(() async {
      proxy = MediaProxy();
      await proxy.start();
    });

    tearDown(() async {
      await proxy.stop();
    });

    test('handles file:// URLs by registering as local file', () {
      final url = proxy.registerSubtitle('file:///tmp/test.vtt');
      expect(url, contains('/file/'));
    });

    test('handles http:// URLs by registering as remote media', () {
      final url = proxy.registerSubtitle('http://example.com/subtitle.vtt');
      expect(url, contains('/stream/'));
    });

    test('handles https:// URLs by registering as remote media', () {
      final url = proxy.registerSubtitle('https://example.com/subtitle.srt');
      expect(url, contains('/stream/'));
    });
  });

  group('SRT-to-VTT auto-conversion via proxy', () {
    late MediaProxy proxy;

    setUp(() async {
      proxy = MediaProxy();
      await proxy.start();
    });

    tearDown(() async {
      await proxy.stop();
    });

    test('auto-converts local SRT file to VTT when served', () async {
      // Create a temporary SRT file
      final tempDir =
          await Directory.systemTemp.createTemp('subtitle_proxy_test');
      final srtFile = File('${tempDir.path}/test.srt');
      await srtFile.writeAsString(
        '1\n'
        '00:00:01,000 --> 00:00:04,000\n'
        'Hello world\n'
        '\n'
        '2\n'
        '00:00:05,500 --> 00:00:08,200\n'
        'Second line\n',
      );

      try {
        final proxyUrl = proxy.registerFile(srtFile.path);

        final client = HttpClient();
        try {
          final request = await client.getUrl(Uri.parse(proxyUrl));
          final response = await request.close();
          expect(response.statusCode, HttpStatus.ok);

          final body =
              await response.transform(SystemEncoding().decoder).join();

          // Should be converted to VTT
          expect(body, startsWith('WEBVTT'));
          expect(body, contains('00:00:01.000 --> 00:00:04.000'));
          expect(body, contains('Hello world'));
          expect(body, contains('00:00:05.500 --> 00:00:08.200'));

          // Content-Type should be text/vtt
          expect(
            response.headers.contentType.toString(),
            contains('vtt'),
          );
        } finally {
          client.close();
        }
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('serves VTT files without conversion', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('subtitle_proxy_vtt');
      final vttFile = File('${tempDir.path}/test.vtt');
      await vttFile.writeAsString(
        'WEBVTT\n\n'
        '00:00:01.000 --> 00:00:04.000\n'
        'Hello world\n',
      );

      try {
        final proxyUrl = proxy.registerFile(vttFile.path);

        final client = HttpClient();
        try {
          final request = await client.getUrl(Uri.parse(proxyUrl));
          final response = await request.close();
          expect(response.statusCode, HttpStatus.ok);

          final body =
              await response.transform(SystemEncoding().decoder).join();
          // Should pass through unchanged (still starts with WEBVTT)
          expect(body, startsWith('WEBVTT'));
          expect(body, contains('00:00:01.000 --> 00:00:04.000'));
        } finally {
          client.close();
        }
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('auto-converts remote SRT to VTT', () async {
      // Create an upstream server that serves SRT content
      final upstreamServer =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final upstreamBaseUrl = 'http://127.0.0.1:${upstreamServer.port}';

      upstreamServer.listen((request) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType =
            ContentType('application', 'x-subrip');
        request.response.write(
          '1\n'
          '00:00:01,000 --> 00:00:04,000\n'
          'Remote subtitle\n',
        );
        await request.response.close();
      });

      try {
        final proxyUrl = proxy.registerMedia('$upstreamBaseUrl/subtitle.srt');

        final client = HttpClient();
        try {
          final request = await client.getUrl(Uri.parse(proxyUrl));
          final response = await request.close();
          expect(response.statusCode, HttpStatus.ok);

          final body =
              await response.transform(SystemEncoding().decoder).join();

          // Should be converted to VTT
          expect(body, startsWith('WEBVTT'));
          expect(body, contains('00:00:01.000 --> 00:00:04.000'));
          expect(body, contains('Remote subtitle'));

          // Content-Type should be text/vtt
          expect(
            response.headers.contentType.toString(),
            contains('vtt'),
          );
        } finally {
          client.close();
        }
      } finally {
        await upstreamServer.close(force: true);
      }
    });

    test('registerSubtitle with file:// serves SRT as VTT', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('subtitle_reg_test');
      final srtFile = File('${tempDir.path}/cast_sub.srt');
      await srtFile.writeAsString(
        '1\n'
        '00:02:10,300 --> 00:02:14,700\n'
        'Roundtrip test\n',
      );

      try {
        final proxyUrl = proxy.registerSubtitle('file://${srtFile.path}');

        final client = HttpClient();
        try {
          final request = await client.getUrl(Uri.parse(proxyUrl));
          final response = await request.close();
          expect(response.statusCode, HttpStatus.ok);

          final body =
              await response.transform(SystemEncoding().decoder).join();

          expect(body, startsWith('WEBVTT'));
          expect(body, contains('00:02:10.300 --> 00:02:14.700'));
          expect(body, contains('Roundtrip test'));
        } finally {
          client.close();
        }
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });
}
