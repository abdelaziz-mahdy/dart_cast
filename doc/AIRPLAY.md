# AirPlay status

**Short version: video casting fails on the receivers tested so far. If you
need it working today, use Chromecast or DLNA.**

Pairing and session setup work. Video casting has not succeeded on any device
tried — and on the one examined closely it cannot, because that device does not
implement the endpoint video casting needs. That is a property of that receiver,
not a general statement about AirPlay: a receiver that does implement `/play`
should work, and none has been tested.

**If you have other hardware — an Apple TV especially — results are very
welcome.** See [Trying it on your own device](#trying-it-on-your-own-device);
it takes two commands.

## What works

- Device discovery, including correct decoding of the capability bitmask
- Transient pairing (`X-Apple-HKP: 4`) — no PIN, no stored credentials, which is
  what modern smart TVs use
- PIN-based HAP pairing (`X-Apple-HKP: 3`) for devices that show a passcode
- The encrypted session: pair-verify, RTSP `SETUP` with a live UDP timing
  server, the event channel, `RECORD` and keep-alive

All of the above is confirmed against a physical TV.

## What doesn't

Sending a video URL. `POST /play` returns 404.

## Why

The receiver examined (TCL Google TV, Apple AirPlaySDK 3.5.0.244) implements
four HTTP endpoints:

```
/command   /feedback   /info   /server-info
```

There is no `/play`, `/playback-info`, `/rate` or `/scrub`, and the string
`Content-Location` — the key every AirPlay `/play` body is built around — does
not appear anywhere in its receiver binary. Those endpoints are the AirPlay 1
era interface; this device drives playback through AirPlay 2 *unified media
control* (`/command`) into an hls.js-based receiver app instead, which is a
different protocol this package does not implement.

Two things rule out the obvious alternative explanations:

- **It isn't an authorization problem.** `/play` returns 404 identically with
  transient credentials, with full PIN-based credentials, and with no session at
  all. The device knows how to say "not authorized" — it answers `470` elsewhere.
  For `/play` it says *not found*.
- **It isn't a defect in this package.** AirPlay video from Apple's own QuickTime
  Player fails on the same TV in the same way: QuickTime reports "This video is
  playing on Living room TV" while the TV shows its idle AirPlay wallpaper and
  the timeline never leaves `00:00:00`. macOS negotiates an *audio* session; no
  video stream is ever set up.

Screen mirroring works on that TV. Media casting does not, for any sender.

## What this package does about it

`play()` throws `UnsupportedFeatureException` naming the cause, rather than
hanging or failing silently. A receiver that advertises no video capability at
all is rejected before any request is sent.

## Devices tested

| Device | `features` | Video V1 (bit 0) | Video V2 (bit 49) | `/play` |
|---|---|---|---|---|
| TCL JX32B / Google TV | `0x000bcf46007f8ad0` | No | Yes | **404 — endpoint absent** |
| Roku Express | `0x038bcf46007f8ad0` | No | Yes | Not tested |
| macOS AirPlay receiver | `0x38174fde4a7fcfd5` | Yes | Yes | Not tested |
| Apple TV | — | — | — | Never tested |

Neither smart TV advertises AirPlay 1 video, and both want PIN-less transient
pairing — which is why the package now picks its protocol version from the
advertised bits rather than probing.

## Trying it on your own device

Other receivers may implement `/play` — an Apple TV is the obvious candidate,
and none has been tested. Two scripts will tell you without guesswork:

```bash
# What the device advertises: capability bits, pairing mode, reachable ports.
# Touches nothing.
dart run tool/airplay_probe.dart

# Full connect → pair → SETUP → play → poll, printing every wire step.
dart run tool/airplay_hardware_check.dart <TV_IP>
```

If `/play` returns 200 on your device, playback should work and I'd be glad to
hear about it — please open an issue with the trace.

## Deeper detail

Raw traces, the receiver's own ADB logs and the full investigation are in
[`specs/2026-07-25-airplay-hardware-results.md`](specs/2026-07-25-airplay-hardware-results.md).

One finding worth flagging for anyone comparing implementations: **pyatv
mis-parses two-part feature strings.** Its `parse_features` concatenates the two
hex strings rather than shifting the upper word by 32 bits, so a device that
omits leading zeros (`0x7F8AD0,0xBCF46`) is decoded 24 bits off and reports no
video support. This package shifts, which matches the value the device reports
for itself.
