import 'dart:convert';
import 'dart:typed_data';

import 'auth/binary_plist.dart';

/// Parses Apple plist responses from AirPlay devices.
///
/// AirPlay 1 answers with an XML plist; AirPlay 2 answers the same endpoints
/// with a *binary* plist. Both are handled here — see
/// [parsePlaybackInfoBytes], which picks a decoder from the `Content-Type`
/// header and falls back to sniffing the `bplist00` magic.
///
/// The XML parser supports the subset needed for AirPlay: `<real>`,
/// `<integer>`, `<string>`, `<true/>`, `<false/>`, `<dict>`, and `<array>`.
class PlistCodec {
  PlistCodec._();

  /// Content type AirPlay 2 uses for binary plists.
  static const String binaryPlistContentType =
      'application/x-apple-binary-plist';

  /// Magic bytes at the start of every binary plist.
  static const List<int> binaryPlistMagic = [
    0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, // "bplist"
  ];

  /// Whether [body] starts with the binary plist magic.
  static bool isBinaryPlist(List<int> body) {
    if (body.length < binaryPlistMagic.length) return false;
    for (int i = 0; i < binaryPlistMagic.length; i++) {
      if (body[i] != binaryPlistMagic[i]) return false;
    }
    return true;
  }

  /// Decodes a plist [body] that may be binary or XML.
  ///
  /// [contentType] is consulted first; when it is absent or unhelpful the
  /// body is sniffed for the `bplist00` magic. Returns an empty map if the
  /// body is empty or cannot be decoded either way.
  static Map<String, dynamic> parsePlist(
    List<int> body, {
    String contentType = '',
  }) {
    if (body.isEmpty) return {};

    final looksBinary =
        contentType.toLowerCase().contains('binary-plist') ||
        isBinaryPlist(body);

    if (looksBinary) {
      try {
        return BinaryPlistDecoder.decode(Uint8List.fromList(body));
      } catch (_) {
        // Fall through and try XML — some receivers mislabel the body, and a
        // malformed one must degrade to an empty result rather than take the
        // polling loop down.
      }
    }

    try {
      return parseXmlPlist(utf8.decode(body, allowMalformed: true));
    } catch (_) {
      return {};
    }
  }

  /// Parses an XML plist string into a [Map<String, dynamic>].
  ///
  /// Returns an empty map if the input is empty, malformed, or does not
  /// contain a top-level `<dict>`.
  static Map<String, dynamic> parseXmlPlist(String xml) {
    if (xml.isEmpty) return {};

    try {
      final dictMatch = RegExp(
        r'<plist[^>]*>\s*<dict>(.*)</dict>\s*</plist>',
        dotAll: true,
      ).firstMatch(xml);
      if (dictMatch == null) return {};

      return _parseDict(dictMatch.group(1)!);
    } catch (_) {
      return {};
    }
  }

  /// Parses the inner content of a `<dict>` element into a map.
  static Map<String, dynamic> _parseDict(String content) {
    final result = <String, dynamic>{};
    final tokens = _tokenize(content);

    int i = 0;
    while (i < tokens.length) {
      final token = tokens[i];
      if (token.tag == 'key') {
        if (i + 1 < tokens.length) {
          result[token.value!] = _tokenValue(tokens, i + 1);
          // Skip past the value token(s)
          i = _skipValue(tokens, i + 1) + 1;
        } else {
          i++;
        }
      } else {
        i++;
      }
    }

    return result;
  }

  /// Extracts the Dart value from a token at the given index.
  static dynamic _tokenValue(List<_Token> tokens, int index) {
    if (index >= tokens.length) return null;
    final token = tokens[index];

    switch (token.tag) {
      case 'real':
        return double.tryParse(token.value ?? '') ?? 0.0;
      case 'integer':
        return int.tryParse(token.value ?? '') ?? 0;
      case 'string':
        return token.value ?? '';
      case 'true':
        return true;
      case 'false':
        return false;
      case 'dict':
        return _parseDict(token.value ?? '');
      case 'array':
        return _parseArray(token.value ?? '');
      default:
        return null;
    }
  }

  /// Returns the index of the last token consumed by the value at [index].
  static int _skipValue(List<_Token> tokens, int index) {
    // All value tokens are single tokens in our tokenizer.
    return index;
  }

  /// Parses the inner content of an `<array>` element into a list.
  static List<dynamic> _parseArray(String content) {
    final items = <dynamic>[];
    final tokens = _tokenize(content);

    int i = 0;
    while (i < tokens.length) {
      items.add(_tokenValue(tokens, i));
      i++;
    }

    return items;
  }

  /// Tokenizes plist XML content into a flat list of [_Token]s.
  ///
  /// Handles self-closing tags (`<true/>`, `<false/>`), simple value tags
  /// (`<real>...</real>`), and block tags (`<dict>...</dict>`, `<array>...</array>`).
  static List<_Token> _tokenize(String content) {
    final tokens = <_Token>[];
    int pos = 0;
    while (pos < content.length) {
      // Skip whitespace
      while (pos < content.length && _isWhitespace(content[pos])) {
        pos++;
      }
      if (pos >= content.length) break;

      if (content[pos] != '<') {
        pos++;
        continue;
      }

      // Self-closing boolean tags
      final boolMatch = RegExp(
        r'<(true|false)\s*/>',
      ).matchAsPrefix(content, pos);
      if (boolMatch != null) {
        tokens.add(_Token(boolMatch.group(1)!, null));
        pos = boolMatch.end;
        continue;
      }

      // Simple value tags: key, real, integer, string
      final simpleMatch = RegExp(
        r'<(key|real|integer|string)>(.*?)</\1>',
        dotAll: true,
      ).matchAsPrefix(content, pos);
      if (simpleMatch != null) {
        tokens.add(_Token(simpleMatch.group(1)!, simpleMatch.group(2)!));
        pos = simpleMatch.end;
        continue;
      }

      // Block tags: dict, array — need to find matching close tag
      final blockOpen = RegExp(r'<(dict|array)>').matchAsPrefix(content, pos);
      if (blockOpen != null) {
        final tag = blockOpen.group(1)!;
        final innerStart = blockOpen.end;
        final closeIndex = _findMatchingClose(content, innerStart, tag);
        if (closeIndex != -1) {
          final inner = content.substring(innerStart, closeIndex);
          tokens.add(_Token(tag, inner));
          pos = closeIndex + '</$tag>'.length;
          continue;
        }
      }

      // Skip unrecognized content
      pos++;
    }

    return tokens;
  }

  /// Finds the index of the matching `</tag>` for a given open tag,
  /// handling nesting.
  static int _findMatchingClose(String content, int start, String tag) {
    final openTag = '<$tag>';
    final closeTag = '</$tag>';
    int depth = 1;
    int pos = start;

    while (pos < content.length && depth > 0) {
      final nextOpen = content.indexOf(openTag, pos);
      final nextClose = content.indexOf(closeTag, pos);

      if (nextClose == -1) return -1;

      if (nextOpen != -1 && nextOpen < nextClose) {
        depth++;
        pos = nextOpen + openTag.length;
      } else {
        depth--;
        if (depth == 0) return nextClose;
        pos = nextClose + closeTag.length;
      }
    }

    return -1;
  }

  static bool _isWhitespace(String ch) =>
      ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r';

  /// Parses an AirPlay `/playback-info` XML plist response.
  static PlaybackInfo parsePlaybackInfo(String xml) =>
      _playbackInfoFromMap(parseXmlPlist(xml));

  /// Parses an AirPlay `/playback-info` response body of either encoding.
  ///
  /// AirPlay 2 returns a binary plist here, so decoding the bytes as UTF-8
  /// first — as the XML-only path must — throws or yields an all-zero result.
  static PlaybackInfo parsePlaybackInfoBytes(
    List<int> body, {
    String contentType = '',
  }) => _playbackInfoFromMap(parsePlist(body, contentType: contentType));

  static PlaybackInfo _playbackInfoFromMap(Map<String, dynamic> map) {
    PlaybackError? error;
    final rawError = map['error'];
    if (rawError is Map) {
      error = PlaybackError(
        code: (rawError['code'] as num?)?.toInt(),
        domain: rawError['domain'] as String?,
      );
    }

    return PlaybackInfo(
      duration: (map['duration'] as num?)?.toDouble() ?? 0.0,
      position: (map['position'] as num?)?.toDouble() ?? 0.0,
      rate: (map['rate'] as num?)?.toDouble() ?? 0.0,
      readyToPlay: map['readyToPlay'] as bool? ?? false,
      playbackBufferEmpty: map['playbackBufferEmpty'] as bool? ?? false,
      playbackLikelyToKeepUp: map['playbackLikelyToKeepUp'] as bool? ?? false,
      hasDuration: map.containsKey('duration'),
      error: error,
    );
  }

  /// Parses an AirPlay `/server-info` XML plist response.
  static ServerInfo parseServerInfo(String xml) {
    final map = parseXmlPlist(xml);
    return ServerInfo(
      deviceId: map['deviceid'] as String? ?? '',
      features: (map['features'] as int?) ?? 0,
      model: map['model'] as String? ?? '',
    );
  }
}

/// An error reported by the receiver inside a `/playback-info` response.
///
/// pyatv aborts playback when this dict is present
/// (`pyatv/protocols/airplay/player.py`), and so does this package — the
/// alternative is a session that sits in `loading` forever while the receiver
/// has already given up.
class PlaybackError {
  /// Receiver-defined error code, when reported.
  final int? code;

  /// Receiver-defined error domain, when reported.
  final String? domain;

  const PlaybackError({this.code, this.domain});

  @override
  String toString() =>
      'PlaybackError(code: ${code ?? 'unknown'}, '
      'domain: ${domain ?? 'unknown domain'})';
}

/// Parsed AirPlay playback info.
class PlaybackInfo {
  /// Total media duration in seconds.
  final double duration;

  /// Current playback position in seconds.
  final double position;

  /// Playback rate (0.0 = paused, 1.0 = playing).
  final double rate;

  /// Whether the device has buffered enough to begin playback.
  final bool readyToPlay;

  /// Whether the playback buffer has run dry.
  final bool playbackBufferEmpty;

  /// Whether buffering is sufficient for smooth playback.
  final bool playbackLikelyToKeepUp;

  /// Whether the response actually carried a `duration` key.
  ///
  /// A receiver that is not playing anything answers with a body that omits
  /// `duration` entirely, which is indistinguishable from `duration: 0` once
  /// it has been defaulted. pyatv uses exactly this key to decide whether
  /// playback has started.
  final bool hasDuration;

  /// The error the receiver reported, if any.
  final PlaybackError? error;

  const PlaybackInfo({
    required this.duration,
    required this.position,
    required this.rate,
    required this.readyToPlay,
    required this.playbackBufferEmpty,
    required this.playbackLikelyToKeepUp,
    this.hasDuration = false,
    this.error,
  });

  @override
  String toString() =>
      'PlaybackInfo(duration: $duration, position: $position, rate: $rate, '
      'readyToPlay: $readyToPlay'
      '${error != null ? ', error: $error' : ''})';
}

/// Parsed AirPlay server info.
class ServerInfo {
  /// Device MAC address / identifier.
  final String deviceId;

  /// Feature bitmask.
  final int features;

  /// Hardware model identifier (e.g. "AppleTV3,2").
  final String model;

  const ServerInfo({
    required this.deviceId,
    required this.features,
    required this.model,
  });

  @override
  String toString() =>
      'ServerInfo(deviceId: $deviceId, features: $features, model: $model)';
}

/// Internal token representation for plist parsing.
class _Token {
  final String tag;
  final String? value;

  const _Token(this.tag, this.value);
}
