# Spec-compliance work: TV test plan

The spec-compliance fixes (branch `fix/spec-compliance`) and the riskier
changes kept apart on `fix/spec-compliance-experimental` were all checked
against mocks only. This plan runs them on a real TV and decides which
experimental commits move to the fixes branch.

## Rules

- PASS and FAIL come from what the **device** reports: playback state,
  position still advancing several seconds later, device volume. A value
  the tool computed never counts (see `CLAUDE.md`).
- Test volume never goes above 0.10 of the TV's range (the suite uses
  0.08 and restores the original level).
- Anything only a picture can show is **LOOK**. Subtitles and the AirPlay
  PIN are LOOK cases, and the screenshots are the evidence.
- `adb screencap` cannot capture the video plane on Google TV, so a black
  frame proves nothing. Overlays such as player-drawn subtitles, dialogs and
  transport UI usually do capture.
- One experimental commit moves to `fix/spec-compliance` only when its cases
  pass on the experimental branch and no case that passed on the fixes
  branch regresses.

## Setup (once)

1. Turn the TV on, on the same LAN as this Mac. The TCL Google TV used so
   far is at `192.168.2.17`.
2. For screenshots and logcat, enable *Network debugging* in the TV's
   Developer options. The first `adb connect 192.168.2.17:5555` shows an
   "Allow debugging?" prompt on the TV, which someone at the TV has to
   accept once. Without adb the suite still runs, with no screenshots or
   logcat.
3. Build the fixtures (needs ffmpeg, takes about 20 s):

   ```sh
   dart run tool/tv_fixtures.dart
   ```

## Run

```sh
# 1. Fixes branch: the baseline.
cd ../dart_cast-spec-audit
dart run tool/tv_suite.dart --tv=192.168.2.17 --skip=ap_pair,ap_verify

# 2. AirPlay pairing: show the PIN, read it from the screenshot, pair.
dart run tool/tv_suite.dart --tv=192.168.2.17 --only=ap_pin_start
dart run tool/tv_suite.dart --tv=192.168.2.17 --only=ap_pair,ap_verify --pin=XXXX

# 3. Experimental branch: the same cases.
cd ../dart_cast-spec-experimental
dart run tool/tv_suite.dart --tv=192.168.2.17 --skip=ap_pair,ap_verify
```

Each run writes `build/tv_results/<time>_<sha>/`. That folder has
`summary.md`, `results.json`, and one folder per case holding `log.txt`
(every request the TV made, with its headers), `samples.tsv` (device values
at 1 Hz), `logcat.txt` and the screenshots.

## Cases

| Case | What it does | Fixes it checks | Judged on |
|---|---|---|---|
| `cc_idle_heartbeat` | Connect, idle 45 s | CC-1, CC-3, CC-4 | Session stays connected |
| `cc_mp4` | Local MP4: play, pause, resume, seek to 120 s | CC-8, CC-9 (exp.) | Device position and state |
| `cc_local_ts` | Local TS wrapped as HLS, seek | CO-11, CO-13, CO-15 (exp.) | Device position and state |
| `cc_hls_redirect_tags` | HLS behind a 302, tags between `#EXTINF` and URI | CO-1, CO-3, CO-17 | Device position and state |
| `cc_hls_obfuscated` | HLS with `.jpg` segment names | CO-19 (exp.) | Device position and state |
| `cc_hls_fmp4` | fMP4 HLS | CO-4, CO-19 (exp.) | Device position and state |
| `cc_hls_byterange` | Single-file byte-range HLS | CO-2, CO-6 | Device position and state |
| `cc_hls_alt_audio` | Separate audio rendition (4 s vs 6 s segments) | CO-1, CO-7 (exp.), CO-8 (exp.) | Device position; audio is LOOK/listen |
| `cc_subtitles_srt` | Sidecar SRT with "42", "1984", `&`, `<`, loose timestamps | CO-9 | Playback, plus LOOK at cue screenshots |
| `cc_volume` | Set 0.08, set −0.2 (expect 0), restore | CC-10 | Device-reported volume |
| `cc_app_closed_on_tv` | A second sender stops our app during playback (BACK on Google TV only backgrounds the receiver, which never reports closing) | CC-2 | Session reaches `disconnected` |
| `dl_mp4` | Local MP4: play, pause, resume, seek; records TV headers | DL-1, DL-6, DL-9, DL-14 | Device position and state |
| `dl_srt_sidecar` | Sidecar SRT | DL-3, CO-9 | Playback, plus LOOK; logs which subtitle URL the TV fetched |
| `dl_vtt_sidecar` | Sidecar WebVTT | DL-3 | As above |
| `dl_latin1_srt` | Latin-1 SRT | CO-9 decoding | As above |
| `dl_mkv_embedded_subs` | MKV with embedded SRT | Baseline | LOOK |
| `dl_set_subtitle_midplay` | Seek to 60 s, switch subtitle | DL-7 | Position stays ≥ 55 s, still playing |
| `dl_hls_piped_seek` | HLS piped as TS, behind a 302, seek | DL-5, DL-15, CO-1, CO-3 | Device position and state |
| `dl_hls_byterange` | Byte-range HLS piped as TS | CO-2 | Device position and state |
| `dl_hls_alt_audio` | Alt-audio HLS muxed and piped, seek | DL-5, CO-7/CO-8 (exp.) | Device position and state |
| `dl_volume` | Set 0.08, read back, restore | DL-8 | Device-reported volume |
| `ap_transient_connect` | Connect with no stored credentials | AP-4, AP-7, AP-9 | Connect succeeds |
| `ap_pin_start` | Show the PIN | AP-6 setup | LOOK (screenshot of the PIN) |
| `ap_pair` | PIN pair-setup | AP-4, AP-6 (exp.) | Credentials returned |
| `ap_verify_and_play` | Pair-verify, event channel, `/play` | AP-1, AP-2, AP-3 | Position; otherwise LOOK at the log (video has not played on any receiver tested so far) |

Cases marked "(exp.)" exercise code that exists only on the experimental
branch. On the fixes branch the same cases show the old behaviour, which is
the baseline for the comparison.

## Not covered by a device-reported value

- **Audio sync on alt-audio HLS.** No receiver reports it. Listen, or read
  the muxed packet counts in the log.
- **Whether a subtitle is drawn.** The screenshots show it only when the
  player draws subtitles in an overlay that `screencap` captures.
- **AirPlay video.** Playback has not started on any receiver tested so far
  (`doc/AIRPLAY.md`); this plan records what happens and does not expect a
  pass.

## Recording results

Copy the `summary.md` of each run to
`doc/specs/2026-11-15-spec-compliance-hardware-results.md`. Name the device
and the branch and SHA for each run, and keep untested paths marked as
untested.
