import 'dart:io';

import '../../core/cast_device.dart';

/// Parsed DLNA device description with extracted service control URLs.
class DlnaDeviceDescription {
  /// Human-readable device name.
  final String friendlyName;

  /// Device manufacturer.
  final String? manufacturer;

  /// Device model name.
  final String? modelName;

  /// Universally unique device name (e.g., `uuid:xxxx-xxxx-...`).
  final String udn;

  /// Absolute URL for AVTransport SOAP control.
  final String? avTransportControlUrl;

  /// Absolute URL for RenderingControl SOAP control.
  final String? renderingControlUrl;

  /// Absolute URL for ConnectionManager SOAP control.
  final String? connectionManagerControlUrl;

  /// Absolute URL of the RenderingControl service description (SCPD), which
  /// declares the renderer's volume range.
  final String? renderingControlScpdUrl;

  /// The location URL this description was fetched from.
  final String locationUrl;

  DlnaDeviceDescription({
    required this.friendlyName,
    this.manufacturer,
    this.modelName,
    required this.udn,
    this.avTransportControlUrl,
    this.renderingControlUrl,
    this.connectionManagerControlUrl,
    this.renderingControlScpdUrl,
    required this.locationUrl,
  });

  /// Parses a device description [xml] fetched from [locationUrl].
  ///
  /// Extracts device metadata and resolves service control URLs against
  /// the `<URLBase>` element (if present) or else the [locationUrl] itself
  /// (UDA 1.1 §2.3: relative URLs resolve against the description's URL).
  factory DlnaDeviceDescription.parse(String xml, String locationUrl) {
    final friendlyName = _extractElement(xml, 'friendlyName') ?? 'Unknown';
    final manufacturer = _extractElement(xml, 'manufacturer');
    final modelName = _extractElement(xml, 'modelName');
    final udn = _extractElement(xml, 'UDN') ?? '';

    // Determine base URL: prefer URLBase, fall back to the URL the
    // description was fetched from — not just its origin, so `AVT/ctl`
    // under `/dmr/desc.xml` becomes `/dmr/AVT/ctl`.
    final urlBase = _extractElement(xml, 'URLBase');
    final baseUri = Uri.parse(
      urlBase != null && urlBase.isNotEmpty ? urlBase : locationUrl,
    );

    // Extract service control URLs.
    String? avTransportControlUrl;
    String? renderingControlUrl;
    String? connectionManagerControlUrl;
    String? renderingControlScpdUrl;

    final serviceBlocks = RegExp(
      r'<service>([\s\S]*?)</service>',
      caseSensitive: false,
    ).allMatches(xml);

    for (final match in serviceBlocks) {
      final block = match.group(1)!;
      final serviceType = _extractElement(block, 'serviceType');
      final controlUrl = _extractElement(block, 'controlURL');

      if (serviceType == null || controlUrl == null) continue;

      final resolvedUrl = _resolveUrl(baseUri, controlUrl);

      if (serviceType.contains('AVTransport')) {
        avTransportControlUrl = resolvedUrl;
      } else if (serviceType.contains('RenderingControl')) {
        renderingControlUrl = resolvedUrl;
        final scpdUrl = _extractElement(block, 'SCPDURL');
        if (scpdUrl != null && scpdUrl.isNotEmpty) {
          renderingControlScpdUrl = _resolveUrl(baseUri, scpdUrl);
        }
      } else if (serviceType.contains('ConnectionManager')) {
        connectionManagerControlUrl = resolvedUrl;
      }
    }

    return DlnaDeviceDescription(
      friendlyName: friendlyName,
      manufacturer: manufacturer,
      modelName: modelName,
      udn: udn,
      avTransportControlUrl: avTransportControlUrl,
      renderingControlUrl: renderingControlUrl,
      connectionManagerControlUrl: connectionManagerControlUrl,
      renderingControlScpdUrl: renderingControlScpdUrl,
      locationUrl: locationUrl,
    );
  }

  /// Creates a [CastDevice] from this device description.
  CastDevice toCastDevice() {
    final uri = Uri.parse(locationUrl);

    final metadata = <String, String>{};
    if (avTransportControlUrl != null) {
      metadata['avTransportControlUrl'] = avTransportControlUrl!;
    }
    if (renderingControlUrl != null) {
      metadata['renderingControlUrl'] = renderingControlUrl!;
    }
    if (connectionManagerControlUrl != null) {
      metadata['connectionManagerControlUrl'] = connectionManagerControlUrl!;
    }
    if (renderingControlScpdUrl != null) {
      metadata['renderingControlScpdUrl'] = renderingControlScpdUrl!;
    }
    if (manufacturer != null) {
      metadata['manufacturer'] = manufacturer!;
    }
    if (modelName != null) {
      metadata['modelName'] = modelName!;
    }

    return CastDevice(
      id: udn,
      name: friendlyName,
      protocol: CastProtocol.dlna,
      address: InternetAddress(uri.host),
      port: uri.port,
      metadata: metadata,
    );
  }

  /// Extracts the text content of an XML element using regex, with XML
  /// character and entity references (`&amp;`, `&#233;`, …) decoded.
  static String? _extractElement(String xml, String element) {
    final match = RegExp(
      '<$element>([^<]*)</$element>',
      caseSensitive: true,
    ).firstMatch(xml);
    final raw = match?.group(1)?.trim();
    return raw == null ? null : _unescapeXml(raw);
  }

  static final _xmlReference = RegExp(r'&(#[0-9]+|#x[0-9a-fA-F]+|[a-zA-Z]+);');

  /// Decodes the five predefined XML entities and numeric character
  /// references in one pass, so `&amp;lt;` becomes `&lt;`, not `<`.
  /// Unknown references are left as they are.
  static String _unescapeXml(String text) {
    if (!text.contains('&')) return text;
    return text.replaceAllMapped(_xmlReference, (m) {
      final ref = m.group(1)!;
      switch (ref) {
        case 'amp':
          return '&';
        case 'lt':
          return '<';
        case 'gt':
          return '>';
        case 'quot':
          return '"';
        case 'apos':
          return "'";
      }
      if (ref.startsWith('#')) {
        final code =
            ref.startsWith('#x')
                ? int.tryParse(ref.substring(2), radix: 16)
                : int.tryParse(ref.substring(1));
        if (code != null && code > 0 && code <= 0x10FFFF) {
          return String.fromCharCode(code);
        }
      }
      return m.group(0)!;
    });
  }

  /// Resolves a potentially relative [controlUrl] against a [baseUri].
  static String _resolveUrl(Uri baseUri, String controlUrl) {
    if (controlUrl.startsWith('http://') || controlUrl.startsWith('https://')) {
      return controlUrl;
    }
    return baseUri.resolve(controlUrl).toString();
  }
}
