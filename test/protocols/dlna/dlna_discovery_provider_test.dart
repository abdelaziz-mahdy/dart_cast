import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_cast/src/core/cast_device.dart';
import 'package:dart_cast/src/protocols/dlna/dlna_discovery_provider.dart';
import 'package:test/test.dart';

/// A fake RawDatagramSocket for testing SSDP discovery.
class FakeRawDatagramSocket implements RawDatagramSocket {
  final StreamController<RawSocketEvent> _controller =
      StreamController<RawSocketEvent>.broadcast();
  final List<List<int>> sentData = [];
  Datagram? nextDatagram;
  bool closed = false;

  @override
  bool broadcastEnabled = false;

  @override
  bool multicastLoopback = true;

  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  int send(List<int> buffer, InternetAddress address, int port) {
    sentData.add(buffer);
    return buffer.length;
  }

  @override
  Datagram? receive() => nextDatagram;

  void simulateResponse(String data) {
    nextDatagram = Datagram(
      Uint8List.fromList(data.codeUnits),
      InternetAddress('192.168.1.100'),
      1900,
    );
    _controller.add(RawSocketEvent.read);
  }

  @override
  void close() {
    closed = true;
    _controller.close();
  }

  // -- Stubs for unused members --
  @override
  InternetAddress get address => InternetAddress.anyIPv4;
  @override
  int get port => 0;
  @override
  void joinMulticast(InternetAddress group, [NetworkInterface? interface_]) {}
  @override
  void leaveMulticast(InternetAddress group, [NetworkInterface? interface_]) {}
  @override
  bool get readEventsEnabled => true;
  @override
  set readEventsEnabled(bool value) {}
  @override
  bool get writeEventsEnabled => false;
  @override
  set writeEventsEnabled(bool value) {}
  @override
  Uint8List getRawOption(RawSocketOption option) => Uint8List(0);
  @override
  void setRawOption(RawSocketOption option) {}
  @override
  int multicastHops = 1;
  @override
  NetworkInterface? multicastInterface;

  // Stream mixin stubs
  @override
  Future<bool> any(bool Function(RawSocketEvent) test) =>
      _controller.stream.any(test);
  @override
  Stream<RawSocketEvent> asBroadcastStream({
    void Function(StreamSubscription<RawSocketEvent>)? onListen,
    void Function(StreamSubscription<RawSocketEvent>)? onCancel,
  }) => _controller.stream.asBroadcastStream(
    onListen: onListen,
    onCancel: onCancel,
  );
  @override
  Stream<E> asyncExpand<E>(Stream<E>? Function(RawSocketEvent) convert) =>
      _controller.stream.asyncExpand(convert);
  @override
  Stream<E> asyncMap<E>(FutureOr<E> Function(RawSocketEvent) convert) =>
      _controller.stream.asyncMap(convert);
  @override
  Stream<R> cast<R>() => _controller.stream.cast<R>();
  @override
  Future<bool> contains(Object? needle) => _controller.stream.contains(needle);
  @override
  Stream<RawSocketEvent> distinct([
    bool Function(RawSocketEvent, RawSocketEvent)? equals,
  ]) => _controller.stream.distinct(equals);
  @override
  Future<E> drain<E>([E? futureValue]) => _controller.stream.drain(futureValue);
  @override
  Future<RawSocketEvent> elementAt(int index) =>
      _controller.stream.elementAt(index);
  @override
  Future<bool> every(bool Function(RawSocketEvent) test) =>
      _controller.stream.every(test);
  @override
  Stream<S> expand<S>(Iterable<S> Function(RawSocketEvent) convert) =>
      _controller.stream.expand(convert);
  @override
  Future<RawSocketEvent> get first => _controller.stream.first;
  @override
  Future<RawSocketEvent> firstWhere(
    bool Function(RawSocketEvent) test, {
    RawSocketEvent Function()? orElse,
  }) => _controller.stream.firstWhere(test, orElse: orElse);
  @override
  Future<S> fold<S>(S initialValue, S Function(S, RawSocketEvent) combine) =>
      _controller.stream.fold(initialValue, combine);
  @override
  Future forEach(void Function(RawSocketEvent) action) =>
      _controller.stream.forEach(action);
  @override
  Stream<RawSocketEvent> handleError(
    Function onError, {
    bool Function(dynamic)? test,
  }) => _controller.stream.handleError(onError, test: test);
  @override
  bool get isBroadcast => _controller.stream.isBroadcast;
  @override
  Future<bool> get isEmpty => _controller.stream.isEmpty;
  @override
  Future<String> join([String separator = '']) =>
      _controller.stream.join(separator);
  @override
  Future<RawSocketEvent> get last => _controller.stream.last;
  @override
  Future<RawSocketEvent> lastWhere(
    bool Function(RawSocketEvent) test, {
    RawSocketEvent Function()? orElse,
  }) => _controller.stream.lastWhere(test, orElse: orElse);
  @override
  Future<int> get length => _controller.stream.length;
  @override
  Stream<S> map<S>(S Function(RawSocketEvent) convert) =>
      _controller.stream.map(convert);
  @override
  Future pipe(StreamConsumer<RawSocketEvent> streamConsumer) =>
      _controller.stream.pipe(streamConsumer);
  @override
  Future<RawSocketEvent> reduce(
    RawSocketEvent Function(RawSocketEvent, RawSocketEvent) combine,
  ) => _controller.stream.reduce(combine);
  @override
  Future<RawSocketEvent> get single => _controller.stream.single;
  @override
  Future<RawSocketEvent> singleWhere(
    bool Function(RawSocketEvent) test, {
    RawSocketEvent Function()? orElse,
  }) => _controller.stream.singleWhere(test, orElse: orElse);
  @override
  Stream<RawSocketEvent> skip(int count) => _controller.stream.skip(count);
  @override
  Stream<RawSocketEvent> skipWhile(bool Function(RawSocketEvent) test) =>
      _controller.stream.skipWhile(test);
  @override
  Stream<RawSocketEvent> take(int count) => _controller.stream.take(count);
  @override
  Stream<RawSocketEvent> takeWhile(bool Function(RawSocketEvent) test) =>
      _controller.stream.takeWhile(test);
  @override
  Stream<RawSocketEvent> timeout(
    Duration timeLimit, {
    void Function(EventSink<RawSocketEvent>)? onTimeout,
  }) => _controller.stream.timeout(timeLimit, onTimeout: onTimeout);
  @override
  Future<List<RawSocketEvent>> toList() => _controller.stream.toList();
  @override
  Future<Set<RawSocketEvent>> toSet() => _controller.stream.toSet();
  @override
  Stream<S> transform<S>(
    StreamTransformer<RawSocketEvent, S> streamTransformer,
  ) => _controller.stream.transform(streamTransformer);
  @override
  Stream<RawSocketEvent> where(bool Function(RawSocketEvent) test) =>
      _controller.stream.where(test);
}

const _deviceXml = '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <friendlyName>Test TV</friendlyName>
    <manufacturer>TestCo</manufacturer>
    <modelName>Model1</modelName>
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
    </serviceList>
  </device>
</root>''';

void main() {
  group('DlnaDiscoveryProvider', () {
    test('protocol is CastProtocol.dlna', () {
      final provider = DlnaDiscoveryProvider();
      expect(provider.protocol, equals(CastProtocol.dlna));
    });

    test('discovers devices from SSDP responses', () async {
      late FakeRawDatagramSocket fakeSocket;

      final provider = DlnaDiscoveryProvider(
        socketFactory: (host, port) async {
          fakeSocket = FakeRawDatagramSocket();
          return fakeSocket;
        },
        httpFetcher: (url) async => _deviceXml,
      );

      final stream = provider.startDiscovery(
        timeout: const Duration(milliseconds: 500),
      );

      // Collect results
      final results = <List<CastDevice>>[];
      final sub = stream.listen(results.add);

      // Wait for socket setup
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Simulate SSDP response
      fakeSocket.simulateResponse(
        'HTTP/1.1 200 OK\r\n'
        'LOCATION: http://192.168.1.100:8080/description.xml\r\n'
        'USN: uuid:test-123::urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
        'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
        '\r\n',
      );

      // Wait for processing
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await sub.cancel();
      provider.dispose();

      expect(results, isNotEmpty);
      final lastDevices = results.last;
      expect(lastDevices, hasLength(1));
      expect(lastDevices.first.name, equals('Test TV'));
      expect(lastDevices.first.protocol, equals(CastProtocol.dlna));
    });

    test('sends M-SEARCH on start', () async {
      late FakeRawDatagramSocket fakeSocket;

      final provider = DlnaDiscoveryProvider(
        socketFactory: (host, port) async {
          fakeSocket = FakeRawDatagramSocket();
          return fakeSocket;
        },
        httpFetcher: (url) async => _deviceXml,
      );

      provider.startDiscovery(timeout: const Duration(milliseconds: 200));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(fakeSocket.sentData, isNotEmpty);

      provider.dispose();
    });

    test('stopDiscovery closes socket', () async {
      late FakeRawDatagramSocket fakeSocket;

      final provider = DlnaDiscoveryProvider(
        socketFactory: (host, port) async {
          fakeSocket = FakeRawDatagramSocket();
          return fakeSocket;
        },
        httpFetcher: (url) async => _deviceXml,
      );

      provider.startDiscovery(timeout: const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      provider.stopDiscovery();
      expect(fakeSocket.closed, isTrue);
    });

    test('deduplicates devices by UUID', () async {
      late FakeRawDatagramSocket fakeSocket;

      final provider = DlnaDiscoveryProvider(
        socketFactory: (host, port) async {
          fakeSocket = FakeRawDatagramSocket();
          return fakeSocket;
        },
        httpFetcher: (url) async => _deviceXml,
      );

      final stream = provider.startDiscovery(
        timeout: const Duration(milliseconds: 500),
      );
      final results = <List<CastDevice>>[];
      final sub = stream.listen(results.add);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Same device twice
      final response =
          'HTTP/1.1 200 OK\r\n'
          'LOCATION: http://192.168.1.100:8080/description.xml\r\n'
          'USN: uuid:test-123::urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
          '\r\n';

      fakeSocket.simulateResponse(response);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      fakeSocket.simulateResponse(response);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await sub.cancel();
      provider.dispose();

      // Should only have emitted once (second was deduplicated)
      if (results.isNotEmpty) {
        expect(results.last, hasLength(1));
      }
    });
  });

  test('the description is decoded as UTF-8 whatever the system code page '
      'is, and entities are unescaped', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      // No charset on the response: the XML declaration says UTF-8, and a
      // Windows host's ANSI code page must not be used instead.
      request.response.headers.set('Content-Type', 'text/xml');
      request.response.add(
        utf8.encode(
          _deviceXml.replaceFirst(
            '<friendlyName>Test TV</friendlyName>',
            '<friendlyName>リビング &amp; Café</friendlyName>',
          ),
        ),
      );
      await request.response.close();
    });

    late FakeRawDatagramSocket fakeSocket;
    final provider = DlnaDiscoveryProvider(
      socketFactory: (host, port) async => fakeSocket = FakeRawDatagramSocket(),
    );
    addTearDown(provider.dispose);
    final results = <List<CastDevice>>[];
    final sub = provider
        .startDiscovery(timeout: const Duration(seconds: 2))
        .listen(results.add);
    addTearDown(sub.cancel);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    fakeSocket.simulateResponse(
      'HTTP/1.1 200 OK\r\n'
      'LOCATION: http://127.0.0.1:${server.port}/description.xml\r\n'
      'USN: uuid:test-123::urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
      'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
      '\r\n',
    );
    for (var i = 0; i < 40 && results.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(results, isNotEmpty);
    expect(results.last.single.name, 'リビング & Café');
  });
}
