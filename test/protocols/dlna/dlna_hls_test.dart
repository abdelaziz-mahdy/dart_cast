import 'dart:convert';
import 'dart:io';

import 'package:dart_cast/src/core/cast_device.dart';
import 'package:dart_cast/src/core/cast_media.dart';
import 'package:dart_cast/src/protocols/dlna/dlna_controller.dart';
import 'package:dart_cast/src/protocols/dlna/dlna_device.dart';
import 'package:dart_cast/src/protocols/dlna/dlna_session.dart';
import 'package:test/test.dart';

void main() {
  group('DlnaSoapBuilder.buildGetProtocolInfo', () {
    test('generates correct SOAP envelope for ConnectionManager', () {
      final xml = DlnaSoapBuilder.buildGetProtocolInfo();

      expect(xml, contains('s:Envelope'));
      expect(xml, contains('s:Body'));
      expect(xml, contains('GetProtocolInfo'));
      expect(xml, contains('urn:schemas-upnp-org:service:ConnectionManager:1'));
    });

    test('uses ConnectionManager service type namespace', () {
      final xml = DlnaSoapBuilder.buildGetProtocolInfo();

      expect(xml, contains('xmlns:u='));
      expect(xml, contains(DlnaServiceType.connectionManager));
    });
  });

  group('DlnaSoapParser.parseProtocolInfo', () {
    test('extracts MIME types from Sink field', () {
      const xml =
          '''<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <u:GetProtocolInfoResponse xmlns:u="urn:schemas-upnp-org:service:ConnectionManager:1">
      <Source></Source>
      <Sink>http-get:*:video/mp4:*,http-get:*:video/mp2t:*,http-get:*:audio/mp3:*</Sink>
    </u:GetProtocolInfoResponse>
  </s:Body>
</s:Envelope>''';

      final protocols = DlnaSoapParser.parseProtocolInfo(xml);
      expect(protocols, hasLength(3));
      expect(protocols[0], 'http-get:*:video/mp4:*');
      expect(protocols[1], 'http-get:*:video/mp2t:*');
      expect(protocols[2], 'http-get:*:audio/mp3:*');
    });

    test('returns empty list when Sink is empty', () {
      const xml =
          '''<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <u:GetProtocolInfoResponse xmlns:u="urn:schemas-upnp-org:service:ConnectionManager:1">
      <Source></Source>
      <Sink></Sink>
    </u:GetProtocolInfoResponse>
  </s:Body>
</s:Envelope>''';

      final protocols = DlnaSoapParser.parseProtocolInfo(xml);
      expect(protocols, isEmpty);
    });

    test('returns empty list when Sink element is missing', () {
      const xml =
          '''<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <u:GetProtocolInfoResponse xmlns:u="urn:schemas-upnp-org:service:ConnectionManager:1">
      <Source>http-get:*:*:*</Source>
    </u:GetProtocolInfoResponse>
  </s:Body>
</s:Envelope>''';

      final protocols = DlnaSoapParser.parseProtocolInfo(xml);
      expect(protocols, isEmpty);
    });

    test('trims whitespace from protocol entries', () {
      const xml =
          '''<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <u:GetProtocolInfoResponse xmlns:u="urn:schemas-upnp-org:service:ConnectionManager:1">
      <Sink> http-get:*:video/mp4:* , http-get:*:video/mpeg:* </Sink>
    </u:GetProtocolInfoResponse>
  </s:Body>
</s:Envelope>''';

      final protocols = DlnaSoapParser.parseProtocolInfo(xml);
      expect(protocols, hasLength(2));
      expect(protocols[0], 'http-get:*:video/mp4:*');
      expect(protocols[1], 'http-get:*:video/mpeg:*');
    });
  });

  group('DlnaSoapBuilder.buildSetAVTransportURI with protocolInfo', () {
    test('uses default video/mp4 protocolInfo', () {
      final xml = DlnaSoapBuilder.buildSetAVTransportURI(
        'http://example.com/video.mp4',
      );

      expect(xml, contains('http-get:*:video/mp4:*'));
    });

    test('uses custom protocolInfo for MPEG-TS', () {
      final xml = DlnaSoapBuilder.buildSetAVTransportURI(
        'http://example.com/stream',
        protocolInfo: 'http-get:*:video/mp2t:*',
      );

      expect(xml, contains('http-get:*:video/mp2t:*'));
      expect(xml, isNot(contains('http-get:*:video/mp4:*')));
    });
  });

  group('DlnaSession.loadMedia with HLS type', () {
    late HttpServer mockServer;
    late String serverUrl;
    late List<_CapturedAction> capturedActions;

    setUp(() async {
      capturedActions = [];
      mockServer = await HttpServer.bind('127.0.0.1', 0);
      serverUrl = 'http://127.0.0.1:${mockServer.port}';

      mockServer.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        final soapAction = request.headers.value('SOAPAction') ?? '';
        final actionMatch = RegExp(r'#(\w+)"').firstMatch(soapAction);
        final action = actionMatch?.group(1) ?? 'Unknown';

        capturedActions.add(_CapturedAction(action: action, body: body));

        request.response.headers.contentType = ContentType('text', 'xml');

        switch (action) {
          case 'SetAVTransportURI':
            request.response.write(
              _soapResponse(
                'SetAVTransportURIResponse',
                DlnaServiceType.avTransport,
                '',
              ),
            );
            break;
          case 'Play':
            request.response.write(
              _soapResponse('PlayResponse', DlnaServiceType.avTransport, ''),
            );
            break;
          case 'Stop':
            request.response.write(
              _soapResponse('StopResponse', DlnaServiceType.avTransport, ''),
            );
            break;
          case 'GetPositionInfo':
            request.response.write(
              _soapResponse(
                'GetPositionInfoResponse',
                DlnaServiceType.avTransport,
                '<Track>1</Track>'
                    '<TrackDuration>00:30:00</TrackDuration>'
                    '<RelTime>00:00:00</RelTime>',
              ),
            );
            break;
          case 'GetTransportInfo':
            request.response.write(
              _soapResponse(
                'GetTransportInfoResponse',
                DlnaServiceType.avTransport,
                '<CurrentTransportState>PLAYING</CurrentTransportState>'
                    '<CurrentTransportStatus>OK</CurrentTransportStatus>'
                    '<CurrentSpeed>1</CurrentSpeed>',
              ),
            );
            break;
          default:
            request.response.write(
              _soapResponse(
                '${action}Response',
                DlnaServiceType.avTransport,
                '',
              ),
            );
        }

        await request.response.close();
      });
    });

    tearDown(() async {
      await mockServer.close(force: true);
    });

    test('uses ts-stream route for HLS media', () async {
      final device = CastDevice(
        id: 'uuid:hls-test',
        name: 'HLS TV',
        protocol: CastProtocol.dlna,
        address: InternetAddress('127.0.0.1'),
        port: 8080,
      );

      final description = DlnaDeviceDescription(
        friendlyName: 'HLS TV',
        udn: 'uuid:hls-test',
        avTransportControlUrl: '$serverUrl/AVTransport/control',
        renderingControlUrl: '$serverUrl/RenderingControl/control',
        locationUrl: serverUrl,
      );

      final session = DlnaSession(device: device, description: description);

      await session.connect();
      await session.loadMedia(
        const CastMedia(
          url: 'http://example.com/video.m3u8',
          type: CastMediaType.hls,
          title: 'HLS Video',
        ),
      );

      final setUri = capturedActions.firstWhere(
        (a) => a.action == 'SetAVTransportURI',
      );

      // Should use ts-stream route, not stream route
      expect(setUri.body, contains('/ts-stream/'));
      expect(setUri.body, isNot(contains('example.com/video.m3u8')));
      // Should use video/mp2t protocolInfo
      expect(setUri.body, contains('video/mp2t'));
      // DLNA.ORG_OP is "<time-seek><byte-seek>". A piped TS is generated on
      // demand and answers `Accept-Ranges: none`, so claiming byte-range seek
      // (OP=01) is a lie — the TCL Google TV responded to a seek by going
      // straight to STOPPED. Time seek is the only one this route can honour.
      expect(setUri.body, contains('DLNA.ORG_OP=10'));
      expect(setUri.body, isNot(contains('DLNA.ORG_OP=01')));

      session.dispose();
    });

    test('byte-seekable routes still advertise byte-range seek', () async {
      final device = CastDevice(
        id: 'uuid:ts-op-test',
        name: 'TS TV',
        protocol: CastProtocol.dlna,
        address: InternetAddress('127.0.0.1'),
        port: 8080,
      );

      final description = DlnaDeviceDescription(
        friendlyName: 'TS TV',
        udn: 'uuid:ts-op-test',
        avTransportControlUrl: '$serverUrl/AVTransport/control',
        renderingControlUrl: '$serverUrl/RenderingControl/control',
        locationUrl: serverUrl,
      );

      final session = DlnaSession(device: device, description: description);

      await session.connect();
      await session.loadMedia(
        const CastMedia(
          url: 'http://example.com/video.mp4',
          type: CastMediaType.mp4,
          title: 'MP4 Video',
        ),
      );

      final setUri = capturedActions.firstWhere(
        (a) => a.action == 'SetAVTransportURI',
      );

      // A real file served through the proxy can honour byte ranges, and
      // seeking one worked on hardware — that path must keep OP=01.
      expect(setUri.body, contains('DLNA.ORG_OP=01'));

      session.dispose();
    });

    test('uses stream route for MP4 media', () async {
      final device = CastDevice(
        id: 'uuid:mp4-test',
        name: 'MP4 TV',
        protocol: CastProtocol.dlna,
        address: InternetAddress('127.0.0.1'),
        port: 8080,
      );

      final description = DlnaDeviceDescription(
        friendlyName: 'MP4 TV',
        udn: 'uuid:mp4-test',
        avTransportControlUrl: '$serverUrl/AVTransport/control',
        renderingControlUrl: '$serverUrl/RenderingControl/control',
        locationUrl: serverUrl,
      );

      final session = DlnaSession(device: device, description: description);

      await session.connect();
      await session.loadMedia(
        const CastMedia(
          url: 'http://example.com/video.mp4',
          type: CastMediaType.mp4,
          title: 'MP4 Video',
        ),
      );

      final setUri = capturedActions.firstWhere(
        (a) => a.action == 'SetAVTransportURI',
      );

      // Should use stream route for MP4
      expect(setUri.body, contains('/stream/'));
      expect(setUri.body, isNot(contains('/ts-stream/')));
      // Should use video/mp4 protocolInfo
      expect(setUri.body, contains('video/mp4'));

      session.dispose();
    });

    test('uses stream route with mp2t protocolInfo for mpegTs media', () async {
      final device = CastDevice(
        id: 'uuid:ts-test',
        name: 'TS TV',
        protocol: CastProtocol.dlna,
        address: InternetAddress('127.0.0.1'),
        port: 8080,
      );

      final description = DlnaDeviceDescription(
        friendlyName: 'TS TV',
        udn: 'uuid:ts-test',
        avTransportControlUrl: '$serverUrl/AVTransport/control',
        renderingControlUrl: '$serverUrl/RenderingControl/control',
        locationUrl: serverUrl,
      );

      final session = DlnaSession(device: device, description: description);

      await session.connect();
      await session.loadMedia(
        const CastMedia(
          url: 'http://example.com/stream.ts',
          type: CastMediaType.mpegTs,
          title: 'TS Video',
        ),
      );

      final setUri = capturedActions.firstWhere(
        (a) => a.action == 'SetAVTransportURI',
      );

      // Should use stream route (not ts-stream) for pre-existing TS
      expect(setUri.body, contains('/stream/'));
      // Should use video/mp2t protocolInfo
      expect(setUri.body, contains('video/mp2t'));

      session.dispose();
    });
  });

  group('DlnaDeviceDescription parses ConnectionManager', () {
    test('extracts connectionManagerControlUrl from device XML', () {
      const xml = '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <friendlyName>Test TV</friendlyName>
    <UDN>uuid:test-123</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>/AVTransport/control</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <controlURL>/RenderingControl/control</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <controlURL>/ConnectionManager/control</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';

      final desc = DlnaDeviceDescription.parse(
        xml,
        'http://192.168.1.100:49152/desc.xml',
      );

      expect(desc.avTransportControlUrl, isNotNull);
      expect(desc.renderingControlUrl, isNotNull);
      expect(desc.connectionManagerControlUrl, isNotNull);
      expect(
        desc.connectionManagerControlUrl,
        contains('/ConnectionManager/control'),
      );
    });

    test('connectionManagerControlUrl is null when not in XML', () {
      const xml = '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <friendlyName>Basic TV</friendlyName>
    <UDN>uuid:basic-123</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>/AVTransport/control</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';

      final desc = DlnaDeviceDescription.parse(
        xml,
        'http://192.168.1.100:49152/desc.xml',
      );

      expect(desc.connectionManagerControlUrl, isNull);
    });
  });
}

class _CapturedAction {
  final String action;
  final String body;
  _CapturedAction({required this.action, required this.body});
}

String _soapResponse(String action, String serviceType, String body) {
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
