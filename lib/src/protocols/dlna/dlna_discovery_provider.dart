import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/cast_device.dart';
import '../../core/discovery_provider.dart';
import '../../utils/logger.dart';
import 'dlna_device.dart';
import 'ssdp_discovery.dart';

/// Function type for creating a UDP socket for SSDP discovery.
typedef RawDatagramSocketFactory =
    Future<RawDatagramSocket> Function(dynamic host, int port);

/// Function type listing the local IPv4 addresses to search from.
typedef LocalAddressLister = Future<List<InternetAddress>> Function();

/// Function type for fetching a URL and returning its body.
typedef HttpFetcher = Future<String> Function(String url);

/// Discovers DLNA (UPnP) media renderers via SSDP M-SEARCH.
///
/// Sends multicast M-SEARCH queries for AVTransport and MediaRenderer
/// services, parses responses, fetches device description XML, and
/// emits [CastDevice] lists as devices are found.
class DlnaDiscoveryProvider implements DeviceDiscoveryProvider {
  final RawDatagramSocketFactory _socketFactory;
  final HttpFetcher _httpFetcher;
  final LocalAddressLister _localAddresses;

  final List<RawDatagramSocket> _sockets = [];
  StreamController<List<CastDevice>>? _controller;
  Timer? _searchTimer;
  Timer? _timeoutTimer;
  final Map<String, CastDevice> _devices = {};

  /// Creates a [DlnaDiscoveryProvider].
  ///
  /// Optional [socketFactory], [httpFetcher] and [localAddresses] can be
  /// provided for testing. With a [socketFactory] but no [localAddresses],
  /// one socket bound to the wildcard address is used.
  DlnaDiscoveryProvider({
    RawDatagramSocketFactory? socketFactory,
    HttpFetcher? httpFetcher,
    LocalAddressLister? localAddresses,
  }) : _socketFactory = socketFactory ?? RawDatagramSocket.bind,
       _httpFetcher = httpFetcher ?? _defaultHttpFetch,
       _localAddresses =
           localAddresses ??
           (socketFactory == null
               ? _ipv4InterfaceAddresses
               : () async => [InternetAddress.anyIPv4]);

  /// Every non-loopback IPv4 address of this host, or the wildcard address
  /// when none can be listed.
  static Future<List<InternetAddress>> _ipv4InterfaceAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      final addresses = [
        for (final i in interfaces)
          for (final a in i.addresses)
            if (!a.isLoopback && !a.isLinkLocal) a,
      ];
      if (addresses.isNotEmpty) return addresses;
    } catch (e) {
      CastLogger.debug('DLNA: could not list interfaces ($e)');
    }
    return [InternetAddress.anyIPv4];
  }

  @override
  CastProtocol get protocol => CastProtocol.dlna;

  @override
  Stream<List<CastDevice>> startDiscovery({
    Duration timeout = const Duration(seconds: 10),
  }) {
    stopDiscovery();
    _devices.clear();
    _controller = StreamController<List<CastDevice>>();

    _doDiscovery(timeout);

    return _controller!.stream;
  }

  Future<void> _doDiscovery(Duration timeout) async {
    try {
      final controller = _controller;
      // UDA 1.1 §1.1.2: a control point searches on every network it is
      // attached to. One wildcard socket only reaches the interface of the
      // default multicast route, so a TV on a second LAN (Ethernet beside
      // Wi-Fi, a VPN) was never asked. One socket per IPv4 address, each
      // sending through its own interface.
      final addresses = await _localAddresses();
      CastLogger.info(
        'DLNA: binding ${addresses.length} UDP socket(s) for SSDP discovery',
      );
      for (final address in addresses) {
        final RawDatagramSocket socket;
        try {
          socket = await _socketFactory(address, 0);
        } catch (e) {
          CastLogger.debug('DLNA: cannot bind ${address.address}: $e');
          continue;
        }
        if (!identical(controller, _controller)) {
          // stopDiscovery() or a newer startDiscovery() ran while binding.
          socket.close();
          return;
        }
        _configure(socket, address);
        _sockets.add(socket);
      }
      if (_sockets.isEmpty) {
        throw const SocketException('DLNA: no socket could be bound');
      }

      // Send M-SEARCH for MediaRenderer
      final searchTarget = SsdpConstants.searchTargets[2]; // MediaRenderer
      final mSearch = SsdpMessage.mSearch(searchTarget, 3);
      final data = mSearch.codeUnits;
      final group = InternetAddress(SsdpConstants.multicastAddress);

      void sendAll() {
        for (final socket in _sockets) {
          try {
            socket.send(data, group, SsdpConstants.multicastPort);
          } catch (e) {
            CastLogger.debug('DLNA: M-SEARCH send failed: $e');
          }
        }
      }

      CastLogger.info(
        'DLNA: sending M-SEARCH to ${SsdpConstants.multicastAddress}:${SsdpConstants.multicastPort}',
      );
      sendAll();

      // Send again after a short delay for reliability
      _searchTimer = Timer(const Duration(milliseconds: 500), sendAll);

      // Close after timeout
      _timeoutTimer = Timer(timeout, () {
        CastLogger.info('DLNA: discovery timeout reached, closing');
        stopDiscovery();
      });
    } catch (e) {
      CastLogger.error('DLNA: discovery failed: $e');
      _controller?.addError(e);
      _controller?.close();
    }
  }

  void _configure(RawDatagramSocket socket, InternetAddress address) {
    socket.broadcastEnabled = true;
    socket.multicastLoopback = false;
    // UDA 1.1 §1.1.2: the multicast TTL SHOULD default to 2.
    socket.multicastHops = 2;
    if (address != InternetAddress.anyIPv4) {
      // Send this socket's multicast through the interface owning
      // [address] (IP_MULTICAST_IF takes the interface's IPv4 address).
      try {
        socket.setRawOption(
          RawSocketOption(
            RawSocketOption.levelIPv4,
            RawSocketOption.IPv4MulticastInterface,
            address.rawAddress,
          ),
        );
      } catch (e) {
        CastLogger.debug(
          'DLNA: cannot pin multicast to ${address.address}: $e',
        );
      }
    }
    socket.listen((event) {
      if (event == RawSocketEvent.read) {
        final datagram = socket.receive();
        if (datagram != null) {
          _handleResponse(String.fromCharCodes(datagram.data));
        }
      }
    });
  }

  void _handleResponse(String data) async {
    final response = SsdpMessage.parseResponse(data);
    final location = response.location;
    if (location == null) return;

    final uuid = SsdpMessage.extractUuid(response.usn);
    if (uuid == null) return;

    // Skip if we already have this device
    if (_devices.containsKey(uuid)) return;

    CastLogger.debug(
      'DLNA: SSDP response from $uuid, fetching description at $location',
    );

    try {
      final xml = await _httpFetcher(location);
      final description = DlnaDeviceDescription.parse(xml, location);
      final device = description.toCastDevice();
      CastLogger.info(
        'DLNA: found device "${device.name}" at ${device.address.address}:${device.port}',
      );
      _devices[uuid] = device;

      if (_controller?.isClosed == false) {
        _controller!.add(_devices.values.toList());
      }
    } catch (e) {
      CastLogger.warning(
        'DLNA: failed to fetch description for $uuid at $location: $e',
      );
    }
  }

  @override
  void stopDiscovery() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _searchTimer?.cancel();
    _searchTimer = null;
    for (final socket in _sockets) {
      socket.close();
    }
    _sockets.clear();
    if (_controller?.isClosed == false) {
      _controller?.close();
    }
    _controller = null;
  }

  @override
  void dispose() {
    stopDiscovery();
  }

  static Future<String> _defaultHttpFetch(String url) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      // UPnP descriptions are UTF-8 (UDA 1.1 §2.1). SystemEncoding would
      // decode them with the ANSI code page on Windows.
      final bytes = await response.fold<List<int>>(
        <int>[],
        (all, chunk) => all..addAll(chunk),
      );
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      client.close();
    }
  }
}
