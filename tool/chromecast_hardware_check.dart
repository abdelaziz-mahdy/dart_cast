// End-to-end Chromecast verification against a real receiver.
//
//     dart run tool/chromecast_hardware_check.dart <IP> <media-file-or-url>
//
// Connects, casts, watches playback, then exercises pause / resume / seek.
// The verdict is judged on what the RECEIVER reports, never on a value this
// tool computed — a check that adds its own offset to a device position will
// happily call a frozen picture a success.
//
// This is not a unit test and is never run by CI: mock servers cannot prove a
// receiver accepts what we send.
//
// Options:
//   --as-source     feed the file through MediaSource instead of a path,
//                   exercising the byte-source path a content:// URI or a
//                   Flutter asset would take
//   --seconds=15    how long to watch before touching the controls
//   --port=8009     receiver port
//   --quiet         hide DEBUG lines

import 'dart:async';
import 'dart:io';

import 'package:dart_cast/src/core/cast_device.dart';
import 'package:dart_cast/src/core/cast_media.dart';
import 'package:dart_cast/src/core/cast_session.dart';
import 'package:dart_cast/src/core/media_source.dart';
import 'package:dart_cast/src/protocols/chromecast/chromecast_session.dart';
import 'package:dart_cast/src/utils/logger.dart';

Future<void> main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.length < 2) {
    stderr.writeln(
      'usage: dart run tool/chromecast_hardware_check.dart <IP> <media>',
    );
    exitCode = 64;
    return;
  }

  final host = positional[0];
  final mediaPath = positional[1];
  final options = _options(args);
  final quiet = args.contains('--quiet');
  final asSource = args.contains('--as-source');
  final port = int.tryParse(options['port'] ?? '') ?? 8009;
  final watchSeconds = int.tryParse(options['seconds'] ?? '') ?? 15;

  final started = DateTime.now();
  CastLogger.setCallback((level, message) {
    if (quiet && level == 'DEBUG') return;
    final elapsed = DateTime.now().difference(started).inMilliseconds;
    stdout.writeln('  [${elapsed.toString().padLeft(6)}ms] $level  $message');
  });

  final device = CastDevice(
    id: 'chromecast-hardware-check',
    name: 'Chromecast under test',
    protocol: CastProtocol.chromecast,
    address: InternetAddress(host),
    port: port,
  );

  final session = ChromecastSession(device: device);
  final states = <SessionState>[];
  Duration? position;
  Duration? duration;
  final stateSub = session.stateStream.listen(states.add);
  final posSub = session.positionStream.listen((p) => position = p);
  final durSub = session.durationStream.listen((d) => duration = d);

  var ok = false;
  try {
    _step('1. Connect', '$host:$port');
    await session.connect();
    stdout.writeln('  connected, state=${session.state}');

    _step('2. Load', asSource ? 'via MediaSource' : mediaPath);
    final media = await _buildMedia(mediaPath, asSource: asSource);
    await session.loadMedia(media);
    stdout.writeln('  loadMedia returned, state=${session.state}');

    _step('3. Watch', '${watchSeconds}s');
    for (var i = 0; i < watchSeconds; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      stdout.writeln(
        '  t+${(i + 1).toString().padLeft(2)}s  state=${session.state}  '
        'position=${position?.inSeconds ?? '-'}s  '
        'duration=${duration?.inSeconds ?? '-'}s',
      );
    }

    final advanced = (position?.inMilliseconds ?? 0) > 0;
    final hasDuration = (duration?.inMilliseconds ?? 0) > 0;

    var controlsOk = true;
    if (advanced) {
      _step('4. Controls', 'pause / resume / seek');

      await session.pause();
      await Future<void>.delayed(const Duration(seconds: 3));
      final paused = session.state == SessionState.paused;
      final atPause = position;
      stdout.writeln('  after pause : state=${session.state}');

      await session.play();
      await Future<void>.delayed(const Duration(seconds: 3));
      stdout.writeln('  after resume: state=${session.state}');

      // Judge the seek on the receiver's own progress, not on anything this
      // tool worked out for itself.
      await session.seek(const Duration(minutes: 2));
      await Future<void>.delayed(const Duration(seconds: 5));
      final justAfter = position;
      await Future<void>.delayed(const Duration(seconds: 5));
      final later = position;

      final landedNearTarget =
          justAfter != null && (justAfter.inSeconds - 120).abs() <= 20;
      final stillProgressing =
          later != null && justAfter != null && later > justAfter;
      final seekOk =
          landedNearTarget &&
          stillProgressing &&
          session.state == SessionState.playing;

      stdout.writeln(
        '  seek        : target=120s  +5s=${justAfter?.inSeconds ?? '-'}s  '
        '+10s=${later?.inSeconds ?? '-'}s  state=${session.state}',
      );
      stdout.writeln(
        seekOk
            ? '  seek OK — landed near the target and kept advancing.'
            : '  seek FAILED — did not land near 120s or stopped advancing.',
      );

      controlsOk = paused && seekOk;
      if (!paused) {
        stdout.writeln('  pause FAILED — receiver never reported paused');
      }
      if (atPause == null) {
        stdout.writeln('  (no position captured at pause)');
      }
    }

    _step('5. Verdict', '');
    stdout.writeln('  states seen    : ${states.join(' -> ')}');
    stdout.writeln('  duration known : $hasDuration (${duration ?? '-'})');
    stdout.writeln('  position moved : $advanced (${position ?? '-'})');
    ok = advanced && hasDuration && controlsOk;
    stdout.writeln('');
    stdout.writeln(
      ok
          ? 'PASS — the receiver played and responded to controls.'
          : 'FAIL — see above. Check the TV screen before trusting this log.',
    );
  } catch (e, stack) {
    stdout.writeln('');
    stdout.writeln('FAIL — $e');
    stdout.writeln(stack.toString().split('\n').take(6).join('\n'));
  } finally {
    _step('6. Teardown', 'stop + disconnect');
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
    await posSub.cancel();
    await durSub.cancel();
    session.dispose();
  }

  exitCode = ok ? 0 : 3;
  exit(exitCode);
}

Future<CastMedia> _buildMedia(String path, {required bool asSource}) async {
  final type = _typeFor(path);
  final isLocal = !path.startsWith('http');

  if (asSource) {
    if (!isLocal) {
      throw ArgumentError('--as-source needs a local file, not a URL');
    }
    final source = await MediaSource.file(File(path), contentType: 'video/mp4');
    stdout.writeln('  MediaSource: ${source.length} bytes');
    return CastMedia.source(
      source,
      type: type,
      fileExtension: '.mp4',
      title: 'dart_cast byte-source check',
    );
  }

  if (isLocal) {
    return CastMedia.file(
      filePath: path,
      type: type,
      title: 'dart_cast hardware check',
    );
  }

  return CastMedia(url: path, type: type, title: 'dart_cast hardware check');
}

CastMediaType _typeFor(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.m3u8')) return CastMediaType.hls;
  if (lower.endsWith('.mkv')) return CastMediaType.mkv;
  if (lower.endsWith('.ts')) return CastMediaType.mpegTs;
  return CastMediaType.mp4;
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

void _step(String title, String detail) {
  stdout.writeln('');
  stdout.writeln('--- $title ${detail.isEmpty ? '' : '— $detail'}');
}
