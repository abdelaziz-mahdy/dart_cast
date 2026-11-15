/// HLS playlist parser with URL rewriting for proxy support.
///
/// Handles both master (multivariant) and media playlists per RFC 8216.
library;

/// A media segment of an HLS media playlist (RFC 8216 §3).
class HlsMediaSegment {
  /// Absolute URL of the resource holding the segment.
  final String url;

  /// Duration from `#EXTINF`, in seconds; 0.0 when it does not parse.
  final double duration;

  /// Length in bytes of the sub-range when `#EXT-X-BYTERANGE` applies,
  /// otherwise null (the segment is the whole resource).
  final int? byteRangeLength;

  /// Offset of the first byte of the sub-range; null without a byte range.
  final int? byteRangeOffset;

  /// Creates an [HlsMediaSegment].
  const HlsMediaSegment({
    required this.url,
    required this.duration,
    this.byteRangeLength,
    this.byteRangeOffset,
  });

  /// The value for an HTTP `Range` request header that fetches exactly
  /// this segment, or null when the segment is the whole resource.
  String? get rangeHeader {
    final length = byteRangeLength;
    final offset = byteRangeOffset;
    if (length == null || offset == null) return null;
    return 'bytes=$offset-${offset + length - 1}';
  }
}

/// A variant stream from an `#EXT-X-STREAM-INF` tag (RFC 8216 §4.3.4.2).
class HlsVariantStream {
  /// Absolute URL of the variant's media playlist.
  final String url;

  /// Peak bandwidth in bits per second; 0 when absent.
  final int bandwidth;

  /// `AUDIO` group ID, when audio comes from a separate rendition.
  final String? audioGroup;

  /// `CODECS` attribute of this variant.
  final String? codecs;

  /// `RESOLUTION` attribute of this variant, such as `1920x1080`.
  final String? resolution;

  /// Creates an [HlsVariantStream].
  const HlsVariantStream({
    required this.url,
    required this.bandwidth,
    this.audioGroup,
    this.codecs,
    this.resolution,
  });
}

class HlsParser {
  HlsParser._();

  /// Tags where the URI is a quoted attribute (Pattern B).
  static const _attributeUriTags = [
    '#EXT-X-KEY:',
    '#EXT-X-MAP:',
    '#EXT-X-MEDIA:',
    '#EXT-X-I-FRAME-STREAM-INF:',
    '#EXT-X-SESSION-KEY:',
    '#EXT-X-SESSION-DATA:',
    // Low-Latency HLS (draft-pantos-hls-rfc8216bis §4.4.4.9, §4.4.5.2-3).
    '#EXT-X-PART:',
    '#EXT-X-PRELOAD-HINT:',
    '#EXT-X-RENDITION-REPORT:',
  ];

  /// Regex matching the `URI="<value>"` attribute in a tag line. Anchored
  /// to an attribute boundary so a longer attribute name ending in `URI`
  /// is not mistaken for it.
  static final _uriAttributeRegex = RegExp(r'(?<=[:,])URI="([^"]*)"');

  /// Parses an HLS attribute list (RFC 8216 §4.2) into name → value.
  ///
  /// Quoted-string values are returned without their quotes and may
  /// contain commas. Attribute names are matched exactly, so
  /// `AVERAGE-BANDWIDTH` is never read as `BANDWIDTH`.
  static Map<String, String> parseAttributeList(String attributes) {
    final result = <String, String>{};
    var i = 0;
    while (i < attributes.length) {
      final eq = attributes.indexOf('=', i);
      if (eq < 0) break;
      final name = attributes.substring(i, eq).trim();
      var j = eq + 1;
      String value;
      if (j < attributes.length && attributes[j] == '"') {
        final close = attributes.indexOf('"', j + 1);
        final end = close < 0 ? attributes.length : close;
        value = attributes.substring(j + 1, end);
        j = close < 0 ? attributes.length : close + 1;
        final comma = attributes.indexOf(',', j);
        j = comma < 0 ? attributes.length : comma + 1;
      } else {
        final comma = attributes.indexOf(',', j);
        final end = comma < 0 ? attributes.length : comma;
        value = attributes.substring(j, end).trim();
        j = comma < 0 ? attributes.length : comma + 1;
      }
      if (name.isNotEmpty) result.putIfAbsent(name, () => value);
      i = j;
    }
    return result;
  }

  /// The attribute list of a tag line such as `#EXT-X-STREAM-INF:...`.
  static Map<String, String> _tagAttributes(String line) {
    final colon = line.indexOf(':');
    if (colon < 0) return const {};
    return parseAttributeList(line.substring(colon + 1));
  }

  /// Whether a media playlist encrypts its segments (an `#EXT-X-KEY` with a
  /// METHOD other than NONE). Such segments cannot be handed to a renderer
  /// that is not given the key.
  static bool isEncrypted(String content) {
    for (final raw in content.split('\n')) {
      final line = raw.trim();
      if (!line.startsWith('#EXT-X-KEY:')) continue;
      final method = _tagAttributes(line)['METHOD'];
      if (method != null && method != 'NONE') return true;
    }
    return false;
  }

  /// Whether a media playlist uses fragmented-MP4 / CMAF segments, which
  /// need the `#EXT-X-MAP` initialization section to decode.
  static bool hasInitializationSection(String content) =>
      content.contains('#EXT-X-MAP:');

  /// Detects whether [content] is a master (multivariant) playlist.
  ///
  /// Returns true if it contains `#EXT-X-STREAM-INF` or
  /// `#EXT-X-I-FRAME-STREAM-INF`.
  static bool isMasterPlaylist(String content) {
    return content.contains('#EXT-X-STREAM-INF') ||
        content.contains('#EXT-X-I-FRAME-STREAM-INF');
  }

  /// Resolves [url] against [baseUrl] per RFC 3986.
  ///
  /// Handles absolute URLs, protocol-relative, absolute-path, and
  /// relative-path references.
  static String resolveUrl(String url, String baseUrl) {
    // Absolute URL — has scheme. Returned untouched so its exact spelling
    // (percent-encoding, query order) reaches the server as written.
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }

    // Everything else, including protocol-relative and absolute-path
    // references, follows RFC 3986 §5.2. Uri.resolve keeps IPv6 brackets
    // and userinfo that hand-built strings would drop.
    try {
      return Uri.parse(baseUrl).resolve(url).toString();
    } on FormatException {
      return url;
    }
  }

  /// Rewrites all URLs in an HLS playlist to go through the proxy.
  ///
  /// [content] is the raw m3u8 text.
  /// [baseUrl] is the URL from which the playlist was fetched.
  /// [proxyBaseUrl] is the proxy server's base URL (e.g. `http://192.168.1.5:8234`).
  /// [token] is the proxy route token for this media session.
  ///
  /// ## URL extension hinting
  ///
  /// The Chromecast Default Media Receiver / Shaka Player consults the URL
  /// *path extension* during `MediaCapabilities.decodingInfo()` probing —
  /// not just the response `Content-Type`. Sources whose segment URLs end
  /// in something other than `.ts` (e.g. `.jpg`-obfuscated TS) silently
  /// fail the probe and trigger `LOAD_FAILED` with no diagnostic detail.
  ///
  /// To work around that, segment URLs (next-line URIs after `#EXTINF`) are
  /// rewritten to `/stream/<token>/seg<n>.ts?url=…`. The fake `.ts` segment
  /// in the path satisfies the receiver's extension probe; the upstream
  /// URL is preserved in the `?url=` query string. Variant playlist URIs
  /// (next-line URIs after `#EXT-X-STREAM-INF`) and attribute-style URIs
  /// (`URI="…"` on `#EXT-X-MEDIA`, etc.) keep the plain
  /// `/stream/<token>?url=…` form because their extension shouldn't
  /// affect playback.
  static String rewritePlaylist(
    String content,
    String baseUrl,
    String proxyBaseUrl,
    String token,
  ) {
    final lines = content.split('\n');
    final result = <String>[];
    // RFC 8216 §4.1: every non-blank line not starting with '#' is a URI,
    // and media segment tags such as #EXT-X-PROGRAM-DATE-TIME or
    // #EXT-X-DISCONTINUITY may sit between #EXTINF and that URI. So the
    // kind of the next URI is remembered across other tags and comments.
    var nextUriIsSegment = false;
    var segmentIndex = 0;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        result.add(line);
        continue;
      }

      if (trimmed.startsWith('#')) {
        if (trimmed.startsWith('#EXTINF:')) {
          nextUriIsSegment = true;
        } else if (trimmed.startsWith('#EXT-X-STREAM-INF:')) {
          nextUriIsSegment = false;
        }
        if (_isAttributeUriTag(trimmed)) {
          result.add(_rewriteUriAttribute(line, baseUrl, proxyBaseUrl, token));
        } else {
          result.add(line);
        }
        continue;
      }

      final resolved = resolveUrl(trimmed, baseUrl);
      if (nextUriIsSegment) {
        segmentIndex++;
        result.add(
          _buildSegmentProxyUrl(proxyBaseUrl, token, resolved, segmentIndex),
        );
      } else {
        result.add(_buildProxyUrl(proxyBaseUrl, token, resolved));
      }
      nextUriIsSegment = false;
    }

    return result.join('\n');
  }

  static bool _isAttributeUriTag(String line) {
    for (final tag in _attributeUriTags) {
      if (line.startsWith(tag)) return true;
    }
    return false;
  }

  /// Rewrites the `URI="..."` attribute in a tag line.
  static String _rewriteUriAttribute(
    String line,
    String baseUrl,
    String proxyBaseUrl,
    String token,
  ) {
    final match = _uriAttributeRegex.firstMatch(line);
    if (match == null) {
      return line; // No URI attribute (e.g. #EXT-X-MEDIA without URI)
    }

    final originalUri = match.group(1)!;
    final resolved = resolveUrl(originalUri, baseUrl);
    // Only http(s) can be fetched through the proxy. Key URIs such as
    // `data:` (inline key material) and `skd://` (FairPlay) are handed to
    // the player's own key system and must pass through untouched.
    final scheme = Uri.tryParse(resolved)?.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return line;
    final proxied = _buildProxyUrl(proxyBaseUrl, token, resolved);
    return line.replaceRange(match.start, match.end, 'URI="$proxied"');
  }

  /// Extract segment URLs from a media playlist.
  ///
  /// Parses `#EXTINF` lines and collects the URI of each segment,
  /// resolving them against [baseUrl].
  static List<String> extractSegmentUrls(String content, String baseUrl) => [
    for (final segment in extractMediaSegments(content, baseUrl)) segment.url,
  ];

  /// Extracts segment URLs together with their `#EXTINF` durations.
  ///
  /// Same parsing rules as [extractSegmentUrls], but each entry also carries
  /// the segment's declared duration in seconds. A segment whose `#EXTINF`
  /// cannot be parsed gets `0.0`, which keeps the list aligned with
  /// [extractSegmentUrls] rather than silently dropping entries.
  ///
  /// Byte ranges are not reported here; use [extractMediaSegments] when the
  /// playlist may contain `#EXT-X-BYTERANGE`.
  static List<({String url, double duration})> extractSegments(
    String content,
    String baseUrl,
  ) => [
    for (final segment in extractMediaSegments(content, baseUrl))
      (url: segment.url, duration: segment.duration),
  ];

  /// Extracts every media segment of a media playlist (RFC 8216 §4.3.2).
  ///
  /// Each segment's URI is the first non-blank, non-`#` line after its
  /// `#EXTINF`; other media segment tags and comments may come between
  /// them. `#EXT-X-BYTERANGE` sub-ranges are carried on the segment, with
  /// a missing offset taken as the byte after the previous sub-range of
  /// the same resource (§4.3.2.2).
  static List<HlsMediaSegment> extractMediaSegments(
    String content,
    String baseUrl,
  ) {
    final segments = <HlsMediaSegment>[];
    var inSegment = false;
    var pendingDuration = 0.0;
    int? pendingLength;
    int? pendingOffset;
    String? lastRangeUrl;
    var lastRangeEnd = 0;

    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      if (trimmed.startsWith('#EXTINF:')) {
        inSegment = true;
        // "#EXTINF:10.5,title" — the duration ends at the comma.
        final value = trimmed.substring('#EXTINF:'.length).split(',').first;
        pendingDuration = double.tryParse(value.trim()) ?? 0.0;
        continue;
      }

      if (trimmed.startsWith('#EXT-X-BYTERANGE:')) {
        final spec = trimmed.substring('#EXT-X-BYTERANGE:'.length).trim();
        final at = spec.indexOf('@');
        pendingLength = int.tryParse(at < 0 ? spec : spec.substring(0, at));
        pendingOffset = at < 0 ? null : int.tryParse(spec.substring(at + 1));
        continue;
      }

      if (trimmed.startsWith('#')) continue;

      if (inSegment) {
        final url = resolveUrl(trimmed, baseUrl);
        int? length;
        int? offset;
        if (pendingLength != null) {
          length = pendingLength;
          offset = pendingOffset ?? (lastRangeUrl == url ? lastRangeEnd : 0);
          lastRangeUrl = url;
          lastRangeEnd = offset + length;
        }
        segments.add(
          HlsMediaSegment(
            url: url,
            duration: pendingDuration,
            byteRangeLength: length,
            byteRangeOffset: offset,
          ),
        );
      }
      inSegment = false;
      pendingDuration = 0.0;
      pendingLength = null;
      pendingOffset = null;
    }

    return segments;
  }

  /// Whether [content] is a complete (VOD) playlist rather than a live one.
  ///
  /// Only a playlist ending in `#EXT-X-ENDLIST` has a total duration that
  /// will not change, so only those can be advertised to a renderer.
  static bool isCompletePlaylist(String content) =>
      content.contains('#EXT-X-ENDLIST');

  /// Total duration of a media playlist, or null when it cannot be trusted.
  ///
  /// Returns null for live playlists (no `#EXT-X-ENDLIST`) and for playlists
  /// with no parseable `#EXTINF` durations. DLNA renderers use this to show a
  /// scrub bar; advertising a duration that later changes is worse than
  /// advertising none.
  static Duration? totalDuration(String content) {
    if (!isCompletePlaylist(content)) return null;

    var seconds = 0.0;
    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('#EXTINF:')) continue;
      final value = trimmed.substring('#EXTINF:'.length).split(',').first;
      seconds += double.tryParse(value.trim()) ?? 0.0;
    }

    if (seconds <= 0) return null;
    return Duration(milliseconds: (seconds * 1000).round());
  }

  /// Given a master playlist, extract variant playlist URLs sorted by
  /// bandwidth (highest first).
  ///
  /// Each variant also carries the `AUDIO="<group-id>"` attribute when
  /// present — that's the link to a separate audio rendition declared via
  /// `EXT-X-MEDIA:TYPE=AUDIO`. A non-null `audioGroup` means the variant
  /// playlist is video-only and audio lives in a separate playlist.
  static List<({String url, int bandwidth, String? audioGroup})>
  extractVariants(String content, String baseUrl) => [
    for (final v in extractVariantStreams(content, baseUrl))
      (url: v.url, bandwidth: v.bandwidth, audioGroup: v.audioGroup),
  ];

  /// Like [extractVariants], but also returns each variant's own `CODECS`
  /// and `RESOLUTION`, read from the same `#EXT-X-STREAM-INF` tag.
  static List<HlsVariantStream> extractVariantStreams(
    String content,
    String baseUrl,
  ) {
    final lines = content.split('\n');
    final variants = <HlsVariantStream>[];

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
      final attributes = _tagAttributes(line);

      // Next non-empty, non-comment line is the URI
      for (var j = i + 1; j < lines.length; j++) {
        final nextLine = lines[j].trim();
        if (nextLine.isEmpty) continue;
        if (nextLine.startsWith('#')) continue;
        variants.add(
          HlsVariantStream(
            url: resolveUrl(nextLine, baseUrl),
            bandwidth: int.tryParse(attributes['BANDWIDTH'] ?? '') ?? 0,
            audioGroup: attributes['AUDIO'],
            codecs: attributes['CODECS'],
            resolution: attributes['RESOLUTION'],
          ),
        );
        break;
      }
    }

    // Sort by bandwidth descending (highest quality first)
    variants.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
    return variants;
  }

  /// Parsed alternate audio rendition (`EXT-X-MEDIA:TYPE=AUDIO`).
  ///
  /// Multiple renditions can share a `groupId` (e.g. one per language)
  /// and the variant in `EXT-X-STREAM-INF` selects which group plays via
  /// its `AUDIO=` attribute.
  static List<({String groupId, String name, String? uri, bool isDefault})>
  extractAudioRenditions(String content, String baseUrl) {
    final renditions =
        <({String groupId, String name, String? uri, bool isDefault})>[];

    for (final raw in content.split('\n')) {
      final line = raw.trim();
      if (!line.startsWith('#EXT-X-MEDIA:')) continue;
      final attributes = _tagAttributes(line);
      if (attributes['TYPE'] != 'AUDIO') continue;

      final groupId = attributes['GROUP-ID'];
      final name = attributes['NAME'];
      final rawUri = attributes['URI'];
      final uri = rawUri != null ? resolveUrl(rawUri, baseUrl) : null;
      final isDefault = attributes['DEFAULT'] == 'YES';

      renditions.add((
        groupId: groupId ?? '',
        name: name ?? '',
        uri: uri,
        isDefault: isDefault,
      ));
    }

    return renditions;
  }

  /// Constructs a proxy URL for the given original URL.
  static String _buildProxyUrl(
    String proxyBaseUrl,
    String token,
    String originalUrl,
  ) {
    return '$proxyBaseUrl/stream/$token?url=${Uri.encodeComponent(originalUrl)}';
  }

  /// Constructs a segment proxy URL whose *path* ends in `.ts`, satisfying
  /// the Chromecast / Shaka URL-extension capability probe even when the
  /// upstream URL ends in `.jpg`, `.bin`, or another non-media extension.
  static String _buildSegmentProxyUrl(
    String proxyBaseUrl,
    String token,
    String originalUrl,
    int segmentIndex,
  ) {
    return '$proxyBaseUrl/stream/$token/seg$segmentIndex.ts'
        '?url=${Uri.encodeComponent(originalUrl)}';
  }
}
