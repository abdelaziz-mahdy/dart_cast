import 'dart:convert';

import 'package:dart_cast/src/core/subtitle_converter.dart';
import 'package:test/test.dart';

void main() {
  group('SubtitleConverter.srtToVtt follows W3C WebVTT', () {
    test('a subtitle line that is only a number is kept', () {
      final vtt = SubtitleConverter.srtToVtt(
        '1\n00:00:01,000 --> 00:00:02,000\n42\n\n'
        '2\n00:00:03,000 --> 00:00:04,000\n1984\n',
      );
      expect(vtt, contains('\n42\n'));
      expect(vtt, contains('\n1984\n'));
      expect(vtt, isNot(contains('\n1\n')));
      expect(vtt, isNot(contains('\n2\n')));
    });

    test('loose timestamps become hh:mm:ss.ttt', () {
      final vtt = SubtitleConverter.srtToVtt(
        '1\n0:00:01,5 --> 0:00:02,25\nHi\n',
      );
      expect(vtt, contains('00:00:01.500 --> 00:00:02.250\n'));
    });

    test('positioning coordinates after the timing are dropped', () {
      final vtt = SubtitleConverter.srtToVtt(
        '1\n00:00:01,000 --> 00:00:02,000 X1:10 X2:20 Y1:30 Y2:40\nHi\n',
      );
      expect(vtt, contains('00:00:01.000 --> 00:00:02.000\n'));
    });

    test('CRLF line endings and a BOM are handled', () {
      final vtt = SubtitleConverter.srtToVtt(
        '﻿1\r\n00:00:01,000 --> 00:00:02,000\r\nHi\r\n\r\n'
        '2\r\n00:00:03,000 --> 00:00:04,000\r\nThere\r\n',
      );
      expect(vtt, startsWith('WEBVTT\n\n'));
      expect(vtt, isNot(contains('\r')));
      expect(vtt, contains('00:00:03.000 --> 00:00:04.000\nThere\n'));
    });

    test('cue text is escaped, keeping i/b/u and dropping other tags', () {
      final vtt = SubtitleConverter.srtToVtt(
        '1\n00:00:01,000 --> 00:00:02,000\n'
        '<i>Tom & Jerry</i> say 1 < 2 <font color="red">red</font>\n'
        r'{\an8}top'
        '\n'
        'a --> b\n',
      );
      expect(vtt, contains('<i>Tom &amp; Jerry</i> say 1 &lt; 2 red\n'));
      expect(vtt, contains('\ntop\n'));
      expect(vtt, contains('a --&gt; b\n'));
    });

    test('existing entities are not escaped twice', () {
      final vtt = SubtitleConverter.srtToVtt(
        '1\n00:00:01,000 --> 00:00:02,000\nA &amp; B\n',
      );
      expect(vtt, contains('A &amp; B\n'));
    });
  });

  group('SubtitleConverter.decodeText', () {
    test('falls back to Latin-1 for non-UTF-8 bytes', () {
      expect(SubtitleConverter.decodeText(latin1.encode('Café')), 'Café');
    });

    test('decodes UTF-16 with a byte-order mark', () {
      final le = [0xFF, 0xFE, 0x48, 0x00, 0x69, 0x00];
      final be = [0xFE, 0xFF, 0x00, 0x48, 0x00, 0x69];
      expect(SubtitleConverter.decodeText(le), 'Hi');
      expect(SubtitleConverter.decodeText(be), 'Hi');
    });

    test('drops a UTF-8 byte-order mark', () {
      expect(
        SubtitleConverter.decodeText([0xEF, 0xBB, 0xBF, ...utf8.encode('x')]),
        'x',
      );
    });
  });

  test('isSrt recognises an SRT without cue numbers', () {
    expect(
      SubtitleConverter.isSrt('00:00:01,000 --> 00:00:02,000\nHi\n'),
      isTrue,
    );
    expect(SubtitleConverter.isSrt('WEBVTT\n\n'), isFalse);
  });
}
