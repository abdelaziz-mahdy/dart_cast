/// A [MediaTransformer] that remuxes local files using ffmpeg before casting.
///
/// ## Why remux?
///
/// Chromecast's Default Media Receiver cannot play raw `.ts` files — its TS
/// demuxer only exists for HLS segment processing. Remuxing to MP4 (no
/// re-encoding) takes ~3-5 seconds for a 24-minute episode and produces a
/// file natively supported by Chromecast, DLNA, and AirPlay.
///
/// ## MKV with embedded subtitles (DLNA)
///
/// For DLNA casting with subtitles, the recommended approach in dart_cast 0.4.0
/// is to remux to MKV with an embedded SRT track. DLNA TVs handle MKV-embedded
/// subtitles more reliably than external sidecar files. Use [FfmpegRemuxer.remuxToMkv]
/// or set [FfmpegMediaTransformer.embedSubtitles] to `true`.
///
/// ## Usage
///
/// ```dart
/// // For Chromecast (remux TS → MP4):
/// final session = ChromecastSession(
///   device: device,
///   mediaTransformer: FfmpegMediaTransformer(),
/// );
///
/// // For DLNA with subtitles (remux → MKV with embedded SRT):
/// final session = DlnaSession.fromDevice(device);
/// // The transformer creates a temp MKV with subtitles baked in.
/// ```
///
/// ## HTTP/1.0 file serving
///
/// dart_cast 0.4.0 automatically uses HTTP/1.0 for DLNA file serving.
/// Some DLNA renderers (e.g., TCL Google TV) reject HTTP/1.1 responses.
/// This is handled transparently — no code changes needed.
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

  /// Remuxes a video file to MKV with an embedded SRT subtitle track.
  ///
  /// This is the recommended approach for DLNA casting with subtitles
  /// (dart_cast 0.4.0+). MKV containers support SRT natively, and DLNA
  /// TVs render embedded MKV subtitles more reliably than external files.
  ///
  /// [subtitlePath] must be an SRT file. Use [SubtitleConverter.vttToSrt]
  /// to convert VTT subtitles first.
  ///
  /// Returns the output path on success, `null` on failure.
  static Future<String?> remuxToMkv(
    String inputPath, {
    required String subtitlePath,
    String? outputPath,
    void Function(String message)? onProgress,
  }) async {
    final mkvPath = outputPath ?? p.setExtension(inputPath, '.mkv');
    final stopwatch = Stopwatch()..start();

    onProgress?.call(
        'Remuxing ${p.basename(inputPath)} → .mkv (with embedded SRT)');

    try {
      final result = await Process.run('ffmpeg', [
        '-fflags', '+genpts',
        '-i', inputPath,
        '-i', subtitlePath,
        '-map', '0:v', '-map', '0:a', '-map', '1:0',
        '-c:v', 'copy',
        '-c:a', 'copy',
        '-c:s', 'srt', // MKV supports SRT natively
        '-y',
        mkvPath,
      ]);

      stopwatch.stop();

      if (result.exitCode == 0) {
        final elapsed =
            (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1);
        onProgress?.call('MKV remux complete (${elapsed}s)');
        return mkvPath;
      }

      final lastLine = result.stderr.toString().split('\n').last;
      onProgress?.call('MKV remux failed (exit ${result.exitCode}): $lastLine');
      _deletePartial(mkvPath);
      return null;
    } catch (e) {
      onProgress?.call('MKV remux failed: $e');
      _deletePartial(mkvPath);
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

/// A [MediaTransformer] that remuxes local MPEG-TS files via ffmpeg.
///
/// Extends [DefaultMediaTransformer] so remote URLs and non-TS local files
/// pass through unchanged. Only local `.ts` files trigger the remux path.
///
/// ## DLNA subtitle embedding (MKV approach — 0.4.0)
///
/// Set [embedSubtitles] to `true` when casting to DLNA. The transformer will:
/// 1. Look for a subtitle file (.srt/.vtt) next to the video
/// 2. Convert VTT to SRT if needed (using [SubtitleConverter.vttToSrt])
/// 3. Create a temp MKV with the subtitle embedded as an SRT track
/// 4. Serve the MKV via the proxy (HTTP/1.0 is used automatically for DLNA)
///
/// MKV is preferred over MP4 for DLNA subtitle embedding because MKV
/// supports SRT natively, while MP4 requires mov_text conversion which
/// some TVs don't support. See [FfmpegRemuxer.remuxToMkv].
class FfmpegMediaTransformer extends DefaultMediaTransformer {
  /// Optional callback invoked with progress messages during remux.
  final RemuxProgressCallback? onProgress;

  /// Whether to embed subtitle files into the container during remux.
  ///
  /// Set to `true` for DLNA targets where external subtitle delivery
  /// is unreliable. Creates a temp MKV with SRT subs baked in.
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

    // If we need to embed subs, remux to MKV with embedded SRT track.
    // MKV supports SRT natively — more reliable on DLNA TVs than MP4's
    // mov_text. VTT subtitles are converted to SRT first.
    if (embedSubtitles && subtitlePath != null) {
      final tempDir = await Directory.systemTemp.createTemp('dart_cast_');

      // Convert VTT → SRT if needed (MKV embeds SRT natively)
      String srtPath = subtitlePath;
      final subContent = File(subtitlePath).readAsStringSync();
      if (subContent.trimLeft().startsWith('WEBVTT')) {
        srtPath = '${tempDir.path}/subtitle.srt';
        File(srtPath).writeAsStringSync(SubtitleConverter.vttToSrt(subContent));
        onProgress?.call('Converted VTT → SRT for MKV embedding');
      }

      final tempMkv = '${tempDir.path}/cast_with_subs.mkv';

      // Use the existing MP4 as input if available, otherwise the TS
      final inputPath = mp4File.existsSync() ? mp4Path : media.url;

      final result = await FfmpegRemuxer.remuxToMkv(
        inputPath,
        subtitlePath: srtPath,
        outputPath: tempMkv,
        onProgress: onProgress,
      );

      if (result != null) {
        final url = proxy.registerFile(result);
        return TransformedMedia(
            proxyUrl: url, effectiveType: CastMediaType.mkv);
      }
      // MKV embedding failed — fall through to normal MP4 remux
      onProgress?.call('MKV subtitle embedding failed, casting without subs');
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
