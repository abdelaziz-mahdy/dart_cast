import 'package:dart_cast/dart_cast.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// Auto-detects media type from a URL or file path.
CastMediaType detectMediaType(String url) {
  final lower = url.toLowerCase();
  if (lower.contains('.m3u8') || lower.contains('hls')) {
    return CastMediaType.hls;
  }
  if (lower.contains('.ts')) {
    return CastMediaType.mpegTs;
  }
  if (lower.contains('.mkv')) {
    return CastMediaType.mkv;
  }
  return CastMediaType.mp4;
}

/// Builds the subtitle list for a custom item from an optional URL.
List<CastSubtitle> subtitlesFromUrl(String subUrl) {
  if (subUrl.isEmpty) return const [];
  return [
    CastSubtitle(
      url: subUrl,
      label: 'Custom',
      language: 'und',
      format: subUrl.endsWith('.srt') ? 'srt' : 'vtt',
    ),
  ];
}

/// Dialog prompting for a video URL and optional subtitle URL.
///
/// Returns the built [CastMedia], or null if cancelled.
Future<CastMedia?> promptForUrlMedia(BuildContext context) {
  final urlController = TextEditingController();
  final subController = TextEditingController();
  return showDialog<CastMedia>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Add Video URL'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: urlController,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Video URL',
              hintText: 'https://example.com/video.mp4',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.link),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: subController,
            decoration: const InputDecoration(
              labelText: 'Subtitle URL (optional)',
              hintText: 'https://example.com/subs.vtt',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.subtitles),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final url = urlController.text.trim();
            if (url.isEmpty) return;
            final type = detectMediaType(url);
            Navigator.of(dialogContext).pop(
              CastMedia(
                url: url,
                type: type,
                title: 'Custom Video (${type.name.toUpperCase()})',
                subtitles: subtitlesFromUrl(subController.text.trim()),
              ),
            );
          },
          child: const Text('Add'),
        ),
      ],
    ),
  );
}

/// Opens the platform file picker and returns the picked video as a
/// [CastMedia.file], or null if cancelled or the path is unavailable.
///
/// The package serves local files over HTTP via its built-in proxy, so the
/// result casts to any device just like a remote URL.
Future<CastMedia?> pickLocalVideoMedia() async {
  // The example disables the macOS app sandbox, so let file_picker skip its
  // entitlements check there. This is a no-op on every other platform.
  await FilePicker.skipEntitlementsChecks();
  final result = await FilePicker.pickFiles(type: FileType.video);
  final path = result?.files.single.path;
  if (path == null) return null;
  return CastMedia.file(
    filePath: path,
    type: detectMediaType(path),
    title: p.basename(path),
  );
}
