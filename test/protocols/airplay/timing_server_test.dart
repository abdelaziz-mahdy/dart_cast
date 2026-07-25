import 'dart:io';
import 'dart:typed_data';

import 'package:dart_cast/src/protocols/airplay/timing_server.dart';
import 'package:test/test.dart';

/// Builds a 32-byte RTP timing request with the given send time.
Uint8List _timingRequest({
  int proto = 0x80,
  int sendTimeSec = 0x12345678,
  int sendTimeFrac = 0x9ABCDEF0,
}) {
  final packet = ByteData(AirPlayTimingServer.packetLength);
  packet.setUint8(0, proto);
  packet.setUint8(1, 0x52); // timing request type
  packet.setUint16(2, 0);
  packet.setUint32(24, sendTimeSec);
  packet.setUint32(28, sendTimeFrac);
  return packet.buffer.asUint8List();
}

void main() {
  group('AirPlayTimingServer.buildReply()', () {
    test('is a 32-byte packet with the timing reply type', () {
      final reply = AirPlayTimingServer.buildReply(_timingRequest());
      expect(reply.length, equals(AirPlayTimingServer.packetLength));

      final view = ByteData.sublistView(reply);
      expect(view.getUint8(1), equals(0xD3), reason: '0x53 | 0x80');
      expect(view.getUint16(2), equals(7), reason: 'sequence number');
      expect(view.getUint32(4), isZero, reason: 'padding');
    });

    test('echoes the protocol byte from the request', () {
      final reply = AirPlayTimingServer.buildReply(_timingRequest(proto: 0x90));
      expect(ByteData.sublistView(reply).getUint8(0), equals(0x90));
    });

    test('copies the request sendtime into the reply reftime', () {
      final reply = AirPlayTimingServer.buildReply(
        _timingRequest(sendTimeSec: 0xAABBCCDD, sendTimeFrac: 0x11223344),
      );
      final view = ByteData.sublistView(reply);
      expect(view.getUint32(8), equals(0xAABBCCDD));
      expect(view.getUint32(12), equals(0x11223344));
    });

    test('stamps recvtime and sendtime with the current NTP time', () {
      // 2026-07-25T00:00:00Z expressed in microseconds since the Unix epoch.
      final micros = DateTime.utc(2026, 7, 25).microsecondsSinceEpoch + 500000;
      final reply = AirPlayTimingServer.buildReply(
        _timingRequest(),
        nowMicroseconds: micros,
      );
      final view = ByteData.sublistView(reply);

      final (expectedSec, expectedFrac) = AirPlayTimingServer.ntpNow(
        nowMicroseconds: micros,
      );
      expect(view.getUint32(16), equals(expectedSec));
      expect(view.getUint32(20), equals(expectedFrac));
      expect(view.getUint32(24), equals(expectedSec));
      expect(view.getUint32(28), equals(expectedFrac));
    });
  });

  group('AirPlayTimingServer.ntpNow()', () {
    test('offsets the Unix epoch to the NTP epoch', () {
      final (seconds, fraction) = AirPlayTimingServer.ntpNow(
        nowMicroseconds: 0,
      );
      expect(seconds, equals(AirPlayTimingServer.ntpEpochOffset));
      expect(fraction, isZero);
    });

    test('encodes the sub-second part as a 32-bit fraction', () {
      final (_, fraction) = AirPlayTimingServer.ntpNow(nowMicroseconds: 500000);
      // Half a second is half of 2^32.
      expect(fraction, equals(0x80000000));
    });
  });

  group('AirPlayTimingServer lifecycle', () {
    test('binds an ephemeral port and reports it', () async {
      final server = AirPlayTimingServer();
      addTearDown(server.close);

      final port = await server.bind();
      expect(port, greaterThan(0));
      expect(server.port, equals(port));
      expect(server.isRunning, isTrue);
    });

    test('bind is idempotent', () async {
      final server = AirPlayTimingServer();
      addTearDown(server.close);

      final first = await server.bind();
      final second = await server.bind();
      expect(second, equals(first));
    });

    test('answers a real UDP timing request', () async {
      final server = AirPlayTimingServer();
      addTearDown(server.close);
      final port = await server.bind(address: InternetAddress.loopbackIPv4);

      final client = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(client.close);

      final replies = <Datagram>[];
      client.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = client.receive();
          if (datagram != null) replies.add(datagram);
        }
      });

      client.send(
        _timingRequest(sendTimeSec: 42, sendTimeFrac: 99),
        InternetAddress.loopbackIPv4,
        port,
      );

      // Give the event loop a moment to round-trip the datagram.
      for (var i = 0; i < 50 && replies.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(replies, isNotEmpty, reason: 'timing request went unanswered');
      final view = ByteData.sublistView(Uint8List.fromList(replies.first.data));
      expect(view.getUint8(1), equals(0xD3));
      expect(view.getUint32(8), equals(42), reason: 'reftime_sec echoed');
      expect(view.getUint32(12), equals(99), reason: 'reftime_frac echoed');
      expect(server.requestCount, equals(1));
    });

    test('ignores packets that are too short to be timing requests', () async {
      final server = AirPlayTimingServer();
      addTearDown(server.close);
      final port = await server.bind(address: InternetAddress.loopbackIPv4);

      final client = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(client.close);

      client.send([1, 2, 3], InternetAddress.loopbackIPv4, port);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(server.requestCount, isZero);
    });

    test('close releases the port and is safe to repeat', () async {
      final server = AirPlayTimingServer();
      await server.bind();
      await server.close();
      await server.close();

      expect(server.isRunning, isFalse);
      expect(server.port, isZero);
    });
  });
}
