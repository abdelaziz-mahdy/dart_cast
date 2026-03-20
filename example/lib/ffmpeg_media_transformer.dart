/// A [MediaTransformer] that remuxes local MPEG-TS files to MP4 using ffmpeg
/// before casting.
///
/// ## Why remux?
///
/// Chromecast's Default Media Receiver cannot play raw `.ts` files — its TS
/// demuxer only exists for HLS segment processing. Remuxing to MP4 (no
/// re-encoding) takes ~3-5 seconds for a 24-minute episode and produces a
/// file natively supported by Chromecast, DLNA, and AirPlay.
///
/// ## Usage
///
/// ```dart
/// // For Chromecast (remux only):
/// final session = ChromecastSession(
///   device: device,
///   mediaTransformer: FfmpegMediaTransformer(),
/// );
///
/// // For DLNA (remux + embed subtitles for TV compatibility):
/// final session = DlnaSession.fromDevice(device);
/// // Pass embedSubtitles: true and the transformer creates a temp MP4
/// // with subtitles baked in, so all TVs can display them.
/// ```
///
/// ## Platform requirements
///
/// - **Windows / Linux / macOS:** Requires `ffmpeg` on the system PATH.
///   Install via your package manager (e.g., `brew install ffmpeg`,
///   `apt install ffmpeg`, `choco install ffmpeg`).
///
/// - **Android / iOS (Flutter):** `Process.run` is not available. Swap
///   [FfmpegRemuxer] internals to use `FFmpegKit.execute` from the
///   `ffmpeg_kit_flutter_new` package instead.
library;

import 'dart:io';

import 'package:dart_cast/dart_cast.dart';
import 'package:path/path.dart' as p;

/// Callback invoked with a progress message during remux.
typedef RemuxProgressCallback = void Function(String message);

/// Utility that remuxes MPEG-TS files to MP4 using the system `ffmpeg` binary.
///
/// Supports optional subtitle embedding for DLNA compatibility — when a
/// subtitle file is provided, it's muxed into the MP4 as a mov_text track
/// so all TVs can display it without vendor-specific extensions.
class FfmpegRemuxer {
  /// Remuxes a TS file to MP4 using ffmpeg.
  ///
  /// Returns the output path on success, `null` on failure.
  /// Cleans up partial output on failure.
  ///
  /// If [subtitlePath] is provided, the subtitle is embedded in the MP4
  /// using the mov_text codec (MP4's native subtitle format). This gives
  /// maximum DLNA TV compatibility.
  static Future<String?> remuxToMp4(
    String inputPath, {
    String? outputPath,
    String? subtitlePath,
    void Function(String message)? onProgress,
  }) async {
    final mp4Path = outputPath ?? p.setExtension(inputPath, '.mp4');
    final stopwatch = Stopwatch()..start();
    final hasSubs = subtitlePath != null && File(subtitlePath).existsSync();

    onProgress?.call(
        'Remuxing ${p.basename(inputPath)} → .mp4${hasSubs ? ' (with subs)' : ''}');

    try {
      final result = await Process.run('ffmpeg', [
        '-fflags', '+genpts',
        '-i', inputPath,
        if (hasSubs) ...['-i', subtitlePath],
        '-map', '0',
        if (hasSubs) ...['-map', '1'],
        '-map', '-0:d',
        '-c', 'copy',
        if (hasSubs) ...['-c:s', 'mov_text'],
        '-movflags', '+faststart',
        '-y',
        mp4Path,
      ]);

      stopwatch.stop();

      if (result.exitCode == 0) {
        final elapsed =
            (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1);
        onProgress?.call('Remux complete (${elapsed}s)');
        return mp4Path;
      }

      final lastLine = result.stderr.toString().split('\n').last;
      onProgress?.call('Remux failed (exit ${result.exitCode}): $lastLine');
      _deletePartial(mp4Path);
      return null;
    } catch (e) {
      onProgress?.call('Remux failed: $e');
      _deletePartial(mp4Path);
      return null;
    }
  }

  /// Deletes a partial output file if it exists.
  static void _deletePartial(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (_) {
      // Best-effort cleanup; ignore errors.
    }
  }
}

/// A [MediaTransformer] that remuxes local MPEG-TS files to MP4 via ffmpeg.
///
/// Extends [DefaultMediaTransformer] so remote URLs and non-TS local files
/// pass through unchanged. Only local `.ts` files trigger the remux path.
///
/// ## DLNA subtitle embedding
///
/// Set [embedSubtitles] to `true` when casting to DLNA. The transformer will:
/// 1. Look for a subtitle file (.srt/.vtt) next to the video
/// 2. Create a temp MP4 with the subtitle embedded as a mov_text track
/// 3. Serve the temp file instead of the original
///
/// This is necessary because DLNA has no standard for external subtitles —
/// embedding them in the container is the most reliable approach.
class FfmpegMediaTransformer extends DefaultMediaTransformer {
  /// Optional callback invoked with progress messages during remux.
  final RemuxProgressCallback? onProgress;

  /// Whether to embed subtitle files into the MP4 during remux.
  ///
  /// Set to `true` for DLNA targets where external subtitle delivery
  /// is unreliable. Creates a temp file with subs baked in.
  /// Set to `false` (default) for Chromecast which handles sidecar VTT.
  final bool embedSubtitles;

  /// Creates an [FfmpegMediaTransformer].
  FfmpegMediaTransformer({
    super.wrapRemoteTs = true,
    this.onProgress,
    this.embedSubtitles = false,
  });

  @override
  Future<TransformedMedia> transform(
    CastMedia media,
    MediaProxy proxy,
  ) async {
    if (!media.isLocalFile || media.type != CastMediaType.mpegTs) {
      return super.transform(media, proxy);
    }

    final mp4Path = p.setExtension(media.url, '.mp4');
    final mp4File = File(mp4Path);

    // Find subtitle to embed (only for DLNA)
    String? subtitlePath;
    if (embedSubtitles && media.subtitles.isNotEmpty) {
      final subUrl = media.subtitles.first.url;
      // Handle file:// URLs
      subtitlePath = subUrl.startsWith('file://')
          ? subUrl.replaceFirst('file://', '')
          : subUrl;
      if (!File(subtitlePath).existsSync()) {
        subtitlePath = null;
      }
    }

    // If we need to embed subs, always create a temp file (don't reuse
    // the permanent MP4 which may not have subs embedded)
    if (embedSubtitles && subtitlePath != null) {
      final tempDir = await Directory.systemTemp.createTemp('dart_cast_');
      final tempMp4 = '${tempDir.path}/cast_with_subs.mp4';

      // Use the existing MP4 as input if available, otherwise the TS
      final inputPath = mp4File.existsSync() ? mp4Path : media.url;

      final result = await FfmpegRemuxer.remuxToMp4(
        inputPath,
        outputPath: tempMp4,
        subtitlePath: subtitlePath,
        onProgress: onProgress,
      );

      if (result != null) {
        final url = proxy.registerFile(result);
        return TransformedMedia(
            proxyUrl: url, effectiveType: CastMediaType.mp4);
      }
      // Subtitle embedding failed — fall through to normal remux
      onProgress?.call('Subtitle embedding failed, casting without subs');
    }

    // Normal remux (no subtitle embedding)
    if (!mp4File.existsSync()) {
      final result = await FfmpegRemuxer.remuxToMp4(
        media.url,
        outputPath: mp4Path,
        onProgress: onProgress,
      );

      if (result == null) {
        onProgress?.call('Remux failed, falling back to .ts');
        return super.transform(media, proxy);
      }
    }

    final proxyUrl = proxy.registerFile(mp4Path);
    return TransformedMedia(
      proxyUrl: proxyUrl,
      effectiveType: CastMediaType.mp4,
    );
  }
}
