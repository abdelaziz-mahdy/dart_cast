// End-to-end DLNA verification against a real renderer.
//
//     dart run tool/dlna_hardware_check.dart [--name="Living room TV"] [media]
//
// Discovers DLNA renderers over SSDP, casts a media file through the built-in
// proxy, polls transport state, and exercises seek / pause / resume. Runs the
// whole thing twice — once without a subtitle track and once with — because
// subtitle delivery is the part of DLNA most likely to differ per TV.
//
// This is not a unit test and is never run by CI: mock servers cannot prove
// a renderer accepts what we send. Capture the output into
// doc/specs/ when recording a hardware result.
//
// Options:
//   --name=<substring>   only test renderers whose name contains this
//   --seconds=20         how long to watch playback for
//   --subtitle=<path>    sidecar subtitle file (.srt/.vtt) for the second pass
//   --skip-subtitles     run only the no-subtitle pass
//   --quiet              hide DEBUG lines

import 'dart:async';
import 'dart:io';

import 'package:dart_cast/src/core/cast_device.dart';
import 'package:dart_cast/src/core/cast_media.dart';
import 'package:dart_cast/src/core/cast_session.dart';
import 'package:dart_cast/src/protocols/dlna/dlna_discovery_provider.dart';
import 'package:dart_cast/src/protocols/dlna/dlna_session.dart';
import 'package:dart_cast/src/utils/logger.dart';

Future<void> main(List<String> args) async {
  final options = _options(args);
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final quiet = args.contains('--quiet');
  final nameFilter = options['name'] ?? '';
  final watchSeconds = int.tryParse(options['seconds'] ?? '') ?? 20;
  final subtitlePath = options['subtitle'];
  final skipSubtitles = args.contains('--skip-subtitles');

  if (positional.isEmpty) {
    stderr.writeln(
      'usage: dart run tool/dlna_hardware_check.dart [--name=TV] <media-file-or-url>',
    );
    exitCode = 64;
    return;
  }
  final mediaPath = positional.first;

  final started = DateTime.now();
  CastLogger.setCallback((level, message) {
    if (quiet && level == 'DEBUG') return;
    final elapsed = DateTime.now().difference(started).inMilliseconds;
    stdout.writeln('  [${elapsed.toString().padLeft(6)}ms] $level  $message');
  });

  // -- 1. Discover ---------------------------------------------------------
  _step('1. SSDP discovery', 'looking for MediaRenderer devices');
  final provider = DlnaDiscoveryProvider();
  var devices = <CastDevice>[];
  await for (final found in provider.startDiscovery(
    timeout: const Duration(seconds: 8),
  )) {
    devices = found;
  }
  provider.stopDiscovery();

  if (devices.isEmpty) {
    stdout.writeln('  no DLNA renderers found');
    exitCode = 1;
    return;
  }
  for (final d in devices) {
    stdout.writeln(
      '  ${d.name}  ${d.address.address}:${d.port}  '
      'avTransport=${d.metadata['avTransportControlUrl'] != null}',
    );
  }

  final target = devices.firstWhere(
    (d) =>
        nameFilter.isEmpty ||
        d.name.toLowerCase().contains(nameFilter.toLowerCase()),
    orElse: () => devices.first,
  );
  stdout.writeln('  -> testing "${target.name}"');

  // -- 2. Run the passes ---------------------------------------------------
  final results = <String, bool>{};

  results['no subtitles'] = await _runPass(
    target: target,
    mediaPath: mediaPath,
    subtitlePath: null,
    watchSeconds: watchSeconds,
    label: 'no subtitles',
  );

  if (!skipSubtitles) {
    if (subtitlePath == null) {
      stdout.writeln('');
      stdout.writeln(
        'Skipping the subtitle pass: pass --subtitle=<file.srt> to run it.',
      );
    } else if (!File(subtitlePath).existsSync()) {
      stdout.writeln('');
      stdout.writeln('Subtitle file not found: $subtitlePath');
    } else {
      results['with subtitles'] = await _runPass(
        target: target,
        mediaPath: mediaPath,
        subtitlePath: subtitlePath,
        watchSeconds: watchSeconds,
        label: 'with subtitles',
      );
    }
  }

  // -- 3. Verdict ----------------------------------------------------------
  _step('Verdict', '');
  results.forEach((pass, ok) {
    stdout.writeln('  ${ok ? 'PASS' : 'FAIL'}  $pass');
  });
  if (results.values.any((ok) => !ok)) exitCode = 3;

  exit(exitCode);
}

Future<bool> _runPass({
  required CastDevice target,
  required String mediaPath,
  required String? subtitlePath,
  required int watchSeconds,
  required String label,
}) async {
  _step('Pass: $label', mediaPath);

  final session = DlnaSession.fromDevice(target);
  final states = <SessionState>[];
  final stateSub = session.stateStream.listen(states.add);
  Duration? lastPosition;
  Duration? lastDuration;
  final posSub = session.positionStream.listen((p) => lastPosition = p);
  final durSub = session.durationStream.listen((d) => lastDuration = d);

  var ok = false;
  try {
    await session.connect();

    final subtitles = <CastSubtitle>[
      if (subtitlePath != null)
        CastSubtitle(
          // The proxy expects file:// for local sidecar subtitles.
          url:
              subtitlePath.startsWith('/')
                  ? 'file://$subtitlePath'
                  : subtitlePath,
          label: 'Test',
          language: 'en',
          format: subtitlePath.toLowerCase().endsWith('.vtt') ? 'vtt' : 'srt',
        ),
    ];

    final isLocal = !mediaPath.startsWith('http');
    final media =
        isLocal
            ? CastMedia.file(
              filePath: mediaPath,
              type: _typeFor(mediaPath),
              title: 'dart_cast hardware check',
              subtitles: subtitles,
            )
            : CastMedia(
              url: mediaPath,
              type: _typeFor(mediaPath),
              title: 'dart_cast hardware check',
              subtitles: subtitles,
            );

    await session.loadMedia(media);
    stdout.writeln('  loadMedia returned, state=${session.state}');

    for (var i = 0; i < watchSeconds; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      stdout.writeln(
        '  t+${(i + 1).toString().padLeft(2)}s  state=${session.state}  '
        'position=${lastPosition?.inSeconds ?? '-'}s  '
        'duration=${lastDuration?.inSeconds ?? '-'}s',
      );
    }

    final advanced = (lastPosition?.inMilliseconds ?? 0) > 0;
    final hasDuration = (lastDuration?.inMilliseconds ?? 0) > 0;

    // Exercise transport controls only if something is actually playing.
    var seekOk = true;
    if (advanced) {
      _step('  controls', 'pause / resume / seek');
      await session.pause();
      await Future<void>.delayed(const Duration(seconds: 2));
      stdout.writeln('  after pause : state=${session.state}');
      await session.play();
      await Future<void>.delayed(const Duration(seconds: 2));
      stdout.writeln('  after resume: state=${session.state}');

      // Judge the seek on the RENDERER's own reported progress, never on a
      // value this tool computed. A session that reports a position it
      // synthesised itself will happily call a frozen picture a success.
      final beforeSeek = lastPosition;
      await session.seek(const Duration(minutes: 1));
      await Future<void>.delayed(const Duration(seconds: 6));
      final justAfter = lastPosition;
      await Future<void>.delayed(const Duration(seconds: 6));
      final later = lastPosition;

      final stillPlaying = session.state == SessionState.playing;
      final progressing =
          later != null && justAfter != null && later > justAfter;
      seekOk = stillPlaying && progressing;

      stdout.writeln(
        '  seek        : before=${beforeSeek?.inSeconds ?? '-'}s  '
        '+6s=${justAfter?.inSeconds ?? '-'}s  '
        '+12s=${later?.inSeconds ?? '-'}s  '
        'state=${session.state}',
      );
      stdout.writeln(
        seekOk
            ? '  seek OK — playback resumed and kept advancing.'
            : '  seek FAILED — the renderer did not resume advancing after '
                'the seek (check the TV: it is probably stuck loading).',
      );
    }

    stdout.writeln('');
    stdout.writeln('  states seen    : ${states.join(' -> ')}');
    stdout.writeln('  duration known : $hasDuration (${lastDuration ?? '-'})');
    stdout.writeln('  position moved : $advanced (${lastPosition ?? '-'})');
    ok = advanced && seekOk;
    stdout.writeln(
      ok
          ? '  PASS — the renderer is playing.'
          : '  FAIL — position never advanced. Check the TV screen: a renderer '
              'that accepted SetAVTransportURI but shows nothing usually '
              'rejected the container or the DLNA profile.',
    );
  } catch (e, stack) {
    stdout.writeln('  FAIL — $e');
    stdout.writeln(stack.toString());
  } finally {
    try {
      await session.stop();
    } catch (_) {}
    try {
      await session.disconnect();
    } catch (_) {}
    await stateSub.cancel();
    await posSub.cancel();
    await durSub.cancel();
    session.dispose();
  }

  return ok;
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
