import 'dart:io';

import 'package:dart_cast/src/core/hls_alt_audio_proxy.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late String origin;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final path = request.uri.path;
      final response = request.response;
      switch (path) {
        case '/a/master.m3u8':
          // CDN-style redirect: relative URIs in the master must resolve
          // against /b/, where the playlist actually lives.
          response.redirect(Uri.parse('$origin/b/master.m3u8'));
          return;
        case '/b/master.m3u8':
          response.write(
            '#EXTM3U\n'
            // An I-frame playlist and a low variant come first, each with
            // CODECS that do not describe the variant that gets picked.
            '#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=90000,'
            'CODECS="avc1.42e01e",URI="iframe.m3u8"\n'
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",'
            'DEFAULT=YES,URI="audio/en.m3u8"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=500000,CODECS="avc1.42e01e,'
            'mp4a.40.2",RESOLUTION=640x360,AUDIO="aud"\n'
            'video/low.m3u8\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=5000000,CODECS="avc1.640028,'
            'mp4a.40.2",RESOLUTION=1920x1080,AUDIO="aud"\n'
            'video/high.m3u8\n',
          );
        case '/b/video/high.m3u8':
          response.write(
            '#EXTM3U\n#EXT-X-TARGETDURATION:6\n'
            '#EXTINF:6.0,\nv1.ts\n#EXT-X-ENDLIST\n',
          );
        case '/b/audio/en.m3u8':
          response.write(
            '#EXTM3U\n#EXT-X-TARGETDURATION:6\n'
            '#EXTINF:6.0,\na1.aac\n#EXT-X-ENDLIST\n',
          );
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('takes CODECS and RESOLUTION from the picked variant and resolves '
      'URIs against the post-redirect playlist URL', () async {
    final planner = HlsAltAudioPlanner();
    addTearDown(planner.close);

    final plan = await planner.plan(
      masterUrl: '$origin/a/master.m3u8',
      headers: const {},
    );

    expect(plan, isNotNull);
    expect(plan!.codecs, 'avc1.640028,mp4a.40.2');
    expect(plan.resolution, '1920x1080');
    expect(plan.bandwidth, 5000000);
    expect(plan.segments.single.videoUrl, '$origin/b/video/v1.ts');
    expect(plan.segments.single.audioUrl, '$origin/b/audio/a1.aac');
  });
}
