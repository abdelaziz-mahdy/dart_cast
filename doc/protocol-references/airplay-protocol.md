# AirPlay 1 Video Casting Protocol Reference

This document is a complete reference for implementing an AirPlay 1 video casting client in pure Dart. It covers discovery, HTTP control endpoints, subtitle embedding, authentication considerations, and implementation flow.

---

## 1. mDNS Discovery

AirPlay devices advertise themselves via multicast DNS (Bonjour/Zeroconf).

### Service Type

```
_airplay._tcp.local
```

### Default Port

```
7000
```

### TXT Record Fields

| Field      | Description                                           | Example Value                  |
|------------|-------------------------------------------------------|--------------------------------|
| `deviceid` | MAC address of the device                            | `AA:BB:CC:DD:EE:FF`           |
| `features` | Hex bitmask describing supported capabilities        | `0x5A7FFFF7,0x1E`             |
| `model`    | Hardware model identifier                            | `AppleTV3,2`                   |
| `srcvers`  | AirPlay source version                               | `220.68`                       |
| `flags`    | Status flags (e.g., 0x04 = audio, 0x44 = password)  | `0x44`                         |
| `pw`       | Whether a PIN/password is required (`0` or `1`)      | `0`                            |
| `vv`       | Protocol version variant                             | `2`                            |

### Features Bitmask

The `features` field is a hex bitmask. Modern devices use a two-part format separated by a comma representing the lower 32 bits and upper 32 bits:

```
features=0x5A7FFFF7,0x1E
         ^^^^^^^^^^  ^^^^
         lower 32    upper 32
```

Key feature bits (lower 32):

| Bit | Hex    | Capability              |
|-----|--------|-------------------------|
| 0   | 0x01   | Video supported         |
| 1   | 0x02   | Photo supported         |
| 2   | 0x04   | Video FairPlay          |
| 3   | 0x08   | Video volume control    |
| 4   | 0x10   | Video HTTP Live Streaming (HLS) |
| 5   | 0x20   | Slideshow               |
| 7   | 0x80   | Screen mirroring        |
| 9   | 0x200  | Audio                   |
| 11  | 0x800  | Audio redundant         |
| 12  | 0x1000 | FairPlay-SAP v2.5       |
| 14  | 0x4000 | Authentication (MFi/FairPlay) |
| 15  | 0x8000 | Metadata via plist      |

To check if a device supports video playback:

```dart
int lowerFeatures = int.parse(featuresLower.replaceFirst('0x', ''), radix: 16);
bool supportsVideo = (lowerFeatures & 0x01) != 0;
bool supportsHLS   = (lowerFeatures & 0x10) != 0;
```

### Discovery in Dart

Use the `multicast_dns` or `nsd` package to browse for `_airplay._tcp`:

```dart
// Pseudocode — browse for AirPlay services
final discovery = MDnsClient();
await discovery.start();

await for (final ptr in discovery.lookup<PtrResourceRecord>(
  ResourceRecordQuery.serverPointer('_airplay._tcp.local'),
)) {
  await for (final srv in discovery.lookup<SrvResourceRecord>(
    ResourceRecordQuery.service(ptr.domainName),
  )) {
    final host = srv.target;
    final port = srv.port; // typically 7000
    // Resolve A/AAAA record for IP address
    // Read TXT records for features, deviceid, etc.
  }
}
discovery.stop();
```

---

## 2. HTTP Endpoints

All requests are standard HTTP/1.1 sent to `http://<device-ip>:7000`.

### Common Headers

Include these headers on every request:

| Header                | Value                              | Notes                                |
|-----------------------|------------------------------------|--------------------------------------|
| `User-Agent`          | `MediaControl/1.0`                | Some devices reject unknown agents   |
| `X-Apple-Session-ID`  | A UUID v4 string                   | Must remain consistent for the entire playback session |
| `Content-Length`      | Length of request body              | Required when body is present        |

Generate the session ID once when starting playback and reuse it for all subsequent requests in that session:

```dart
import 'package:uuid/uuid.dart';
final sessionId = const Uuid().v4(); // e.g., "7C4E963B-4F6A-4C4E-A8D0-2C37B5C14612"
```

---

### POST /play — Start Video Playback

Initiates playback of a video URL on the AirPlay device.

**Request:**

```http
POST /play HTTP/1.1
Content-Type: text/parameters
User-Agent: MediaControl/1.0
X-Apple-Session-ID: 7C4E963B-4F6A-4C4E-A8D0-2C37B5C14612
Content-Length: 98

Content-Location: https://example.com/video.m3u8
Start-Position: 0.0
```

**Body format (text/parameters):**

```
Content-Location: <video-url>
Start-Position: <fraction>
```

- `Content-Location` — The URL to a video file or HLS manifest (.m3u8). The device fetches this URL directly, so it must be reachable from the device's network.
- `Start-Position` — A float from `0.0` (beginning) to `1.0` (end) representing the fractional start position within the media duration. Use `0.0` for the start.

**Alternative body format (binary plist):**

```
Content-Type: application/x-apple-binary-plist
```

The body is a binary property list with the same keys: `Content-Location` (string) and `Start-Position` (real). Text/parameters is simpler for implementation.

**Response:**

```http
HTTP/1.1 200 OK
```

An empty 200 response indicates the device accepted the playback request. The device will begin buffering and playing the content.

**Dart example:**

```dart
Future<void> startPlayback(String deviceIp, int port, String videoUrl, String sessionId) async {
  final uri = Uri.parse('http://$deviceIp:$port/play');
  final body = 'Content-Location: $videoUrl\nStart-Position: 0.0\n';

  final response = await http.post(
    uri,
    headers: {
      'Content-Type': 'text/parameters',
      'User-Agent': 'MediaControl/1.0',
      'X-Apple-Session-ID': sessionId,
    },
    body: body,
  );

  if (response.statusCode != 200) {
    throw Exception('Failed to start playback: ${response.statusCode}');
  }
}
```

---

### GET /scrub — Get Current Position

Returns the current playback position and total duration.

**Request:**

```http
GET /scrub HTTP/1.1
User-Agent: MediaControl/1.0
X-Apple-Session-ID: 7C4E963B-4F6A-4C4E-A8D0-2C37B5C14612
```

**Response:**

```http
HTTP/1.1 200 OK
Content-Type: text/parameters

duration: 5400.000000
position: 123.456789
```

- `duration` — Total duration in seconds (float).
- `position` — Current playback position in seconds (float).

**Dart parsing:**

```dart
Future<({double duration, double position})> getPlaybackPosition(
  String deviceIp, int port, String sessionId,
) async {
  final uri = Uri.parse('http://$deviceIp:$port/scrub');
  final response = await http.get(uri, headers: {
    'User-Agent': 'MediaControl/1.0',
    'X-Apple-Session-ID': sessionId,
  });

  final lines = response.body.trim().split('\n');
  double duration = 0;
  double position = 0;
  for (final line in lines) {
    final parts = line.split(':');
    if (parts.length == 2) {
      final key = parts[0].trim();
      final value = double.tryParse(parts[1].trim()) ?? 0;
      if (key == 'duration') duration = value;
      if (key == 'position') position = value;
    }
  }
  return (duration: duration, position: position);
}
```

---

### POST /scrub?position=<seconds> — Seek

Seeks to an absolute position in seconds.

**Request:**

```http
POST /scrub?position=300.5 HTTP/1.1
User-Agent: MediaControl/1.0
X-Apple-Session-ID: 7C4E963B-4F6A-4C4E-A8D0-2C37B5C14612
Content-Length: 0
```

- `position` — Absolute position in seconds (float), NOT fractional. For example, to seek to 5 minutes, use `position=300.0`.

**Response:**

```http
HTTP/1.1 200 OK
```

**Dart example:**

```dart
Future<void> seek(String deviceIp, int port, String sessionId, double positionSeconds) async {
  final uri = Uri.parse('http://$deviceIp:$port/scrub?position=${positionSeconds.toStringAsFixed(6)}');
  await http.post(uri, headers: {
    'User-Agent': 'MediaControl/1.0',
    'X-Apple-Session-ID': sessionId,
    'Content-Length': '0',
  });
}
```

---

### POST /rate?value=<float> — Play / Pause

Controls the playback rate (play or pause).

**Request (pause):**

```http
POST /rate?value=0.000000 HTTP/1.1
User-Agent: MediaControl/1.0
X-Apple-Session-ID: 7C4E963B-4F6A-4C4E-A8D0-2C37B5C14612
Content-Length: 0
```

**Request (play / resume):**

```http
POST /rate?value=1.000000 HTTP/1.1
User-Agent: MediaControl/1.0
X-Apple-Session-ID: 7C4E963B-4F6A-4C4E-A8D0-2C37B5C14612
Content-Length: 0
```

| Value | Effect              |
|-------|---------------------|
| `0`   | Pause               |
| `1`   | Normal speed play   |
| `2`   | 2x fast forward (not universally supported) |

**Response:**

```http
HTTP/1.1 200 OK
```

**Dart example:**

```dart
Future<void> setRate(String deviceIp, int port, String sessionId, double rate) async {
  final uri = Uri.parse('http://$deviceIp:$port/rate?value=${rate.toStringAsFixed(6)}');
  await http.post(uri, headers: {
    'User-Agent': 'MediaControl/1.0',
    'X-Apple-Session-ID': sessionId,
    'Content-Length': '0',
  });
}

Future<void> pause(String deviceIp, int port, String sessionId) =>
    setRate(deviceIp, port, sessionId, 0.0);

Future<void> play(String deviceIp, int port, String sessionId) =>
    setRate(deviceIp, port, sessionId, 1.0);
```

---

### POST /stop — Stop Playback

Stops the current playback session entirely.

**Request:**

```http
POST /stop HTTP/1.1
User-Agent: MediaControl/1.0
X-Apple-Session-ID: 7C4E963B-4F6A-4C4E-A8D0-2C37B5C14612
Content-Length: 0
```

**Response:**

```http
HTTP/1.1 200 OK
```

After stopping, discard the `X-Apple-Session-ID`. Generate a new UUID for the next playback session.

**Dart example:**

```dart
Future<void> stopPlayback(String deviceIp, int port, String sessionId) async {
  final uri = Uri.parse('http://$deviceIp:$port/stop');
  await http.post(uri, headers: {
    'User-Agent': 'MediaControl/1.0',
    'X-Apple-Session-ID': sessionId,
    'Content-Length': '0',
  });
}
```

---

### GET /playback-info — Get Detailed Playback State

Returns a comprehensive XML plist describing the full playback state.

**Request:**

```http
GET /playback-info HTTP/1.1
User-Agent: MediaControl/1.0
X-Apple-Session-ID: 7C4E963B-4F6A-4C4E-A8D0-2C37B5C14612
```

**Response:**

```http
HTTP/1.1 200 OK
Content-Type: text/x-apple-plist+xml

<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>duration</key>
    <real>5400.000000</real>
    <key>position</key>
    <real>123.456789</real>
    <key>rate</key>
    <real>1.000000</real>
    <key>readyToPlay</key>
    <true/>
    <key>playbackBufferEmpty</key>
    <false/>
    <key>playbackBufferFull</key>
    <false/>
    <key>playbackLikelyToKeepUp</key>
    <true/>
    <key>loadedTimeRanges</key>
    <array>
        <dict>
            <key>duration</key>
            <real>120.000000</real>
            <key>start</key>
            <real>0.000000</real>
        </dict>
    </array>
    <key>seekableTimeRanges</key>
    <array>
        <dict>
            <key>duration</key>
            <real>5400.000000</real>
            <key>start</key>
            <real>0.000000</real>
        </dict>
    </array>
</dict>
</plist>
```

**Key fields:**

| Field                      | Type    | Description                                       |
|----------------------------|---------|---------------------------------------------------|
| `duration`                 | real    | Total duration in seconds                         |
| `position`                 | real    | Current position in seconds                       |
| `rate`                     | real    | 0.0 = paused, 1.0 = playing                      |
| `readyToPlay`              | boolean | Whether the device has buffered enough to play    |
| `playbackBufferEmpty`      | boolean | True if buffer has run dry (stalling)             |
| `playbackBufferFull`       | boolean | True if buffer is completely full                 |
| `playbackLikelyToKeepUp`  | boolean | True if buffering is sufficient for smooth play   |
| `loadedTimeRanges`         | array   | Buffered time ranges (start + duration)           |
| `seekableTimeRanges`       | array   | Seekable time ranges (start + duration)           |

**Interpreting playback state:**

```dart
// rate == 0.0 → paused
// rate == 1.0 → playing
// readyToPlay == false → still loading / buffering
// playbackBufferEmpty == true → stalled, rebuffering
// duration and position not present or 0 → no media loaded
```

**Dart parsing (using xml package):**

```dart
import 'package:xml/xml.dart';

Future<Map<String, dynamic>> getPlaybackInfo(
  String deviceIp, int port, String sessionId,
) async {
  final uri = Uri.parse('http://$deviceIp:$port/playback-info');
  final response = await http.get(uri, headers: {
    'User-Agent': 'MediaControl/1.0',
    'X-Apple-Session-ID': sessionId,
  });

  if (response.statusCode != 200) return {};

  final doc = XmlDocument.parse(response.body);
  final dict = doc.findAllElements('dict').first;
  final children = dict.children.whereType<XmlElement>().toList();

  final result = <String, dynamic>{};
  for (int i = 0; i < children.length - 1; i += 2) {
    final key = children[i].innerText;
    final valueElement = children[i + 1];
    switch (valueElement.name.local) {
      case 'real':
        result[key] = double.tryParse(valueElement.innerText) ?? 0.0;
        break;
      case 'true':
        result[key] = true;
        break;
      case 'false':
        result[key] = false;
        break;
      case 'integer':
        result[key] = int.tryParse(valueElement.innerText) ?? 0;
        break;
      // Handle 'array' and nested 'dict' as needed
    }
  }
  return result;
}
```

---

### GET /server-info — Device Capabilities

Retrieves device information. Does NOT require a session ID.

**Request:**

```http
GET /server-info HTTP/1.1
User-Agent: MediaControl/1.0
```

**Response:**

```http
HTTP/1.1 200 OK
Content-Type: text/x-apple-plist+xml

<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>deviceid</key>
    <string>AA:BB:CC:DD:EE:FF</string>
    <key>features</key>
    <integer>1518338039</integer>
    <key>model</key>
    <string>AppleTV3,2</string>
    <key>protovers</key>
    <string>1.0</string>
    <key>srcvers</key>
    <string>220.68</string>
</dict>
</plist>
```

Use this to verify device capabilities before attempting playback.

---

## 3. Request/Response Format Summary

| Endpoint                      | Method | Request Body             | Content-Type (Request)    | Response Body               | Content-Type (Response)        |
|-------------------------------|--------|--------------------------|---------------------------|-----------------------------|--------------------------------|
| `/play`                       | POST   | URL + start position     | `text/parameters`         | Empty                       | —                              |
| `/scrub`                      | GET    | None                     | —                         | duration + position text    | `text/parameters`              |
| `/scrub?position=<sec>`       | POST   | Empty                    | —                         | Empty                       | —                              |
| `/rate?value=<float>`         | POST   | Empty                    | —                         | Empty                       | —                              |
| `/stop`                       | POST   | Empty                    | —                         | Empty                       | —                              |
| `/playback-info`              | GET    | None                     | —                         | XML plist                   | `text/x-apple-plist+xml`      |
| `/server-info`                | GET    | None                     | —                         | XML plist                   | `text/x-apple-plist+xml`      |

---

## 4. Subtitle Support

### Limitation

AirPlay 1 has **no native subtitle endpoint**. There is no `/subtitles` or equivalent API to push subtitle data to the receiver. The receiver simply plays the media stream as-is.

### Recommended Approach: Embed Subtitles in HLS

The most reliable method is to include subtitles as a track in the HLS manifest before sending it to the device. This requires serving a modified HLS playlist from your application (e.g., via a local HTTP server on the casting device).

#### Step 1: Create a Master Playlist with Subtitle Track

```m3u8
#EXTM3U
#EXT-X-VERSION:3

#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,LANGUAGE="en",URI="subtitles_en.m3u8"

#EXT-X-STREAM-INF:BANDWIDTH=2000000,SUBTITLES="subs"
video_playlist.m3u8
```

Key attributes of `#EXT-X-MEDIA`:
- `TYPE=SUBTITLES` — Declares this as a subtitle track.
- `GROUP-ID="subs"` — An identifier referenced by the stream.
- `NAME="English"` — Display name for the subtitle track.
- `DEFAULT=YES` — Subtitle track is enabled by default.
- `AUTOSELECT=YES` — Automatically selected if language matches.
- `LANGUAGE="en"` — ISO 639-1 language code.
- `URI="subtitles_en.m3u8"` — Pointer to the subtitle segment playlist.

The `#EXT-X-STREAM-INF` line must include `SUBTITLES="subs"` to associate the video stream with the subtitle group.

#### Step 2: Create a Subtitle Segment Playlist

```m3u8
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:5400
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-PLAYLIST-TYPE:VOD

#EXTINF:5400.000,
subtitles_en.vtt

#EXT-X-ENDLIST
```

For long media, you can split subtitles into multiple segments aligned with the video segments. For simplicity, a single VTT file covering the entire duration works for VOD content.

#### Step 3: Create a WebVTT File with Timestamp Mapping

```vtt
WEBVTT
X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000

00:01:15.000 --> 00:01:18.500
This is the first subtitle line.

00:02:30.000 --> 00:02:34.000
This is the second subtitle line.

00:05:00.000 --> 00:05:03.500
Another subtitle entry here.
```

The `X-TIMESTAMP-MAP` header is critical. It maps the MPEG-TS presentation timestamps to local VTT timestamps so the receiver can synchronize subtitles with the video:

- `MPEGTS:0` — The MPEG-TS timestamp corresponding to the start of the VTT timeline.
- `LOCAL:00:00:00.000` — The local VTT time that maps to the MPEG-TS value above.

Without this header, subtitle timing may be offset on some receivers.

#### Implementation Strategy in Dart

1. Start a local HTTP server (e.g., using `shelf` or raw `HttpServer`).
2. Serve the modified master playlist, subtitle playlist, and VTT file.
3. Proxy the original video playlist and segments (or redirect to them).
4. Send the local master playlist URL to the AirPlay device via `POST /play`.

```dart
// Pseudocode for local proxy approach
final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
server.listen((request) {
  switch (request.uri.path) {
    case '/master.m3u8':
      // Serve modified master playlist with subtitle track
      break;
    case '/subtitles_en.m3u8':
      // Serve subtitle segment playlist
      break;
    case '/subtitles_en.vtt':
      // Serve WebVTT file
      break;
    default:
      // Proxy or redirect to original video server
      break;
  }
});

// Then start AirPlay playback with the local URL
await startPlayback(deviceIp, 7000, 'http://<local-ip>:8080/master.m3u8', sessionId);
```

---

## 5. AirPlay Version Compatibility

### AirPlay 1 vs AirPlay 2

| Aspect                  | AirPlay 1                        | AirPlay 2                            |
|-------------------------|----------------------------------|--------------------------------------|
| Protocol                | HTTP + reverse HTTP events       | HTTP + TLS + FairPlay-SAP encryption |
| Authentication          | None (or simple PIN)             | FairPlay-SAP mandatory (Apple TV)    |
| Video                   | URL-based (device fetches URL)   | Same, but encrypted channel          |
| Audio                   | RAOP (RTP/RTSP)                  | Buffered audio + multi-room          |
| Discovery               | mDNS `_airplay._tcp`            | mDNS `_airplay._tcp` (same)         |
| Port                    | 7000                             | 7000                                 |
| Introduced              | 2010 (iOS 4.2)                   | 2018 (iOS 11.4)                      |

### FairPlay-SAP Authentication (Apple TV)

Modern Apple TVs running tvOS 10.2 and later **require FairPlay-SAP authentication** before accepting AirPlay connections. This is a multi-step cryptographic handshake:

1. **POST /pair-setup** — SRP-6a (Secure Remote Password) exchange using a PIN displayed on the Apple TV screen.
2. **POST /pair-verify** — Ed25519 signature verification + Curve25519 key agreement to establish a shared secret.
3. **Encrypted channel** — All subsequent communication is wrapped in ChaCha20-Poly1305 AEAD encryption using the derived shared secret.

The cryptographic primitives involved:
- **SRP-6a** — Password-authenticated key exchange (the PIN is the password).
- **Ed25519** — Digital signatures for device identity.
- **Curve25519** — Elliptic curve Diffie-Hellman for session key derivation.
- **ChaCha20-Poly1305** — Authenticated encryption for the data channel.
- **HKDF-SHA-512** — Key derivation from the shared secret.

This is complex to implement and Apple does not publish official documentation for it. Reverse-engineered implementations exist in `pyatv` and `openairplay`.

### Third-Party Receivers

Third-party AirPlay receivers (Samsung TVs, LG TVs, Roku, VIZIO, etc.) generally **do not require FairPlay-SAP authentication**. They accept unauthenticated AirPlay 1 connections using the plain HTTP endpoints documented in this reference.

> **Correction (2026-07-25).** The recommendation that used to follow this
> paragraph — "target third-party receivers first, the plain HTTP protocol works
> with these devices" — is contradicted by every third-party receiver we have
> actually measured. A real discovery run (`test/integration/logs.txt`) found a
> Roku Express advertising `0x038bcf46007f8ad0` and a TCL Google TV advertising
> `0x000bcf46007f8ad0`. Both have **bit 0 (`SupportsAirPlayVideoV1`) clear** and
> **bit 49 (`SupportsAirPlayVideoV2`) set**, and both advertise bits 43 and 48,
> which means they expect *transient* pairing and an encrypted channel.
>
> In other words: the plain HTTP AirPlay 1 path in sections 1–4 is the one path
> these devices do **not** implement. Sending them a V1 `POST /play` gets a 404,
> correctly. Modern third-party receivers are AirPlay 2 receivers; only the
> macOS receiver on that same network still advertises bit 0.
>
> Decide from the bitmask, never from a trial request. See
> `doc/specs/2026-07-25-airplay-v2-video-hardware-verification-design.md`.

### Determining Authentication Requirements

After mDNS discovery, check the device's features bitmask:

```dart
// If bit 14 (0x4000) is set, device may require authentication
bool requiresAuth = (lowerFeatures & 0x4000) != 0;

// Also check the 'pw' TXT record
bool requiresPassword = txtRecords['pw'] == '1';
```

Additionally, send `GET /server-info` and inspect the response. If the device returns a `401 Unauthorized` on any endpoint, authentication is required.

---

## 6. Implementation Flow

The complete flow for an AirPlay 1 video casting client:

```
1. Discover devices
   └─ Browse mDNS for _airplay._tcp.local
   └─ Collect IP, port, TXT records for each device

2. Select a device and verify capabilities
   └─ Parse features bitmask from TXT record
   └─ Confirm bit 0 (video) is set
   └─ Optionally GET /server-info for full capability check

3. Generate a session UUID
   └─ uuid.v4() → use this for all requests in this session

4. Start playback
   └─ POST /play with video URL and Start-Position: 0.0
   └─ Include X-Apple-Session-ID header

5. Poll playback state (every 1-2 seconds)
   └─ GET /playback-info → parse XML plist
   └─ Extract: duration, position, rate, readyToPlay
   └─ Update UI with progress, buffer state, play/pause state
   └─ Alternative: GET /scrub for lightweight position polling

6. Handle user controls
   └─ Play:  POST /rate?value=1.000000
   └─ Pause: POST /rate?value=0.000000
   └─ Seek:  POST /scrub?position=<seconds>

7. Stop playback
   └─ POST /stop
   └─ Discard the session UUID
   └─ Generate a new UUID for the next session
```

### Polling Strategy

The AirPlay 1 protocol does not support server-push events for playback state changes. You must poll. Recommended intervals:

- **Active playback:** Poll `GET /playback-info` every **1 second** for responsive UI updates.
- **Paused:** Reduce polling to every **3-5 seconds** to conserve resources.
- **Buffering (readyToPlay=false):** Poll every **500ms** to detect when playback becomes ready.

### Error Handling

| HTTP Status | Meaning                                     | Action                          |
|-------------|---------------------------------------------|---------------------------------|
| 200         | Success                                     | Continue                        |
| 401         | Unauthorized (FairPlay-SAP required)        | Authentication needed           |
| 403         | Forbidden                                   | Device rejected the request     |
| 404         | Not found (device not playing)              | Session may have expired        |
| 500         | Internal server error                       | Retry once, then abort          |
| Connection refused | Device unreachable                   | Device went offline or changed IP |

When a request fails with a connection error, the device may have gone to sleep or left the network. Re-run mDNS discovery to find it again.

### Session Lifecycle

```
[No Session]
     │
     ▼
  POST /play  ──→  [Active Session]  ──→  POST /stop  ──→  [No Session]
                         │
                    poll /playback-info
                    POST /rate (play/pause)
                    POST /scrub (seek)
```

A session begins with `POST /play` and ends with `POST /stop`. If the device stops playback on its own (e.g., media ended), `GET /playback-info` will return with no duration/position or an error. Detect this and clean up the session.

---

## 7. Open-Source References

These projects provide working implementations and additional protocol details:

| Project | Language | URL | Notes |
|---------|----------|-----|-------|
| Unofficial AirPlay Protocol Spec | — | https://nto.github.io/AirPlay.html | Canonical reverse-engineered specification; covers AirPlay 1 HTTP, RAOP audio, and mirroring |
| openairplay/openairplay | Python | https://github.com/openairplay/openairplay | AirPlay 1 sender/receiver implementation |
| postlund/pyatv | Python | https://github.com/postlund/pyatv | Full Apple TV control library; supports AirPlay 1 and 2, including FairPlay-SAP pairing |
| node_airplay | Node.js | https://github.com/nicohman/node_airplay | Lightweight AirPlay 1 client for video casting |
| AirPlayKit | Swift | https://github.com/niceto/AirPlayKit | Native Swift AirPlay sender |
| RPiPlay | C | https://github.com/FD-/RPiPlay | AirPlay 1 mirroring receiver for Raspberry Pi; useful for understanding the receiver side |

### Key Sections in nto.github.io/AirPlay.html

- **HTTP Video Service** — Matches the endpoints in this document.
- **Server Info** — Full list of plist keys returned by `/server-info`.
- **Events** — Reverse HTTP event channel (not needed for basic video casting but useful for receiving device-initiated notifications).
