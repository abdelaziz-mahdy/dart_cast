// Generates the media fixtures that tool/tv_suite.dart casts to a real TV.
//
//     dart run tool/tv_fixtures.dart [--out=build/tv_fixtures] [--force]
//
// Needs ffmpeg on PATH. Every fixture is synthetic (test pattern + tone) and
// is built to hit specific spec-compliance fixes; see
// doc/specs/2026-11-15-spec-compliance-tv-test-plan.md for which case uses
// which file and why.
//
// Output (all under --out):
//   local.mp4            H.264 High / AAC, 180 s, 2 s GOP
//   local.ts             same, MPEG-TS
//   local_subs.mkv       local.mp4 + embedded SRT track
//   sidecar.srt          SRT with number-only lines, & and <, italics
//   sidecar_latin1.srt   Latin-1 encoded SRT ("Café", "Ñandú")
//   sidecar.vtt          WebVTT version of sidecar.srt
//   hls_ts/              TS VOD; tags placed between #EXTINF and its URI
//   hls_obf/             hls_ts with segments renamed to .jpg
//   hls_fmp4/            fMP4 / CMAF VOD (#EXT-X-MAP)
//   hls_single/          single-file VOD using #EXT-X-BYTERANGE
//   hls_alt/             video-only variant + separate audio rendition whose
//                        segments are 4 s against video's 6 s

import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final out = Directory(_option(args, 'out') ?? 'build/tv_fixtures').absolute;
  final force = args.contains('--force');
  await out.create(recursive: true);

  Future<void> step(String name, Future<void> Function() build) async {
    stdout.writeln('• $name');
    await build();
  }

  final mp4 = File('${out.path}/local.mp4');
  if (force || !mp4.existsSync()) {
    await step(
      'local.mp4',
      () => _ffmpeg([
        '-f',
        'lavfi',
        '-i',
        'testsrc=size=1280x720:rate=25',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:beep_factor=4:sample_rate=48000',
        '-t',
        '180',
        '-c:v',
        'libx264',
        '-profile:v',
        'high',
        '-pix_fmt',
        'yuv420p',
        '-g',
        '50',
        '-keyint_min',
        '50',
        '-sc_threshold',
        '0',
        '-c:a',
        'aac',
        '-b:a',
        '128k',
        '-ac',
        '2',
        '-movflags',
        '+faststart',
        mp4.path,
      ]),
    );
  }

  await step(
    'local.ts',
    () => _ffmpeg([
      '-i',
      mp4.path,
      '-c',
      'copy',
      '-f',
      'mpegts',
      '${out.path}/local.ts',
    ]),
  );

  await step('subtitles', () async {
    File('${out.path}/sidecar.srt').writeAsStringSync(_srt);
    File('${out.path}/sidecar.vtt').writeAsStringSync(_vtt);
    File(
      '${out.path}/sidecar_latin1.srt',
    ).writeAsBytesSync(latin1.encode(_srtLatin1));
  });

  await step(
    'local_subs.mkv',
    () => _ffmpeg([
      '-i',
      mp4.path,
      '-i',
      '${out.path}/sidecar.srt',
      '-map',
      '0',
      '-map',
      '1',
      '-c',
      'copy',
      '-c:s',
      'srt',
      '-metadata:s:s:0',
      'language=eng',
      '${out.path}/local_subs.mkv',
    ]),
  );

  await step('hls_ts', () async {
    final dir = await _clean('${out.path}/hls_ts');
    await _ffmpeg([
      '-i',
      mp4.path,
      '-c',
      'copy',
      '-f',
      'hls',
      '-hls_time',
      '6',
      '-hls_playlist_type',
      'vod',
      '-hls_segment_filename',
      '${dir.path}/seg%03d.ts',
      '${dir.path}/index.m3u8',
    ]);
    // RFC 8216 allows media segment tags and comments between #EXTINF and
    // the segment URI; the proxy used to lose the URI when one was there.
    final playlist = File('${dir.path}/index.m3u8');
    final lines = playlist.readAsLinesSync();
    final rewritten = <String>[];
    var minute = 0;
    for (final line in lines) {
      rewritten.add(line);
      if (line.startsWith('#EXTINF:')) {
        final second = (minute * 6) % 60;
        rewritten.add(
          '#EXT-X-PROGRAM-DATE-TIME:2026-01-01T00:'
          '${(minute * 6 ~/ 60).toString().padLeft(2, '0')}:'
          '${second.toString().padLeft(2, '0')}.000Z',
        );
        rewritten.add('# comment between EXTINF and its URI');
        minute++;
      }
    }
    playlist.writeAsStringSync('${rewritten.join('\n')}\n');
  });

  await step('hls_obf', () async {
    final dir = await _clean('${out.path}/hls_obf');
    final source = Directory('${out.path}/hls_ts');
    for (final f in source.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (name.endsWith('.ts')) {
        f.copySync('${dir.path}/${name.replaceAll('.ts', '.jpg')}');
      }
    }
    final playlist = File(
      '${source.path}/index.m3u8',
    ).readAsStringSync().replaceAll('.ts\n', '.jpg\n');
    File('${dir.path}/index.m3u8').writeAsStringSync(playlist);
  });

  await step('hls_fmp4', () async {
    final dir = await _clean('${out.path}/hls_fmp4');
    await _ffmpeg([
      '-i',
      mp4.path,
      '-c',
      'copy',
      '-f',
      'hls',
      '-hls_time',
      '6',
      '-hls_playlist_type',
      'vod',
      '-hls_segment_type',
      'fmp4',
      '-hls_fmp4_init_filename',
      'init.mp4',
      '-hls_segment_filename',
      '${dir.path}/seg%03d.m4s',
      '${dir.path}/index.m3u8',
    ]);
  });

  await step('hls_single', () async {
    final dir = await _clean('${out.path}/hls_single');
    await _ffmpeg([
      '-i',
      mp4.path,
      '-c',
      'copy',
      '-f',
      'hls',
      '-hls_time',
      '6',
      '-hls_playlist_type',
      'vod',
      '-hls_flags',
      'single_file',
      '-hls_segment_filename',
      '${dir.path}/all.ts',
      '${dir.path}/index.m3u8',
    ]);
  });

  await step('hls_alt', () async {
    final dir = await _clean('${out.path}/hls_alt');
    await Directory('${dir.path}/video').create();
    await Directory('${dir.path}/audio').create();
    await _ffmpeg([
      '-i',
      mp4.path,
      '-map',
      '0:v',
      '-c',
      'copy',
      '-f',
      'hls',
      '-hls_time',
      '6',
      '-hls_playlist_type',
      'vod',
      '-hls_segment_filename',
      '${dir.path}/video/v%03d.ts',
      '${dir.path}/video/index.m3u8',
    ]);
    await _ffmpeg([
      '-i',
      mp4.path,
      '-map',
      '0:a',
      '-c',
      'copy',
      '-f',
      'hls',
      '-hls_time',
      '4',
      '-hls_playlist_type',
      'vod',
      '-hls_segment_filename',
      '${dir.path}/audio/a%03d.ts',
      '${dir.path}/audio/index.m3u8',
    ]);
    File('${dir.path}/master.m3u8').writeAsStringSync(
      '#EXTM3U\n'
      '#EXT-X-VERSION:3\n'
      '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",'
      'DEFAULT=YES,AUTOSELECT=YES,URI="audio/index.m3u8"\n'
      '#EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=900000,BANDWIDTH=2500000,'
      'CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1280x720,AUDIO="aud"\n'
      'video/index.m3u8\n',
    );
  });

  stdout.writeln('\nFixtures ready in ${out.path}');
}

Future<Directory> _clean(String path) async {
  final dir = Directory(path);
  if (dir.existsSync()) await dir.delete(recursive: true);
  return dir.create(recursive: true);
}

Future<void> _ffmpeg(List<String> args) async {
  final result = await Process.run('ffmpeg', [
    '-hide_banner',
    '-loglevel',
    'error',
    '-y',
    ...args,
  ]);
  if (result.exitCode != 0) {
    stderr.writeln(result.stderr);
    throw ProcessException('ffmpeg', args, '${result.stderr}', result.exitCode);
  }
}

String? _option(List<String> args, String name) {
  for (final a in args) {
    if (a.startsWith('--$name=')) return a.substring(name.length + 3);
  }
  return null;
}

// Cue text is chosen to break the old SRT→VTT converter: a line that is only
// a number ("42", "1984") used to be deleted as a cue id, & and < were passed
// through unescaped, and a one-digit fraction ("0:00:20,5") was invalid VTT.
const _srt = '''1
00:00:02,000 --> 00:00:05,000
SUBTITLE 1 — the answer is

2
00:00:05,000 --> 00:00:08,000
42

3
00:00:08,000 --> 00:00:11,000
<i>Tom & Jerry</i> say 1 < 2

4
00:00:11,000 --> 00:00:14,000
1984

5
0:00:14,5 --> 0:00:18,25
Loose timestamp cue (14.5 s → 18.25 s)

6
00:00:18,000 --> 00:01:00,000
Long cue — subtitles still on screen

7
00:01:00,000 --> 00:03:00,000
After seek: subtitles still on screen
''';

const _vtt = '''WEBVTT

00:00:02.000 --> 00:00:05.000
SUBTITLE 1 — the answer is

00:00:05.000 --> 00:00:08.000
42

00:00:08.000 --> 00:00:11.000
<i>Tom &amp; Jerry</i> say 1 &lt; 2

00:00:11.000 --> 00:00:14.000
1984

00:00:14.500 --> 00:00:18.250
Loose timestamp cue (14.5 s → 18.25 s)

00:00:18.000 --> 00:01:00.000
Long cue — subtitles still on screen

00:01:00.000 --> 00:03:00.000
After seek: subtitles still on screen
''';

const _srtLatin1 = '''1
00:00:02,000 --> 00:01:00,000
Latin-1 file: Café, Ñandú, über

2
00:01:00,000 --> 00:03:00,000
Latin-1 after seek: Café
''';
