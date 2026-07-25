# AirPlay 2 Hardware Verification — Results

**Date:** 2026-07-25
**Status:** Executed. Verdict below is from a live receiver, not a mock.
**Plan followed:** `doc/specs/2026-07-25-airplay-hardware-test-plan.md`
**Branch:** `fix/airplay-v2-capability-driven-play`

---

## Verdict

**The AirPlay 2 handshake this branch implements is correct and works against
real hardware.** Pairing, RTSP `SETUP` with a live UDP timing server, the event
channel, `/feedback` and `RECORD` were all accepted by the receiver.

**Video playback is impossible on this receiver, and not because of a defect
in this package.** Two independent lines of evidence:

1. The device does not implement the AirPlay `/play` endpoint, or any of the
   AirPlay 1-era media REST endpoints. Its receiver binary exports exactly four
   HTTP endpoints and does not contain the string `Content-Location`.
2. **AirPlay video from Apple's own software fails the same way.** QuickTime
   Player on macOS reports "This video is playing on Living room TV" while the
   TV displays only its idle AirPlay wallpaper and QuickTime's timeline never
   leaves `00:00:00`. The session macOS negotiates is an *audio* session
   (`timingProtocol: PTP`, volume negotiation, `_GeneralAudioAddIPAddrs`); no
   video stream is ever set up.

Screen mirroring works on this TV. Media casting does not — for anyone.

Route this device class to Chromecast, which is already verified working
against this exact TV.

---

## Device under test

| Field | Value |
|---|---|
| Name | Living room TV |
| Model | TCL JX32B (`integrator: TCL`, `manufacturer: TCL`) |
| Address | 192.168.2.17:7000 |
| Device ID | `81:5E:E3:E5:85:23` |
| Firmware | `5.3.4`, built Oct 13 2025 |
| OS | Android |
| AirPlay receiver | Apple AirPlaySDK `3.5.0.244`, `Server: AirTunes/377.40.00` |
| Receiver app | `com.realtek.airplay2` / `com.realtek.airplay2.daemon` |
| Web app | `webAppVersion: 75.112.0`, `hlsJSVersion: 3.4.21`, engine "Apple App Engine" |
| mDNS `features` | `0x7F8AD0,0xBCF46` |
| mDNS `flags` | `0x244` |
| Sender | macOS, 192.168.2.15, dart_cast on this branch |

---

## Finding 1 — our feature decoding is right; pyatv's is wrong

`atvremote` refused to even try: `PlayUrl: Unavailable`, `play_url is not
supported`. That is a **bug in pyatv**, not a property of the TV.

`pyatv/protocols/airplay/utils.py::parse_features` combines the two words by
**concatenating the hex strings**:

```python
value, upper = match.groups()
if upper is not None:
    value = upper + value          # "BCF46" + "7F8AD0" -> "BCF467F8AD0"
return AirPlayFlags(int(value, 16))
```

That is only equivalent to `upper << 32 | lower` when the lower word is written
with all eight digits. This TV advertises `0x7F8AD0` — six digits — so pyatv
shifts by 24 bits instead of 32 and lands on `0xbcf467f8ad0`, in which bit 49
is clear. Hence its refusal.

The receiver settles the argument itself. Its `fex` TXT record — and the
`featuresEx` field in `GET /info` — is the same bitmask as raw little-endian
bytes:

| Source | Value |
|---|---|
| `fex` = `0Ip/AEbPCwBAAg`, base64-decoded, first 8 bytes LE | `0x000bcf46007f8ad0` |
| `GET /info` → `features: 3324124306836176` | `0x000bcf46007f8ad0` |
| dart_cast `AirPlayFeatures.parse` (`upper << 32 \| lower`) | `0x000bcf46007f8ad0` ✅ |
| pyatv `parse_features` | `0x00000bcf467f8ad0` ❌ |

Decoded bits (dart_cast, confirmed against the device's own `featuresEx`):

| Bit | Name | Set |
|---|---|---|
| 0 | SupportsAirPlayVideoV1 | **no** |
| 38 | SupportsUnifiedMediaControl | yes |
| 43 | SupportsSystemPairing | yes |
| 48 | SupportsCoreUtilsPairingAndEncryption | yes |
| 49 | SupportsAirPlayVideoV2 | yes |

The captured-bitmask tests added in this branch assert exactly this table, and
they were written before the device was available. They match.

---

## Finding 2 — the handshake works, including both pairing flows

Everything this branch added was exercised end to end against the device.

| Step | Result |
|---|---|
| `GET /info` | **200**, binary plist, 1839 bytes — parsed correctly by the new bplist path |
| Transient pairing (`X-Apple-HKP: 4`, PIN `3939`, `Flags` TLV `0x10`, M1–M4) | **works** — SRP proof accepted, no PIN prompt, nothing persisted |
| HAP PIN pairing (`X-Apple-HKP: 3`, M1–M6) | **works** — passcode `1428` read off the TV, credentials issued |
| pair-verify with those credentials | **works** — device signature verified |
| HAP channel encryption | **works** — every subsequent frame decrypted, no MAC failures |
| RTSP `SETUP` with `timingPort` + `timingProtocol: "NTP"` | **200**; receiver echoed `{uiPreloaded: true, eventPort: 43145, timingPort: 40469}` |
| Event channel on the returned port | **connected on attempt 1** |
| `POST /feedback` | **200** |
| RTSP `RECORD` | **200** |

The receiver's own log confirms it accepted our session verbatim:

```
[AirPlay] Setup (192.168.2.15:56050)
[AirPlay] AirPlay session[14191248873535783523] created successfully
[AirPlay] Setting up session ... {
    "timingProtocol" : "NTP"
    "timingPort" : 58594
    "name" : "dart_cast"
    "sessionUUID" : "C4F171A9-7A43-4263-AF61-1A29140DB1B9"
    ...
}
[AirPlayReceiverUI] AirPlayReceiverUI_AirPlaySessionEstablished
```

Two things this rules out for good:

- **Our SRP is not broken.** With a wrong PIN, pyatv and dart_cast received
  byte-identical rejections — M4 = `07 01 02 06 01 04`, i.e. TLV `Error =
  0x02 (kTLVError_Authentication)`, `SeqNo = 4`. The earlier failures were
  stale passcodes, nothing else. (pyatv does not check for that error TLV and
  ploughs on into M5, where it gets a `470`; this package stops at M4.)
- **Authorization is not the blocker.** `/play` returns 404 identically with
  transient credentials, with full PIN-based HAP credentials, and with no
  session set up at all. The device knows perfectly well how to say
  "unauthorized" — it answered `470 Connection Authorization Required` during a
  mis-sequenced pair-setup. For `/play` it says *not found*.

---

## Finding 3 — the receiver has no `/play` endpoint at all

Every AirPlay media REST endpoint answers 404, in every variant tried:
binary-plist body and `text/parameters`; over HTTP/1.1 and over RTSP/1.0;
before `SETUP` and after `RECORD`; with transient and with HAP credentials.

| Request | Response |
|---|---|
| `POST /play` | **404 Not Found** |
| `GET /playback-info` | **404 Not Found** |
| `POST /rate?value=1.000000` | **404 Not Found** |
| `GET /server-info` | **404 Not Found** |
| `POST /scrub`, `POST /getProperty?…`, `GET /features` | **404 Not Found** |
| `POST /feedback` | 200 OK |
| `GET /info` | 200 OK |
| `POST /command` | **400 Bad Request** — the endpoint exists, our payload was invented |

That is not a permissions pattern; it is an "endpoint does not exist" pattern,
and pulling the receiver apart confirms it. From
`/system/app/RtkAirPlay/RtkAirPlay.apk`,
`lib/armeabi-v7a/libairplay2-lib.so`:

```
$ strings -a libairplay2-lib.so | grep -E "^/(play|playback-info|rate|scrub|stop|info|server-info|feedback|command)"
/command
/feedback
/info
/server-info

$ strings -a libairplay2-lib.so | grep -c "Content-Location"
0
```

Four HTTP endpoints, and the string `Content-Location` — the key every
AirPlay `/play` body is built around — does not occur anywhere in the binary.

What *is* in there points at the modern path: `streams`, `streamType`,
`mediaControlPort`, `AssetUrl`, `AirPlayReceiverUI_ForwardMessageFromSenderToWebApp`,
`WebApp requesting to get/set properties or issuing command[%@]`. Playback is
performed by an hls.js-based receiver web app driven by control messages
forwarded from the sender — the AirPlay 2 *unified media control* design that
feature bit 38 advertises.

The receiver log also shows the SDK never learns what kind of session we want:

```
_AirPlayReceiverAppInterface_StartAirPlayApp inForeground[true] airPlaySessionType[Unknown]
    "airPlaySessionType" : 0
```

A video session would have to be requested through a second `SETUP` carrying a
`streams` array, which would yield a `mediaControlPort` to drive.

---

## Finding 4 — Apple's own sender cannot play video to this TV either

This is the control experiment, and it is the strongest evidence in this
document: **the failure reproduces with Apple's own software.**

A local 1080p MP4 was opened in **QuickTime Player** on macOS and sent to the TV
using QuickTime's AirPlay button — media AirPlay, deliberately not Control
Centre screen mirroring, which is a different code path and does work.

QuickTime reported success:

> AirPlay — This video is playing on "Living room TV".

The TV showed the idle AirPlay wallpaper and nothing else:

> **AirPlay** — Wirelessly share content from your iPhone, iPad, or Mac
> *Connected to abdelaziz's MacBook Pro*

No video. QuickTime's own timeline stayed pinned at `00:00:00` for the entire
attempt. Switching the output back to the MacBook resumed normal local
playback immediately (timeline advancing, picture on screen), so the file and
the player were never in question.

The receiver log explains why — the session Apple negotiated is an **audio**
session:

```
[AirPlay] Setup ([fe80::142d:95d3:5839:522a%wlan0]:56710)
[AirPlay] Setting up session 325365879309419824 ... {
    "osName" : "macOS"
    "timingProtocol" : "PTP"
    "model" : "Mac14,9"
    "timingPeerList" : [ ... ]
}
[AirPlay] _GeneralAudioAddIPAddrs: our ptp info: { ... }
[AirPlayReceiverAppInterface] _AirPlayReceiverAppInterface_StartAirPlayApp
    inForeground[true] airPlaySessionType[Unknown]
    "airPlaySessionType" : 0
[AirPlay] Responding to sender with current volume[-27.600000]
```

Across the whole capture, the strings `streams`, `mediaControlPort`,
`AssetUrl` and `dataPort` occur **zero** times. No video stream is ever set up,
by anyone, and `airPlaySessionType` never becomes anything but `Unknown` (0) —
neither for dart_cast nor for macOS.

**Conclusion: video AirPlay to this receiver does not work from any sender
tested, Apple's included.** Screen mirroring works; media casting does not.
That is a receiver-side limitation of this TV's AirPlay implementation, not a
defect in dart_cast — which is exactly what a package cannot fix from the
sender side.

---

## Per-phase results

| Phase | Outcome |
|---|---|
| Gate 0 — pyatv ground truth | **Invalid as a gate.** pyatv refused before contacting the TV, due to its own feature-parsing bug. Its verdict says nothing about the receiver. |
| 1 — capability probe | **Pass.** dart_cast's decode matches the device's own `featuresEx` exactly. (`tool/airplay_probe.dart` could not run: `multicast_dns` failed with `No route to host` on this host's interface, so the TXT records were read with `dns-sd` instead. Worth fixing separately.) |
| 2 — pairing | **Pass**, both transient and PIN-based HAP. |
| 3 — playback sequence | **Fail at `/play` (404).** Not a defect in this package — see Finding 3. |
| 4 — playback control | Not reachable. |
| 5 — second receiver | Not run (Roku Express not on this network at test time). |

---

## Consequences for this package

1. `AirPlayMediaController.play()` now raises `UnsupportedFeatureException`
   rather than a bare `PlaybackException` when an AirPlay 2 receiver completes
   the handshake and then 404s `/play`, and the message names the real cause
   and the alternative. A user hitting this should reach for Chromecast, not
   file a bug.
2. The README hardware matrix records this result. AirPlay video URL casting
   is **implemented and handshake-verified**, but no receiver has yet been
   found on this network that accepts `/play`.
3. Supporting these receivers means implementing AirPlay 2 unified media
   control: a `streams` `SETUP` to obtain `mediaControlPort`, then `POST
   /command` messages. That is a separate feature, and it needs a captured
   trace from a sender that genuinely drives video to this TV before it can be
   attempted honestly.

---

## Reproducing

```bash
dart run tool/airplay_probe.dart
dart run tool/airplay_hardware_check.dart 192.168.2.17 --features=0x7F8AD0,0xBCF46
```

Receiver-side observation (the TV must have ADB debugging enabled):

```bash
adb connect 192.168.2.17:5555
adb -s 192.168.2.17:5555 logcat -v time AirPlaySDK:V AirPlay:V '*:S'
adb -s 192.168.2.17:5555 exec-out screencap -p > tv.png   # reads the AirPlay passcode
```
