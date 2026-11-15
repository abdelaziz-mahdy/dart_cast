import 'dart:async';

import '../../core/cast_device.dart';
import '../../core/discovery_provider.dart';
import '../../utils/logger.dart';
import '../../utils/mdns_discovery.dart';
import 'airplay_features.dart';

/// Discovers AirPlay devices via mDNS (_airplay._tcp.local).
///
/// Queries the local network for AirPlay services, parses TXT records
/// via [MdnsServiceInfo], filters by video support, and emits [CastDevice]
/// lists as devices are found.
class AirPlayDiscoveryProvider implements DeviceDiscoveryProvider {
  final MdnsLookup _mdnsLookup;
  StreamController<List<CastDevice>>? _controller;
  StreamSubscription<MdnsServiceInfo>? _subscription;
  Timer? _timeoutTimer;
  final Map<String, CastDevice> _devices = {};

  /// Creates an [AirPlayDiscoveryProvider].
  ///
  /// An optional [mdnsLookup] can be provided for testing.
  AirPlayDiscoveryProvider({MdnsLookup? mdnsLookup})
    : _mdnsLookup = mdnsLookup ?? _defaultMdnsLookup;

  @override
  CastProtocol get protocol => CastProtocol.airplay;

  @override
  Stream<List<CastDevice>> startDiscovery({
    Duration timeout = const Duration(seconds: 10),
  }) {
    stopDiscovery();
    _devices.clear();
    _controller = StreamController<List<CastDevice>>();

    CastLogger.info('AirPlay: starting mDNS discovery');
    final stream = _mdnsLookup(MdnsDiscovery.airplayServiceType);
    _subscription = stream.listen(
      (info) {
        // Note: We do NOT filter by features bitmask here.
        // AirPlay 2 devices (smart TVs) use different feature bits than
        // AirPlay 1, so bit 0 is not a reliable indicator of video support.
        // Computer filtering is handled by DiscoveryManager._shouldFilter().
        final featuresStr =
            info.txtRecords['features'] ?? info.txtRecords['ft'] ?? '';
        final features = AirPlayFeatures.parse(featuresStr);
        final device = info.toAirplayDevice();
        if (!_devices.containsKey(device.id)) {
          CastLogger.info(
            'AirPlay: found "${device.name}" at ${device.address.address}:${device.port} $features',
          );
          _devices[device.id] = device;
          if (_controller?.isClosed == false) {
            _controller!.add(_devices.values.toList());
          }
        }
      },
      onError: (Object error) {
        CastLogger.error('AirPlay: discovery error: $error');
        if (_controller?.isClosed == false) {
          _controller!.addError(error);
        }
      },
      onDone: () {
        if (_controller?.isClosed == false) {
          _controller!.close();
        }
      },
    );

    // Close after timeout
    // Kept so a later startDiscovery() or stopDiscovery() can cancel it;
    // otherwise this run's timer would close the next run's stream early.
    _timeoutTimer = Timer(timeout, stopDiscovery);

    return _controller!.stream;
  }

  @override
  void stopDiscovery() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _subscription?.cancel();
    _subscription = null;
    if (_controller?.isClosed == false) {
      _controller?.close();
    }
    _controller = null;
  }

  @override
  void dispose() {
    stopDiscovery();
  }

  /// Default mDNS lookup using the multicast_dns package.
  static Stream<MdnsServiceInfo> _defaultMdnsLookup(String serviceType) {
    return MdnsDiscovery.discover(serviceType);
  }
}
