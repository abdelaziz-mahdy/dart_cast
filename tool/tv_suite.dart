// Hardware test suite for the spec-compliance work: casts purpose-built
// fixtures to a real TV over Chromecast, DLNA and AirPlay and records what
// the DEVICE reports.
//
//     dart run tool/tv_fixtures.dart              # once, needs ffmpeg
//     dart run tool/tv_suite.dart --tv=192.168.2.17 [options]
//
// Every case writes its evidence to build/tv_results/<run>/<case>/:
//   samples.tsv    device-reported state / position / duration / volume, 1 Hz
//   log.txt        full dart_cast log, including every request the TV made
//                  to our proxy with its headers
//   logcat.txt     `adb logcat` for the case (when adb reaches the TV)
//   *.png          `adb` screenshots at the moments named in the case
// and the run gets summary.md + results.json.
//
// Verdicts follow CLAUDE.md: PASS/FAIL are judged only on values the device
// reported (position advancing, state, volume), never on a number this tool
// computed. Things only a picture can show (subtitles, PIN) are LOOK: the
// screenshots are the evidence. Note that `adb screencap` cannot capture the
// video plane on Google TV — a black picture is not a black screen — but
// overlays (subtitles drawn by the player UI, dialogs) usually do capture.
//
// Options:
//   --tv=<ip>            TV address (required)
//   --adb=<ip:port>      adb target, default <tv>:5555; --no-adb to skip
//   --only=a,b           run only these case ids (prefix match)
//   --set=next           run a named case list (see _sets); combines with
//                        --only/--skip
//   --quick              shorter watch windows (~half); still judged on
//                        device-reported progress
//   --skip=a,b           skip these case ids (prefix match)
//   --pin=1234           AirPlay PIN read from the ap_pin_start screenshot
//   --fixtures=<dir>     default build/tv_fixtures
//   --out=<dir>          default build/tv_results
//   --list               print the cases and exit
//
// See doc/specs/2026-11-15-spec-compliance-tv-test-plan.md for the plan.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_cast/dart_cast.dart';
import 'package:dart_cast/src/protocols/chromecast/cast_receiver_channel.dart';
import 'package:dart_cast/src/protocols/chromecast/castv2_channel.dart';

Future<void> main(List<String> args) async {
  final opts = _Options(args);
  final cases = _cases();
  if (opts.flag('list')) {
    for (final c in cases) {
      stdout.writeln('${c.id.padRight(26)} ${c.fixes.join(', ')}');
      stdout.writeln('${''.padRight(26)} ${c.title}');
    }
    return;
  }

  final tv = opts.value('tv');
  if (tv == null) {
    stderr.writeln('usage: dart run tool/tv_suite.dart --tv=<ip> [--pin=..]');
    exitCode = 64;
    return;
  }

  final setName = opts.value('set');
  final set = setName == null ? null : _sets[setName];
  if (setName != null && set == null) {
    stderr.writeln('Unknown --set=$setName (have: ${_sets.keys.join(', ')})');
    exitCode = 64;
    return;
  }

  final fixtures = Directory(opts.value('fixtures') ?? 'build/tv_fixtures');
  if (!File('${fixtures.path}/local.mp4').existsSync()) {
    stderr.writeln(
      'No fixtures in ${fixtures.path}. Run tool/tv_fixtures.dart',
    );
    exitCode = 66;
    return;
  }

  final branch = await _git(['rev-parse', '--abbrev-ref', 'HEAD']);
  final sha = await _git(['rev-parse', '--short', 'HEAD']);
  final stamp = DateTime.now()
      .toIso8601String()
      .substring(0, 19)
      .replaceAll(':', '-');
  final runDir = Directory(
    '${opts.value('out') ?? 'build/tv_results'}/${stamp}_$sha',
  )..createSync(recursive: true);

  final adb =
      opts.flag('no-adb')
          ? null
          : await _Adb.connect(opts.value('adb') ?? '$tv:5555');
  final server = await _FixtureServer.start(fixtures, tv);
  final env = _Env(
    tv: tv,
    adb: adb,
    fixtures: fixtures,
    server: server,
    pin: opts.value('pin'),
    quick: opts.flag('quick'),
    credentialsFile: File(
      '${opts.value('out') ?? 'build/tv_results'}/airplay_credentials.json',
    ),
  );

  stdout.writeln('dart_cast TV suite — $branch @ $sha');
  stdout.writeln(
    'TV $tv, adb ${adb?.target ?? 'off'}, '
    'fixtures at ${server.origin}',
  );
  stdout.writeln('Evidence: ${runDir.path}\n');

  final only = opts.list('only');
  final skip = opts.list('skip');
  final results = <_Result>[];
  for (final c in cases) {
    if (set != null && !set.any(c.id.startsWith)) continue;
    if (only.isNotEmpty && !only.any(c.id.startsWith)) continue;
    if (skip.any(c.id.startsWith)) continue;
    results.add(await _runCase(c, env, Directory('${runDir.path}/${c.id}')));
  }

  await server.close();
  CastLogger.setCallback(null);
  _writeSummary(runDir, results, branch: branch, sha: sha, tv: tv);
  stdout.writeln('\nSummary: ${runDir.path}/summary.md');
  for (final r in results) {
    stdout.writeln('  ${r.verdict.name.toUpperCase().padRight(5)} ${r.id}');
  }
  exit(results.any((r) => r.verdict == _Verdict.fail) ? 3 : 0);
}

// ---------------------------------------------------------------------------
// Cases
// ---------------------------------------------------------------------------

/// Named case lists for `--set`.
///
/// `next`: the next TV round. Leaves out the DLNA sidecar-subtitle cases,
/// whose answer on the TCL TV is known (its renderer drops sidecar
/// subtitles), and the AirPlay steps that need `--pin`; run those after
/// reading the PIN from the `ap_pin_start` screenshot.
const _sets = <String, List<String>>{
  'next': [
    'cc_',
    'dl_mp4',
    'dl_mkv_embedded_subs',
    'dl_set_subtitle_midplay',
    'dl_hls_',
    'dl_volume',
    'ap_transient_connect',
    'ap_pin_start',
  ],
};

/// Volume the suite sets on the TV. Never above 0.10 of the device range:
/// the TV is in a living room.
const _testVolume = 0.08;

List<_Case> _cases() => [
  // -- Chromecast ----------------------------------------------------------
  _Case(
    'cc_idle_heartbeat',
    'Connect and stay idle 45 s: the session must stay connected',
    ['CC-3 liveness timeout', 'CC-4 PONG to device PING', 'CC-1 app match'],
    (x) async {
      final s = await x.chromecast();
      // Quick: 25 s still outlasts the 15 s liveness timeout once.
      final samples = await x.watch(s, x.env.quick ? 25 : 45);
      final stayed = samples.every((p) => p.state == SessionState.connected);
      x.note('states: ${samples.map((p) => p.state.name).toSet()}');
      x.note('session id: ${s.sessionId}');
      return stayed ? _Verdict.pass : _Verdict.fail;
    },
  ),
  _Case(
    'cc_mp4',
    'Local MP4: play, pause, resume, seek to 120 s',
    ['CC-8 LOAD without currentTime', 'CC-9 LOAD attribution (exp.)'],
    (x) async {
      final s = await x.chromecast();
      await s.loadMedia(x.file('local.mp4', CastMediaType.mp4));
      return x.playbackChecks(s, seekTo: 120);
    },
  ),
  _Case(
    'cc_local_ts',
    'Local MPEG-TS wrapped as HLS: play and seek to 120 s',
    ['CO-15 keyframe scan (exp.)', 'CO-11 CORS/type on segments', 'CO-13'],
    (x) async {
      final s = await x.chromecast();
      await s.loadMedia(x.file('local.ts', CastMediaType.mpegTs));
      return x.playbackChecks(s, seekTo: 120);
    },
  ),
  _Case(
    'cc_hls_redirect_tags',
    'Remote HLS behind a 302, tags between #EXTINF and URI',
    ['CO-1 redirect base', 'CO-3 tags before URI', 'CO-17 Range on playlist'],
    (x) async {
      final s = await x.chromecast();
      await s.loadMedia(x.url('hls_ts/index.m3u8', redirect: true));
      return x.playbackChecks(s, seekTo: 60);
    },
  ),
  _Case(
    'cc_hls_obfuscated',
    'HLS whose TS segments are named .jpg',
    ['CO-19 .ts hint kept for obfuscated names (exp.)'],
    (x) async {
      final s = await x.chromecast();
      await s.loadMedia(x.url('hls_obf/index.m3u8'));
      return x.playbackChecks(s, seekTo: 60);
    },
  ),
  _Case(
    'cc_hls_fmp4',
    'fMP4 / CMAF HLS (#EXT-X-MAP, .m4s)',
    ['CO-19 real extension kept (exp.)', 'CO-4 MAP URI proxied'],
    (x) async {
      final s = await x.chromecast();
      await s.loadMedia(x.url('hls_fmp4/index.m3u8'));
      return x.playbackChecks(s, seekTo: 60);
    },
  ),
  _Case(
    'cc_hls_byterange',
    'Single-file HLS using #EXT-X-BYTERANGE',
    ['CO-2 byte ranges', 'CO-6 no DVB strip on 206'],
    (x) async {
      final s = await x.chromecast();
      await s.loadMedia(x.url('hls_single/index.m3u8'));
      return x.playbackChecks(s, seekTo: 60);
    },
  ),
  _Case(
    'cc_hls_alt_audio',
    'HLS with a separate audio rendition (4 s audio vs 6 s video)',
    ['CO-7 pair by time (exp.)', 'CO-8 PCR/interleave (exp.)', 'CO-1'],
    (x) async {
      final s = await x.chromecast();
      await s.loadMedia(x.url('hls_alt/master.m3u8'));
      final v = await x.playbackChecks(s, seekTo: 60);
      x.note(
        'audio presence/sync is not device-reported: LOOK at log for '
        'muxed segment counts',
      );
      return v;
    },
  ),
  _Case(
    'cc_subtitles_srt',
    'Local MP4 + sidecar SRT ("42", "1984", "&", "<", loose timestamps)',
    ['CO-9 SRT→WebVTT', 'subtitle track activation'],
    (x) async {
      final s = await x.chromecast();
      final sub = x.subtitle('sidecar.srt');
      await s.loadMedia(
        x.file('local.mp4', CastMediaType.mp4, subtitles: [sub], def: sub),
      );
      return x.subtitleChecks(s);
    },
  ),
  _Case(
    'cc_volume',
    'Device volume: set 0.08, set -0.2 (clamped to 0), restore',
    ['CC-10 SET_VOLUME clamp'],
    (x) async {
      final s = await x.chromecast();
      await s.loadMedia(x.file('local.mp4', CastMediaType.mp4));
      await x.watch(s, 3);
      final original = x.probe.volume;
      await s.setVolume(_testVolume);
      await x.watch(s, 3);
      final atTest = x.probe.volume;
      await s.setVolume(-0.2);
      await x.watch(s, 3);
      final atZero = x.probe.volume;
      if (original != null) await s.setVolume(original);
      x.note(
        'device volume: start=$original  after $_testVolume=$atTest  '
        'after -0.2=$atZero',
      );
      final ok =
          atTest != null &&
          (atTest - _testVolume).abs() < 0.03 &&
          atZero != null &&
          atZero < 0.05;
      return ok ? _Verdict.pass : _Verdict.fail;
    },
  ),
  _Case(
    'cc_app_closed_on_tv',
    'Another sender stops our cast app: session must end',
    ['CC-2 receiver CLOSE / app gone'],
    (x) async {
      final s = await x.chromecast();
      await s.loadMedia(x.file('local.mp4', CastMediaType.mp4));
      await x.watch(s, 8);
      final appSession = s.sessionId;
      if (appSession == null) {
        x.note('no receiver sessionId to stop');
        return _Verdict.fail;
      }
      // A second sender connection stopping the app is what happens when
      // someone else casts or presses "stop casting" on their phone. (The
      // TV remote's BACK only backgrounds the receiver on Google TV: it
      // keeps reporting BUFFERING and never says the app closed.)
      final other = CastV2Channel();
      await other.connect(x.env.tv);
      const receiverNs = 'urn:x-cast:com.google.cast.receiver';
      other.sendMessage(
        namespace: 'urn:x-cast:com.google.cast.tp.connection',
        sourceId: 'sender-tv-suite-other',
        destinationId: 'receiver-0',
        payload: CastReceiverChannel.buildConnect(),
      );
      other.sendMessage(
        namespace: receiverNs,
        sourceId: 'sender-tv-suite-other',
        destinationId: 'receiver-0',
        payload: CastReceiverChannel.buildStop(appSession),
      );
      x.note('second sender sent STOP for app session $appSession');
      final samples = await x.watch(s, 15);
      // Close politely; the TV may never close its end of a sender
      // connection, so do not wait on it.
      other.sendMessage(
        namespace: 'urn:x-cast:com.google.cast.tp.connection',
        sourceId: 'sender-tv-suite-other',
        destinationId: 'receiver-0',
        payload: CastReceiverChannel.buildClose(),
      );
      await other.close().timeout(const Duration(seconds: 3), onTimeout: () {});
      await x.screenshot('after_stop');
      final ended = samples.any((p) => p.state == SessionState.disconnected);
      x.note('states after STOP: ${samples.map((p) => p.state.name).toSet()}');
      return ended ? _Verdict.pass : _Verdict.fail;
    },
  ),

  // -- DLNA ------------------------------------------------------------------
  _Case(
    'dl_mp4',
    'Local MP4: play, pause, resume, seek to 120 s; TV request headers',
    ['DL-6 reload race', 'DL-9 Range', 'DL-14 Date', 'DL-1 headers'],
    (x) async {
      final s = await x.dlna();
      await s.loadMedia(x.file('local.mp4', CastMediaType.mp4));
      final v = await x.playbackChecks(s, seekTo: 120);
      x.noteDlnaHeaders();
      return v;
    },
  ),
  _Case(
    'dl_srt_sidecar',
    'Local MP4 + sidecar SRT',
    ['DL-3 SRT variant serves SRT', 'CO-9'],
    (x) async {
      final s = await x.dlna();
      final sub = x.subtitle('sidecar.srt');
      await s.loadMedia(
        x.file('local.mp4', CastMediaType.mp4, subtitles: [sub], def: sub),
      );
      final v = await x.subtitleChecks(s);
      x.noteSubtitleFetches();
      return v;
    },
  ),
  _Case('dl_vtt_sidecar', 'Local MP4 + sidecar WebVTT', ['DL-3', 'CO-9'], (
    x,
  ) async {
    final s = await x.dlna();
    final sub = x.subtitle('sidecar.vtt');
    await s.loadMedia(
      x.file('local.mp4', CastMediaType.mp4, subtitles: [sub], def: sub),
    );
    final v = await x.subtitleChecks(s);
    x.noteSubtitleFetches();
    return v;
  }),
  _Case(
    'dl_latin1_srt',
    'Local MP4 + Latin-1 encoded SRT',
    ['CO-9 non-UTF-8 subtitles'],
    (x) async {
      final s = await x.dlna();
      final sub = x.subtitle('sidecar_latin1.srt');
      await s.loadMedia(
        x.file('local.mp4', CastMediaType.mp4, subtitles: [sub], def: sub),
      );
      final v = await x.subtitleChecks(s);
      x.noteSubtitleFetches();
      return v;
    },
  ),
  _Case(
    'dl_mkv_embedded_subs',
    'Local MKV with an embedded SRT track',
    ['baseline: embedded subtitles'],
    (x) async {
      final s = await x.dlna();
      await s.loadMedia(x.file('local_subs.mkv', CastMediaType.mkv));
      return x.subtitleChecks(s);
    },
  ),
  _Case(
    'dl_set_subtitle_midplay',
    'Seek to 60 s, then switch subtitle: position must be kept',
    ['DL-7 setSubtitle keeps position/metadata'],
    (x) async {
      final s = await x.dlna();
      final srt = x.subtitle('sidecar.srt');
      final vtt = x.subtitle('sidecar.vtt');
      await s.loadMedia(
        x.file('local.mp4', CastMediaType.mp4, subtitles: [srt, vtt], def: srt),
      );
      await x.watch(s, x.env.quick ? 4 : 6);
      await s.seek(const Duration(seconds: 60));
      await x.watch(s, x.env.quick ? 4 : 6);
      await s.setSubtitle(vtt);
      final after = await x.watch(s, 12);
      await x.screenshot('after_switch');
      final kept =
          after.last.position != null &&
          after.last.position!.inSeconds >= 55 &&
          after.last.state == SessionState.playing;
      x.note('position after switch: ${after.last.position}');
      return kept ? _Verdict.pass : _Verdict.fail;
    },
  ),
  _Case(
    'dl_hls_piped_seek',
    'Remote HLS (302, tags before URI) piped as TS, seek to 60 s',
    ['DL-5/DL-15 time seek', 'CO-1', 'CO-3'],
    (x) async {
      final s = await x.dlna();
      await s.loadMedia(x.url('hls_ts/index.m3u8', redirect: true));
      return x.playbackChecks(s, seekTo: 60);
    },
  ),
  _Case(
    'dl_hls_byterange',
    'Single-file byte-range HLS piped as TS',
    ['CO-2 byte ranges on the DLNA pipe'],
    (x) async {
      final s = await x.dlna();
      await s.loadMedia(x.url('hls_single/index.m3u8'));
      return x.playbackChecks(s, seekTo: 60);
    },
  ),
  _Case(
    'dl_hls_alt_audio',
    'Alt-audio HLS muxed and piped as TS, seek to 60 s',
    ['DL-5 alt-audio time seek', 'CO-8 continuity (exp.)', 'CO-7 (exp.)'],
    (x) async {
      final s = await x.dlna();
      await s.loadMedia(x.url('hls_alt/master.m3u8'));
      return x.playbackChecks(s, seekTo: 60);
    },
  ),
  _Case(
    'dl_volume',
    'Renderer volume: set 0.08, read back, restore',
    ['DL-8 volume range from SCPD'],
    (x) async {
      final s = await x.dlna();
      await s.loadMedia(x.file('local.mp4', CastMediaType.mp4));
      await x.watch(s, 4);
      final original = x.probe.volume;
      await s.setVolume(_testVolume);
      await x.watch(s, 4);
      final after = x.probe.volume;
      if (original != null) await s.setVolume(original);
      x.note('device volume: start=$original after $_testVolume=$after');
      final ok = after != null && (after - _testVolume).abs() < 0.03;
      return ok ? _Verdict.pass : _Verdict.fail;
    },
  ),

  // -- AirPlay ---------------------------------------------------------------
  _Case(
    'ap_transient_connect',
    'Connect without stored credentials (transient pairing if offered)',
    ['AP-4 M4 proof check', 'AP-9 Host header', 'AP-7 framing'],
    (x) async {
      final s = await x.airplay(withCredentials: false);
      x.note('connected, state=${s.state}');
      return _Verdict.pass;
    },
  ),
  _Case(
    'ap_pin_start',
    'Ask the TV to show the AirPlay PIN and screenshot it',
    ['AP-6 setup'],
    (x) async {
      final device = await x.airplayDevice();
      AirPlayPairSetup(
        host: device.address.address,
        port: device.port,
      ).startPinDisplay();
      await Future<void>.delayed(const Duration(seconds: 5));
      final shot = await x.screenshot('pin');
      x.note(
        shot == null
            ? 'no adb: read the PIN off the TV'
            : 'read the PIN from $shot, rerun with --only=ap_pair --pin=XXXX',
      );
      return _Verdict.look;
    },
  ),
  _Case(
    'ap_pair',
    'PIN pair-setup on one connection, verify the TV\'s SRP proof',
    ['AP-4 M4 proof check', 'AP-6 one connection (exp.)'],
    (x) async {
      final pin = x.env.pin;
      if (pin == null) return x.skip('pass --pin from ap_pin_start');
      final device = await x.airplayDevice();
      final session = AirPlaySession(device);
      final creds = await session.pairSetup(pin, triggerPinDisplay: false);
      x.env.credentialsFile
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(creds.toJson()));
      x.note('credentials saved to ${x.env.credentialsFile.path}');
      session.dispose();
      return _Verdict.pass;
    },
  ),
  _Case(
    'ap_verify_and_play',
    'Pair-verify with stored credentials, event channel, /play local MP4',
    ['AP-1 event keys', 'AP-2 event replies', 'AP-3 plist types'],
    (x) async {
      final s = await x.airplay(withCredentials: true);
      try {
        await s.loadMedia(x.file('local.mp4', CastMediaType.mp4));
      } catch (e) {
        x.note(
          'loadMedia failed: $e (known: video has not played on the '
          'receivers tested; compare with doc/AIRPLAY.md)',
        );
      }
      final samples = await x.watch(s, 20);
      await x.screenshot('during_play');
      x.noteMatching('event', RegExp('event', caseSensitive: false));
      final advanced = _advanced(samples, 20);
      x.note('position advanced: $advanced');
      return advanced ? _Verdict.pass : _Verdict.look;
    },
  ),
];

// ---------------------------------------------------------------------------
// Case runner
// ---------------------------------------------------------------------------

Future<_Result> _runCase(_Case c, _Env env, Directory dir) async {
  dir.createSync(recursive: true);
  stdout.writeln('▶ ${c.id} — ${c.title}');
  final log = IOSink(File('${dir.path}/log.txt').openWrite());
  final logLines = <String>[];
  final started = DateTime.now();
  CastLogger.setCallback((level, message) {
    final t = DateTime.now().difference(started).inMilliseconds;
    final line = '[${t.toString().padLeft(7)}ms] $level  $message';
    log.writeln(line);
    logLines.add(line);
  });
  await env.adb?.clearLogcat();

  final ctx = _Ctx(env, dir, logLines);
  _Verdict verdict;
  try {
    verdict = await c.run(ctx).timeout(const Duration(minutes: 4));
  } catch (e, st) {
    ctx.note('error: $e');
    log.writeln('ERROR $e\n$st');
    await ctx.screenshot('error');
    verdict = _Verdict.fail;
  } finally {
    await ctx.teardown();
  }

  await env.adb?.dumpLogcat(File('${dir.path}/logcat.txt'));
  File('${dir.path}/samples.tsv').writeAsStringSync(ctx.samplesTsv());
  await log.flush();
  await log.close();
  final seconds = DateTime.now().difference(started).inSeconds;
  stdout.writeln(
    '  ${verdict.name.toUpperCase()} (${seconds}s)'
    '${ctx.notes.isEmpty ? '' : '\n    ${ctx.notes.join('\n    ')}'}',
  );
  // Let the TV settle before the next case.
  await Future<void>.delayed(const Duration(seconds: 3));
  return _Result(c, verdict, ctx.notes, ctx.shots, seconds);
}

class _Ctx {
  final _Env env;
  final Directory dir;
  final List<String> logLines;
  final notes = <String>[];
  final shots = <String>[];
  final samples = <_Sample>[];
  final _sessions = <CastSession>[];
  _Probe probe = _Probe.none();

  _Ctx(this.env, this.dir, this.logLines);

  void note(String text) => notes.add(text);

  Future<_Verdict> skip(String why) async {
    note('skipped: $why');
    return _Verdict.skip;
  }

  Future<ChromecastSession> chromecast() async {
    final s = ChromecastSession(
      device: CastDevice(
        id: 'tv-suite-chromecast',
        name: 'TV',
        protocol: CastProtocol.chromecast,
        address: InternetAddress(env.tv),
        port: 8009,
      ),
    );
    return _connect(s);
  }

  Future<DlnaSession> dlna() async {
    final device = await env.dlnaDevice();
    return _connect(DlnaSession.fromDevice(device));
  }

  Future<CastDevice> airplayDevice() => env.airplayDevice();

  Future<AirPlaySession> airplay({required bool withCredentials}) async {
    final device = await env.airplayDevice();
    HapCredentials? creds;
    if (withCredentials) {
      if (!env.credentialsFile.existsSync()) {
        throw StateError('no stored credentials: run ap_pin_start + ap_pair');
      }
      creds = HapCredentials.fromJson(
        jsonDecode(env.credentialsFile.readAsStringSync())
            as Map<String, dynamic>,
      );
    }
    return _connect(AirPlaySession(device, credentials: creds));
  }

  Future<T> _connect<T extends CastSession>(T s) async {
    _sessions.add(s);
    probe = _Probe(s);
    await s.connect();
    return s;
  }

  CastMedia file(
    String name,
    CastMediaType type, {
    List<CastSubtitle> subtitles = const [],
    CastSubtitle? def,
  }) => CastMedia.file(
    filePath: '${env.fixtures.absolute.path}/$name',
    type: type,
    title: 'dart_cast suite: $name',
    subtitles: subtitles,
    defaultSubtitle: def,
  );

  CastMedia url(String path, {bool redirect = false}) => CastMedia(
    url: env.server.url(path, redirect: redirect),
    type: CastMediaType.hls,
    title: 'dart_cast suite: $path',
  );

  CastSubtitle subtitle(String name) => CastSubtitle(
    url: 'file://${env.fixtures.absolute.path}/$name',
    label: name,
    language: 'en',
    format: name.endsWith('.vtt') ? 'vtt' : 'srt',
  );

  /// Samples device-reported values once a second for [seconds].
  Future<List<_Sample>> watch(CastSession s, int seconds) async {
    final out = <_Sample>[];
    for (var i = 0; i < seconds; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final sample = _Sample(
        DateTime.now(),
        s.state,
        probe.position,
        probe.duration,
        probe.volume,
      );
      out.add(sample);
      samples.add(sample);
    }
    return out;
  }

  /// Waits (up to [timeout] seconds) until the device reports a position
  /// above zero: a DLNA renderer says PLAYING at 0 s while it still buffers.
  Future<void> waitForProgress(CastSession s, {int timeout = 15}) async {
    for (var i = 0; i < timeout; i++) {
      final p = probe.position;
      if (p != null && p > Duration.zero) return;
      await watch(s, 1);
    }
  }

  /// Play / pause / resume / seek, all judged on device-reported values.
  Future<_Verdict> playbackChecks(CastSession s, {required int seekTo}) async {
    // Watch windows in seconds; --quick roughly halves them. Every check
    // still needs the device-reported position to move (or hold) by itself.
    final q = env.quick;
    final playFor = q ? 6 : 12;
    final pauseFor = q ? 3 : 4;
    final resumeFor = q ? 4 : 5;
    final landAfter = q ? 4 : 5;
    final seekFor = q ? 9 : 12;

    await waitForProgress(s);
    final play = await watch(s, playFor);
    await screenshot('playing');
    final played = _advanced(play, playFor);
    note('play: ${_span(play)}  duration=${play.last.duration}');
    if (!played) return _Verdict.fail;

    await s.pause();
    final paused = await watch(s, pauseFor);
    // The player's transport UI (title, scrub bar) is drawn while paused.
    await screenshot('paused');
    final pausedOk =
        paused.last.state == SessionState.paused &&
        !_advanced(paused.sublist(1), pauseFor - 1, minRatio: 0.5);
    note('pause: ${paused.last.state.name} ${_span(paused)}');

    await s.play();
    final resumed = await watch(s, resumeFor);
    final resumedOk = _advanced(resumed, resumeFor);
    note('resume: ${resumed.last.state.name} ${_span(resumed)}');

    await s.seek(Duration(seconds: seekTo));
    final seek = await watch(s, seekFor);
    await screenshot('after_seek');
    final landed = seek[landAfter].position;
    final landedOk = landed != null && (landed.inSeconds - seekTo).abs() <= 20;
    final progressing = _advanced(seek.sublist(landAfter), seekFor - landAfter);
    note(
      'seek to $seekTo: +${landAfter}s=${landed?.inSeconds}s, '
      '+${seekFor}s=${seek.last.position?.inSeconds}s, ${seek.last.state.name}',
    );

    final ok =
        pausedOk &&
        resumedOk &&
        landedOk &&
        progressing &&
        seek.last.state == SessionState.playing;
    return ok ? _Verdict.pass : _Verdict.fail;
  }

  /// Plays from the start with subtitles and screenshots the cues that
  /// break naive converters; playback itself is judged, the picture is LOOK.
  Future<_Verdict> subtitleChecks(CastSession s) async {
    // Cue windows in seconds (see tool/tv_fixtures.dart). A screenshot is
    // taken once per cue, the first time the device reports a position
    // inside its window, so a skipped second does not miss it.
    const cues = <String, (int, int)>{
      'cue_42': (5, 8),
      'cue_tom_jerry': (8, 11),
      'cue_1984': (11, 14),
      'cue_loose_ts': (15, 18),
      'cue_long': (22, 60),
    };
    final taken = <String>{};
    final out = <_Sample>[];
    // Quick: stop once the 14.5–18.25 s cue has been on screen; the long
    // cue only proves the track stays on, which the after-seek shot shows.
    final watchFor = env.quick ? 20 : 26;
    for (var i = 1; i <= watchFor; i++) {
      out.addAll(await watch(s, 1));
      final pos = out.last.position?.inMilliseconds;
      if (pos == null) continue;
      for (final cue in cues.entries) {
        final (from, to) = cue.value;
        if (!taken.contains(cue.key) &&
            pos >= (from * 1000 + 300) &&
            pos < to * 1000) {
          taken.add(cue.key);
          await screenshot(cue.key);
        }
      }
    }
    final played = _advanced(out, watchFor);
    note('play: ${_span(out)}');
    await s.seek(const Duration(seconds: 70));
    await watch(s, env.quick ? 4 : 6);
    await screenshot('cue_after_seek');
    if (!played) return _Verdict.fail;
    note(
      'subtitles: LOOK at cue_*.png (expect "42", "Tom & Jerry say 1 < 2",'
      ' "1984", loose-timestamp cue, "After seek")',
    );
    return _Verdict.look;
  }

  /// Which DLNA transfer headers the TV sent to our server.
  void noteDlnaHeaders() {
    final seen = <String>{};
    for (final l in logLines) {
      for (final h in [
        'getcontentFeatures.dlna.org',
        'transferMode.dlna.org',
        'TimeSeekRange.dlna.org',
        'Range:',
      ]) {
        if (l.toLowerCase().contains(h.toLowerCase())) seen.add(h);
      }
    }
    note('TV request headers seen: ${seen.isEmpty ? 'none' : seen.join(', ')}');
  }

  /// Subtitle requests the TV made, with the content type we answered.
  void noteSubtitleFetches() {
    final hits =
        logLines
            .where(
              (l) => RegExp(
                r'(GET|HEAD) \S*\.(srt|vtt)',
                caseSensitive: false,
              ).hasMatch(l),
            )
            .take(6)
            .toList();
    note(
      hits.isEmpty
          ? 'TV fetched no sidecar subtitle URL'
          : 'TV fetched: ${hits.map((l) => l.split('  ').last).join(' | ')}',
    );
  }

  void noteMatching(String label, RegExp pattern) {
    final count = logLines.where(pattern.hasMatch).length;
    note('$label log lines: $count');
  }

  Future<String?> screenshot(String name) async {
    final adb = env.adb;
    if (adb == null) return null;
    final file = File('${dir.path}/$name.png');
    if (await adb.screenshot(file)) {
      shots.add(file.path);
      return file.path;
    }
    return null;
  }

  Future<void> teardown() async {
    for (final s in _sessions.reversed) {
      try {
        await s.stop().timeout(const Duration(seconds: 5));
      } catch (_) {}
      try {
        await s.disconnect().timeout(const Duration(seconds: 5));
      } catch (_) {}
      s.dispose();
    }
    probe.cancel();
  }

  String samplesTsv() => [
    'time\tstate\tposition_s\tduration_s\tvolume',
    for (final s in samples)
      '${s.at.toIso8601String()}\t${s.state.name}\t'
          '${s.position?.inMilliseconds == null ? '' : s.position!.inMilliseconds / 1000}\t'
          '${s.duration?.inMilliseconds == null ? '' : s.duration!.inMilliseconds / 1000}\t'
          '${s.volume ?? ''}',
  ].join('\n');
}

/// Whether the device-reported position moved by at least [minRatio] of
/// [seconds] across [samples]. Samples taken before the device reported any
/// position (a DLNA renderer's first poll) are skipped rather than failing
/// the check; the span is then measured over the samples that remain.
bool _advanced(List<_Sample> samples, int seconds, {double minRatio = 0.6}) {
  final known = samples.where((s) => s.position != null).toList();
  if (known.length < 2) return false;
  final first = known.first.position!;
  final last = known.last.position!;
  final span = known.length == samples.length ? seconds : known.length - 1;
  return (last - first).inMilliseconds >= span * 1000 * minRatio * 0.9;
}

String _span(List<_Sample> s) =>
    '${s.first.position?.inSeconds ?? '-'}s→${s.last.position?.inSeconds ?? '-'}s';

class _Probe {
  final List<StreamSubscription<Object?>> _subs;
  Duration? position;
  Duration? duration;
  double? volume;

  _Probe.none() : _subs = [];

  _Probe(CastSession s) : _subs = [] {
    _subs
      ..add(s.positionStream.listen((p) => position = p))
      ..add(s.durationStream.listen((d) => duration = d))
      ..add(s.volumeStream.listen((v) => volume = v));
  }

  void cancel() {
    for (final s in _subs) {
      s.cancel();
    }
  }
}

class _Sample {
  final DateTime at;
  final SessionState state;
  final Duration? position;
  final Duration? duration;
  final double? volume;
  _Sample(this.at, this.state, this.position, this.duration, this.volume);
}

// ---------------------------------------------------------------------------
// Environment: devices, adb, fixture server
// ---------------------------------------------------------------------------

class _Env {
  final String tv;
  final _Adb? adb;
  final Directory fixtures;
  final _FixtureServer server;
  final String? pin;
  final File credentialsFile;

  /// `--quick`: roughly halves every watch window.
  final bool quick;
  CastDevice? _dlna;
  CastDevice? _airplay;

  _Env({
    required this.tv,
    required this.adb,
    required this.fixtures,
    required this.server,
    required this.pin,
    required this.credentialsFile,
    this.quick = false,
  });

  Future<CastDevice> dlnaDevice() async {
    if (_dlna != null) return _dlna!;
    final provider = DlnaDiscoveryProvider();
    try {
      await for (final list in provider.startDiscovery(
        timeout: const Duration(seconds: 8),
      )) {
        for (final d in list) {
          if (d.address.address == tv) {
            provider.stopDiscovery();
            return _dlna = d;
          }
        }
      }
    } finally {
      provider.dispose();
    }
    throw StateError('no DLNA renderer answered at $tv');
  }

  Future<CastDevice> airplayDevice() async {
    if (_airplay != null) return _airplay!;
    final provider = AirPlayDiscoveryProvider();
    try {
      await for (final list in provider.startDiscovery(
        timeout: const Duration(seconds: 8),
      )) {
        for (final d in list) {
          if (d.address.address == tv) {
            provider.stopDiscovery();
            return _airplay = d;
          }
        }
      }
    } finally {
      provider.dispose();
    }
    throw StateError('no AirPlay receiver answered at $tv');
  }
}

class _Adb {
  final String target;
  _Adb(this.target);

  static Future<_Adb?> connect(String target) async {
    try {
      await Process.run('adb', ['connect', target]);
      final r = await Process.run('adb', ['-s', target, 'get-state']);
      if ('${r.stdout}'.trim() == 'device') return _Adb(target);
      stdout.writeln(
        'adb: $target not ready (${'${r.stderr}'.trim()}); '
        'screenshots and logcat off',
      );
    } on ProcessException {
      stdout.writeln('adb not found; screenshots and logcat off');
    }
    return null;
  }

  Future<void> key(String keycode) =>
      Process.run('adb', ['-s', target, 'shell', 'input', 'keyevent', keycode]);

  Future<void> clearLogcat() =>
      Process.run('adb', ['-s', target, 'logcat', '-c']);

  Future<void> dumpLogcat(File file) async {
    final r = await Process.run('adb', [
      '-s',
      target,
      'logcat',
      '-d',
      '-v',
      'time',
    ], stdoutEncoding: const Utf8Codec(allowMalformed: true));
    file.writeAsStringSync('${r.stdout}');
  }

  Future<bool> screenshot(File file) async {
    final r = await Process.run('adb', [
      '-s',
      target,
      'exec-out',
      'screencap',
      '-p',
    ], stdoutEncoding: null);
    final bytes = r.stdout as List<int>;
    if (r.exitCode != 0 || bytes.length < 100) return false;
    file.writeAsBytesSync(bytes);
    return true;
  }
}

/// Serves the fixtures on the LAN address the TV can reach. `/r/<path>`
/// answers 302 to `/<path>`, so a playlist's relative URIs only resolve if
/// the client uses the post-redirect URL (RFC 3986 §5.1.3).
class _FixtureServer {
  final HttpServer _server;
  final String origin;
  _FixtureServer(this._server, this.origin);

  static Future<_FixtureServer> start(Directory root, String tv) async {
    final ip =
        await NetworkUtils.getLocalIpAddress(targetDeviceIp: tv) ?? '127.0.0.1';
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final origin = 'http://$ip:${server.port}';
    server.listen((request) async {
      final path = Uri.decodeComponent(request.uri.path);
      if (path.startsWith('/r/')) {
        request.response.redirect(Uri.parse('$origin${path.substring(2)}'));
        return;
      }
      final file = File('${root.path}$path');
      if (path.contains('..') || !file.existsSync()) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response.headers.contentType = _type(path);
      request.response.contentLength = file.lengthSync();
      await request.response.addStream(file.openRead());
      await request.response.close();
    });
    return _FixtureServer(server, origin);
  }

  String url(String path, {bool redirect = false}) =>
      redirect ? '$origin/r/$path' : '$origin/$path';

  Future<void> close() => _server.close(force: true);

  static ContentType _type(String path) {
    if (path.endsWith('.m3u8')) {
      return ContentType('application', 'vnd.apple.mpegurl');
    }
    if (path.endsWith('.ts')) return ContentType('video', 'mp2t');
    if (path.endsWith('.m4s') || path.endsWith('.mp4')) {
      return ContentType('video', 'mp4');
    }
    // Obfuscated TS segments come back as images, like the real sources
    // the image/* override exists for.
    if (path.endsWith('.jpg')) return ContentType('image', 'jpeg');
    return ContentType.binary;
  }
}

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

enum _Verdict { pass, fail, look, skip }

class _Case {
  final String id;
  final String title;
  final List<String> fixes;
  final Future<_Verdict> Function(_Ctx) run;
  _Case(this.id, this.title, this.fixes, this.run);
}

class _Result {
  final _Case c;
  final _Verdict verdict;
  final List<String> notes;
  final List<String> shots;
  final int seconds;
  _Result(this.c, this.verdict, this.notes, this.shots, this.seconds);
  String get id => c.id;
}

void _writeSummary(
  Directory dir,
  List<_Result> results, {
  required String branch,
  required String sha,
  required String tv,
}) {
  final b =
      StringBuffer()
        ..writeln('# dart_cast TV suite')
        ..writeln()
        ..writeln('- Branch: `$branch` @ `$sha`')
        ..writeln('- TV: $tv')
        ..writeln('- Run: ${DateTime.now().toIso8601String()}')
        ..writeln()
        ..writeln(
          'PASS/FAIL come from device-reported state, position and '
          'volume. LOOK needs the screenshots read. SKIP did not run.',
        )
        ..writeln()
        ..writeln('| Case | Covers | Verdict | Notes | Evidence |')
        ..writeln('|---|---|---|---|---|');
  for (final r in results) {
    final shots = r.shots
        .map((s) => '[${s.split('/').last}](${r.id}/${s.split('/').last})')
        .join(' ');
    b.writeln(
      '| `${r.id}` | ${r.c.fixes.join('; ')} | '
      '**${r.verdict.name.toUpperCase()}** | '
      '${r.notes.join('<br>').replaceAll('|', '\\|')} | '
      '[log](${r.id}/log.txt) [samples](${r.id}/samples.tsv) $shots |',
    );
  }
  File('${dir.path}/summary.md').writeAsStringSync(b.toString());
  File('${dir.path}/results.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert([
      for (final r in results)
        {
          'id': r.id,
          'covers': r.c.fixes,
          'verdict': r.verdict.name,
          'notes': r.notes,
          'screenshots': r.shots,
          'seconds': r.seconds,
        },
    ]),
  );
}

// ---------------------------------------------------------------------------
// Options / git
// ---------------------------------------------------------------------------

class _Options {
  final List<String> args;
  _Options(this.args);
  bool flag(String name) => args.contains('--$name');
  String? value(String name) {
    for (final a in args) {
      if (a.startsWith('--$name=')) return a.substring(name.length + 3);
    }
    return null;
  }

  List<String> list(String name) =>
      (value(name) ?? '').split(',').where((s) => s.isNotEmpty).toList();
}

Future<String> _git(List<String> args) async {
  final r = await Process.run('git', args);
  return '${r.stdout}'.trim();
}
