import 'dart:async';

import 'package:dart_cast/src/protocols/chromecast/castv2_channel.dart';
import 'package:dart_cast/src/protocols/chromecast/chromecast_discovery_provider.dart';
import 'package:dart_cast/src/protocols/chromecast/proto/cast_channel.dart';
import 'package:dart_cast/src/utils/mdns_discovery.dart';
import 'package:test/test.dart';

CastMessage _message(String payload) =>
    CastMessage()
      ..protocolVersion = CastMessage_ProtocolVersion.CASTV2_1_0
      ..sourceId = 'sender-0'
      ..destinationId = 'receiver-0'
      ..namespace_ = 'urn:x-cast:com.google.cast.tp.heartbeat'
      ..payloadType = CastMessage_PayloadType.STRING
      ..payloadUtf8 = payload;

void main() {
  group('CASTV2 64 KiB message limit', () {
    test('frameMessage refuses a body over 64 KiB', () {
      expect(
        () => CastV2Channel.frameMessage(_message('x' * 70000)),
        throwsArgumentError,
      );
    });

    test('a length header over 64 KiB ends the stream with an error '
        'instead of buffering forever', () async {
      final source = Stream<List<int>>.fromIterable([
        [0x00, 0x10, 0x00, 0x00, 1, 2, 3],
      ]);
      await expectLater(
        CastV2Channel.parseMessages(source).toList(),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'an undecodable frame is skipped and the next one still arrives',
      () async {
        final garbage = [0x00, 0x00, 0x00, 0x03, 0xFF, 0xFF, 0xFF];
        final good = CastV2Channel.frameMessage(_message('{"type":"PING"}'));
        final messages =
            await CastV2Channel.parseMessages(
              Stream<List<int>>.fromIterable([
                [...garbage, ...good],
              ]),
            ).toList();
        expect(messages.map((m) => m.payloadUtf8), ['{"type":"PING"}']);
      },
    );
  });

  test('restarting Chromecast discovery is not cut short by the previous '
      "run's timer", () async {
    final provider = ChromecastDiscoveryProvider(
      mdnsLookup: (_) => StreamController<MdnsServiceInfo>().stream,
    );
    addTearDown(provider.dispose);

    provider.startDiscovery(timeout: const Duration(milliseconds: 150));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    var closed = false;
    provider
        .startDiscovery(timeout: const Duration(milliseconds: 300))
        .listen(null, onDone: () => closed = true);

    // The first run's timer would have fired at 150 ms.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(closed, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(closed, isTrue);
  });
}
