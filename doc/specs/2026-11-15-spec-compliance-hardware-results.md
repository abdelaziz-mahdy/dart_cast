# Spec-compliance work: hardware results

Runs of `tool/tv_suite.dart` (plan: `2026-11-15-spec-compliance-tv-test-plan.md`)
on 2026-11-15.

**Device:** TCL Google TV "Living room TV", Android 14, at 192.168.2.17.
Chromecast built in (Default Media Receiver); DLNA renderer is TCL's
`com.tcl.ttvs` (Platinum DMR) handing playback to TCL Media Center.
**Sender:** MacBook Pro on the same Wi-Fi.

PASS/FAIL come from device-reported state, position and volume. LOOK cases
were judged from `adb screencap` screenshots and, where the video plane
matters, from a webcam pointed at the TV (QuickTime camera preview), which
also shows the test pattern's burned-in second counter.

Evidence folders (`build/tv_results/<time>_<sha>/`) are local and not
committed; each holds the session log, TV logcat, 1 Hz device samples and
screenshots.

## Chromecast

Fixes branch at `bd40e2d` (the two cases marked † re-run at `c4261c8` /
`bc45530` after the suite itself was corrected).

| Case | Verdict | Device evidence |
|---|---|---|
| `cc_idle_heartbeat` | PASS | Connected through 45 s idle |
| `cc_mp4` | PASS | 0→9 s; paused 12→12 s; seek 120 → 124, 130 s, playing |
| `cc_local_ts` | PASS | Seek 120 → 125, 131 s, playing |
| `cc_hls_redirect_tags` | PASS | Seek 60 → 65, 71 s, playing |
| `cc_hls_obfuscated` | PASS | Seek 60 → 64, 70 s, playing |
| `cc_hls_fmp4` | **FAIL** | `LOAD_FAILED` — passes on the experimental branch, see below |
| `cc_hls_byterange` | PASS | Seek 60 → 64, 70 s, playing |
| `cc_hls_alt_audio` | PASS | Seek 60 → 64, 70 s, playing. Audio not judged |
| `cc_subtitles_srt` | LOOK ✓ | Camera and screenshots: "42", "*Tom & Jerry* say 1 < 2", "1984", the 14.5–18.25 s cue, each in its window |
| `cc_volume` † | PASS | 0.02 → 0.08 → 0.0 for −0.2 (clamped) |
| `cc_app_closed_on_tv` † | PASS | A second sender's STOP: session reached `disconnected` |

`cc_app_closed_on_tv` first pressed BACK on the remote. On Google TV that
only backgrounds the receiver: it kept sending `BUFFERING` and never closed,
so the case now stops the app from a second sender connection instead.

Experimental branch at `c83ad7b`, run stopped by request after seven cases:
`cc_idle_heartbeat`, `cc_mp4`, `cc_local_ts`, `cc_hls_redirect_tags`,
`cc_hls_obfuscated`, **`cc_hls_fmp4`** and `cc_hls_byterange` all PASS. That
run exercised the LOAD attribution (CC-9), keyframe scan (CO-15) and
segment-extension (CO-19) commits; those three moved to the fixes branch.

## DLNA

Fixes branch at `9b624a5` (final run of the day):

| Case | Verdict | Device evidence |
|---|---|---|
| `dl_mp4` | PASS | 2→13 s; paused 14→14 s; seek 120 → 124, 130 s, playing |
| `dl_srt_sidecar` | LOOK ✗ | Plays; no subtitle shown; TV never requested the subtitle |
| `dl_vtt_sidecar` | LOOK ✗ | Same |
| `dl_latin1_srt` | LOOK ✗ | Same |
| `dl_mkv_embedded_subs` | LOOK ✓ | Camera: embedded cues ("1984", 14.5 s cue) drawn |
| `dl_set_subtitle_midplay` | PASS | Seek 60, switch subtitle: 70 s and playing after |
| `dl_hls_piped_seek` | PASS | 3→14 s; paused 16→16 s; seek 60 → 61, 67 s, playing |
| `dl_hls_byterange` | PASS | Seek 60 → 63, 69 s, playing |
| `dl_hls_alt_audio` | **FAIL** | TV opens it but reports position 0 throughout |
| `dl_volume` | PASS | 0.02 → 0.08 read back, restored |

The same cases on `main` (`fc53c72`) for comparison: `dl_mp4` PASS;
`dl_srt_sidecar` no subtitle; `dl_set_subtitle_midplay` FAIL (restarted at
0 s, 10 s after the switch); `dl_hls_piped_seek` FAIL (the TV reported
STOPPED after 3 s and returned to the home screen).

### What the TV showed that the spec work did not predict

- **Sidecar subtitles cannot reach TCL's player.** The renderer parses the
  first subtitle `<res>` as `MediaMinorURI`, then starts TCL Media Center
  with the video URL alone; its player reports zero subtitle streams. In
  the renderer's code the minor URI is only used for photos
  (`dmrImageMinorUri`). Subtitles embedded in the container do show.
- **The player shows the URL's last path segment as the title** and ignores
  `dc:title`; it does not percent-decode it. Fixed by ending DLNA URLs in a
  URL-safe name built from the title (`e20ef3a`).
- **A piped TS URL with no `.ts` at the end** got a player the renderer
  never registered: position stuck at 0, and Stop/pause/seek ignored (the
  stream kept playing after Stop). With the named `.ts` URL the same stream
  passes every check.
- **Reloads race the player screen.** Stop closes TCL's player screen; a new
  URI ~100 ms later, while it is still closing, got an uncontrollable player
  that also broke the next cast. Fixed by waiting for STOPPED plus a short
  settle before the new URI (`9b624a5`). After a reload the renderer says
  PLAYING at 0 s / 0 s while loading and drops a Seek sent then; the
  deferred seek now waits for a position or duration (`1985f43`).
- Discovery with one socket per interface (experimental) still finds the TV
  from this Mac.

## AirPlay

Not run. Every AirPlay change in this work is verified against mocks only.

## Next round

On this TV:

1. All `ap_*` cases: transient connect, PIN pairing (PIN read from a
   screenshot), pair-verify + event channel + `/play`.
2. `dl_hls_alt_audio` and `cc_hls_alt_audio` on the experimental branch
   (segments paired by time, PCR kept, continuity counters across the pipe).
3. Every `dl_*` case on the experimental branch (no `DLNA.ORG_PN` profile).
4. A new case for an HLS master playlist with a sidecar subtitle on
   Chromecast (subtitle wrapper copies variants).
5. One full `cc_*` + `dl_*` run on the release commit.

Needs other hardware: sidecar subtitles and the 406 answers on a Samsung or
LG renderer; per-interface SSDP on a multi-homed sender.
