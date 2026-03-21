# dart_cast

A pure Dart package for casting media to Chromecast, AirPlay, and DLNA devices.

<!-- Badges placeholder -->
<!-- [![pub package](https://img.shields.io/pub/v/dart_cast.svg)](https://pub.dev/packages/dart_cast) -->
<!-- [![build](https://github.com/abdelaziz-mahdy/dart_cast/actions/workflows/ci.yml/badge.svg)](https://github.com/abdelaziz-mahdy/dart_cast/actions) -->

## Features

- **Chromecast (CASTV2)** -- TLS + protobuf protocol with default media receiver
- **AirPlay** -- HTTP-based video casting with HAP authentication and feature detection
- **DLNA/UPnP** -- SSDP discovery with SOAP AVTransport control
- **Cross-platform** -- Android, iOS, macOS, Windows, Linux
- **Built-in HTTP proxy** -- transparent custom header injection for cast devices
- **HLS rewriting** -- m3u8 playlist URLs rewritten through proxy automatically
- **Subtitle support** -- WebVTT and SRT with automatic SRT-to-VTT conversion
- **Local file serving** -- cast downloaded content via the proxy server with `MediaTransformer` interface
- **Pluggable discovery** -- swap in native mDNS (e.g., bonsoir) on Apple platforms
- **Thoroughly tested** -- 666+ tests with mock servers for each protocol

## Protocol Status

| Protocol   | Streaming | Local Files | Subtitles | Status |
|------------|-----------|-------------|-----------|--------|
| **Chromecast** | Fully tested | MP4 recommended, TS fallback | VTT (auto-converts SRT) | **Recommended** |
| **DLNA** | Tested (HLS piped as TS) | Working (MP4, MKV, TS) | MKV embedded SRT | Working |
| **AirPlay** | Feature detection + V1/V2 `/play` | Not tested | Not yet supported | Experimental |

> **Chromecast is the most thoroughly tested protocol.** For local file casting, remux `.ts` files to `.mp4` using ffmpeg for the best experience. See [`doc/LOCAL_FILE_CASTING.md`](doc/LOCAL_FILE_CASTING.md) for details.

### What Works Where

| Use Case | Chromecast | DLNA | AirPlay |
|----------|-----------|------|---------|
| Stream HLS (remote) | Yes | Partial (piped as TS) | Yes |
| Stream MP4 (remote) | Yes | No | Yes |
| Local MP4 files | Yes | Yes | Untested |
| Local TS files | Yes (HLS wrap) | Yes | Untested |
| Local MKV files | No | Yes | Untested |
| Subtitles (sidecar VTT) | Yes | No | No |
| Subtitles (MKV embedded) | N/A | Yes | N/A |
| Seeking | Yes | Yes | Yes |
| Resume from position | Yes | Yes | Yes |
| Volume control | Yes | Yes | No |
| Subtitle switching | Yes | Requires reload | No |

### Protocol Notes

**Chromecast**
- Best all-round support, recommended for streaming
- Sidecar VTT subtitles with auto SRT-to-VTT conversion
- Local TS files wrapped in HLS automatically via `TsHlsMediaTransformer`

**DLNA**
- Best for local/downloaded file casting
- Uses HTTP/1.0 raw socket server -- Dart's HTTP/1.1 breaks some TVs (e.g., TCL Google TV)
- Subtitles: embed SRT in MKV container (sidecar subtitles ignored by most TVs)
- Subtitle styling controlled by TV settings, not the app
- Streaming (HLS piped as TS): works but duration reports as zero and seeking is unavailable
- Seeking in local files works via byte-range requests (206 Partial Content)

**AirPlay**
- Video URL casting supported (V1 and V2 auto-negotiation)
- Many smart TVs (Google TV, Roku) return 404 on `/play` -- only reliable on Apple TV
- Screen mirroring and RAOP audio not yet implemented

### Known Limitations

- **AirPlay video**: Feature flag detection works, but actual video casting (URL `/play`) returns 404 on some Google TV devices. AirPlay screen mirroring is not implemented.
- **Local TS files on Chromecast**: The built-in `TsHlsMediaTransformer` has known issues (per-segment buffering, subtitle drift). Remuxing to MP4 via ffmpeg is strongly recommended -- see [`example/lib/ffmpeg_media_transformer.dart`](example/lib/ffmpeg_media_transformer.dart) for a reference implementation.
- **DLNA streaming**: HLS piped as TS works, but duration shows as zero and seeking is not available in streaming mode.
- **DLNA subtitle styling**: Controlled by the TV's own settings, not configurable from the app.

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

The main entry point. Manages discovery, connections, and session lifecycle.

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

An active connection to a cast device. Provides full playback control.

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

A built-in HTTP proxy server that handles header injection. Used internally by protocol sessions, but also available directly.

- `start()` / `stop()` -- lifecycle
- `registerMedia(url, headers: {...})` -- returns a proxy URL
- `registerFile(filePath)` -- serves a local file over HTTP

### SubtitleConverter

Format conversion utilities for subtitles.

- `SubtitleConverter.srtToVtt(srtContent)` -- convert SRT to WebVTT (for Chromecast)
- `SubtitleConverter.vttToSrt(vttContent)` -- convert VTT to SRT (for DLNA MKV embedding)
- `SubtitleConverter.toAss(content)` -- convert to ASS format

### DeviceDiscoveryProvider

An abstract interface for pluggable discovery. Each protocol ships with a default implementation, and you can inject alternatives (e.g., `bonsoir` on Apple platforms).

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

No special permissions. Users may need to allow the app through Windows Firewall for proxy and multicast traffic.

## How the Proxy Works

Cast devices cannot send custom HTTP headers (like `Referer` or cookies) when fetching media. The built-in `MediaProxy` runs a local HTTP server on the device's WiFi IP, rewrites media URLs to point through itself, and forwards requests to the upstream server with the required headers attached. For HLS streams, the proxy also rewrites all segment and variant URLs inside m3u8 playlists so every subsequent request also goes through the proxy.

## DLNA Local Files

DLNA local file casting works out of the box -- just use `CastMedia.file()` with `CastMediaType.mp4` or `.mkv`. The proxy handles HTTP serving automatically (using HTTP/1.0 for maximum TV compatibility).

For **subtitles**, most DLNA TVs ignore sidecar subtitle URLs. The reliable approach is to embed SRT into an MKV container using ffmpeg before casting:

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

The default mDNS discovery uses `multicast_dns` (pure Dart), which works on Android, Windows, and Linux. On Apple platforms (iOS/macOS), the app sandbox may block raw UDP multicast. To handle this, inject a `bonsoir`-based discovery provider:

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

AirPlay devices advertise their capabilities as a bitmask in the `features` (or `ft`) TXT record of their mDNS advertisement. dart_cast parses this automatically during discovery and exposes it via `AirPlayFeatures`:

```dart
final features = AirPlayFeatures.parse('0x5A7FFFF7,0x1E');

features.supportsVideo    // true if bit 0 (V1) or bit 49 (V2) is set
features.supportsScreen   // true if bit 7 is set (screen mirroring)
features.supportsAudio    // true if bit 9 is set (RAOP audio)
features.requiresHapPairing // true if bit 46 or 48 is set
features.isV2Protocol     // true if bit 38 or 48 is set
```

### AirPlay Modes and Current Support

| Mode | Feature Bits | Status |
|------|-------------|--------|
| Video URL casting (V1) | Bit 0 | Supported |
| Video URL casting (V2) | Bit 49 | Supported |
| Screen mirroring | Bit 7 | Not yet implemented (see [docs/FUTURE_WORK.md](docs/FUTURE_WORK.md)) |
| Audio streaming (RAOP) | Bit 9 | Not yet implemented (see [docs/FUTURE_WORK.md](docs/FUTURE_WORK.md)) |

### V1/V2 Auto-Negotiation

`AirPlayMediaController.play()` automatically selects the best `/play` format for the target device:

1. **V1 binary plist** (`application/x-apple-binary-plist`) — tried first
2. **V1 text/parameters** — fallback if V1 plist returns 404 or 415
3. **V2 with RTSP SETUP** — fallback if V1 text also returns 404 or 415

This negotiation handles the wide variation in third-party AirPlay receiver implementations (Apple TV, smart TVs, audio receivers) without any manual configuration.

### Devices Without Video Support

If a device advertises neither video bit (0 nor 49), `play()` immediately throws `UnsupportedFeatureException` rather than attempting connection. This applies to many Google TV / Android TV devices that implement only screen mirroring but not video URL casting.

```dart
try {
  await airPlaySession.loadMedia(media);
} on UnsupportedFeatureException catch (e) {
  // Device supports screen mirroring only — video URL cast not available
  print(e.message);
}
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
| `PlaybackException`            | AirPlay device rejected /play after all format attempts      |

All exceptions carry a `message` and optional `cause`.

## Example

See the [example/](example/) directory for a Flutter app demonstrating device discovery, connection, and a full remote control UI.

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

This package was built with the help of the following open-source projects, protocol specifications, and community resources:

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
