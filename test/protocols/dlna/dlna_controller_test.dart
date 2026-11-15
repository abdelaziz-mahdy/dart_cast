import 'dart:convert';
import 'dart:io';

import 'package:dart_cast/src/core/cast_exceptions.dart';
import 'package:dart_cast/src/protocols/dlna/dlna_controller.dart';
import 'package:test/test.dart';

void main() {
  group('DlnaSoapBuilder', () {
    group('buildSetAVTransportURI', () {
      test('generates correct SOAP envelope with AVTransport namespace', () {
        final xml = DlnaSoapBuilder.buildSetAVTransportURI(
          'http://example.com/video.mp4',
        );

        expect(xml, contains('s:Envelope'));
        expect(xml, contains('s:Body'));
        expect(xml, contains('SetAVTransportURI'));
        expect(xml, contains('urn:schemas-upnp-org:service:AVTransport:1'));
        expect(xml, contains('<InstanceID>0</InstanceID>'));
        expect(
          xml,
          contains('<CurrentURI>http://example.com/video.mp4</CurrentURI>'),
        );
      });

      test('includes DIDL-Lite metadata with title and URL', () {
        final xml = DlnaSoapBuilder.buildSetAVTransportURI(
          'http://example.com/video.mp4',
          title: 'My Video',
        );

        // DIDL-Lite is XML-escaped inside CurrentURIMetaData
        expect(xml, contains('DIDL-Lite'));
        expect(xml, contains('dc:title'));
        expect(xml, contains('My Video'));
        expect(xml, contains('http://example.com/video.mp4'));
        expect(xml, contains('object.item.videoItem'));
        expect(xml, contains('http-get:*:video/mp4:*'));
      });

      test('includes sec:CaptionInfoEx when subtitle URL provided', () {
        final xml = DlnaSoapBuilder.buildSetAVTransportURI(
          'http://example.com/video.mp4',
          title: 'My Video',
          subtitleUrl: 'http://example.com/subs.srt',
        );

        // DIDL-Lite content is XML-escaped inside CurrentURIMetaData
        expect(xml, contains('CaptionInfoEx'));
        expect(xml, contains('srt'));
        expect(xml, contains('http://example.com/subs.srt'));
        expect(xml, contains('sec.co.kr'));
      });

      test('omits sec:CaptionInfoEx when no subtitle URL', () {
        final xml = DlnaSoapBuilder.buildSetAVTransportURI(
          'http://example.com/video.mp4',
        );

        expect(xml, isNot(contains('CaptionInfoEx')));
      });

      test('escapes XML entities in title', () {
        final xml = DlnaSoapBuilder.buildSetAVTransportURI(
          'http://example.com/video.mp4',
          title: 'Tom & Jerry <Episode> "1"',
        );

        // Title is escaped once for DIDL-Lite, then the whole DIDL is escaped
        // again for embedding in CurrentURIMetaData. So & becomes &amp; then &amp;amp;
        expect(xml, isNot(contains('Tom & Jerry <Episode>')));
        // The double-escaped form should be present
        expect(xml, contains('&amp;amp;'));
      });

      test('escapes XML entities in URL', () {
        final xml = DlnaSoapBuilder.buildSetAVTransportURI(
          'http://example.com/video.mp4?a=1&b=2',
        );

        expect(xml, contains('a=1&amp;b=2'));
      });

      test('uses default title when none provided', () {
        final xml = DlnaSoapBuilder.buildSetAVTransportURI(
          'http://example.com/video.mp4',
        );

        // Should still have DIDL-Lite with some title (escaped inside metadata)
        expect(xml, contains('DIDL-Lite'));
        expect(xml, contains('dc:title'));
      });
    });

    group('buildPlay', () {
      test('generates correct Play SOAP envelope', () {
        final xml = DlnaSoapBuilder.buildPlay();

        expect(xml, contains('s:Envelope'));
        expect(xml, contains('Play'));
        expect(xml, contains('<InstanceID>0</InstanceID>'));
        expect(xml, contains('<Speed>1</Speed>'));
        expect(xml, contains('urn:schemas-upnp-org:service:AVTransport:1'));
      });
    });

    group('buildPause', () {
      test('generates correct Pause SOAP envelope', () {
        final xml = DlnaSoapBuilder.buildPause();

        expect(xml, contains('s:Envelope'));
        expect(xml, contains('Pause'));
        expect(xml, contains('<InstanceID>0</InstanceID>'));
        expect(xml, contains('urn:schemas-upnp-org:service:AVTransport:1'));
      });
    });

    group('buildStop', () {
      test('generates correct Stop SOAP envelope', () {
        final xml = DlnaSoapBuilder.buildStop();

        expect(xml, contains('s:Envelope'));
        expect(xml, contains('Stop'));
        expect(xml, contains('<InstanceID>0</InstanceID>'));
        expect(xml, contains('urn:schemas-upnp-org:service:AVTransport:1'));
      });
    });

    group('buildSeek', () {
      test('formats Duration as HH:MM:SS', () {
        final xml = DlnaSoapBuilder.buildSeek(
          const Duration(hours: 1, minutes: 23, seconds: 45),
        );

        expect(xml, contains('Seek'));
        expect(xml, contains('<InstanceID>0</InstanceID>'));
        expect(xml, contains('<Unit>REL_TIME</Unit>'));
        expect(xml, contains('<Target>01:23:45</Target>'));
      });

      test('formats zero duration correctly', () {
        final xml = DlnaSoapBuilder.buildSeek(Duration.zero);

        expect(xml, contains('<Target>00:00:00</Target>'));
      });

      test('formats large durations correctly', () {
        final xml = DlnaSoapBuilder.buildSeek(
          const Duration(hours: 10, minutes: 5, seconds: 3),
        );

        expect(xml, contains('<Target>10:05:03</Target>'));
      });
    });

    group('buildGetPositionInfo', () {
      test('generates correct GetPositionInfo SOAP envelope', () {
        final xml = DlnaSoapBuilder.buildGetPositionInfo();

        expect(xml, contains('GetPositionInfo'));
        expect(xml, contains('<InstanceID>0</InstanceID>'));
        expect(xml, contains('urn:schemas-upnp-org:service:AVTransport:1'));
      });
    });

    group('buildGetTransportInfo', () {
      test('generates correct GetTransportInfo SOAP envelope', () {
        final xml = DlnaSoapBuilder.buildGetTransportInfo();

        expect(xml, contains('GetTransportInfo'));
        expect(xml, contains('<InstanceID>0</InstanceID>'));
        expect(xml, contains('urn:schemas-upnp-org:service:AVTransport:1'));
      });
    });

    group('buildSetVolume', () {
      test('uses RenderingControl namespace', () {
        final xml = DlnaSoapBuilder.buildSetVolume(50);

        expect(xml, contains('SetVolume'));
        expect(
          xml,
          contains('urn:schemas-upnp-org:service:RenderingControl:1'),
        );
        expect(xml, contains('<InstanceID>0</InstanceID>'));
        expect(xml, contains('<Channel>Master</Channel>'));
        expect(xml, contains('<DesiredVolume>50</DesiredVolume>'));
      });

      test('handles volume 0', () {
        final xml = DlnaSoapBuilder.buildSetVolume(0);
        expect(xml, contains('<DesiredVolume>0</DesiredVolume>'));
      });

      test('handles volume 100', () {
        final xml = DlnaSoapBuilder.buildSetVolume(100);
        expect(xml, contains('<DesiredVolume>100</DesiredVolume>'));
      });
    });

    group('buildGetVolume', () {
      test('uses RenderingControl namespace', () {
        final xml = DlnaSoapBuilder.buildGetVolume();

        expect(xml, contains('GetVolume'));
        expect(
          xml,
          contains('urn:schemas-upnp-org:service:RenderingControl:1'),
        );
        expect(xml, contains('<InstanceID>0</InstanceID>'));
        expect(xml, contains('<Channel>Master</Channel>'));
      });
    });
  });

  group('DlnaSoapParser', () {
    group('parsePositionInfo', () {
      test('extracts position and duration', () {
        const xml = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <Track>1</Track>
      <TrackDuration>01:30:00</TrackDuration>
      <TrackMetaData></TrackMetaData>
      <TrackURI>http://example.com/video.mp4</TrackURI>
      <RelTime>00:15:30</RelTime>
      <AbsTime>00:15:30</AbsTime>
      <RelCount>2147483647</RelCount>
      <AbsCount>2147483647</AbsCount>
    </u:GetPositionInfoResponse>
  </s:Body>
</s:Envelope>''';

        final result = DlnaSoapParser.parsePositionInfo(xml);
        expect(
          result.position,
          equals(const Duration(minutes: 15, seconds: 30)),
        );
        expect(result.duration, equals(const Duration(hours: 1, minutes: 30)));
      });

      test('handles zero position', () {
        const xml =
            '''<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <TrackDuration>02:00:00</TrackDuration>
      <RelTime>00:00:00</RelTime>
    </u:GetPositionInfoResponse>
  </s:Body>
</s:Envelope>''';

        final result = DlnaSoapParser.parsePositionInfo(xml);
        expect(result.position, equals(Duration.zero));
        expect(result.duration, equals(const Duration(hours: 2)));
      });
    });

    group('parseTransportInfo', () {
      test('extracts PLAYING state', () {
        const xml =
            '''<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <u:GetTransportInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <CurrentTransportState>PLAYING</CurrentTransportState>
      <CurrentTransportStatus>OK</CurrentTransportStatus>
      <CurrentSpeed>1</CurrentSpeed>
    </u:GetTransportInfoResponse>
  </s:Body>
</s:Envelope>''';

        expect(DlnaSoapParser.parseTransportInfo(xml), equals('PLAYING'));
      });

      test('extracts PAUSED_PLAYBACK state', () {
        const xml =
            '''<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <u:GetTransportInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <CurrentTransportState>PAUSED_PLAYBACK</CurrentTransportState>
    </u:GetTransportInfoResponse>
  </s:Body>
</s:Envelope>''';

        expect(
          DlnaSoapParser.parseTransportInfo(xml),
          equals('PAUSED_PLAYBACK'),
        );
      });

      test('extracts STOPPED state', () {
        const xml =
            '''<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <u:GetTransportInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <CurrentTransportState>STOPPED</CurrentTransportState>
    </u:GetTransportInfoResponse>
  </s:Body>
</s:Envelope>''';

        expect(DlnaSoapParser.parseTransportInfo(xml), equals('STOPPED'));
      });

      test('extracts TRANSITIONING state', () {
        const xml =
            '''<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <u:GetTransportInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <CurrentTransportState>TRANSITIONING</CurrentTransportState>
    </u:GetTransportInfoResponse>
  </s:Body>
</s:Envelope>''';

        expect(DlnaSoapParser.parseTransportInfo(xml), equals('TRANSITIONING'));
      });

      test('extracts NO_MEDIA_PRESENT state', () {
        const xml =
            '''<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <u:GetTransportInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <CurrentTransportState>NO_MEDIA_PRESENT</CurrentTransportState>
    </u:GetTransportInfoResponse>
  </s:Body>
</s:Envelope>''';

        expect(
          DlnaSoapParser.parseTransportInfo(xml),
          equals('NO_MEDIA_PRESENT'),
        );
      });
    });

    group('parseVolume', () {
      test('extracts integer volume value', () {
        const xml =
            '''<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <u:GetVolumeResponse xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
      <CurrentVolume>75</CurrentVolume>
    </u:GetVolumeResponse>
  </s:Body>
</s:Envelope>''';

        expect(DlnaSoapParser.parseVolume(xml), equals(75));
      });

      test('handles volume 0', () {
        const xml =
            '''<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <u:GetVolumeResponse xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
      <CurrentVolume>0</CurrentVolume>
    </u:GetVolumeResponse>
  </s:Body>
</s:Envelope>''';

        expect(DlnaSoapParser.parseVolume(xml), equals(0));
      });

      test('handles volume 100', () {
        const xml =
            '''<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <u:GetVolumeResponse xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
      <CurrentVolume>100</CurrentVolume>
    </u:GetVolumeResponse>
  </s:Body>
</s:Envelope>''';

        expect(DlnaSoapParser.parseVolume(xml), equals(100));
      });
    });
  });

  group('DlnaHttpClient', () {
    late HttpServer server;
    late String serverUrl;
    late List<HttpRequest> capturedRequests;
    late List<String> capturedBodies;

    setUp(() async {
      capturedRequests = [];
      capturedBodies = [];
      server = await HttpServer.bind('127.0.0.1', 0);
      serverUrl = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        capturedRequests.add(request);
        final body = await utf8.decoder.bind(request).join();
        capturedBodies.add(body);
        request.response.headers.contentType = ContentType('text', 'xml');
        request.response.write('''<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
  <s:Body>
    <u:PlayResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
    </u:PlayResponse>
  </s:Body>
</s:Envelope>''');
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('sends POST with correct SOAPAction header', () async {
      final client = DlnaHttpClient();
      final body = DlnaSoapBuilder.buildPlay();
      await client.sendAction(
        '$serverUrl/AVTransport/control',
        'urn:schemas-upnp-org:service:AVTransport:1',
        'Play',
        body,
      );

      expect(capturedRequests, hasLength(1));
      expect(capturedRequests.first.method, equals('POST'));
      expect(
        capturedRequests.first.headers.value('SOAPAction'),
        equals('"urn:schemas-upnp-org:service:AVTransport:1#Play"'),
      );
    });

    test('sends Content-Type text/xml', () async {
      final client = DlnaHttpClient();
      await client.sendAction(
        '$serverUrl/AVTransport/control',
        'urn:schemas-upnp-org:service:AVTransport:1',
        'Play',
        DlnaSoapBuilder.buildPlay(),
      );

      expect(capturedRequests, hasLength(1));
      final contentType = capturedRequests.first.headers.contentType;
      expect(contentType?.primaryType, equals('text'));
      expect(contentType?.subType, equals('xml'));
    });

    test('sends SOAP body in request', () async {
      final client = DlnaHttpClient();
      final body = DlnaSoapBuilder.buildPlay();
      await client.sendAction(
        '$serverUrl/AVTransport/control',
        'urn:schemas-upnp-org:service:AVTransport:1',
        'Play',
        body,
      );

      expect(capturedBodies.first, contains('Play'));
      expect(capturedBodies.first, contains('s:Envelope'));
    });

    test('returns response body', () async {
      final client = DlnaHttpClient();
      final response = await client.sendAction(
        '$serverUrl/AVTransport/control',
        'urn:schemas-upnp-org:service:AVTransport:1',
        'Play',
        DlnaSoapBuilder.buildPlay(),
      );

      expect(response, contains('PlayResponse'));
    });
  });

  group('DlnaHttpClient spec details', () {
    late HttpServer server;
    late String serverUrl;
    late List<String?> rawContentTypes;

    setUp(() async {
      rawContentTypes = [];
      server = await HttpServer.bind('127.0.0.1', 0);
      serverUrl = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() => server.close(force: true));

    test('Content-Type carries a quoted charset (UDA 1.1 §3.2.1)', () async {
      server.listen((request) async {
        rawContentTypes.add(request.headers.value('Content-Type'));
        await request.drain<void>();
        await request.response.close();
      });
      final client = DlnaHttpClient();
      addTearDown(client.close);
      await client.sendAction(
        '$serverUrl/ctl',
        DlnaServiceType.avTransport,
        'Play',
        DlnaSoapBuilder.buildPlay(),
      );
      expect(rawContentTypes.single, 'text/xml; charset="utf-8"');
    });

    test('a SOAP fault reports the UPnPError code and description '
        '(UDA 1.1 §3.2.2)', () async {
      server.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = 500;
        request.response.headers.set(
          'Content-Type',
          'text/xml; charset="utf-8"',
        );
        request.response.write(
          '<?xml version="1.0"?>'
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
          's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
          '<s:Body><s:Fault>'
          '<faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>'
          '<detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0">'
          '<errorCode>701</errorCode>'
          '<errorDescription>Transition not available</errorDescription>'
          '</UPnPError></detail></s:Fault></s:Body></s:Envelope>',
        );
        await request.response.close();
      });
      final client = DlnaHttpClient();
      addTearDown(client.close);
      await expectLater(
        client.sendAction(
          '$serverUrl/ctl',
          DlnaServiceType.avTransport,
          'Seek',
          DlnaSoapBuilder.buildSeek(const Duration(seconds: 5)),
        ),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('500'),
              contains('701'),
              contains('Transition not available'),
            ),
          ),
        ),
      );
    });

    test('fetchText GETs a document', () async {
      server.listen((request) async {
        request.response.write('method=${request.method}');
        await request.response.close();
      });
      final client = DlnaHttpClient();
      addTearDown(client.close);
      expect(await client.fetchText('$serverUrl/scpd.xml'), 'method=GET');
    });
  });

  group('DlnaScpdParser.volumeRange', () {
    String scpd(String volumeVariable) =>
        '<?xml version="1.0"?>'
        '<scpd xmlns="urn:schemas-upnp-org:service-1-0"><serviceStateTable>'
        '<stateVariable sendEvents="no"><name>Mute</name>'
        '<dataType>boolean</dataType></stateVariable>'
        '<stateVariable sendEvents="no"><name>A_ARG_TYPE_InstanceID</name>'
        '<dataType>ui4</dataType><allowedValueRange><minimum>0</minimum>'
        '<maximum>9999</maximum></allowedValueRange></stateVariable>'
        '$volumeVariable'
        '</serviceStateTable></scpd>';

    test('reads the Volume maximum, not another variable\'s', () {
      final range = DlnaScpdParser.volumeRange(
        scpd(
          '<stateVariable sendEvents="no"><name>Volume</name>'
          '<dataType>ui2</dataType><allowedValueRange>'
          '<minimum>0</minimum><maximum>60</maximum><step>1</step>'
          '</allowedValueRange></stateVariable>',
        ),
      );
      expect(range, (min: 0, max: 60));
    });

    test('returns null when Volume has no usable range', () {
      expect(
        DlnaScpdParser.volumeRange(
          scpd(
            '<stateVariable><name>Volume</name><dataType>ui2</dataType>'
            '</stateVariable>',
          ),
        ),
        isNull,
      );
      expect(DlnaScpdParser.volumeRange('garbage'), isNull);
    });
  });
}
