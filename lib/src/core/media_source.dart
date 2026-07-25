import 'dart:io';

/// Reads a byte range from a [MediaSource].
///
/// [start] is inclusive and [end] is **exclusive**, matching
/// [File.openRead]. A source is asked for ranges whenever the cast device
/// seeks, so this must be able to start from an arbitrary offset — returning
/// the whole payload and ignoring the arguments will break seeking.
typedef MediaSourceReader = Stream<List<int>> Function(int start, int end);

/// A byte payload the proxy can serve without knowing where it came from.
///
/// [MediaProxy.registerFile] only handles things `dart:io` can open. A lot of
/// real content is not a file on disk:
///
/// - Android `content://` URIs from the Storage Access Framework, which is how
///   a user-picked file arrives in a Flutter app
/// - Flutter assets, read through `rootBundle`
/// - decrypted or otherwise transformed bytes held in memory
/// - a remote object that needs credentials the cast device cannot supply
///
/// Rather than pull a platform plugin into this package — which is pure Dart
/// and has no Flutter dependency — [MediaSource] lets the application supply
/// the bytes and keeps the proxy responsible only for serving them.
///
/// ```dart
/// // Flutter asset
/// final bytes = (await rootBundle.load('assets/clip.mp4')).buffer.asUint8List();
/// final url = proxy.registerSource(
///   MediaSource.bytes(bytes, contentType: 'video/mp4'),
///   fileExtension: '.mp4',
/// );
///
/// // Android content:// via a SAF plugin
/// final url = proxy.registerSource(
///   MediaSource(
///     length: await saf.length(uri),
///     contentType: 'video/mp4',
///     read: (start, end) => saf.openRead(uri, start, end),
///   ),
///   fileExtension: '.mp4',
/// );
/// ```
class MediaSource {
  /// Total size of the payload in bytes.
  ///
  /// Must be exact: it becomes `Content-Length`, and a renderer that is lied
  /// to here will either truncate playback or hang waiting for bytes that
  /// never arrive. It is also what makes seeking possible at all — without a
  /// known length there is nothing to seek within.
  final int length;

  /// MIME type served to the device, e.g. `video/mp4`.
  final String contentType;

  /// Reads `[start, end)` from the payload.
  final MediaSourceReader read;

  /// Creates a source from an explicit [length], [contentType] and [read].
  const MediaSource({
    required this.length,
    required this.contentType,
    required this.read,
  });

  /// A source backed by bytes already in memory.
  ///
  /// Suitable for Flutter assets and anything small enough to hold. Large
  /// media should use the main constructor and stream instead of loading the
  /// whole payload.
  factory MediaSource.bytes(
    List<int> bytes, {
    String contentType = 'application/octet-stream',
  }) {
    return MediaSource(
      length: bytes.length,
      contentType: contentType,
      read: (start, end) => Stream.value(bytes.sublist(start, end)),
    );
  }

  /// A source backed by a file on disk.
  ///
  /// Equivalent to [MediaProxy.registerFile]; useful when a caller wants to
  /// mix files and other sources behind one type.
  static Future<MediaSource> file(
    File file, {
    String contentType = 'application/octet-stream',
  }) async {
    final length = await file.length();
    return MediaSource(
      length: length,
      contentType: contentType,
      read: file.openRead,
    );
  }

  @override
  String toString() => 'MediaSource($contentType, $length bytes)';
}
