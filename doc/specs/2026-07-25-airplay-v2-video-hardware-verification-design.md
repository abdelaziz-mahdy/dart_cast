# AirPlay 2 Video URL Casting — Hardware Verification and V2 Path Completion

**Date:** 2026-07-25
**Status:** Proposed
**Scope:** Sub-project 2 of AirPlay casting improvements (follows `doc/specs/2026-03-16-airplay-feature-detection-and-play-design.md`)

## Problem

AirPlay video URL casting has never succeeded against physical hardware. The README records the symptom as `/play` returning 404 on Google TV devices and concludes AirPlay is "reliable only on Apple TV". That conclusion is not supported by the evidence, and it sent the investigation in the wrong direction.

The real situation: every AirPlay receiver on the developer's network is an **AirPlay 2–only** receiver, and the codebase's `/play` path is an **AirPlay 1** path that is only ever reached by accident. The V2 path exists but is unreachable in practice and incomplete where it is reachable.

## Evidence

`test/integration/logs.txt` (lines ~9861-9930) captured three real receivers. Decoding their advertised `features` bitmasks against the reference table in `pyatv/protocols/airplay/utils.py` gives:

| Device | raw `features` | bit 0 `VideoV1` | bit 49 `VideoV2` | bit 38 | bit 43 | bit 48 | bit 27 `LegacyPairing` |
|---|---|---|---|---|---|---|---|
| MacBook Pro (macOS receiver) | `0x38174fde4a7fcfd5` | **true** | true | true | true | true | true |
| Roku Express | `0x038bcf46007f8ad0` | **false** | true | true | true | true | false |
| "Living room TV" (TCL / Google TV) | `0x000bcf46007f8ad0` | **false** | true | true | true | true | false |

Three conclusions follow directly:

1. **The TV does not advertise AirPlay 1 video at all.** Bit 0 is clear. A V1 `/play` is being sent to a receiver that never claimed to implement it, which is exactly why it answers 404. The 404 is correct behaviour by the TV, not a defect in it.
2. **The TV does advertise AirPlay 2 video** (bit 49) and is unambiguously an AirPlay 2 receiver (bits 38 and 48 both set). So video URL casting is very likely achievable — over the V2 path.
3. **The TV wants transient pairing.** pyatv selects transient credentials when bit 43 or bit 48 is set (`pyatv/protocols/airplay/auth/__init__.py:120-134`). Both are set. Transient pairing needs no PIN and no user interaction.

The previous diagnosis ("device only supports mirroring") is contradicted by bit 49 being set on both the TV and the Roku.

## Root cause chain

Six defects compound. Each is sufficient on its own to produce a silent failure; together they guarantee one.

### RC-1 — Protocol version is chosen by trial-and-error, not by capability

`lib/src/protocols/airplay/airplay_media_controller.dart:132-164` tries `playV1` (binary plist), then `playV1Text`, and only reaches `playV2` if the previous attempt returned exactly 404 or 415. `AirPlayFeatures.isV2Protocol` (`airplay_features.dart:66`) implements pyatv's rule correctly — bit 38 or bit 48 — but **has zero call sites in `lib/`**. The one feature actually consulted in the play path is `supportsVideo` at `airplay_media_controller.dart:123`.

pyatv decides up front from the bitmask (`utils.py:241-256`) and never probes.

### RC-2 — The V2 path is unreachable on this hardware anyway

`AirPlaySession._mediaController` is assigned **only** inside `_handleAuthRequired` (`airplay_session.dart:156-159`), which runs only when `/server-info` returns 403 (`:73-76`). An AirPlay 2 receiver using transient encryption does not 403 on `/server-info`. So `loadMedia` falls through to `_client!.play()` (`airplay_client.dart:50-58`) — a bare `POST /play` with a `text/parameters` body on port 7000, with no pair-verify, no SETUP, no RECORD, no feedback, no timing server.

### RC-3 — Transient pairing is not implemented

`airplay_auth.dart:154, 416, 622` hardcode `X-Apple-HKP: 3` (PIN-based HAP). Transient pairing needs `X-Apple-HKP: 4`, the `Flags: TransientPairing` TLV, and the fixed PIN `3939` (`pyatv/protocols/airplay/auth/hap_transient.py:23-80`). `Tlv8.tagFlags = 0x13` is defined at `tlv8.dart:44` but never written. On a bit-48 device the only implemented route in is a PIN the TV will never display.

### RC-4 — No UDP timing server; SETUP declares `timingProtocol: "None"`

`hap_session.dart:484-499` sends `'timingProtocol': 'None'` with no `timingPort`. There is no `RawDatagramSocket` anywhere in the AirPlay code. pyatv creates a real timing server per playback (`pyatv/protocols/airplay/player.py:24-33`) and sends `"timingPort": <port>` with `"timingProtocol": "NTP"` (`raop/protocols/airplayv2.py:58-73`).

### RC-5 — `/rate?value=1.0` is never sent after `/play`

Nothing in `playV2` (`airplay_media_controller.dart:78-111`) or `AirPlaySession._loadMediaInternal` (`:274-280`) issues `/rate` after a successful `/play`. pyatv does, at `airplayv2.py:261`, with the comment: *"Most important command is '/rate' as that sets playback rate to 100% (will start paused otherwise)."*

**On AirPlay 2, `/play` alone starts the item paused.** Even a fully correct handshake yields a black screen without this.

### RC-6 — `/playback-info` is parsed as XML only, so state polling always fails on V2

`airplay_media_controller.dart:212` feeds `resp.bodyText` (a `utf8.decode`, `hap_session.dart:89`) into `PlistCodec.parsePlaybackInfo`, and `plist_codec.dart:12-26` is a regex-based XML plist parser. AirPlay 2 returns `/playback-info` as a **binary** plist. `BinaryPlistDecoder` already exists (`binary_plist.dart:14`) and is already used for the SETUP response (`hap_session.dart:515`) — it simply is not used here. pyatv uses `decode_bplist_from_body` (`player.py:92`).

The failure is swallowed at debug level in `_pollPlaybackInfo` (`airplay_session.dart:502-504`), so position and duration sit at zero and the session never leaves `loading`. pyatv also raises on an `error` dict in the response (`player.py:98-103`); `PlaybackInfo` (`plist_codec.dart:213-245`) has no `error` field.

### Secondary defects (fix while in the area)

- **`/server-info` instead of `/info`.** `airplay_client.dart:97-104` throws on any non-200 and `connect()` only recognises 403 (`airplay_session.dart:70-90`). `/server-info` is the AirPlay 1 endpoint; pyatv uses `GET /info` and tolerates non-200 (`pyatv/support/rtsp.py:101-110`). Receivers implementing only `/info` fail at connect before playback is ever attempted.
- **RTSP URI uses the receiver's host, not the sender's IP.** `hap_session.dart:479-480` builds `rtsp://$host/$sessionId` from the device address; pyatv uses `local_ip` (`support/rtsp.py:91-94`). Worse, when SETUP/RECORD is rejected, `setupRtspSession` logs a warning and marks the session set up anyway (`hap_session.dart:558-566`).
- **Feedback loop races with foreground requests.** `hap_session.dart:681-698` fires `/feedback` every 2s on the same socket through the same single reader, with no CSeq correlation and one shared `_dataArrived` completer (`:165`, `:739`, `:782`). `/play` can receive the feedback 200; concurrent writers desync the ChaCha20 nonce counters and every subsequent frame fails MAC verification. pyatv correlates responses per CSeq (`support/rtsp.py:292-324`).
- **`requiresHapPairing` omits bit 43** (`airplay_features.dart:63`).
- **`media.startPosition` is discarded** — hardcoded `0.0` at `airplay_session.dart:276, 279`. Separately, `Start-Position` is documented as a 0.0–1.0 fraction (`airplay_client.dart:49`) while `Start-Position-Seconds` is absolute — one parameter, two units.
- **`setVolume` is a local no-op** (`airplay_session.dart:381-384`), despite AirPlay 2 supporting volume in dBFS (`pyatv/protocols/airplay/utils.py:281-291`).

## Design

### Gate 0: establish ground truth before writing any code

Do not implement anything until pyatv has been pointed at the TV. pyatv is a known-good AirPlay 2 sender. Its result partitions the problem cleanly:

- **pyatv plays the URL** → the receiver is capable, the wire trace is the spec, and every defect above is worth fixing. Capture the trace with `--debug` and treat it as the acceptance target.
- **pyatv also fails** → the TV's third-party AirPlay stack does not implement video URL playback despite advertising bit 49. Stop. Record the finding, correct the README, and route that device class to Chromecast, which already works on this exact TV per `logs.txt`.

This gate is the single highest-value step in the project and costs minutes. Everything downstream is conditional on it.

### 1. Capability-driven protocol selection

Replace the 404/415 ladder in `AirPlayMediaController.play` with an up-front decision:

```
features = AirPlayFeatures(txt['features'] ?? txt['ft'])

if features.isV2Protocol:            # bit 38 || bit 48
    if !features.supportsVideoV2:    # bit 49
        throw UnsupportedFeatureException
    return playV2(...)
else:
    if !features.supportsVideoV1:    # bit 0
        throw UnsupportedFeatureException
    return playV1(...)               # binary plist, not text/parameters
```

Keep no fallback ladder. A V1 `/play` to a bit-0-clear receiver is a request the device told us not to make.

### 2. Transient pairing

Add a transient path alongside the existing PIN path, selected when bit 43 or bit 48 is set:

- header `X-Apple-HKP: 4`
- M1 carries `Flags: TransientPairing` (TLV tag `0x13`, value `0x00000010`) alongside `Method: 0x00`
- SRP password is the fixed string `3939`
- M3/M4 complete as in the existing SRP flow; no M5/M6 exchange, no persisted credentials

Reference: `pyatv/protocols/airplay/auth/hap_transient.py`.

### 3. Timing server

Bind a `RawDatagramSocket` on `InternetAddress.anyIPv4:0` for the duration of playback. Send its port as `timingPort` with `timingProtocol: "NTP"` in the SETUP body. Answer NTP-shaped timing packets as pyatv's `TimingServer` does (`raop/protocols/__init__.py:102-140`). Close it when playback ends.

### 4. Post-`/play` command sequence

After a successful V2 `/play`, in order:

```
PUT  /setProperty?isInterestedInDateRange   {value: true}
PUT  /setProperty?actionAtItemEnd           {value: 0}
PUT  /setProperty?forwardEndTime            {value: ...}
PUT  /setProperty?reverseEndTime            {value: ...}
POST /rate?value=1.000000
```

`/rate` is mandatory. The `/setProperty` calls are best-effort — log and continue on error.

### 5. Content negotiation on `/playback-info`

Branch on the response `Content-Type`: `application/x-apple-binary-plist` → `BinaryPlistDecoder`; `text/x-apple-plist+xml` → existing XML parser. Sniff the `bplist00` magic when the header is absent. Add an `error` field to `PlaybackInfo` and surface a `PlaybackError` when the receiver reports one, rather than swallowing at debug level.

### 6. Connect path

Try `GET /info` first, fall back to `GET /server-info`, and treat a non-200 from either as an empty capability map rather than a fatal error. Reserve hard failure for a connection that cannot be established at all.

### 7. Request/response correlation

Give `HapSession` a request queue keyed by CSeq, or a mutex around write-then-read. The current shared-completer design is a correctness bug that will surface as intermittent MAC-verification failures under any real traffic.

## Error handling

| Condition | Behaviour |
|---|---|
| bit 38/48 clear and bit 0 clear | `UnsupportedFeatureException` — suggest Chromecast/DLNA |
| bit 38/48 set and bit 49 clear | `UnsupportedFeatureException` — mirroring-only receiver |
| transient pair-verify fails | `AuthenticationException`, do not fall through to unencrypted |
| SETUP or RECORD non-200 | `PlaybackException` — **do not** mark the session set up (fixes `hap_session.dart:558-566`) |
| `/play` 200 but `/rate` fails | `PlaybackException` — the item is paused and will never start |
| `/playback-info` contains `error` | `PlaybackError` with code and domain |

## Test strategy

Mock-server tests cannot validate this work. Every defect above is invisible to `mock_airplay_server.dart`, which is precisely why 666 passing tests coexist with a protocol that has never once worked. Required:

- Extend `test/protocols/airplay/airplay_features_test.dart` with the **three real bitmasks** from `logs.txt` — `0x38174fde4a7fcfd5`, `0x038bcf46007f8ad0`, `0x000bcf46007f8ad0` — asserting the exact bit-0/bit-49/bit-38/bit-48 values in the table above. The existing "Apple TV 4K" case uses an invented value (`0x5A7FFFF7,0x1E`) that matches no observed device.
- Upgrade the mock server to AirPlay 2 semantics: require transient pairing, demand SETUP with a non-zero `timingPort`, return `/playback-info` as a binary plist, and **report `rate: 0.0` until `/rate` is called**. That last one turns RC-5 into a failing test.
- Add a hardware verification script (not a unit test) that runs the full connect → pair → setup → play → rate → poll sequence against a real device and prints each wire step.

## Protocol references

- `pyatv/protocols/raop/protocols/airplayv2.py` — the authoritative V2 `play_url` sequence
- `pyatv/protocols/airplay/auth/hap_transient.py` — transient pairing
- `pyatv/protocols/airplay/player.py` — timing server lifecycle and playback polling
- `pyatv/support/rtsp.py` — RTSP framing, `/info`, CSeq correlation
- `pyatv/protocols/airplay/utils.py` — feature bitmask table and version selection
- https://openairplay.github.io/airplay-spec/features.html
- `doc/protocol-references/airplay-protocol.md` (in-repo). Note line 691-693 recommends targeting third-party receivers first, which contradicts the current README claim that AirPlay is "reliable only on Apple TV". Resolve this explicitly once Gate 0 returns a result.
