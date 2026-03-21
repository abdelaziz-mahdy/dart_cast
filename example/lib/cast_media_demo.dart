import 'package:dart_cast/dart_cast.dart';

/// Provides sample media items for testing cast functionality.
///
/// These are publicly available test streams. Replace with your own
/// media URLs for production use.
class CastMediaDemo {
  CastMediaDemo._();

  /// Sample HLS stream (Big Buck Bunny) — no subtitles.
  static const hlsStream = CastMedia(
    url: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
    type: CastMediaType.hls,
    title: 'Big Buck Bunny (HLS)',
    imageUrl:
        'https://upload.wikimedia.org/wikipedia/commons/thumb/c/c5/Big_buck_bunny_poster_big.jpg/220px-Big_buck_bunny_poster_big.jpg',
  );

  /// Sample HLS stream (Tears of Steel) — no subtitles.
  static const hlsTearsOfSteel = CastMedia(
    url:
        'https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8',
    type: CastMediaType.hls,
    title: 'Tears of Steel (HLS)',
    imageUrl:
        'https://upload.wikimedia.org/wikipedia/commons/thumb/6/6d/Tears_of_Steel_poster.jpg/220px-Tears_of_Steel_poster.jpg',
  );

  /// Sample MP4 video (Elephants Dream) — no subtitles.
  static const mp4Video = CastMedia(
    url:
        'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4',
    type: CastMediaType.mp4,
    title: 'Elephants Dream (MP4)',
    imageUrl:
        'https://upload.wikimedia.org/wikipedia/commons/thumb/e/e8/Elephants_Dream_s5_both.jpg/220px-Elephants_Dream_s5_both.jpg',
  );

  /// Sample MP4 video (Tears of Steel) — with subtitles.
  ///
  /// Demonstrates how to attach [CastSubtitle] entries to a media item.
  /// The subtitle URLs below are publicly hosted VTT files from the
  /// Blender Foundation.
  static const mp4TearsOfSteel = CastMedia(
    url:
        'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/TearsOfSteel.mp4',
    type: CastMediaType.mp4,
    title: 'Tears of Steel (MP4 + Subs)',
    imageUrl:
        'https://upload.wikimedia.org/wikipedia/commons/thumb/6/6d/Tears_of_Steel_poster.jpg/220px-Tears_of_Steel_poster.jpg',
    subtitles: [
      CastSubtitle(
        url:
            'https://raw.githubusercontent.com/nicmart/subtitle-sample/master/tears-of-steel-en.vtt',
        label: 'English',
        language: 'en',
        format: 'vtt',
      ),
      CastSubtitle(
        url:
            'https://raw.githubusercontent.com/nicmart/subtitle-sample/master/tears-of-steel-es.vtt',
        label: 'Spanish',
        language: 'es',
        format: 'vtt',
      ),
    ],
  );

  /// Sample MKV with embedded subtitles — demonstrates the MKV container
  /// support added in dart_cast 0.4.0.
  ///
  /// When casting a local file via DLNA with subtitles, the recommended
  /// approach is to remux to MKV with an embedded SRT track. DLNA TVs
  /// handle embedded MKV subtitles more reliably than external sidecar files.
  ///
  /// For this demo we use a remote MP4 URL — in a real app you'd use
  /// [CastMedia.file] with a local MKV path:
  ///
  /// ```dart
  /// CastMedia.file(
  ///   filePath: '/path/to/video.mkv',
  ///   type: CastMediaType.mkv,
  ///   title: 'My Video (MKV + embedded subs)',
  /// )
  /// ```
  static const mkvWithEmbeddedSubs = CastMedia(
    url:
        'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/TearsOfSteel.mp4',
    type: CastMediaType.mkv,
    title: 'Tears of Steel (MKV demo)',
    imageUrl:
        'https://upload.wikimedia.org/wikipedia/commons/thumb/6/6d/Tears_of_Steel_poster.jpg/220px-Tears_of_Steel_poster.jpg',
  );

  /// All available sample media items.
  static const List<CastMedia> allMedia = [
    hlsStream,
    hlsTearsOfSteel,
    mp4Video,
    mp4TearsOfSteel,
    mkvWithEmbeddedSubs,
  ];
}
