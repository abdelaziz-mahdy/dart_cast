## Unreleased

### Changed (behaviour)
- **AirPlay no longer probes `/play`.** The protocol version is chosen from the
  device's advertised feature bits before any request is sent, so a receiver
  that advertises no video bit now throws `UnsupportedFeatureException` earlier
  than it used to — at `play()`, rather than after up to three rejected
  requests. The V1 → V1-text → V2 fallback ladder is gone.
- `AirPlaySession.connect()` opens an encrypted, paired session for every
  AirPlay 2 receiver (feature bit 38 or 48), not only for devices that answer
  `/server-info` with 403. Connecting to such a device now performs transient
  pairing, so it can fail with `NeedsPairingException` where it previously
  succeeded into a session that could not actually cast.
- `AirPlayMediaController.dispose()` returns `Future<void>` (it now closes the
  UDP timing server). `play()` takes `startPositionSeconds:` in place of
  `startPosition:`, which was ambiguous between the two protocol versions.

### New
- AirPlay 2 transient pairing (`X-Apple-HKP: 4`, fixed PIN `3939`, `Flags`
  TLV `TransientPairing`) — no PIN prompt, no persisted credentials
- `AirPlayTimingServer` — UDP timing server bound for the life of a playback,
  advertised to the receiver as `timingProtocol: "NTP"` in RTSP `SETUP`
- The post-`/play` command sequence AirPlay 2 requires, including the mandatory
  `POST /rate?value=1.000000` — without it the receiver stays paused
- `AirPlayFeatures.supportsTransientPairing`, `.supportsSystemPairing`,
  `.supportsCoreUtilsPairing`, `.supportsLegacyPairing`
- `PlaybackInfo.error` and `.hasDuration`; `PlistCodec.parsePlaybackInfoBytes()`
- `tool/airplay_probe.dart` — mDNS + feature-bit + reachability probe
- `tool/airplay_hardware_check.dart` — end-to-end connect → pair → play → poll
  trace for verifying against a real receiver
- `doc/specs/2026-07-25-airplay-hardware-test-plan.md` — the procedure for that
  verification, and `README.md` now carries a hardware matrix instead of
  unsupported claims

### Fixed
- AirPlay 2 `/playback-info` is decoded as a binary plist. It was run through
  `utf8.decode` into an XML parser, so every poll yielded an all-zero result:
  position and duration stayed at 0 and the session never left `loading`
- RTSP `SETUP` advertises a real timing port instead of `timingProtocol: "None"`
- The RTSP URI names the sender's IP, not the receiver's
- A non-200 `SETUP` or `RECORD` throws instead of logging a warning and marking
  the session set up anyway
- Requests on the HAP encrypted socket are serialized, so the 2-second
  `/feedback` loop can no longer be handed the response belonging to `/play`,
  and concurrent writers can no longer desynchronise the ChaCha20 nonce
  counters into permanent MAC-verification failures
- `requiresHapPairing` includes bit 43 (`SupportsSystemPairing`)
- `MdnsServiceInfo.supportsVideo` accepts bit 49, not only bit 0
- `media.startPosition` reaches the device instead of being replaced with 0.0
- The pair-verify socket subscription is released before the socket is handed
  to `HapSession`, instead of buffering every encrypted byte for the session's
  lifetime
- `/playback-info` polling failures are logged at warning level, and a
  receiver-reported error ends the session rather than leaving it in `loading`
- Stale `docs/` paths in `README.md` and `CHANGELOG.md` corrected to `doc/`

## 0.6.0

### New
- Alt-audio HLS sources (split video + audio) now play on Chromecast and DLNA — pure-Dart MPEG-TS remuxer combines them into one muxed stream
- `MediaProxy.registerAltAudioMuxed()` — synthetic single-stream HLS master backed by per-segment muxing
- `HlsParser.extractAudioRenditions` + `audioGroup` on `extractVariants` entries
- TS DVB-table stripper for proxied `video/mp2t`, on by default; opt out via `registerMedia(stripDvbTables: false)`
- `MediaLoadFailedException` from `loadMedia()` on `LOAD_FAILED` / `IDLE+ERROR` / 15s timeout, carrying the receiver-reported reason
- HLS LOAD retries pass-through → muxer + stripper on failure, with `requestId` / `mediaSessionId` filtering against stale responses
- `ChromecastSession.enableReceiverDebugNamespaces` (default `false`) — opt-in CaC + debugoverlay subscribe and verbose receiver logging for debugging

### Fixed
- `setSubtitle()` activates the correct track (was always `trackId=1`)
- CORS `Access-Control-Allow-Origin` echoes the receiver `Origin` when the LOAD includes a `tracks` array
- State machine accepts `loading → {buffering, paused, idle}` and `idle → {buffering, playing, paused}`
- DLNA: failed `loadMedia` returns to `idle` instead of stuck in `loading`
- `Content-Length` only forwarded when the body streams through unchanged
- Proxy segment / subtitle URLs end in `.ts` / `.vtt` for the Chromecast URL-extension probe
- `image/*` Content-Type on proxied MPEG-TS subresources rewritten to `video/mp2t`

## 0.5.1

### Fixed
- **Pub points (static analysis)**: Resolved the six pana lints under `lib/` that kept the 0.5.0 static-analysis score at 40/50:
  - `curly_braces_in_flow_control_structures` in `ts_keyframe_scanner.dart` and `airplay/auth/airplay_auth.dart` — single-statement `if` bodies now wrapped in braces.
  - `use_super_parameters` on the two `CastMessage_*` enum constructors — converted to super-parameter syntax.
  - `camel_case_types` on the hand-written `CastMessage_ProtocolVersion` / `CastMessage_PayloadType` bindings in `chromecast/proto/cast_channel.dart` — suppressed via a file-level `// ignore_for_file: camel_case_types`, since these identifiers intentionally mirror the names `protoc --dart_out` would emit for Chromium's `cast_channel.proto`.

## 0.5.0

### Changed
- **protobuf**: Upgraded `protobuf` dependency from `^3.1.0` to `^6.0.0` for the latest performance improvements and bug fixes (#6). Hand-written CastMessage bindings remain compatible; no API changes.
- **Minimum Dart SDK**: Bumped `sdk` constraint from `^3.0.0` to `^3.7.0` (required by `protobuf` 4.1.1+).

## 0.4.3

### Fixed
- **Analyzer warnings**: Resolved pre-existing unused variable warnings in test files
- **Code formatting**: Applied `dart format` to all source files

## 0.4.2

### Fixed
- **Proxy IP selection**: MediaProxy now picks the local interface on the same subnet as the target cast device, fixing casting failures on Android where the proxy would bind to a non-WiFi address unreachable by the cast device
- **Concurrent loadMedia guard**: All protocol sessions (Chromecast, AirPlay, DLNA) now ignore duplicate `loadMedia()` calls while one is already in progress, preventing multiple LOAD messages from being sent to the device
- **Socket disconnect detection**: Chromecast session now handles message stream errors and unexpected closures, transitioning to disconnected state so the app can react (previously the session stayed "connected" after a network drop)

## 0.4.1

### Fixed
- DLNA start position: seek now deferred until TV confirms PLAYING state (immediate seek was ignored by TVs still loading)
- Chromecast subtitles for local files: subtitle files now served via HTTP/1.1 with CORS headers (HTTP/1.0 path lacked `Access-Control-Allow-Origin` required by Shaka Player)
- `Http10FileServer`: returns 416 Range Not Satisfiable for invalid/out-of-bounds ranges
- `SubtitleConverter.vttToSrt()`: uses targeted regex for timestamp dots (no longer corrupts non-timestamp content), expands 2-component MM:SS timestamps to HH:MM:SS
- Removed stray `response.close()` after socket detach in synthetic content handler

### New
- Updated example app with optimistic slider state, keyboard shortcuts, mute toggle, and responsive layout
- Added protocol feature indicators in example device picker
- Updated README with "What Works Where" feature matrix, protocol notes, and DLNA local files guide

## 0.4.0

### Breaking
- DLNA file serving now uses HTTP/1.0 via raw sockets instead of Dart's HttpServer response. This fixes playback on TCL Google TV and other renderers that reject HTTP/1.1.
- Removed DLNA-specific HTTP headers (`transferMode.dlna.org`, `contentFeatures.dlna.org`, `Connection: close`) from file responses — these caused some DLNA renderers to reject content.
- Cleared Dart's default security headers (`x-frame-options`, `x-xss-protection`, `x-content-type-options`) from the proxy server.

### New
- `Http10FileServer` — reusable HTTP/1.0 file server class for DLNA compatibility
- `CastMediaType.mkv` — MKV container support for casting with embedded subtitles
- `SubtitleConverter.vttToSrt()` — WebVTT to SRT conversion
- `SubtitleConverter.toAss()` — VTT/SRT to ASS conversion with customizable styling (font, outline, shadow, margins)
- `MediaProxy.registerSubtitleVariants()` — registers both SRT and VTT subtitle variants for maximum TV compatibility
- DLNA subtitle variants: DIDL-Lite now includes both SRT and VTT subtitle URLs with proper format/type attributes
- DLNA seek instantly updates position without waiting for next polling cycle
- MKV content type detection and proxy URL extension support

### Fixed
- DLNA playback failing on TCL Google TV and similar renderers that reject HTTP/1.1 responses
- DLNA flags mismatch between DIDL-Lite protocolInfo (`21500000`) and HTTP headers (`01700000`) — now aligned to `01700000` matching VLC and MiniDLNA
- Missing `DLNA.ORG_PN` profile name in protocolInfo (`AVC_MP4_HP_HD_AAC` for MP4, `MPEG_TS_HD_NA_ISO` for TS)
- DLNA seeking not working — Range responses now correctly return 206 with Content-Range
- Subtitle file proxy URLs missing file extensions (`.vtt`, `.srt`) — some TVs need extensions to recognize subtitle files
- Synthetic content (subtitle playlists, converted subtitles) now served via HTTP/1.0 for DLNA compatibility

## 0.3.1

- Added protocol status table to README with testing coverage and known limitations
- Documented DLNA MP4 playback issues (TV-dependent, some reject proxy-served MP4)
- Documented DLNA subtitle limitations (`sec:CaptionInfoEx` not universally supported)
- Documented AirPlay video casting limitations (404 on some Google TV devices)
- Recommended Chromecast as the primary tested protocol for local file casting

## 0.3.0

### Breaking changes
- `DefaultMediaTransformer` no longer wraps local TS files in HLS — it
  serves them directly via the proxy. Use `TsHlsMediaTransformer` or
  `FfmpegMediaTransformer` for Chromecast-compatible local TS casting.
- `CastMedia.useChunkedHls` is deprecated and will be removed in a future
  release. `TsHlsMediaTransformer` always uses chunked HLS.
- `ChromecastSession` now defaults to `TsHlsMediaTransformer` instead of
  `DefaultMediaTransformer`.

### New
- `TsHlsMediaTransformer` — wraps local TS files in keyframe-aligned HLS
  playlists for Chromecast compatibility
- `MediaProxy.setPatPmt()` / `MediaProxy.setFirstPts()` — enable correct
  PAT/PMT prepending and PTS offset for virtual HLS segments
- `FfmpegMediaTransformer` reference implementation in example app — remuxes
  TS→MP4 via ffmpeg with progress callbacks and mobile platform support
- `doc/LOCAL_FILE_CASTING.md` — comprehensive guide covering remux, HLS
  wrapping, and transcode approaches with tradeoffs

### Migration guide

Replace direct `DefaultMediaTransformer` usage for local TS files:

```dart
// Before (0.2.x) — DefaultMediaTransformer handled local TS→HLS internally
final session = await device.connect();

// After (0.3.0) — choose your transformer explicitly
// Option A: FFmpeg remux (recommended)
final session = await device.connect(
  mediaTransformer: FfmpegMediaTransformer(),
);

// Option B: Built-in HLS wrapping (no external tools)
final session = await device.connect(
  mediaTransformer: TsHlsMediaTransformer(),
);
```

## 0.2.1

### Local file casting
- Local file support with `CastMedia.file()` constructor
- `MediaTransformer` interface for extensible media format preparation
- `TsKeyframeScanner` for keyframe-aligned HLS segment boundaries
- Virtual segment URLs for Chromecast compatibility (replaces EXT-X-BYTERANGE)
- `useChunkedHls` flag for chunked vs single-segment HLS
- Local subtitle support with automatic SRT-to-VTT conversion

### Chromecast fixes
- Fixed local file casting — HLS playlists and file routes were destroyed by cleanup before the device could fetch them
- CORS preflight (OPTIONS) handler for HLS segment requests
- RFC 8216-compliant TARGETDURATION calculation
- Consistent `application/x-mpegURL` content type across all HLS responses
- File extension on proxy URLs for HLS player format detection
- Volume updates via RECEIVER_STATUS instead of optimistic update

### DLNA improvements
- Duration metadata via DIDL-Lite `<res duration="HH:MM:SS">` attribute
- DLNA-specific HTTP headers (`transferMode.dlna.org`, `DLNA.ORG_OP=01` flags)
- Serve local TS files directly (not piped through HLS)

### Other
- Retry mDNS queries 3 times for slow-responding devices
- Comprehensive logging for all discovery providers and sessions
- Subtitle proxy for Chromecast (CORS + SRT conversion)
- Log viewer and custom media input in example app

## 0.2.0

- AirPlay feature flag detection via mDNS TXT records (`AirPlayFeatures` class parses `features`/`ft` bitmask)
- `AirPlayMediaController` with V1/V2 `/play` format auto-negotiation (V1 binary plist → V1 text/parameters → V2 with RTSP SETUP)
- `UnsupportedFeatureException` thrown immediately when a device lacks video support bits (0 and 49)
- `PlaybackException` thrown when all `/play` format attempts are rejected by the device
- Breaking: `HapSession` no longer has `play`, `stop`, `scrub`, or `rate` methods — use `AirPlayMediaController` instead
- Added `doc/PROTOCOL_REFERENCES.md` with links to AirPlay, Chromecast, and DLNA specs
- Added `doc/FUTURE_WORK.md` documenting AirPlay screen mirroring and RAOP audio streaming roadmap

## 0.1.0

- Initial release
- Chromecast (CASTV2) protocol support with default media receiver
- AirPlay 1 video casting support
- DLNA/UPnP protocol support with AVTransport and RenderingControl
- Built-in HTTP proxy server for custom header injection
- HLS m3u8 playlist URL rewriting through proxy
- Local file serving for downloaded content
- Subtitle support across all protocols (WebVTT, SRT)
- Cross-platform: Android, iOS, macOS, Windows, Linux
- Pluggable device discovery (default: multicast_dns, injectable: bonsoir)
- 366+ tests with mock servers for each protocol
- Flutter example app with device picker and remote control
