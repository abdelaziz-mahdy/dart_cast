import 'dart:async';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

import '../core/cast_device.dart';
import '../protocols/airplay/airplay_features.dart';
import 'logger.dart';

/// Represents a discovered mDNS service with its TXT records.
///
/// Shared infrastructure for both Chromecast and AirPlay device discovery.
class MdnsServiceInfo {
  /// The mDNS service name.
  final String name;

  /// The resolved host address.
  final String host;

  /// The service port.
  final int port;

  /// TXT record key-value pairs from the mDNS advertisement.
  final Map<String, String> txtRecords;

  const MdnsServiceInfo({
    required this.name,
    required this.host,
    required this.port,
    required this.txtRecords,
  });

  /// Human-readable device name.
  ///
  /// Uses the Chromecast `fn` TXT field if present, otherwise falls back
  /// to the mDNS service [name].
  String get friendlyName {
    if (txtRecords.containsKey('fn')) return txtRecords['fn']!;
    // Strip mDNS service suffix from name (e.g., "My TV._airplay._tcp.local" → "My TV")
    final dotIndex = name.indexOf('._');
    return dotIndex > 0 ? name.substring(0, dotIndex) : name;
  }

  /// Unique device identifier.
  ///
  /// Uses Chromecast `id` or AirPlay `deviceid` TXT field. When neither is
  /// present (TXT records are advisory and the lookup may time out, RFC
  /// 6763 §6), falls back to the service instance [name], which is unique
  /// on the link, so two such devices are not merged into one.
  String get deviceId {
    final id = txtRecords['id'] ?? txtRecords['deviceid'];
    if (id != null && id.isNotEmpty) return id;
    return name;
  }

  /// Device model string.
  ///
  /// Uses Chromecast `md` or AirPlay `model` TXT field.
  String get model => txtRecords['md'] ?? txtRecords['model'] ?? '';

  /// Whether the given AirPlay features bitmask indicates video support.
  ///
  /// The [features] string can be single-part (`"0x5A7FFFF7"`) or
  /// two-part (`"0x5A7FFFF7,0x1E"`) where the first part is the lower
  /// 32 bits and the second is the upper 32 bits.
  ///
  /// Video support is bit 0 (`SupportsAirPlayVideoV1`) **or** bit 49
  /// (`SupportsAirPlayVideoV2`). Checking only bit 0 misreads every
  /// AirPlay 2–only receiver as incapable of video — which is exactly the
  /// wrong call for the Roku and Google TV devices that set bit 49 and leave
  /// bit 0 clear.
  static bool supportsVideo(String features) =>
      AirPlayFeatures.parse(features).supportsVideo;

  /// Creates a [CastDevice] configured for the Chromecast protocol.
  CastDevice toChromecastDevice() {
    return CastDevice(
      id: deviceId,
      name: friendlyName,
      protocol: CastProtocol.chromecast,
      address: InternetAddress(host),
      port: port,
      metadata: Map<String, String>.from(txtRecords),
    );
  }

  /// Creates a [CastDevice] configured for the AirPlay protocol.
  CastDevice toAirplayDevice() {
    return CastDevice(
      id: deviceId,
      name: friendlyName,
      protocol: CastProtocol.airplay,
      address: InternetAddress(host),
      port: port,
      metadata: Map<String, String>.from(txtRecords),
    );
  }
}

/// Function type for performing mDNS service discovery.
///
/// Returns a stream of [MdnsServiceInfo] entries found on the network.
typedef MdnsLookup = Stream<MdnsServiceInfo> Function(String serviceType);

/// Constants and utilities for mDNS-based device discovery.
class MdnsDiscovery {
  MdnsDiscovery._();

  /// mDNS service type for Chromecast devices.
  static const String chromecastServiceType = '_googlecast._tcp.local';

  /// Parses the TXT strings of a service, as the multicast_dns package
  /// hands them over (one string per line), into [into].
  ///
  /// RFC 6763 §6.4: keys are case-insensitive (stored lower-case), only
  /// the first occurrence of a key counts, a string with no `=` is a
  /// boolean attribute (stored with an empty value), and a string that
  /// starts with `=` is ignored. Values are kept exactly as sent.
  static Map<String, String> parseTxtRecords(
    String text, {
    Map<String, String>? into,
  }) {
    final records = into ?? <String, String>{};
    for (var line in text.split('\n')) {
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      if (line.isEmpty) continue;
      final eqIndex = line.indexOf('=');
      if (eqIndex == 0) continue;
      final key =
          (eqIndex < 0 ? line : line.substring(0, eqIndex)).toLowerCase();
      final value = eqIndex < 0 ? '' : line.substring(eqIndex + 1);
      records.putIfAbsent(key, () => value);
    }
    return records;
  }

  /// mDNS service type for AirPlay devices.
  static const String airplayServiceType = '_airplay._tcp.local';

  /// Discover mDNS services of the given [serviceType] using the
  /// `multicast_dns` package.
  ///
  /// Yields [MdnsServiceInfo] entries as they are found on the local network.
  /// The stream completes after all discovered PTR records have been resolved.
  static Stream<MdnsServiceInfo> discover(String serviceType) async* {
    CastLogger.info('mDNS: starting discovery for $serviceType');
    final client = MDnsClient();
    try {
      await client.start();
      CastLogger.debug('mDNS: client started, querying PTR records');
    } catch (e) {
      CastLogger.error('mDNS discovery failed to start: $e');
      return;
    }

    try {
      const nestedTimeout = Duration(seconds: 3);
      final seenServices = <String>{};

      // Send multiple mDNS queries to catch slow-responding devices.
      // Each lookup() sends one query — devices may not respond to the first.
      for (int round = 0; round < 3; round++) {
        if (round > 0) {
          await Future<void>.delayed(const Duration(seconds: 2));
          CastLogger.debug(
            'mDNS: re-querying PTR records (round ${round + 1})',
          );
        }

        // Query for PTR records (service instances).
        await for (final PtrResourceRecord ptr in client
            .lookup<PtrResourceRecord>(
              ResourceRecordQuery.serverPointer(serviceType),
            )) {
          // Skip already-discovered services
          if (seenServices.contains(ptr.domainName)) continue;
          seenServices.add(ptr.domainName);
          try {
            // For each PTR result, look up SRV record (host + port).
            await for (final SrvResourceRecord srv in client
                .lookup<SrvResourceRecord>(
                  ResourceRecordQuery.service(ptr.domainName),
                )
                .timeout(nestedTimeout, onTimeout: (sink) => sink.close())) {
              try {
                // Look up A record (IPv4 address).
                await for (final IPAddressResourceRecord ip in client
                    .lookup<IPAddressResourceRecord>(
                      ResourceRecordQuery.addressIPv4(srv.target),
                    )
                    .timeout(
                      nestedTimeout,
                      onTimeout: (sink) => sink.close(),
                    )) {
                  // Look up TXT records (metadata key=value pairs).
                  final txtRecords = <String, String>{};
                  try {
                    await for (final TxtResourceRecord txt in client
                        .lookup<TxtResourceRecord>(
                          ResourceRecordQuery.text(ptr.domainName),
                        )
                        .timeout(
                          nestedTimeout,
                          onTimeout: (sink) => sink.close(),
                        )) {
                      MdnsDiscovery.parseTxtRecords(txt.text, into: txtRecords);
                    }
                  } catch (_) {
                    // TXT lookup timed out — proceed with empty TXT records
                  }

                  CastLogger.info(
                    'mDNS: found service "${ptr.domainName}" at ${ip.address.address}:${srv.port}',
                  );
                  yield MdnsServiceInfo(
                    name: ptr.domainName,
                    host: ip.address.address,
                    port: srv.port,
                    txtRecords: txtRecords,
                  );
                }
              } catch (_) {
                // A record lookup timed out — skip this device
              }
            }
          } catch (_) {
            // SRV lookup timed out — skip this device
          }
        }
      } // end for round
    } finally {
      client.stop();
    }
  }
}
