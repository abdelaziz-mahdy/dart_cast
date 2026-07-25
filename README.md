# dart_cast

Cast media to Chromecast, AirPlay, and DLNA devices from pure Dart.

<!-- Badges placeholder -->
<!-- [![pub package](https://img.shields.io/pub/v/dart_cast.svg)](https://pub.dev/packages/dart_cast) -->
<!-- [![build](https://github.com/abdelaziz-mahdy/dart_cast/actions/workflows/ci.yml/badge.svg)](https://github.com/abdelaziz-mahdy/dart_cast/actions) -->

## Features

- **Chromecast (CASTV2)** -- TLS + protobuf with default media receiver
- **AirPlay** -- HTTP video casting with HAP authentication and feature detection
- **DLNA/UPnP** -- SSDP discovery, SOAP AVTransport control
- **Cross-platform** -- Android, iOS, macOS, Windows, Linux
- **Built-in HTTP proxy** -- injects custom headers transparently for cast devices
- **HLS rewriting** -- rewrites m3u8 playlist URLs through proxy automatically
- **Subtitle support** -- WebVTT and SRT with automatic SRT-to-VTT conversion
- **Local file serving** -- serves downloaded content via proxy with `MediaTransformer` interface
- **Pluggable discovery** -- swap in native mDNS (e.g., bonsoir) on Apple platforms
- **750+ tests** -- mock servers for each protocol

## Protocol Status

**Chromecast and DLNA both play media on real hardware.** AirPlay does not —
its handshake is verified but no tested receiver accepts a video URL.

| Protocol | Hardware-verified? | Evidence | Use it? |
|---|---|---|---|
| **Chromecast** | **Yes** — media actually played | Full local-file cast to a TCL Google TV captured in [`test/integration/logs.txt`](test/integration/logs.txt) (`Local file loaded successfully`) | **Recommended** |
| **DLNA** | **Yes** — media actually played | Local MP4 and remote HLS both played on a TCL Google TV on 2026-07-25: correct duration, position advancing, pause/resume/seek all working (`tool/dlna_hardware_check.dart`). Sidecar subtitles did **not** render | Good second choice, especially for local MKV |
| **AirPlay** | Handshake yes, playback **no** | Pairing, RTSP `SETUP` with timing server, event channel and `RECORD` all verified against a real receiver on 2026-07-25. `/play` returns 404 — see below | **Not for video.** Use Chromecast or DLNA |

> **A passing test suite is not hardware verification.** All 750+ tests here run
> against mock servers. The AirPlay work is the cautionary tale: 666 tests passed
> for months against a protocol path that hardware testing had already shown
> failing — the suite simply could not see it. Where this README says "verified", it means a captured session with a
> physical device; where it doesn't, assume it hasn't been.

### AirPlay: read this before using it

AirPlay video casting is implemented and its AirPlay 2 handshake is
hardware-verified, but **no receiver has yet been found that accepts the
`/play` request**, and the one device tested in depth cannot play AirPlay video
from *any* sender:

- The TCL Google TV tested exports only four HTTP endpoints — `/command`,
  `/feedback`, `/info`, `/server-info`. `/play`, `/playback-info`, `/rate` and
  `/scrub` do not exist on it, and the string `Content-Location` is absent from
  its receiver binary entirely.
- **Apple's own software fails the same way.** QuickTime Player on macOS reports
  "This video is playing on Living room TV" while the TV shows only its idle
  AirPlay wallpaper and QuickTime's timeline never leaves `00:00:00`. macOS
  negotiates an *audio* session; no video stream is ever set up. Screen
  mirroring works on that TV — media casting does not, for anyone.
- On such a receiver `play()` throws `UnsupportedFeatureException` with a
  message naming the cause, rather than hanging or silently doing nothing.

Full write-up, including the ADB-captured receiver logs:
[`doc/specs/2026-07-25-airplay-hardware-results.md`](doc/specs/2026-07-25-airplay-hardware-results.md).

> **Chromecast is the best-tested protocol.** For local file casting, remux `.ts` to `.mp4` with ffmpeg. See [`doc/LOCAL_FILE_CASTING.md`](doc/LOCAL_FILE_CASTING.md).

### What Works Where

"Implemented" means the code path exists and passes mock tests. Only the
Chromecast column has a captured hardware session behind it.

| Use Case | Chromecast | DLNA | AirPlay |
|----------|-----------|------|---------|
| Stream HLS (remote) | Yes | Partial (piped as TS) | Implemented, no receiver accepts it yet |
| Stream MP4 (remote) | Yes | No | Implemented, no receiver accepts it yet |
| Local MP4 files | **Yes (verified)** | Implemented | Implemented, unverified |
| Local TS files | Yes (HLS wrap) | Implemented | Implemented, unverified |
| Local MKV files | No | Implemented | Implemented, unverified |
| Subtitles (sidecar VTT) | Yes | No | No |
| Subtitles (MKV embedded) | N/A | Yes | N/A |
| Seeking | Yes | Yes | Implemented, unverified |
| Resume from position | Yes | Yes | Implemented, unverified |
| Volume control | Yes | Yes | No |
| Subtitle switching | Yes | Requires reload | No |
| Device discovery | Yes | **Yes (verified)** | **Yes (verified)** |
| Pairing / auth | N/A | N/A | **Yes (verified)** — transient and PIN |

### Protocol Notes

**Chromecast**
- Best overall support; recommended for streaming
- Sidecar VTT subtitles with auto SRT-to-VTT conversion
- Wraps local TS files in HLS via `TsHlsMediaTransformer`

**DLNA**
- Best for local/downloaded files
- Uses HTTP/1.0 raw socket server -- Dart's HTTP/1.1 breaks some TVs (e.g., TCL Google TV)
- Embed SRT in MKV for subtitles (most TVs ignore sidecar files)
- TV controls subtitle styling
- HLS piped as TS: plays, and seeking now works (the pipe restarts at the requested offset). The session reports the real duration probed from the playlist; the TV's own on-screen readout may still show a placeholder, which a sender cannot change
- Local file seeking via byte-range requests (206 Partial Content)

**AirPlay**
- Video URL casting, with the protocol version chosen from the device's advertised feature bits
- Handshake verified against a real receiver; video URL playback not yet achieved on any tested device — see the hardware matrix below
- Screen mirroring and RAOP audio unimplemented

### Known Limitations

- **AirPlay video**: the AirPlay 2 handshake is hardware-verified, but no tested receiver accepts `/play` -- modern smart TVs use AirPlay 2 unified media control (`/command`), which is unimplemented. See the hardware matrix below. Screen mirroring is also unimplemented.
- **Local TS on Chromecast**: `TsHlsMediaTransformer` has per-segment buffering and subtitle drift. Remux to MP4 via ffmpeg instead -- see [`example/lib/ffmpeg_media_transformer.dart`](example/lib/ffmpeg_media_transformer.dart).
- **DLNA streaming**: HLS is piped as MPEG-TS. Seeking works via a pipe restart, and `durationStream` carries the real length; a renderer's own UI may still show a placeholder duration because the stream has no `Content-Length`.
- **DLNA subtitle styling**: The TV controls styling, not the app.

## Supported Platforms

| Protocol   | Android | iOS | macOS | Windows | Linux |
|------------|---------|-----|-------|---------|-------|
| Chromecast | yes     | yes | yes   | yes     | yes   |
| AirPlay    | yes     | yes | yes   | yes     | yes   |
| DLNA       | yes     | yes | yes   | yes     | yes   |

## Quick Start

```dart
import 'package:dart_cast/dart_cast.dart';

final castService = CastService(
  discoveryProviders: [
    DlnaDiscoveryProvider(),
    ChromecastDiscoveryProvider(),
    AirPlayDiscoveryProvider(),
  ],
  sessionFactory: (device) {
    switch (device.protocol) {
      case CastProtocol.chromecast:
        return ChromecastSession(device: device);
      case CastProtocol.airplay:
        return AirPlaySession(device);
      case CastProtocol.dlna:
        // DLNA requires a device description with control URLs.
        // Use DlnaDeviceDescription.fetch(device) then DlnaSession(device, description).
        return DlnaSession(device, dlnaDescription);
    }
  },
);

// Discover devices on the local network
final devices = await castService.startDiscovery().first;

// Connect to the first device found
final session = await castService.connect(devices.first);

// Cast an HLS stream with custom headers
await session.loadMedia(CastMedia(
  url: 'https://example.com/video.m3u8',
  type: CastMediaType.hls,
  httpHeaders: {'Referer': 'https://example.com'},
  title: 'My Video',
));

// Control playback
await session.pause();
await session.seek(Duration(minutes: 5));
await session.play();

// Monitor state
session.stateStream.listen((state) => print('State: $state'));
session.positionStream.listen((pos) => print('Position: $pos'));

// Clean up
await session.disconnect();
castService.dispose();
```

## API Overview

### CastService

The main entry point. Manages discovery, connections, and sessions.

```dart
final service = CastService(
  discoveryProviders: [...],  // protocol-specific providers
  sessionFactory: (device) => ...,  // creates sessions by protocol
);
```

- `startDiscovery()` -- returns a `Stream<List<CastDevice>>`
- `connect(device)` -- returns a `Future<CastSession>`
- `reconnect()` -- reconnects to the last-used device
- `activeSession` -- the current session, if any
- `dispose()` -- releases all resources

### CastDevice

A discovered device on the network.

- `id`, `name` -- identity
- `protocol` -- `CastProtocol.chromecast`, `.airplay`, or `.dlna`
- `address`, `port` -- network location
- `toJson()` / `CastDevice.fromJson()` -- serialization for persistence

### CastSession

An active connection to a cast device with full playback control.

- `loadMedia(CastMedia)` -- start playing content
- `play()`, `pause()`, `stop()`, `seek(Duration)` -- playback controls
- `setVolume(double)` -- 0.0 to 1.0
- `setSubtitle(CastSubtitle?)` -- subtitle track selection
- `stateStream`, `positionStream`, `durationStream`, `volumeStream` -- reactive streams
- `disconnect()` -- end the session

### CastMedia

Describes what to play.

```dart
CastMedia(
  url: 'https://example.com/video.m3u8',
  type: CastMediaType.hls,        // hls, mp4, mkv, or mpegTs
  httpHeaders: {'Referer': '...'}, // injected via proxy
  title: 'Episode 1',
  imageUrl: 'https://example.com/thumb.jpg',
  startPosition: Duration(seconds: 30),
  subtitles: [
    CastSubtitle(
      url: 'https://example.com/subs.vtt',
      label: 'English',
      language: 'en',
      format: 'vtt',
    ),
  ],
);
```

### MediaProxy

Built-in HTTP proxy that injects headers. Protocol sessions use it internally, but you can use it directly.

- `start()` / `stop()` -- lifecycle
- `registerMedia(url, headers: {...})` -- returns a proxy URL
- `registerFile(filePath)` -- serves a local file over HTTP

### SubtitleConverter

Converts between subtitle formats.

- `SubtitleConverter.srtToVtt(srtContent)` -- convert SRT to WebVTT (for Chromecast)
- `SubtitleConverter.vttToSrt(vttContent)` -- convert VTT to SRT (for DLNA MKV embedding)
- `SubtitleConverter.toAss(content)` -- convert to ASS format

### DeviceDiscoveryProvider

Abstract interface for pluggable discovery. Each protocol ships a default implementation; inject alternatives (e.g., `bonsoir`) on Apple platforms.

## Platform Setup

### iOS

Add to `Info.plist`:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>This app discovers cast devices on your local network.</string>
<key>NSBonjourServices</key>
<array>
  <string>_googlecast._tcp</string>
  <string>_airplay._tcp</string>
</array>
```

### Android

Add to `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
<uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<!-- Android 12+ -->
<uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" />
```

### macOS

Add to your entitlements file:

```xml
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.network.server</key>
<true/>
```

### Windows

No special permissions. Users may need to allow the app through Windows Firewall for proxy and multicast.

## How the Proxy Works

Cast devices cannot send custom HTTP headers (like `Referer` or cookies) when fetching media. `MediaProxy` runs a local HTTP server on the device's WiFi IP, rewrites media URLs to route through itself, and forwards requests with the required headers. For HLS streams, it also rewrites segment and variant URLs inside m3u8 playlists so every subsequent request routes through the proxy.

## DLNA Local Files

DLNA local file casting works out of the box -- use `CastMedia.file()` with `CastMediaType.mp4` or `.mkv`. The proxy serves files over HTTP/1.0 for maximum TV compatibility.

Most DLNA TVs ignore sidecar subtitle URLs. Embed SRT into an MKV container with ffmpeg before casting:

```bash
# Remux video + subtitle into MKV (fast, no re-encoding)
ffmpeg -i video.mp4 -i subtitle.srt -map 0 -map 1 -c copy -c:s srt output.mkv
```

```dart
// Cast the MKV with embedded subtitles
await session.loadMedia(CastMedia.file(
  filePath: '/path/to/output.mkv',
  type: CastMediaType.mkv,
  title: 'My Video',
  startPosition: Duration(minutes: 5), // resume from saved position
));
```

See the [example app](example/) for a complete implementation with ffmpeg remuxing.

## Pluggable Discovery

The default mDNS discovery uses `multicast_dns` (pure Dart), which works on Android, Windows, and Linux. On Apple platforms (iOS/macOS), the app sandbox may block raw UDP multicast. Inject a `bonsoir`-based provider instead:

```dart
// In your Flutter app
import 'package:bonsoir/bonsoir.dart';

class BonsoirChromecastProvider implements DeviceDiscoveryProvider {
  @override
  CastProtocol get protocol => CastProtocol.chromecast;

  @override
  Stream<List<CastDevice>> startDiscovery({
    Duration timeout = const Duration(seconds: 10),
  }) {
    // Use BonsoirDiscovery to find _googlecast._tcp services
    // and map them to CastDevice instances.
  }

  // ...
}

final service = CastService(
  discoveryProviders: [BonsoirChromecastProvider()],
  sessionFactory: ...,
);
```

## AirPlay Capabilities

### Feature Flag Detection

AirPlay devices advertise capabilities as a bitmask in the `features` (or `ft`) TXT record. dart_cast parses this during discovery and exposes it via `AirPlayFeatures`:

```dart
final features = AirPlayFeatures.parse('0x5A7FFFF7,0x1E');

features.supportsVideo    // true if bit 0 (V1) or bit 49 (V2) is set
features.supportsScreen   // true if bit 7 is set (screen mirroring)
features.supportsAudio    // true if bit 9 is set (RAOP audio)
features.requiresHapPairing // true if bit 43, 46 or 48 is set
features.supportsTransientPairing // true if bit 43 or 48 is set (no PIN)
features.isV2Protocol     // true if bit 38 or 48 is set
```

### AirPlay Modes and Current Support

| Mode | Feature Bits | Status |
|------|-------------|--------|
| Video URL casting (V1) | Bit 0 | Implemented -- plain HTTP `POST /play`, no RTSP setup |
| Video URL casting (V2) | Bits 38/48 + bit 49 | Implemented -- requires transient pairing, RTSP `SETUP` with a live UDP timing server, `RECORD`, and a `/rate` after `/play`. Not yet verified against hardware |
| Screen mirroring | Bit 7 | Not yet implemented (see [doc/FUTURE_WORK.md](doc/FUTURE_WORK.md)) |
| Audio streaming (RAOP) | Bit 9 | Not yet implemented (see [doc/FUTURE_WORK.md](doc/FUTURE_WORK.md)) |

### Capability-Driven Version Selection

`AirPlayMediaController.play()` decides which protocol to speak **before sending anything**, from the bitmask the device advertises over mDNS:

- Bit 38 or bit 48 set -> AirPlay 2. Bit 49 is then required; the session pairs
  transiently, runs RTSP `SETUP` (advertising a live UDP timing port) and
  `RECORD`, sends `POST /play`, and follows it with `POST /rate?value=1.000000`.
  **That last command is not optional** -- an AirPlay 2 `/play` starts the item
  paused, so without it the receiver sits on a black frame.
- Otherwise -> AirPlay 1. Bit 0 is required; a plain `POST /play` with a binary
  plist body, no RTSP setup.

There is no fallback ladder. Earlier versions tried a V1 `/play` first and only
reached the V2 path if the device answered 404 or 415. Every AirPlay 2-only
receiver answers that first request with 404 -- correctly, since it never
advertised V1 -- and the 404 was then misread as "this TV cannot cast video".

### Devices Without Video Support

If a device advertises neither video bit (0 nor 49), `play()` throws `UnsupportedFeatureException` before any request goes out. An AirPlay 2 receiver with bits 38/48 but no bit 49 is a mirroring-only or audio-only device; use Chromecast or DLNA for those.

```dart
try {
  await airPlaySession.loadMedia(media);
} on UnsupportedFeatureException catch (e) {
  // Device supports screen mirroring only — video URL cast not available
  print(e.message);
}
```

### Hardware Test Matrix

Status after a live hardware run on 2026-07-25 (full write-up:
[`doc/specs/2026-07-25-airplay-hardware-results.md`](doc/specs/2026-07-25-airplay-hardware-results.md)):
the AirPlay 2 **handshake is verified working** — pairing (transient *and*
PIN-based), RTSP `SETUP` with a live timing server, the event channel,
`/feedback` and `RECORD` were all accepted by a real receiver. **Video URL
playback was not achieved**, because the receiver tested has no `/play`
endpoint at all.

| Device | Raw `features` | V1 (bit 0) | V2 (bit 49) | Pairing verified | `/play` |
|---|---|---|---|---|---|
| TCL JX32B / Google TV, AirPlaySDK 3.5.0.244 | `0x000bcf46007f8ad0` | No | Yes | **Yes** — transient *and* PIN-based HAP | **404 — endpoint absent** |
| Roku Express | `0x038bcf46007f8ad0` | No | Yes | Not tested (device off-network) | Not tested |
| macOS AirPlay receiver (MacBook Pro) | `0x38174fde4a7fcfd5` | Yes | Yes | Not tested | Not tested |
| Apple TV (any model) | — | — | — | — | **Never tested.** Earlier README versions claimed AirPlay was "reliable only on Apple TV"; that claim was never supported by evidence |

**Why the TCL 404s.** Pulling its receiver apart
(`/system/app/RtkAirPlay/RtkAirPlay.apk` → `libairplay2-lib.so`) shows it
exports exactly four HTTP endpoints — `/command`, `/feedback`, `/info`,
`/server-info` — and the string `Content-Location` does not appear in the
binary at all. The AirPlay 1-era media REST endpoints (`/play`,
`/playback-info`, `/rate`, `/scrub`) are simply not implemented. Playback is
driven over AirPlay 2 *unified media control* (`POST /command`, feature bit 38)
into an hls.js receiver web app. dart_cast does not speak that protocol yet, so
`play()` raises `UnsupportedFeatureException` naming the cause. Use Chromecast
for these devices — it is verified working against this exact TV.

**Apple's own sender fails identically.** Sending a local MP4 from QuickTime
Player on macOS to this TV reports "This video is playing on Living room TV"
while the TV shows only its idle AirPlay wallpaper and QuickTime's timeline
stays at `00:00:00`. The session macOS negotiates is an *audio* session. Screen
mirroring works on this TV; media casting does not — for any sender tested,
Apple included. No sender-side library can fix that.

> **Note on pyatv.** `atvremote` reports `PlayUrl: Unavailable` for this TV, but
> that is a bug in pyatv, not a property of the device: its `parse_features`
> concatenates the two hex *strings* rather than shifting by 32 bits, so a
> device that omits leading zeros (`0x7F8AD0,0xBCF46`) is decoded 24 bits off.
> The TV's own `fex`/`featuresEx` field confirms dart_cast's decoding.

Two things worth reading off this table:

- Neither third-party receiver advertises AirPlay 1 video, so the old V1-first
  `/play` probe was always a request they had said they do not accept.
- Both want transient pairing, which needs no PIN and no user interaction — so
  the PIN flow the package used to be limited to could never have worked on
  them unattended.

Chromecast, by contrast, is verified working against the same TV — there is a
complete successful local-file cast to it in `test/integration/logs.txt`.

To run the verification yourself, follow
[`doc/specs/2026-07-25-airplay-hardware-test-plan.md`](doc/specs/2026-07-25-airplay-hardware-test-plan.md):

```bash
dart run tool/airplay_probe.dart                       # decode what is on the network
dart run tool/airplay_hardware_check.dart <TV_IP>      # full connect → play → poll trace
```

## Error Handling

| Exception                      | When                                                         |
|--------------------------------|--------------------------------------------------------------|
| `CastException`               | Base class for all casting errors                            |
| `DeviceUnreachableException`   | Device found but connection failed (offline, refused)        |
| `ConnectionLostException`      | Connection dropped (network change, device sleep)            |
| `MediaLoadFailedException`     | Device rejected the media (unsupported format, bad URL)      |
| `ProxyUpstreamException`       | Proxy failed to fetch upstream content (403, timeout)        |
| `DiscoveryException`           | Discovery failed (permissions denied, no network)            |
| `ProtocolException`            | Protocol-specific error (bad SOAP response, protobuf err)    |
| `UnsupportedFeatureException`  | AirPlay device lacks the required feature (e.g. video bits)  |
| `PlaybackException`            | AirPlay device rejected `/play`, or the `/rate` that must follow it |

All exceptions carry a `message` and optional `cause`.

## Example

See [example/](example/) for a Flutter app with device discovery, connection, and a full remote control UI.

## Architecture

```
Consumer App (any Dart/Flutter app)
  Uses: CastService, CastSession, CastMedia
          |
Core Layer (protocol-agnostic)
  CastService -> DiscoveryManager
              -> CastSession (state machine)
              -> MediaProxy (header injection)
          |
Protocol Layer (isolated per protocol)
  DLNA         Chromecast       AirPlay
  SSDP         mDNS             mDNS
  SOAP/XML     TLS+Protobuf     HTTP
```

## Acknowledgments and References

Built with help from these open-source projects, specifications, and community resources:

### Protocol References

- **[pyatv](https://github.com/postlund/pyatv)** by Erik Hilsdale -- The most complete open-source Apple TV / AirPlay protocol implementation. Our AirPlay HAP authentication (SRP-6a, pair-setup, pair-verify) is based on pyatv's protocol analysis.
- **[node-castv2](https://github.com/thibauts/node-castv2)** by Thibaut Séguy -- Reference implementation of the Chromecast CASTV2 protocol. Our protobuf message framing and channel architecture follows this implementation.
- **[dart_chromecast](https://github.com/terrabythia/dart_chromecast)** -- Dart Chromecast implementation that informed our CASTV2 TLS connection and message handling.
- **[dlna_dart](https://github.com/nicedayzhu/dlna-dart)** -- Lightweight DLNA client in Dart. Our SSDP discovery and SOAP action patterns were influenced by this package.
- **[pair_ap](https://github.com/ejurgensen/pair_ap)** by ejurgensen -- C library for AirPlay pairing used by shairport-sync and owntone-server. Referenced for FairPlay-SAP authentication flow details.

### Protocol Specifications

- [RFC 8216](https://www.rfc-editor.org/rfc/rfc8216) -- HTTP Live Streaming (HLS) specification
- [RFC 5054](https://www.rfc-editor.org/rfc/rfc5054) -- SRP-6a protocol and group parameters
- [UPnP AV Transport Service](https://upnp.org/specs/av/UPnP-av-AVTransport-v1-Service.pdf) -- DLNA/UPnP media control
- [Unofficial AirPlay Protocol Specification](https://nto.github.io/AirPlay.html) -- Community-maintained AirPlay reverse engineering docs
- [Google Cast Media Messages](https://developers.google.com/cast/docs/media/messages) -- Official Chromecast media protocol documentation
- [OpenAirPlay Spec](https://openairplay.github.io/airplay-spec/) -- AirPlay 2 protocol documentation including HAP pairing

### Dart Packages

- **[cryptography](https://pub.dev/packages/cryptography)** -- Ed25519, X25519, ChaCha20-Poly1305, HKDF-SHA512 for AirPlay authentication
- **[multicast_dns](https://pub.dev/packages/multicast_dns)** -- mDNS service discovery for Chromecast and AirPlay
- **[protobuf](https://pub.dev/packages/protobuf)** -- Protocol Buffers for Chromecast CASTV2 message serialization
- **[http](https://pub.dev/packages/http)** -- HTTP client for DLNA SOAP, AirPlay control, and media proxy

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, testing, and PR guidelines.

## License

MIT -- see [LICENSE](LICENSE) for details.
