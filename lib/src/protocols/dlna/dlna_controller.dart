import 'package:http/http.dart' as http;

import '../../core/cast_device.dart';
import '../../core/cast_exceptions.dart';
import '../../utils/logger.dart';
import '../../utils/network_utils.dart';

/// Service type URNs for DLNA SOAP actions.
class DlnaServiceType {
  static const avTransport = 'urn:schemas-upnp-org:service:AVTransport:1';
  static const renderingControl =
      'urn:schemas-upnp-org:service:RenderingControl:1';
  static const connectionManager =
      'urn:schemas-upnp-org:service:ConnectionManager:1';
}

/// Builds SOAP XML envelopes for DLNA/UPnP actions.
class DlnaSoapBuilder {
  DlnaSoapBuilder._();

  /// Builds a SetAVTransportURI SOAP envelope with DIDL-Lite metadata.
  ///
  /// [protocolInfo] defaults to `http-get:*:video/mp4:*` but can be overridden
  /// to e.g. `http-get:*:video/mp2t:*` for MPEG-TS streams.
  ///
  /// [duration] is the optional media duration in `HH:MM:SS` format. When
  /// provided, it is added as a `duration` attribute on the `<res>` element
  /// so the TV can show the correct total duration from the start.
  ///
  /// [size] is the optional file size in bytes. When provided, it is added as
  /// a `size` attribute on the `<res>` element.
  static String buildSetAVTransportURI(
    String url, {
    String? title,
    String? subtitleUrl,
    String? subtitleFormat,
    List<({String url, String format})>? subtitleVariants,
    String protocolInfo = 'http-get:*:video/mp4:*',
    String? duration,
    int? size,
  }) {
    final escapedUrl = _escapeXml(url);
    final escapedTitle = _escapeXml(title ?? 'Media');

    // Subtitle elements — use multiple vendor-specific approaches for
    // maximum TV compatibility. No DLNA standard exists for external subs.
    // When subtitleVariants is provided (e.g., both SRT and VTT), include
    // all variants so the TV can pick whichever format it supports.
    final subtitleElements = StringBuffer();
    final variants = subtitleVariants ??
        (subtitleUrl != null
            ? [(url: subtitleUrl, format: subtitleFormat ?? 'srt')]
            : <({String url, String format})>[]);
    for (final variant in variants) {
      final escapedSubUrl = _escapeXml(variant.url);
      final subType = variant.format;
      final subMime = 'text/$subType';
      // Samsung: sec:CaptionInfoEx
      subtitleElements.write(
          '<sec:CaptionInfoEx sec:type="$subType">$escapedSubUrl</sec:CaptionInfoEx>');
      // Generic: separate <res> element with subtitle MIME
      subtitleElements.write(
          '<res protocolInfo="http-get:*:$subMime:*">$escapedSubUrl</res>');
    }

    // Build optional <res> attributes for duration and size
    final durationAttr = duration != null ? ' duration="$duration"' : '';
    final sizeAttr = size != null ? ' size="$size"' : '';

    final didlLite = _escapeXml(
      '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"'
      ' xmlns:dc="http://purl.org/dc/elements/1.1/"'
      ' xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"'
      ' xmlns:sec="http://www.sec.co.kr/"'
      ' xmlns:pv="http://www.pv.com/pvns/">'
      '<item id="0" parentID="0" restricted="0">'
      '<dc:title>$escapedTitle</dc:title>'
      '<upnp:class>object.item.videoItem</upnp:class>'
      '<res protocolInfo="$protocolInfo"$durationAttr$sizeAttr>$escapedUrl</res>'
      '$subtitleElements'
      '</item>'
      '</DIDL-Lite>',
    );

    return _wrapSoap(
      DlnaServiceType.avTransport,
      'SetAVTransportURI',
      '<InstanceID>0</InstanceID>'
          '<CurrentURI>$escapedUrl</CurrentURI>'
          '<CurrentURIMetaData>$didlLite</CurrentURIMetaData>',
    );
  }

  /// Builds a Play SOAP envelope.
  static String buildPlay() {
    return _wrapSoap(
      DlnaServiceType.avTransport,
      'Play',
      '<InstanceID>0</InstanceID><Speed>1</Speed>',
    );
  }

  /// Builds a Pause SOAP envelope.
  static String buildPause() {
    return _wrapSoap(
      DlnaServiceType.avTransport,
      'Pause',
      '<InstanceID>0</InstanceID>',
    );
  }

  /// Builds a Stop SOAP envelope.
  static String buildStop() {
    return _wrapSoap(
      DlnaServiceType.avTransport,
      'Stop',
      '<InstanceID>0</InstanceID>',
    );
  }

  /// Builds a Seek SOAP envelope with the position formatted as HH:MM:SS.
  static String buildSeek(Duration position) {
    final formatted = NetworkUtils.formatDuration(position);
    return _wrapSoap(
      DlnaServiceType.avTransport,
      'Seek',
      '<InstanceID>0</InstanceID>'
          '<Unit>REL_TIME</Unit>'
          '<Target>$formatted</Target>',
    );
  }

  /// Builds a GetPositionInfo SOAP envelope.
  static String buildGetPositionInfo() {
    return _wrapSoap(
      DlnaServiceType.avTransport,
      'GetPositionInfo',
      '<InstanceID>0</InstanceID>',
    );
  }

  /// Builds a GetTransportInfo SOAP envelope.
  static String buildGetTransportInfo() {
    return _wrapSoap(
      DlnaServiceType.avTransport,
      'GetTransportInfo',
      '<InstanceID>0</InstanceID>',
    );
  }

  /// Builds a SetVolume SOAP envelope using RenderingControl.
  static String buildSetVolume(int volume) {
    return _wrapSoap(
      DlnaServiceType.renderingControl,
      'SetVolume',
      '<InstanceID>0</InstanceID>'
          '<Channel>Master</Channel>'
          '<DesiredVolume>$volume</DesiredVolume>',
    );
  }

  /// Builds a GetVolume SOAP envelope using RenderingControl.
  static String buildGetVolume() {
    return _wrapSoap(
      DlnaServiceType.renderingControl,
      'GetVolume',
      '<InstanceID>0</InstanceID>'
          '<Channel>Master</Channel>',
    );
  }

  /// Builds a GetProtocolInfo SOAP envelope for ConnectionManager.
  ///
  /// Used to query the device's supported media types.
  static String buildGetProtocolInfo() {
    return _wrapSoap(
      DlnaServiceType.connectionManager,
      'GetProtocolInfo',
      '',
    );
  }

  static String _wrapSoap(
    String serviceType,
    String action,
    String body,
  ) {
    return '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"'
        ' s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body>'
        '<u:$action xmlns:u="$serviceType">'
        '$body'
        '</u:$action>'
        '</s:Body>'
        '</s:Envelope>';
  }

  static String _escapeXml(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}

/// Parsed position info from a GetPositionInfo SOAP response.
class PositionInfo {
  /// Current playback position.
  final Duration position;

  /// Total media duration.
  final Duration duration;

  /// Creates a [PositionInfo].
  const PositionInfo({required this.position, required this.duration});
}

/// Parses SOAP XML responses from DLNA devices.
class DlnaSoapParser {
  DlnaSoapParser._();

  /// Parses a GetPositionInfo response, returning position and duration.
  static PositionInfo parsePositionInfo(String xml) {
    final relTime = _extractElement(xml, 'RelTime') ?? '00:00:00';
    final trackDuration = _extractElement(xml, 'TrackDuration') ?? '00:00:00';

    return PositionInfo(
      position: _parseDuration(relTime),
      duration: _parseDuration(trackDuration),
    );
  }

  /// Parses a GetTransportInfo response, returning the transport state string.
  static String parseTransportInfo(String xml) {
    return _extractElement(xml, 'CurrentTransportState') ?? 'UNKNOWN';
  }

  /// Parses a GetVolume response, returning the volume as an integer (0-100).
  static int parseVolume(String xml) {
    final value = _extractElement(xml, 'CurrentVolume') ?? '0';
    return int.tryParse(value) ?? 0;
  }

  /// Parses a GetProtocolInfo response, returning supported MIME types.
  ///
  /// Extracts the `Sink` field from the response, splits by comma,
  /// and returns the list of protocol info strings.
  static List<String> parseProtocolInfo(String xml) {
    final sink = _extractElement(xml, 'Sink') ?? '';
    if (sink.trim().isEmpty) return [];
    return sink
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  static String? _extractElement(String xml, String element) {
    final match = RegExp(
      '<$element>([^<]*)</$element>',
      caseSensitive: true,
    ).firstMatch(xml);
    return match?.group(1)?.trim();
  }

  static Duration _parseDuration(String timeString) {
    final parts = timeString.split(':');
    if (parts.length != 3) return Duration.zero;

    final hours = int.tryParse(parts[0]) ?? 0;
    final minutes = int.tryParse(parts[1]) ?? 0;
    final seconds = int.tryParse(parts[2].split('.').first) ?? 0;

    return Duration(hours: hours, minutes: minutes, seconds: seconds);
  }
}

/// HTTP client for sending SOAP actions to DLNA devices.
class DlnaHttpClient {
  final http.Client _client;

  /// Creates a [DlnaHttpClient] with an optional HTTP client for testing.
  DlnaHttpClient({http.Client? client}) : _client = client ?? http.Client();

  /// Sends a SOAP action to the given control URL.
  ///
  /// Returns the response body as a string.
  Future<String> sendAction(
    String controlUrl,
    String serviceType,
    String action,
    String body,
  ) async {
    // Only log SOAP bodies for non-polling actions to reduce noise
    if (action != 'GetPositionInfo' &&
        action != 'GetTransportInfo' &&
        action != 'GetVolume') {
      CastLogger.debug('DLNA: SOAP $action request body:\n$body');
    }
    final response = await _client.post(
      Uri.parse(controlUrl),
      headers: {
        'Content-Type': 'text/xml; charset=utf-8',
        'SOAPAction': '"$serviceType#$action"',
      },
      body: body,
    );

    if (response.statusCode >= 400) {
      CastLogger.error(
          'DLNA: SOAP $action failed: HTTP ${response.statusCode}');
      CastLogger.debug('DLNA: SOAP error body: ${response.body}');
      throw ProtocolException(
        'DLNA SOAP error: HTTP ${response.statusCode}',
        CastProtocol.dlna,
      );
    }

    return response.body;
  }

  /// Closes the underlying HTTP client.
  void close() {
    _client.close();
  }
}
