// End-to-end AirPlay verification against a real receiver.
//
//     dart run tool/airplay_hardware_check.dart <TV_IP> [media-url]
//
// Runs the full sequence the package uses — discover, connect, pair, RTSP
// SETUP with a live timing server, RECORD, /play, /rate, then poll
// /playback-info — and prints every wire step with its status so the trace
// can be diffed against a pyatv `--debug` run.
//
// This is not a unit test and is never run by CI. Mock servers cannot prove
// this code works; only a receiver can. Capture the output into
// doc/specs/2026-07-25-airplay-hardware-results.md.
//
// Options:
//   --features=0x...,0x...  override the advertised bitmask (skips mDNS)
//   --port=7000             AirPlay control port (default 7000)
//   --seconds=30            how long to poll /playback-info
//   --quiet                 hide DEBUG lines

import 'dart:async';
import 'dart:io';

import 'package:dart_cast/src/core/cast_device.dart';
import 'package:dart_cast/src/core/cast_media.dart';
import 'package:dart_cast/src/core/cast_session.dart';
import 'package:dart_cast/src/protocols/airplay/airplay_features.dart';
import 'package:dart_cast/src/protocols/airplay/airplay_session.dart';
import 'package:dart_cast/src/utils/logger.dart';
import 'package:dart_cast/src/utils/mdns_discovery.dart';

const String _defaultUrl =
    'http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4';

Future<void> main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln(
      'usage: dart run tool/airplay_hardware_check.dart <TV_IP> [media-url]',
    );
    exitCode = 64;
    return;
  }

  final host = positional[0];
  final mediaUrl = positional.length > 1 ? positional[1] : _defaultUrl;
  final options = _options(args);
  final quiet = args.contains('--quiet');
  final port = int.tryParse(options['port'] ?? '') ?? 7000;
  final pollSeconds = int.tryParse(options['seconds'] ?? '') ?? 30;

  final started = DateTime.now();
  CastLogger.setCallback((level, message) {
    if (quiet && level == 'DEBUG') return;
    final elapsed = DateTime.now().difference(started).inMilliseconds;
    stdout.writeln('  [${elapsed.toString().padLeft(6)}ms] $level  $message');
  });

  _step('Target', '$host:$port');
  _step('Media', mediaUrl);

  // -- Discovery -----------------------------------------------------------
  var features = options['features'] ?? '';
  var metadata = <String, String>{};
  var name = host;

  if (features.isEmpty) {
    _step('1. mDNS', 'looking for $host on _airplay._tcp ...');
    final service = await _findService(host);
    if (service == null) {
      stdout.writeln(
        '  NOT FOUND. Pass --features=0x...,0x... to skip discovery.',
      );
      exitCode = 1;
      return;
    }
    name = service.friendlyName;
    metadata = Map<String, String>.from(service.txtRecords);
    features = metadata['features'] ?? metadata['ft'] ?? '';
    stdout.writeln('  found "$name" with ${metadata.length} TXT records');
  } else {
    metadata = {'features': features};
    stdout.writeln('  using supplied features=$features');
  }

  final parsed = AirPlayFeatures.parse(features);
  _step('2. Capabilities', '$features -> $parsed');
  stdout.writeln(
    '  protocol            : ${parsed.isV2Protocol ? 'AirPlay 2' : 'AirPlay 1'}',
  );
  stdout.writeln('  video V1 (bit 0)    : ${parsed.supportsVideoV1}');
  stdout.writeln('  video V2 (bit 49)   : ${parsed.supportsVideoV2}');
  stdout.writeln('  transient pairing   : ${parsed.supportsTransientPairing}');

  if (!parsed.supportsVideo) {
    stdout.writeln('');
    stdout.writeln(
      'VERDICT: this receiver advertises no video URL playback. The package '
      'will refuse before sending anything. Use Chromecast or DLNA.',
    );
    exitCode = 2;
    return;
  }

  final device = CastDevice(
    id: metadata['deviceid'] ?? host,
    name: name,
    protocol: CastProtocol.airplay,
    address: InternetAddress(host),
    port: port,
    metadata: metadata,
  );

  final session = AirPlaySession(device);
  final states = <SessionState>[];
  final stateSub = session.stateStream.listen(states.add);

  try {
    // -- Connect + pair + (for AirPlay 2) encrypted channel ----------------
    _step('3. Connect', 'probing /info, pairing, opening the HAP channel');
    await session.connect();
    stdout.writeln('  connected, state=${session.state}');

    // -- SETUP + RECORD + /play + /rate ------------------------------------
    _step('4. Play', 'SETUP (with timing server) -> RECORD -> /play -> /rate');
    await session.loadMedia(CastMedia(url: mediaUrl, type: CastMediaType.mp4));
    stdout.writeln('  /play accepted, state=${session.state}');

    // -- Poll --------------------------------------------------------------
    _step('5. Poll', 'reading /playback-info for ${pollSeconds}s');
    Duration? lastPosition;
    Duration? lastDuration;
    final posSub = session.positionStream.listen((p) => lastPosition = p);
    final durSub = session.durationStream.listen((d) => lastDuration = d);

    for (var i = 0; i < pollSeconds; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      stdout.writeln(
        '  t+${(i + 1).toString().padLeft(2)}s  state=${session.state}  '
        'position=${lastPosition?.inSeconds ?? '-'}s  '
        'duration=${lastDuration?.inSeconds ?? '-'}s',
      );
    }

    await posSub.cancel();
    await durSub.cancel();

    // -- Verdict -----------------------------------------------------------
    _step('6. Verdict', '');
    final playing = session.state == SessionState.playing;
    final advanced = (lastPosition?.inMilliseconds ?? 0) > 0;
    final hasDuration = (lastDuration?.inMilliseconds ?? 0) > 0;

    stdout.writeln('  states seen     : ${states.join(' -> ')}');
    stdout.writeln('  reached playing : $playing');
    stdout.writeln('  duration known  : $hasDuration (${lastDuration ?? '-'})');
    stdout.writeln('  position moved  : $advanced (${lastPosition ?? '-'})');
    stdout.writeln('');

    if (playing && hasDuration && advanced) {
      stdout.writeln('PASS — the receiver is playing the URL.');
    } else if (hasDuration && !advanced) {
      stdout.writeln(
        'PARTIAL — the item loaded but the position is not advancing. '
        'That is the signature of a missing or rejected /rate: an AirPlay 2 '
        '/play starts paused.',
      );
      exitCode = 3;
    } else {
      stdout.writeln(
        'FAIL — no duration was ever reported. Compare the trace above with a '
        'pyatv --debug run; the first request that differs is the defect.',
      );
      exitCode = 3;
    }
  } catch (e, stack) {
    stdout.writeln('');
    stdout.writeln('FAIL — $e');
    stdout.writeln(stack.toString());
    exitCode = 1;
  } finally {
    _step('7. Teardown', 'stop + disconnect');
    try {
      await session.stop();
    } catch (e) {
      stdout.writeln('  stop failed: $e');
    }
    try {
      await session.disconnect();
    } catch (e) {
      stdout.writeln('  disconnect failed: $e');
    }
    await stateSub.cancel();
    session.dispose();
  }
}

Map<String, String> _options(List<String> args) {
  final result = <String, String>{};
  for (final arg in args.where((a) => a.startsWith('--'))) {
    final body = arg.substring(2);
    final eq = body.indexOf('=');
    if (eq > 0) result[body.substring(0, eq)] = body.substring(eq + 1);
  }
  return result;
}

Future<MdnsServiceInfo?> _findService(String host) async {
  try {
    await for (final service in MdnsDiscovery.discover(
      MdnsDiscovery.airplayServiceType,
    ).timeout(const Duration(seconds: 12), onTimeout: (sink) => sink.close())) {
      if (service.host == host) return service;
    }
  } catch (e) {
    stdout.writeln('  discovery error: $e');
  }
  return null;
}

void _step(String title, String detail) {
  stdout.writeln('');
  stdout.writeln('--- $title ${detail.isEmpty ? '' : '— $detail'}');
}
