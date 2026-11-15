import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_cast/src/core/cast_device.dart';
import 'package:dart_cast/src/core/cast_media.dart';
import 'package:dart_cast/src/core/cast_session.dart';
import 'package:dart_cast/src/core/http10_file_server.dart';
import 'package:dart_cast/src/protocols/dlna/dlna_controller.dart';
import 'package:dart_cast/src/protocols/dlna/dlna_device.dart';
import 'package:dart_cast/src/protocols/dlna/dlna_session.dart';
import 'package:test/test.dart';

/// Mock DLNA device HTTP server that captures SOAP requests and returns
/// appropriate responses.
class MockDlnaServer {
  late HttpServer _server;
  String get baseUrl => 'http://127.0.0.1:${_server.port}';
  String get avTransportUrl => '$baseUrl/AVTransport/control';
  String get renderingControlUrl => '$baseUrl/RenderingControl/control';
  String get connectionManagerUrl => '$baseUrl/ConnectionManager/control';

  /// Supported protocol info entries for GetProtocolInfo Sink response.
  /// Set this to control what supportsMediaType() will see.
  List<String> supportedProtocols = [];

  final List<_CapturedSoapAction> capturedActions = [];

  String _transportState = 'STOPPED';
  String _relTime = '00:00:00';
  String _trackDuration = '00:00:00';
  int _volume = 50;

  set transportState(String value) => _transportState = value;
  set relTime(String value) => _relTime = value;
  set trackDuration(String value) => _trackDuration = value;
  set volume(int value) => _volume = value;

  /// Delay before answering SetAVTransportURI, to widen the window in which
  /// a poll can land in the middle of a Stop → SetAVTransportURI → Play.
  Duration setUriDelay = Duration.zero;

  /// Body served at [scpdUrl]; null answers 404.
  String? renderingControlScpd;
  int scpdRequests = 0;
  String get scpdUrl => '$baseUrl/RenderingControl/scpd.xml';

  /// A 60-second VOD playlist (six 10 s segments) for piped HLS routes.
  String get playlistUrl => '$baseUrl/media.m3u8';

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server.listen(_handleRequest);
  }

  Future<void> stop() async {
    await _server.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.method == 'GET') {
      await _handleGet(request);
      return;
    }
    final body = await utf8.decoder.bind(request).join();
    final soapAction = request.headers.value('SOAPAction') ?? '';

    // Extract action name from SOAPAction header
    final actionMatch = RegExp(r'#(\w+)"').firstMatch(soapAction);
    final action = actionMatch?.group(1) ?? 'Unknown';

    capturedActions.add(_CapturedSoapAction(action: action, body: body));

    request.response.headers.contentType = ContentType('text', 'xml');

    switch (action) {
      case 'SetAVTransportURI':
        if (setUriDelay > Duration.zero) {
          await Future<void>.delayed(setUriDelay);
        }
        request.response.write(
          _soapResponse(
            'SetAVTransportURIResponse',
            DlnaServiceType.avTransport,
            '',
          ),
        );
        break;
      case 'Play':
        _transportState = 'PLAYING';
        request.response.write(
          _soapResponse('PlayResponse', DlnaServiceType.avTransport, ''),
        );
        break;
      case 'Pause':
        _transportState = 'PAUSED_PLAYBACK';
        request.response.write(
          _soapResponse('PauseResponse', DlnaServiceType.avTransport, ''),
        );
        break;
      case 'Stop':
        _transportState = 'STOPPED';
        request.response.write(
          _soapResponse('StopResponse', DlnaServiceType.avTransport, ''),
        );
        break;
      case 'Seek':
        request.response.write(
          _soapResponse('SeekResponse', DlnaServiceType.avTransport, ''),
        );
        break;
      case 'GetPositionInfo':
        request.response.write(
          _soapResponse(
            'GetPositionInfoResponse',
            DlnaServiceType.avTransport,
            '<Track>1</Track>'
                '<TrackDuration>$_trackDuration</TrackDuration>'
                '<RelTime>$_relTime</RelTime>',
          ),
        );
        break;
      case 'GetTransportInfo':
        request.response.write(
          _soapResponse(
            'GetTransportInfoResponse',
            DlnaServiceType.avTransport,
            '<CurrentTransportState>$_transportState</CurrentTransportState>'
                '<CurrentTransportStatus>OK</CurrentTransportStatus>'
                '<CurrentSpeed>1</CurrentSpeed>',
          ),
        );
        break;
      case 'SetVolume':
        request.response.write(
          _soapResponse(
            'SetVolumeResponse',
            DlnaServiceType.renderingControl,
            '',
          ),
        );
        break;
      case 'GetVolume':
        request.response.write(
          _soapResponse(
            'GetVolumeResponse',
            DlnaServiceType.renderingControl,
            '<CurrentVolume>$_volume</CurrentVolume>',
          ),
        );
        break;
      case 'GetProtocolInfo':
        final sink = supportedProtocols.join(',');
        request.response.write(
          _soapResponse(
            'GetProtocolInfoResponse',
            DlnaServiceType.connectionManager,
            '<Source></Source><Sink>$sink</Sink>',
          ),
        );
        break;
      default:
        request.response.statusCode = 500;
        request.response.write('Unknown action: $action');
    }

    await request.response.close();
  }

  Future<void> _handleGet(HttpRequest request) async {
    switch (request.uri.path) {
      case '/RenderingControl/scpd.xml':
        scpdRequests++;
        final scpd = renderingControlScpd;
        if (scpd == null) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.headers.contentType = ContentType('text', 'xml');
          request.response.write(scpd);
        }
      case '/media.m3u8':
        final b = StringBuffer('#EXTM3U\n#EXT-X-TARGETDURATION:10\n');
        for (var i = 0; i < 6; i++) {
          b.write('#EXTINF:10.0,\nseg$i.ts\n');
        }
        b.write('#EXT-X-ENDLIST\n');
        request.response.write(b.toString());
      default:
        request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
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
}

class _CapturedSoapAction {
  final String action;
  final String body;

  _CapturedSoapAction({required this.action, required this.body});
}

void main() {
  late MockDlnaServer mockServer;
  late CastDevice device;
  late DlnaDeviceDescription description;
  late DlnaSession session;

  setUp(() async {
    mockServer = MockDlnaServer();
    await mockServer.start();

    device = CastDevice(
      id: 'uuid:test-device',
      name: 'Test TV',
      protocol: CastProtocol.dlna,
      address: InternetAddress('127.0.0.1'),
      port: 8080,
    );

    description = DlnaDeviceDescription(
      friendlyName: 'Test TV',
      udn: 'uuid:test-device',
      avTransportControlUrl: mockServer.avTransportUrl,
      renderingControlUrl: mockServer.renderingControlUrl,
      locationUrl: mockServer.baseUrl,
    );

    session = DlnaSession(device: device, description: description);
  });

  tearDown(() async {
    session.dispose();
    await mockServer.stop();
  });

  group('DlnaSession', () {
    group('connect', () {
      test('transitions to connected state', () async {
        await session.connect();
        expect(session.state, equals(SessionState.connected));
      });
    });

    group('loadMedia', () {
      test('calls SetAVTransportURI then Play', () async {
        await session.connect();

        final media = CastMedia(
          url: 'http://example.com/video.mp4',
          type: CastMediaType.mp4,
          title: 'Test Video',
        );

        mockServer.transportState = 'PLAYING';
        mockServer.trackDuration = '01:30:00';

        await session.loadMedia(media);

        // Verify SetAVTransportURI was called
        final setUriActions =
            mockServer.capturedActions
                .where((a) => a.action == 'SetAVTransportURI')
                .toList();
        expect(setUriActions, hasLength(1));

        // Verify Play was called after SetAVTransportURI
        final playActions =
            mockServer.capturedActions
                .where((a) => a.action == 'Play')
                .toList();
        expect(playActions, hasLength(1));

        // SetAVTransportURI should come before Play
        final setUriIndex = mockServer.capturedActions.indexWhere(
          (a) => a.action == 'SetAVTransportURI',
        );
        final playIndex = mockServer.capturedActions.indexWhere(
          (a) => a.action == 'Play',
        );
        expect(setUriIndex, lessThan(playIndex));
      });

      test('transitions through loading to playing', () async {
        await session.connect();

        final states = <SessionState>[];
        session.stateStream.listen(states.add);

        mockServer.transportState = 'PLAYING';

        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        // Should have gone through loading state
        expect(states, contains(SessionState.loading));
      });
    });

    group('play', () {
      test('calls Play SOAP action', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        mockServer.capturedActions.clear();

        // Simulate paused state first
        session.stateMachine.forceState(SessionState.paused);
        await session.play();

        final playActions =
            mockServer.capturedActions
                .where((a) => a.action == 'Play')
                .toList();
        expect(playActions, hasLength(1));
      });
    });

    group('pause', () {
      test('calls Pause SOAP action', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        mockServer.capturedActions.clear();
        await session.pause();

        final pauseActions =
            mockServer.capturedActions
                .where((a) => a.action == 'Pause')
                .toList();
        expect(pauseActions, hasLength(1));
      });
    });

    group('stop', () {
      test('calls Stop SOAP action', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        mockServer.capturedActions.clear();
        await session.stop();

        final stopActions =
            mockServer.capturedActions
                .where((a) => a.action == 'Stop')
                .toList();
        expect(stopActions, hasLength(1));
      });

      test('transitions to idle state', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        await session.stop();

        expect(session.state, equals(SessionState.idle));
      });
    });

    group('seek', () {
      test('converts Duration to HH:MM:SS and calls Seek', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        mockServer.capturedActions.clear();
        await session.seek(const Duration(hours: 1, minutes: 23, seconds: 45));

        final seekActions =
            mockServer.capturedActions
                .where((a) => a.action == 'Seek')
                .toList();
        expect(seekActions, hasLength(1));
        expect(seekActions.first.body, contains('01:23:45'));
      });
    });

    group('setVolume', () {
      test('normalizes 0.0-1.0 to 0-100 and calls SetVolume', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        mockServer.capturedActions.clear();
        await session.setVolume(0.75);

        final volumeActions =
            mockServer.capturedActions
                .where((a) => a.action == 'SetVolume')
                .toList();
        expect(volumeActions, hasLength(1));
        expect(
          volumeActions.first.body,
          contains('<DesiredVolume>75</DesiredVolume>'),
        );
      });

      test('handles volume 0.0', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        mockServer.capturedActions.clear();
        await session.setVolume(0.0);

        final volumeActions =
            mockServer.capturedActions
                .where((a) => a.action == 'SetVolume')
                .toList();
        expect(
          volumeActions.first.body,
          contains('<DesiredVolume>0</DesiredVolume>'),
        );
      });

      test('handles volume 1.0', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        mockServer.capturedActions.clear();
        await session.setVolume(1.0);

        final volumeActions =
            mockServer.capturedActions
                .where((a) => a.action == 'SetVolume')
                .toList();
        expect(
          volumeActions.first.body,
          contains('<DesiredVolume>100</DesiredVolume>'),
        );
      });
    });

    group('position polling', () {
      test('emits position updates on positionStream', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        mockServer.relTime = '00:05:30';
        mockServer.trackDuration = '01:00:00';

        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        // Wait for at least one poll
        final position = await session.positionStream.first.timeout(
          const Duration(seconds: 5),
        );

        expect(position, isA<Duration>());
      });

      test('emits duration updates on durationStream', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        mockServer.relTime = '00:05:30';
        mockServer.trackDuration = '01:00:00';

        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        // Wait for at least one poll
        final duration = await session.durationStream.first.timeout(
          const Duration(seconds: 5),
        );

        expect(duration, isA<Duration>());
      });
    });

    group('state transitions', () {
      test('playing to paused', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        // Should be in playing state
        expect(session.state, equals(SessionState.playing));

        mockServer.transportState = 'PAUSED_PLAYBACK';
        await session.pause();

        expect(session.state, equals(SessionState.paused));
      });

      test('paused to playing', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        // Pause first
        mockServer.transportState = 'PAUSED_PLAYBACK';
        await session.pause();
        expect(session.state, equals(SessionState.paused));

        // Resume
        mockServer.transportState = 'PLAYING';
        await session.play();
        expect(session.state, equals(SessionState.playing));
      });
    });

    group('disconnect', () {
      test('sends Stop and transitions to disconnected', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        mockServer.capturedActions.clear();
        await session.disconnect();

        // Should have sent Stop
        final stopActions =
            mockServer.capturedActions
                .where((a) => a.action == 'Stop')
                .toList();
        expect(stopActions, hasLength(1));

        expect(session.state, equals(SessionState.disconnected));
      });

      test('stops position polling', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        mockServer.relTime = '00:05:30';
        mockServer.trackDuration = '01:00:00';

        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        // Wait for polling to start
        await session.positionStream.first.timeout(const Duration(seconds: 5));

        await session.disconnect();

        // Record actions after disconnect
        mockServer.capturedActions.clear();

        // Wait a bit to confirm no more polling
        await Future.delayed(const Duration(seconds: 2));

        // Should not have any GetPositionInfo after disconnect
        final positionPolls =
            mockServer.capturedActions
                .where((a) => a.action == 'GetPositionInfo')
                .toList();
        expect(positionPolls, isEmpty);
      });
    });

    group('setSubtitle', () {
      test('re-loads media with subtitle in DIDL-Lite', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
            title: 'Test Video',
          ),
        );

        mockServer.capturedActions.clear();

        await session.setSubtitle(
          const CastSubtitle(
            url: 'http://example.com/subs.srt',
            label: 'English',
            language: 'en',
            format: 'srt',
          ),
        );

        // Should have called SetAVTransportURI again with proxied subtitle
        final setUriActions =
            mockServer.capturedActions
                .where((a) => a.action == 'SetAVTransportURI')
                .toList();
        expect(setUriActions, hasLength(1));
        // Subtitle URL should be proxied (not raw), so it should contain /stream/
        expect(setUriActions.first.body, contains('/stream/'));
        // Raw subtitle URL should NOT appear (it's proxied)
        expect(setUriActions.first.body, isNot(contains('subs.srt')));
      });
    });
  });

  group('DlnaSession.fromDevice()', () {
    test('creates session from device with valid metadata', () {
      final device = CastDevice(
        id: 'uuid:test',
        name: 'My TV',
        protocol: CastProtocol.dlna,
        address: InternetAddress('192.168.1.100'),
        port: 49152,
        metadata: {
          'avTransportControlUrl':
              'http://192.168.1.100:49152/AVTransport/control',
          'renderingControlUrl':
              'http://192.168.1.100:49152/RenderingControl/control',
          'manufacturer': 'Samsung',
          'modelName': 'UE55',
        },
      );

      final session = DlnaSession.fromDevice(device);
      expect(session.device.name, 'My TV');
      expect(
        session.description.avTransportControlUrl,
        'http://192.168.1.100:49152/AVTransport/control',
      );
      expect(
        session.description.renderingControlUrl,
        'http://192.168.1.100:49152/RenderingControl/control',
      );
      expect(session.description.manufacturer, 'Samsung');
    });

    test('throws ArgumentError when avTransportControlUrl is missing', () {
      final device = CastDevice(
        id: 'uuid:test',
        name: 'My TV',
        protocol: CastProtocol.dlna,
        address: InternetAddress('192.168.1.100'),
        port: 49152,
        metadata: {
          'renderingControlUrl':
              'http://192.168.1.100:49152/RenderingControl/control',
        },
      );

      expect(
        () => DlnaSession.fromDevice(device),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('missing the DLNA AVTransport control URL'),
          ),
        ),
      );
    });

    test('throws ArgumentError with available metadata keys listed', () {
      final device = CastDevice(
        id: 'uuid:test',
        name: 'My TV',
        protocol: CastProtocol.dlna,
        address: InternetAddress('192.168.1.100'),
        port: 49152,
        metadata: {'someOtherKey': 'value'},
      );

      expect(
        () => DlnaSession.fromDevice(device),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('someOtherKey'),
          ),
        ),
      );
    });

    test('loadMedia uses proxy URL not raw URL', () async {
      final mockServer = MockDlnaServer();
      await mockServer.start();

      final device = CastDevice(
        id: 'uuid:proxy-test',
        name: 'Proxy TV',
        protocol: CastProtocol.dlna,
        address: InternetAddress('127.0.0.1'),
        port: 8080,
        metadata: {
          'avTransportControlUrl': mockServer.avTransportUrl,
          'renderingControlUrl': mockServer.renderingControlUrl,
        },
      );

      final session = DlnaSession.fromDevice(device);
      mockServer.transportState = 'PLAYING';
      await session.connect();
      await session.loadMedia(
        const CastMedia(
          url: 'https://secret-cdn.example.com/video.m3u8',
          type: CastMediaType.hls,
          httpHeaders: {'Referer': 'https://megacloud.blog/'},
        ),
      );

      final setUri = mockServer.capturedActions.firstWhere(
        (a) => a.action == 'SetAVTransportURI',
      );
      // Should contain proxy URL, NOT the raw CDN URL
      expect(setUri.body, isNot(contains('secret-cdn.example.com')));
      expect(setUri.body, contains('/ts-stream/')); // HLS uses ts-stream route

      await session.disconnect();
      session.dispose();
      await mockServer.stop();
    });
  });

  group('supportsMediaType', () {
    test('returns false when connectionManagerControlUrl is null', () async {
      final mockServer = MockDlnaServer();
      await mockServer.start();

      final device = CastDevice(
        id: 'uuid:no-cm',
        name: 'No CM TV',
        protocol: CastProtocol.dlna,
        address: InternetAddress('127.0.0.1'),
        port: 8080,
      );

      final description = DlnaDeviceDescription(
        friendlyName: 'No CM TV',
        udn: 'uuid:no-cm',
        avTransportControlUrl: mockServer.avTransportUrl,
        renderingControlUrl: mockServer.renderingControlUrl,
        connectionManagerControlUrl: null,
        locationUrl: mockServer.baseUrl,
      );

      final session = DlnaSession(device: device, description: description);

      final result = await session.supportsMediaType('video/mp4');
      expect(result, isFalse);

      session.dispose();
      await mockServer.stop();
    });

    test('returns true when Sink contains the queried MIME type', () async {
      final mockServer = MockDlnaServer();
      await mockServer.start();
      mockServer.supportedProtocols = [
        'http-get:*:video/mp4:*',
        'http-get:*:video/mp2t:*',
        'http-get:*:audio/mpeg:*',
      ];

      final device = CastDevice(
        id: 'uuid:cm-test',
        name: 'CM TV',
        protocol: CastProtocol.dlna,
        address: InternetAddress('127.0.0.1'),
        port: 8080,
      );

      final description = DlnaDeviceDescription(
        friendlyName: 'CM TV',
        udn: 'uuid:cm-test',
        avTransportControlUrl: mockServer.avTransportUrl,
        renderingControlUrl: mockServer.renderingControlUrl,
        connectionManagerControlUrl: mockServer.connectionManagerUrl,
        locationUrl: mockServer.baseUrl,
      );

      final session = DlnaSession(device: device, description: description);

      final result = await session.supportsMediaType('video/mp4');
      expect(result, isTrue);

      session.dispose();
      await mockServer.stop();
    });

    test(
      'returns false when Sink does not contain the queried MIME type',
      () async {
        final mockServer = MockDlnaServer();
        await mockServer.start();
        mockServer.supportedProtocols = [
          'http-get:*:video/mp4:*',
          'http-get:*:audio/mpeg:*',
        ];

        final device = CastDevice(
          id: 'uuid:cm-test2',
          name: 'CM TV 2',
          protocol: CastProtocol.dlna,
          address: InternetAddress('127.0.0.1'),
          port: 8080,
        );

        final description = DlnaDeviceDescription(
          friendlyName: 'CM TV 2',
          udn: 'uuid:cm-test2',
          avTransportControlUrl: mockServer.avTransportUrl,
          renderingControlUrl: mockServer.renderingControlUrl,
          connectionManagerControlUrl: mockServer.connectionManagerUrl,
          locationUrl: mockServer.baseUrl,
        );

        final session = DlnaSession(device: device, description: description);

        final result = await session.supportsMediaType('video/webm');
        expect(result, isFalse);

        session.dispose();
        await mockServer.stop();
      },
    );
  });

  group('DlnaSession spec compliance', () {
    String scpdWithMax(int max) =>
        '<?xml version="1.0"?><scpd><serviceStateTable>'
        '<stateVariable sendEvents="no"><name>Volume</name>'
        '<dataType>ui2</dataType><allowedValueRange><minimum>0</minimum>'
        '<maximum>$max</maximum><step>1</step></allowedValueRange>'
        '</stateVariable></serviceStateTable></scpd>';

    DlnaSession sessionWithScpd() {
      final s = DlnaSession(
        device: device,
        description: DlnaDeviceDescription(
          friendlyName: 'Test TV',
          udn: 'uuid:test-device',
          avTransportControlUrl: mockServer.avTransportUrl,
          renderingControlUrl: mockServer.renderingControlUrl,
          renderingControlScpdUrl: mockServer.scpdUrl,
          locationUrl: mockServer.baseUrl,
        ),
      );
      addTearDown(s.dispose);
      return s;
    }

    List<String> bodiesOf(String action) =>
        mockServer.capturedActions
            .where((a) => a.action == action)
            .map((a) => a.body)
            .toList();

    test('volume is scaled by the renderer\'s SCPD maximum', () async {
      mockServer.renderingControlScpd = scpdWithMax(60);
      final s = sessionWithScpd();
      await s.connect();

      await s.setVolume(1.0);
      expect(bodiesOf('SetVolume').last, contains('<DesiredVolume>60<'));
      await s.setVolume(0.5);
      expect(bodiesOf('SetVolume').last, contains('<DesiredVolume>30<'));
      expect(mockServer.scpdRequests, 1, reason: 'SCPD is fetched once');

      mockServer.volume = 30;
      mockServer.transportState = 'PLAYING';
      await s.loadMedia(
        const CastMedia(
          url: 'http://example.com/video.mp4',
          type: CastMediaType.mp4,
        ),
      );
      final volume = await s.volumeStream.first.timeout(
        const Duration(seconds: 3),
      );
      expect(volume, closeTo(0.5, 1e-9));
      expect(mockServer.scpdRequests, 1);
    });

    test('volume falls back to 0..100 when the SCPD cannot be read', () async {
      mockServer.renderingControlScpd = null; // 404
      final s = sessionWithScpd();
      await s.connect();
      await s.setVolume(1.0);
      expect(bodiesOf('SetVolume').last, contains('<DesiredVolume>100<'));
    });

    test('a poll that sees STOPPED during a piped-seek reload does not end '
        'the session', () async {
      await session.connect();
      mockServer.transportState = 'PLAYING';
      await session.loadMedia(
        CastMedia(
          url: mockServer.playlistUrl,
          type: CastMediaType.hls,
          title: 'Piped',
        ),
      );
      expect(session.state, SessionState.playing);

      // The renderer sits in STOPPED from the Stop until the Play, and the
      // SetAVTransportURI in between is slow: the 1 s poll lands inside.
      mockServer.setUriDelay = const Duration(milliseconds: 2500);
      final states = <SessionState>[];
      final sub = session.stateStream.listen(states.add);
      addTearDown(sub.cancel);
      await session.seek(const Duration(seconds: 30));
      mockServer.setUriDelay = Duration.zero;

      // The renderer sat in STOPPED for longer than two poll periods; before
      // the guard, the poll read that and moved the session to idle.
      expect(states, isNot(contains(SessionState.idle)));
      expect(session.state, SessionState.playing);

      // Polling must still be running afterwards.
      final before =
          mockServer.capturedActions
              .where((a) => a.action == 'GetPositionInfo')
              .length;
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      final after =
          mockServer.capturedActions
              .where((a) => a.action == 'GetPositionInfo')
              .length;
      expect(after, greaterThan(before));
    });

    test('setSubtitle on a piped route reloads at the current position and '
        'keeps the metadata', () async {
      await session.connect();
      mockServer.transportState = 'PLAYING';
      await session.loadMedia(
        CastMedia(
          url: mockServer.playlistUrl,
          type: CastMediaType.hls,
          title: 'Piped',
        ),
      );
      final loadBody = bodiesOf('SetAVTransportURI').single;
      expect(loadBody, contains('duration=&quot;00:01:00&quot;'));

      await session.seek(const Duration(seconds: 30));
      mockServer.capturedActions.clear();

      await session.setSubtitle(
        const CastSubtitle(
          url: 'http://example.com/subs.srt',
          label: 'English',
          language: 'en',
          format: 'srt',
        ),
      );

      final setUri = bodiesOf('SetAVTransportURI');
      expect(setUri, hasLength(1));
      expect(setUri.single, contains('t=30.000'));
      expect(setUri.single, contains('duration=&quot;00:01:00&quot;'));
      expect(setUri.single, contains('DLNA.ORG_OP=10'));
      // The subtitle is attached (proxied, not the raw URL).
      expect(setUri.single, contains('CaptionInfoEx'));
      expect(setUri.single, isNot(contains('example.com/subs.srt')));
      final actions = mockServer.capturedActions.map((a) => a.action).toList();
      expect(
        actions.where(
          (a) =>
              a != 'GetPositionInfo' &&
              a != 'GetTransportInfo' &&
              a != 'GetVolume',
        ),
        ['Stop', 'SetAVTransportURI', 'Play'],
      );

      // Positions keep the 30 s offset rather than restarting at 0.
      mockServer.relTime = '00:00:02';
      final position = await session.positionStream.first.timeout(
        const Duration(seconds: 3),
      );
      expect(position, const Duration(seconds: 32));
    });

    test('setSubtitle on a byte-seekable route seeks back to where it was '
        'and keeps the duration', () async {
      await session.connect();
      mockServer.transportState = 'PLAYING';
      mockServer.relTime = '00:00:40';
      await session.loadMedia(
        const CastMedia(
          url: 'http://example.com/video.mp4',
          type: CastMediaType.mp4,
          duration: Duration(minutes: 2),
        ),
      );
      await session.positionStream
          .firstWhere((p) => p == const Duration(seconds: 40))
          .timeout(const Duration(seconds: 3));
      mockServer.capturedActions.clear();

      await session.setSubtitle(
        const CastSubtitle(
          url: 'http://example.com/subs.srt',
          label: 'English',
          language: 'en',
          format: 'srt',
        ),
      );
      final setUri = bodiesOf('SetAVTransportURI').single;
      expect(setUri, contains('duration=&quot;00:02:00&quot;'));

      // The renderer restarts the item at 0; we put it back at 40 s once it
      // reports PLAYING again.
      for (var i = 0; i < 30 && bodiesOf('Seek').isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(bodiesOf('Seek').single, contains('<Target>00:00:40</Target>'));
    });

    test('the seek back after setSubtitle waits until the renderer has '
        'loaded the item, not just until it says PLAYING', () async {
      // TCL's renderer answers PLAYING with position and duration 0 while
      // its player is still loading; a Seek sent then is accepted and lost.
      await session.connect();
      mockServer.transportState = 'PLAYING';
      mockServer.relTime = '00:00:40';
      mockServer.trackDuration = '00:02:00';
      await session.loadMedia(
        const CastMedia(
          url: 'http://example.com/video.mp4',
          type: CastMediaType.mp4,
        ),
      );
      await session.positionStream
          .firstWhere((p) => p == const Duration(seconds: 40))
          .timeout(const Duration(seconds: 3));

      mockServer.relTime = '00:00:00';
      mockServer.trackDuration = '00:00:00';
      mockServer.capturedActions.clear();
      await session.setSubtitle(
        const CastSubtitle(
          url: 'http://example.com/subs.srt',
          label: 'English',
          language: 'en',
          format: 'srt',
        ),
      );

      // Two polls of PLAYING at 0 s / 0 s: still loading, no seek yet.
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      expect(bodiesOf('Seek'), isEmpty);

      // Loaded: the renderer now knows the duration.
      mockServer.trackDuration = '00:02:00';
      for (var i = 0; i < 30 && bodiesOf('Seek').isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(bodiesOf('Seek').single, contains('<Target>00:00:40</Target>'));
    });

    test('the media URL ends in the title, which some renderers show '
        'instead of dc:title', () async {
      await session.connect();
      mockServer.transportState = 'PLAYING';
      await session.loadMedia(
        CastMedia(
          url: mockServer.playlistUrl,
          type: CastMediaType.hls,
          title: 'Big Buck Bunny',
        ),
      );
      final uri =
          RegExp(
            r'<CurrentURI>([^<]*)</CurrentURI>',
          ).firstMatch(bodiesOf('SetAVTransportURI').single)!.group(1)!;
      expect(uri, endsWith('/Big_Buck_Bunny.ts'));
    });

    test('the DIDL protocolInfo 4th field is what the servers answer '
        'getcontentFeatures with', () async {
      await session.connect();
      mockServer.transportState = 'PLAYING';
      await session.loadMedia(
        CastMedia(url: mockServer.playlistUrl, type: CastMediaType.hls),
      );
      expect(
        bodiesOf('SetAVTransportURI').single,
        contains(
          'protocolInfo=&quot;http-get:*:video/mp2t:'
          '${DlnaContentFeatures.pipedTransportStream}&quot;',
        ),
      );
    });

    test('fromDevice carries the RenderingControl SCPD URL', () {
      final d = CastDevice(
        id: 'uuid:x',
        name: 'TV',
        protocol: CastProtocol.dlna,
        address: InternetAddress('127.0.0.1'),
        port: 1,
        metadata: {
          'avTransportControlUrl': 'http://127.0.0.1:1/avt',
          'renderingControlScpdUrl': 'http://127.0.0.1:1/rcs.xml',
        },
      );
      final s = DlnaSession.fromDevice(d);
      addTearDown(s.dispose);
      expect(
        s.description.renderingControlScpdUrl,
        'http://127.0.0.1:1/rcs.xml',
      );
    });
  });
}
