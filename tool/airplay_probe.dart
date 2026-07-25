// Standalone network probe for AirPlay / Chromecast receivers.
//
// Run it on a machine that shares a LAN with the TV:
//
//     dart run tool/airplay_probe.dart
//
// It lists every `_airplay._tcp`, `_raop._tcp` and `_googlecast._tcp` instance
// it can see, prints each TXT record verbatim, decodes the AirPlay feature
// bitmask bit by bit, and checks TCP reachability on the ports each protocol
// uses. The decoded bits are what decide which protocol path the package
// takes, so this is the first thing to run when a device misbehaves.
//
// Nothing here touches the device beyond a TCP connect — it starts no
// playback and performs no pairing.

import 'dart:async';
import 'dart:io';

import 'package:dart_cast/src/protocols/airplay/airplay_features.dart';
import 'package:dart_cast/src/utils/mdns_discovery.dart';

/// Feature bits worth naming in the output, from pyatv's `AirPlayFlags`.
const Map<int, String> _featureBitNames = {
  0: 'SupportsAirPlayVideoV1',
  1: 'SupportsAirPlayPhoto',
  5: 'SupportsAirPlaySlideShow',
  7: 'SupportsAirPlayScreen',
  9: 'SupportsAirPlayAudio',
  11: 'AudioRedundant',
  14: 'Authentication_4',
  15: 'MetadataFeatures_0',
  16: 'MetadataFeatures_1',
  17: 'MetadataFeatures_2',
  18: 'AudioFormats_0',
  19: 'AudioFormats_1',
  20: 'AudioFormats_2',
  21: 'AudioFormats_3',
  23: 'Authentication_1',
  26: 'Authentication_8',
  27: 'SupportsLegacyPairing',
  30: 'HasUnifiedAdvertiserInfo',
  32: 'IsCarPlay',
  33: 'SupportsAirPlayVideoPlayQueue',
  34: 'SupportsAirPlayFromCloud',
  35: 'SupportsTLS_PSK',
  38: 'SupportsUnifiedMediaControl',
  40: 'SupportsBufferedAudio',
  41: 'SupportsPTP',
  42: 'SupportsScreenMultiCodec',
  43: 'SupportsSystemPairing',
  44: 'IsAPValeriaScreenSender',
  46: 'SupportsHKPairingAndAccessControl',
  48: 'SupportsCoreUtilsPairingAndEncryption',
  49: 'SupportsAirPlayVideoV2',
  50: 'MetadataFeatures_3',
  51: 'SupportsUnifiedPairSetupandMFi',
  52: 'SupportsSetPeersExtendedMessage',
  54: 'SupportsAPSync',
  55: 'SupportsWoL',
  56: 'SupportsWoL2',
  58: 'SupportsHangdogRemoteControl',
  59: 'SupportsAudioStreamConnectionSetup',
  60: 'SupportsAudioMetadataControl',
  61: 'SupportsRFC2198Redundancy',
};

const List<int> _portsToProbe = [7000, 5000, 8008, 8009, 7100];

Future<void> main(List<String> args) async {
  final serviceTypes = {
    'AirPlay': '_airplay._tcp.local',
    'RAOP (AirPlay audio)': '_raop._tcp.local',
    'Chromecast': '_googlecast._tcp.local',
  };

  stdout.writeln('dart_cast AirPlay probe');
  stdout.writeln('Local interfaces: ${await _localAddresses()}');
  stdout.writeln('');

  for (final entry in serviceTypes.entries) {
    stdout.writeln('=' * 72);
    stdout.writeln('${entry.key}  (${entry.value})');
    stdout.writeln('=' * 72);

    final found = <MdnsServiceInfo>[];
    try {
      await for (final service in MdnsDiscovery.discover(entry.value).timeout(
        const Duration(seconds: 12),
        onTimeout: (sink) => sink.close(),
      )) {
        found.add(service);
      }
    } catch (e) {
      stdout.writeln('  discovery failed: $e');
    }

    if (found.isEmpty) {
      stdout.writeln('  (nothing found)');
      stdout.writeln('');
      continue;
    }

    for (final service in found) {
      await _report(service);
    }
  }

  stdout.writeln('Probe complete.');
}

Future<void> _report(MdnsServiceInfo service) async {
  stdout.writeln('');
  stdout.writeln(
    '  ${service.friendlyName}  ->  ${service.host}:${service.port}',
  );
  stdout.writeln('    instance : ${service.name}');
  if (service.deviceId.isNotEmpty) {
    stdout.writeln('    deviceid : ${service.deviceId}');
  }
  if (service.model.isNotEmpty) {
    stdout.writeln('    model    : ${service.model}');
  }

  if (service.txtRecords.isEmpty) {
    stdout.writeln('    TXT      : (none)');
  } else {
    stdout.writeln('    TXT      :');
    final keys = service.txtRecords.keys.toList()..sort();
    for (final key in keys) {
      stdout.writeln('      $key=${service.txtRecords[key]}');
    }
  }

  final rawFeatures =
      service.txtRecords['features'] ?? service.txtRecords['ft'] ?? '';
  if (rawFeatures.isNotEmpty) {
    _reportFeatures(rawFeatures);
  }

  final reachable = <String>[];
  for (final port in _portsToProbe) {
    if (await _isReachable(service.host, port)) {
      reachable.add('$port');
    }
  }
  stdout.writeln(
    '    TCP open : ${reachable.isEmpty ? '(none of $_portsToProbe)' : reachable.join(', ')}',
  );
}

void _reportFeatures(String raw) {
  final features = AirPlayFeatures.parse(raw);
  final hex = features.rawValue.toRadixString(16).padLeft(16, '0');

  stdout.writeln('    features : $raw  (0x$hex)');

  final set = <String>[];
  for (final bit in _featureBitNames.keys.toList()..sort()) {
    if ((features.rawValue >> bit) & 1 == 1) {
      set.add('$bit ${_featureBitNames[bit]}');
    }
  }
  stdout.writeln('    bits set :');
  for (final name in set) {
    stdout.writeln('      $name');
  }

  // The four decisions the package actually makes off this bitmask.
  stdout.writeln('    verdict  :');
  stdout.writeln(
    '      protocol           : ${features.isV2Protocol ? 'AirPlay 2' : 'AirPlay 1'}'
    ' (bit 38=${_bit(features.rawValue, 38)}, bit 48=${_bit(features.rawValue, 48)})',
  );
  stdout.writeln(
    '      video URL playback : '
    '${_videoVerdict(features)}',
  );
  stdout.writeln(
    '      pairing            : '
    '${features.supportsTransientPairing
        ? 'transient (X-Apple-HKP 4, no PIN)'
        : features.requiresHapPairing
        ? 'HAP PIN (X-Apple-HKP 3)'
        : 'none advertised'}',
  );
  stdout.writeln(
    '      audio / mirroring  : audio=${features.supportsAudio}, '
    'screen=${features.supportsScreen}',
  );
}

String _videoVerdict(AirPlayFeatures features) {
  if (features.isV2Protocol) {
    return features.supportsVideoV2
        ? 'yes, via AirPlay 2 (bit 49)'
        : 'NO — AirPlay 2 receiver without bit 49, mirroring/audio only';
  }
  return features.supportsVideoV1
      ? 'yes, via AirPlay 1 (bit 0)'
      : 'NO — neither bit 0 nor an AirPlay 2 protocol bit';
}

String _bit(int value, int bit) => (value >> bit) & 1 == 1 ? '1' : '0';

Future<bool> _isReachable(String host, int port) async {
  try {
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(milliseconds: 700),
    );
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

Future<String> _localAddresses() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
  );
  return interfaces
      .expand((i) => i.addresses.map((a) => '${i.name}=${a.address}'))
      .join(', ');
}
