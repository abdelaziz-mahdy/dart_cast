/// Media type for casting.
enum CastMediaType {
  /// HTTP Live Streaming (m3u8 playlist with TS/fMP4 segments).
  hls,

  /// MP4 container (H.264/AAC). Best Chromecast compatibility.
  mp4,

  /// Matroska container. Supports embedded SRT/ASS subtitle tracks.
  /// Recommended for DLNA casting with subtitles.
  mkv,

  /// Raw MPEG Transport Stream.
  mpegTs,
}

/// Represents a subtitle track for cast media.
class CastSubtitle {
  /// URL of the subtitle file.
  final String url;

  /// Human-readable label (e.g., "English").
  final String label;

  /// Language code (e.g., "en").
  final String language;

  /// Subtitle format (e.g., "vtt", "srt").
  final String format;

  /// Creates a [CastSubtitle].
  const CastSubtitle({
    required this.url,
    required this.label,
    required this.language,
    required this.format,
  });
}

/// Represents media to be cast to a device.
class CastMedia {
  /// URL of the media content (HTTP URL or local file path).
  ///
  /// For local files, [isLocalFile] will be `true` and the URL will be
  /// the absolute file path without any `file://` prefix.
  final String url;

  /// Type of the media content.
  final CastMediaType type;

  /// Whether this media is a local file (vs. a remote HTTP URL).
  final bool isLocalFile;

  /// HTTP headers to include when fetching the media (remote URLs only).
  final Map<String, String> httpHeaders;

  /// Optional title for the media.
  final String? title;

  /// Optional image/thumbnail URL.
  final String? imageUrl;

  /// Optional start position for playback.
  final Duration? startPosition;

  /// Optional known duration of the media.
  ///
  /// For local files, providing this enables accurate HLS segment splitting
  /// so the cast device reports correct playback progress.
  final Duration? duration;

  /// Subtitle tracks for this media.
  final List<CastSubtitle> subtitles;

  /// Creates a [CastMedia] for a remote URL.
  const CastMedia({
    required this.url,
    required this.type,
    this.httpHeaders = const {},
    this.title,
    this.imageUrl,
    this.startPosition,
    this.duration,
    this.subtitles = const [],
  }) : isLocalFile = false;

  /// Creates a [CastMedia] for a local file.
  ///
  /// [filePath] should be the absolute path to the file (e.g., `/path/to/video.ts`).
  /// [duration] should be provided if known — it enables accurate HLS segmentation.
  /// The proxy will serve it over HTTP so the cast device can access it.
  const CastMedia.file({
    required String filePath,
    required this.type,
    this.title,
    this.imageUrl,
    this.startPosition,
    this.duration,
    this.subtitles = const [],
  })  : url = filePath,
        isLocalFile = true,
        httpHeaders = const {};
}
