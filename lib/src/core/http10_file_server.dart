import 'dart:convert';
import 'dart:io';

import '../utils/logger.dart';
import 'media_source.dart';

/// Serves files using raw HTTP/1.0 responses over detached sockets.
///
/// Some DLNA renderers (e.g., TCL Google TV) reject HTTP/1.1 responses
/// from Dart's built-in HttpServer. This class writes HTTP/1.0 headers
/// directly to the socket, matching the behavior of Python's
/// SimpleHTTPServer which works universally with DLNA renderers.
///
/// Usage:
/// ```dart
/// final socket = await request.response.detachSocket(writeHeaders: false);
/// try {
///   await Http10FileServer.serve(socket, file, request);
/// } finally {
///   await socket.close();
/// }
/// ```
class Http10FileServer {
  Http10FileServer._();

  /// Serves a file over a detached socket using HTTP/1.0 protocol.
  ///
  /// Supports:
  /// - Full file requests (200 OK)
  /// - Range requests with `bytes=` (206 Partial Content)
  /// - HEAD requests (headers only, no body)
  /// - `Accept-Ranges: bytes` header to advertise seek support
  ///
  /// The [contentType] defaults to `application/octet-stream` if not provided.
  static Future<void> serve(
    Socket socket,
    File file,
    HttpRequest request, {
    ContentType? contentType,
    String? contentFeatures,
  }) async {
    final source = MediaSource(
      length: await file.length(),
      contentType: contentType?.mimeType ?? 'application/octet-stream',
      read: file.openRead,
    );
    return serveSource(
      socket,
      source,
      request,
      contentFeatures: contentFeatures,
    );
  }

  /// Serves any [MediaSource] over a detached socket, with the same HTTP/1.0
  /// framing and range handling [serve] gives a file.
  ///
  /// This is what lets content that is not a file on disk — a Flutter asset,
  /// an Android `content://` URI, decrypted bytes — reach a DLNA renderer
  /// while still supporting seeking.
  ///
  /// [contentFeatures] is the 4th field of the DIDL-Lite `protocolInfo` the
  /// sender advertised for this resource. It is returned as
  /// `contentFeatures.dlna.org` when the renderer asks for it with
  /// `getcontentFeatures.dlna.org: 1`. When null, a default for the MIME type
  /// is used ([DlnaContentFeatures.forByteSeekableMime]), which is the same
  /// value the DLNA session advertises for byte-seekable routes.
  static Future<void> serveSource(
    Socket socket,
    MediaSource source,
    HttpRequest request, {
    String? contentFeatures,
  }) async {
    final fileLength = source.length;
    final mime = source.contentType;
    final range = _parseRange(request.headers.value('Range'), fileLength);

    final dlnaHeaders = DlnaContentFeatures.responseHeaders(
      request.headers,
      contentFeatures ?? DlnaContentFeatures.forByteSeekableMime(mime),
    );

    if (range is _Unsatisfiable) {
      final errorHeaders = StringBuffer();
      errorHeaders.write('HTTP/1.0 416 Range Not Satisfiable\r\n');
      errorHeaders.write('Date: ${HttpDate.format(DateTime.now())}\r\n');
      errorHeaders.write('Content-Range: bytes */$fileLength\r\n');
      errorHeaders.write('Content-Length: 0\r\n');
      errorHeaders.write('\r\n');
      socket.add(utf8.encode(errorHeaders.toString()));
      return;
    }

    final int start;
    final int end; // inclusive; -1 for an empty body
    final bool partial;
    if (range is _Satisfiable) {
      start = range.start;
      end = range.end;
      partial = true;
    } else {
      start = 0;
      end = fileLength - 1;
      partial = false;
    }

    final length = end - start + 1;
    final statusCode = partial ? 206 : 200;
    final statusText = partial ? 'Partial Content' : 'OK';

    // Write HTTP/1.0 response headers
    final headers = StringBuffer();
    headers.write('HTTP/1.0 $statusCode $statusText\r\n');
    headers.write('Date: ${HttpDate.format(DateTime.now())}\r\n');
    headers.write('Content-Type: $mime\r\n');
    headers.write('Content-Length: $length\r\n');
    headers.write('Accept-Ranges: bytes\r\n');
    if (partial) {
      headers.write('Content-Range: bytes $start-$end/$fileLength\r\n');
    }
    dlnaHeaders.forEach((name, value) => headers.write('$name: $value\r\n'));
    headers.write('\r\n');

    CastLogger.debug(
      'Http10FileServer: ${request.method} $mime '
      '${partial ? 'bytes $start-$end/$fileLength' : 'full file'} '
      '($length bytes) status=$statusCode',
    );

    socket.add(utf8.encode(headers.toString()));

    // HEAD — no body
    if (request.method == 'HEAD' || length == 0) {
      return;
    }

    // Stream the requested range. `end` is inclusive here, and
    // MediaSourceReader takes an exclusive end, matching File.openRead.
    // The reader may open asynchronously, so resolve it before piping.
    final stream = await source.read(start, end + 1);
    await stream.pipe(socket);
  }

  static final _rangeSpec = RegExp(r'^\s*(\d*)\s*-\s*(\d*)\s*$');

  /// Interprets a `Range` header per RFC 9110 §14.1–14.2.
  ///
  /// Returns null when the header must be ignored (absent, another unit,
  /// several ranges, or a syntactically invalid range-spec) — the full
  /// representation is then sent with 200. Several ranges are ignored rather
  /// than answered with `multipart/byteranges`, which §14.2 permits.
  static _ByteRange? _parseRange(String? header, int length) {
    if (header == null) return null;
    final eq = header.indexOf('=');
    if (eq < 0) return null;
    if (header.substring(0, eq).trim().toLowerCase() != 'bytes') return null;
    final spec = header.substring(eq + 1);
    if (spec.contains(',')) return null;

    final match = _rangeSpec.firstMatch(spec);
    if (match == null) return null;
    final first = match.group(1)!;
    final last = match.group(2)!;

    if (first.isEmpty) {
      // suffix-range: "-N" is the last N bytes.
      if (last.isEmpty) return null;
      final suffix = int.tryParse(last);
      if (suffix == null) return null;
      if (suffix == 0) return const _Unsatisfiable();
      // A zero-length representation has no bytes to address; serve it
      // whole (an empty 200) rather than invent a Content-Range.
      if (length == 0) return null;
      final start = suffix >= length ? 0 : length - suffix;
      return _Satisfiable(start, length - 1);
    }

    final start = int.tryParse(first);
    if (start == null) return null;
    int? end;
    if (last.isNotEmpty) {
      end = int.tryParse(last);
      if (end == null || end < start) return null;
    }
    if (start >= length) return const _Unsatisfiable();
    final lastByte = length - 1;
    return _Satisfiable(start, end == null || end > lastByte ? lastByte : end);
  }
}

sealed class _ByteRange {
  const _ByteRange();
}

class _Satisfiable extends _ByteRange {
  final int start;
  final int end;
  const _Satisfiable(this.start, this.end);
}

class _Unsatisfiable extends _ByteRange {
  const _Unsatisfiable();
}

/// DLNA transfer headers (DLNA guidelines 7.4.1.3.x) and the 4th
/// `protocolInfo` field they carry.
///
/// Lives in core so both the HTTP servers here and the DLNA session (which
/// writes the same string into DIDL-Lite) build it from one place.
class DlnaContentFeatures {
  DlnaContentFeatures._();

  /// STREAMING + BACKGROUND + CONNECTION_STALL + DLNA v1.5 — the same flags
  /// VLC and MiniDLNA send.
  static const flags = '01700000000000000000000000000000';

  /// Builds the 4th `protocolInfo` field, e.g.
  /// `DLNA.ORG_PN=…;DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=…`.
  ///
  /// `DLNA.ORG_OP` is `<time-seek><byte-seek>`, one digit each.
  static String build({
    String? profile,
    required bool timeSeek,
    required bool byteSeek,
  }) {
    final op = '${timeSeek ? 1 : 0}${byteSeek ? 1 : 0}';
    final pn = profile == null ? '' : 'DLNA.ORG_PN=$profile;';
    return '${pn}DLNA.ORG_OP=$op;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=$flags';
  }

  /// The value advertised for a generated (piped) MPEG-TS route, which
  /// supports time seek only.
  static final pipedTransportStream = build(
    profile: 'MPEG_TS_HD_NA_ISO',
    timeSeek: true,
    byteSeek: false,
  );

  /// The value advertised for a byte-seekable file of [mimeType], or null
  /// for a type the DLNA session does not advertise this way.
  static String? forByteSeekableMime(String mimeType) {
    switch (mimeType.toLowerCase()) {
      case 'video/mp2t':
        return build(
          profile: 'MPEG_TS_HD_NA_ISO',
          timeSeek: false,
          byteSeek: true,
        );
      case 'video/x-matroska':
        return build(timeSeek: false, byteSeek: true);
      case 'video/mp4':
        return build(
          profile: 'AVC_MP4_HP_HD_AAC',
          timeSeek: false,
          byteSeek: true,
        );
    }
    return null;
  }

  static const _transferModes = ['Streaming', 'Interactive', 'Background'];

  /// The DLNA headers to add to a response, given the [request] headers.
  ///
  /// Only headers the renderer asked for are returned: `contentFeatures` in
  /// answer to `getcontentFeatures.dlna.org: 1` (when [contentFeatures] is
  /// known), and `transferMode.dlna.org` echoed when it names a valid mode.
  static Map<String, String> responseHeaders(
    HttpHeaders request,
    String? contentFeatures,
  ) {
    final result = <String, String>{};
    final wantsFeatures =
        request.value('getcontentFeatures.dlna.org')?.trim() == '1';
    if (wantsFeatures && contentFeatures != null) {
      result['contentFeatures.dlna.org'] = contentFeatures;
    }
    final mode = request.value('transferMode.dlna.org')?.trim();
    if (mode != null) {
      for (final valid in _transferModes) {
        if (valid.toLowerCase() == mode.toLowerCase()) {
          result['transferMode.dlna.org'] = valid;
        }
      }
    }
    return result;
  }
}
