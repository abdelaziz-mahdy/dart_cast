# AirPlay 2 Video URL Casting — Hardware Verification and V2 Path Completion Plan

> **For agentic workers:** This plan has a hard gate at Chunk 0. Do not start Chunk 1 until Chunk 0 produces a recorded result. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Get AirPlay video URL casting working against a real AirPlay 2 receiver, or prove definitively that the receiver cannot do it — and in either case replace the current unverified claims in the README with a recorded hardware result.

**Architecture:** Replace the trial-and-error V1→V2 `/play` ladder in `AirPlayMediaController` with capability-driven selection off the feature bitmask. Make the V2 path actually reachable and complete: transient pairing (`X-Apple-HKP: 4`), a real UDP timing server advertised in SETUP, the mandatory `/rate?value=1.0` after `/play`, and binary-plist parsing of `/playback-info`.

**Tech Stack:** Dart 3.7, dart_cast package, `cryptography`, `protobuf`, `multicast_dns`

**Spec:** `doc/specs/2026-07-25-airplay-v2-video-hardware-verification-design.md`

**Context you must read first:** the spec above, and `pyatv/protocols/raop/protocols/airplayv2.py` from a local clone of https://github.com/postlund/pyatv. pyatv is the reference implementation for every wire detail in this plan.

---

## Why this plan exists

The repo has 666 passing tests and an AirPlay implementation that has never once succeeded against hardware. Every test runs against `mock_airplay_server.dart`, which accepts the V1 requests the code sends. Real receivers do not.

Decoding the `features` bitmasks captured in `test/integration/logs.txt` shows both non-Apple receivers on the developer's network — a Roku Express and the TCL "Living room TV" — have **bit 0 (`SupportsAirPlayVideoV1`) clear** and **bit 49 (`SupportsAirPlayVideoV2`) set**. The code sends a V1 `/play` first. The 404 in the README is the TV correctly rejecting a request it advertised no support for.

---

## File Structure

### New Files
- `tool/airplay_probe.dart` — standalone mDNS + capability probe, run by hand against a live network
- `tool/airplay_hardware_check.dart` — end-to-end connect→pair→setup→play→rate→poll script that prints every wire step
- `lib/src/protocols/airplay/auth/airplay_transient_auth.dart` — transient pairing (`X-Apple-HKP: 4`, PIN `3939`)
- `lib/src/protocols/airplay/timing_server.dart` — UDP timing server bound for the life of a playback
- `test/protocols/airplay/airplay_v2_play_sequence_test.dart` — asserts the full V2 command order

### Modified Files
- `lib/src/protocols/airplay/airplay_media_controller.dart:78-170` — capability selection replaces the 404/415 ladder; add post-play command sequence
- `lib/src/protocols/airplay/airplay_session.dart:70-90, 156-159, 274-280` — `/info` connect path; construct the media controller for all AirPlay 2 devices, not only on 403; stop discarding `media.startPosition`
- `lib/src/protocols/airplay/auth/hap_session.dart:479-499, 558-566, 681-698` — RTSP URI from local IP; real `timingPort`/`timingProtocol: NTP`; fail loudly on SETUP/RECORD errors; CSeq correlation
- `lib/src/protocols/airplay/airplay_features.dart:63` — `requiresHapPairing` must include bit 43
- `lib/src/protocols/airplay/plist_codec.dart:189-245` — content-type branching, `error` field on `PlaybackInfo`
- `test/protocols/airplay/mock_airplay_server.dart` — upgrade to AirPlay 2 semantics
- `test/protocols/airplay/airplay_features_test.dart` — real captured bitmasks
- `README.md`, `CHANGELOG.md`

---

## Chunk 0: Ground truth (do this before writing a single line of library code)

### Task 1: Establish what the receiver can actually do, using pyatv

**Files:** none — this task produces a recorded result, not code.

- [ ] **Step 1: Install pyatv on the machine that shares a LAN with the TV**

Run:
```sh
pipx install pyatv || pip install --user pyatv
atvremote --version
```
Expected: a version prints.

- [ ] **Step 2: Scan and capture the receiver's advertised capabilities**

Run:
```sh
atvremote scan
```
Expected: the TV appears with an AirPlay service. Record its identifier, address, and the full `features` value verbatim into the results file created in Step 6.

- [ ] **Step 3: Attempt a URL playback with full protocol tracing**

Run:
```sh
atvremote --id <TV_IDENTIFIER> --debug \
  play_url=http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4 \
  2>&1 | tee /tmp/pyatv-airplay-trace.log
```
Expected: either the video plays on the TV, or a specific protocol failure appears in the trace.

- [ ] **Step 4: If pairing is requested, complete it and retry**

Run:
```sh
atvremote --id <TV_IDENTIFIER> --protocol airplay pair
```
Expected: pairing succeeds (transient pairing needs no PIN) or fails with a recorded reason. Retry Step 3 with any credentials produced.

- [ ] **Step 5: Extract the wire sequence from the trace**

Run:
```sh
grep -E "(POST|GET|PUT|SETUP|RECORD|ANNOUNCE|/play|/rate|/info|/feedback|setProperty|timingPort|X-Apple-HKP)" /tmp/pyatv-airplay-trace.log
```
Expected: an ordered list of every request pyatv made. **This is the specification.** Everything in Chunks 1-3 exists to reproduce it.

- [ ] **Step 6: Record the verdict**

Create `doc/specs/2026-07-25-airplay-hardware-results.md` containing: the device model and firmware, the raw `features` value, the decoded bits, whether pyatv succeeded, and the extracted wire sequence (or the exact failure).

**GATE — read this before continuing:**
- **pyatv played the video** → the receiver is capable. Continue to Chunk 1. The trace from Step 5 is your acceptance target.
- **pyatv failed too** → the receiver does not implement video URL playback despite advertising bit 49. **Stop here.** Skip Chunks 1-3 and go directly to Chunk 4 Task 11, which corrects the README and routes this device class to Chromecast (already verified working against this exact TV in `test/integration/logs.txt`). Do not spend effort completing a V2 path the hardware will not honour.

- [ ] **Step 7: Commit the result**

```bash
git add doc/specs/2026-07-25-airplay-hardware-results.md
git commit -m "docs: record AirPlay hardware verification result from pyatv ground-truth run"
```

### Task 2: Add a repeatable probe tool

**Files:**
- Create: `tool/airplay_probe.dart` (use the standalone probe already written for this investigation — zero dependencies, `dart:io` only)

- [ ] **Step 1: Add the probe and run it on the TV's network**

Run: `dart run tool/airplay_probe.dart`
Expected: prints every `_airplay._tcp`, `_raop._tcp` and `_googlecast._tcp` instance on the LAN, each TXT record, the decoded feature bits per device, and TCP reachability on 7000/5000/8008/8009.

- [ ] **Step 2: Confirm the probe's decoded bits match pyatv's scan output from Task 1**

Expected: identical bit sets. A mismatch means the parser is wrong — fix it before proceeding, because every decision in Chunk 1 depends on it.

- [ ] **Step 3: Commit**

```bash
git add tool/airplay_probe.dart
git commit -m "feat(tool): add standalone AirPlay/Cast network probe with feature-bit decoding"
```

---

## Chunk 1: Make capability detection real and load-bearing

### Task 3: Test feature parsing against real captured bitmasks

**Files:**
- Modify: `test/protocols/airplay/airplay_features_test.dart`

- [ ] **Step 1: Write failing tests using the three bitmasks from `test/integration/logs.txt`**

Add cases asserting exactly this table:

| device | raw | bit 0 | bit 49 | bit 38 | bit 43 | bit 48 | bit 27 |
|---|---|---|---|---|---|---|---|
| macOS receiver | `0x38174fde4a7fcfd5` | true | true | true | true | true | true |
| Roku Express | `0x038bcf46007f8ad0` | false | true | true | true | true | false |
| TCL Google TV | `0x000bcf46007f8ad0` | false | true | true | true | true | false |

Also assert `isV2Protocol == true` for all three, and that the split form `0x...,0x...` treats the **second** word as the high 32 bits.

- [ ] **Step 2: Run and confirm which assertions fail**

Run: `dart test test/protocols/airplay/airplay_features_test.dart -r expanded`
Expected: the bit-0 assertions for Roku and TCL fail if the parser is wrong; if they pass, the parser is correct and this task is pure regression coverage. Record which.

- [ ] **Step 3: Delete the invented "Apple TV 4K" bitmask case**

The existing `0x5A7FFFF7,0x1E` matches no observed device and gives false confidence. Replace it with the real macOS receiver value.

- [ ] **Step 4: Fix `requiresHapPairing` to include bit 43**

`lib/src/protocols/airplay/airplay_features.dart:63` currently checks bits 46 and 48 only. pyatv also treats bit 43 `SupportsSystemPairing` as requiring credentials (`pyatv/protocols/airplay/auth/__init__.py:128-131`).

- [ ] **Step 5: Run the full suite**

Run: `dart test`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/src/protocols/airplay/airplay_features.dart test/protocols/airplay/airplay_features_test.dart
git commit -m "test: assert AirPlay feature parsing against real captured device bitmasks"
```

### Task 4: Replace the 404/415 ladder with capability-driven selection

**Files:**
- Modify: `lib/src/protocols/airplay/airplay_media_controller.dart:122-170`
- Modify: `test/protocols/airplay/airplay_media_controller_test.dart`

- [ ] **Step 1: Write failing tests for the new selection logic**

Cases: a bit-49-only device must go straight to `playV2` and must **never** send a V1 `/play`; a bit-0-only device must use `playV1` with a binary plist body (not `text/parameters`); a device with neither bit must throw `UnsupportedFeatureException` before any request is sent.

- [ ] **Step 2: Run and confirm failure**

Run: `dart test test/protocols/airplay/airplay_media_controller_test.dart -r expanded`
Expected: the bit-49-only case fails — current code sends V1 first.

- [ ] **Step 3: Implement**

Wire `AirPlayFeatures.isV2Protocol` (`airplay_features.dart:66`) into `play()`. It currently has zero call sites. Remove the 404/415 fallback entirely.

- [ ] **Step 4: Run tests, then the full suite**

Run: `dart test test/protocols/airplay/airplay_media_controller_test.dart -r expanded && dart test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/src/protocols/airplay/airplay_media_controller.dart test/protocols/airplay/airplay_media_controller_test.dart
git commit -m "fix: select AirPlay protocol version from feature bits instead of probing /play"
```

### Task 5: Make the V2 path reachable for every AirPlay 2 device

**Files:**
- Modify: `lib/src/protocols/airplay/airplay_session.dart:70-90, 156-159`

- [ ] **Step 1: Write a failing test**

A device that returns **200** from `/server-info` but advertises bit 48 must still end up with an `AirPlayMediaController` and an encrypted session. Today `_mediaController` is assigned only inside `_handleAuthRequired`, which runs only on 403.

- [ ] **Step 2: Run and confirm failure**

Run: `dart test test/protocols/airplay/airplay_session_test.dart -r expanded`
Expected: the new case fails — `_mediaController` is null and the bare client path is used.

- [ ] **Step 3: Implement**

Decide the transport from the feature bits at connect time, not from an HTTP status. Also change the connect probe to `GET /info` with `/server-info` as fallback, and treat a non-200 from either as an empty capability map rather than a fatal throw (`pyatv/support/rtsp.py:101-110`).

- [ ] **Step 4: Run the full suite**

Run: `dart test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/src/protocols/airplay/airplay_session.dart test/protocols/airplay/airplay_session_test.dart
git commit -m "fix: use /info and build the encrypted media controller for all AirPlay 2 devices"
```

---

## Chunk 2: Complete the V2 handshake

### Task 6: Implement transient pairing

**Files:**
- Create: `lib/src/protocols/airplay/auth/airplay_transient_auth.dart`
- Create: `test/protocols/airplay/auth/airplay_transient_auth_test.dart`

- [ ] **Step 1: Write failing tests**

Assert: header `X-Apple-HKP: 4`; M1 carries `Method: 0x00` **and** the `Flags` TLV (tag `0x13`) with `TransientPairing`; SRP password is `3939`; the flow completes at M4 with no M5/M6 and persists no credentials.

- [ ] **Step 2: Run and confirm failure**

Run: `dart test test/protocols/airplay/auth/airplay_transient_auth_test.dart -r expanded`
Expected: compilation error — the class does not exist.

- [ ] **Step 3: Implement against `pyatv/protocols/airplay/auth/hap_transient.py`**

Reuse the existing SRP and TLV8 code (`hap_srp.dart`, `tlv8.dart:44` already defines `tagFlags`). Select transient when bit 43 or bit 48 is set (`pyatv/protocols/airplay/auth/__init__.py:120-134`).

- [ ] **Step 4: Fix the leaked pair-verify subscription**

`releaseSocket()` (`airplay_auth.dart:603-606`) is documented as required before constructing a `HapSession` on the same socket, and is never called. Call it. Otherwise every encrypted byte also accumulates in `_socketBuffer` for the life of the session.

- [ ] **Step 5: Run tests, then the full suite**

Run: `dart test test/protocols/airplay/auth/ -r expanded && dart test`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/src/protocols/airplay/auth/ test/protocols/airplay/auth/
git commit -m "feat: implement AirPlay 2 transient pairing (X-Apple-HKP 4)"
```

### Task 7: Add the UDP timing server and fix SETUP

**Files:**
- Create: `lib/src/protocols/airplay/timing_server.dart`
- Modify: `lib/src/protocols/airplay/auth/hap_session.dart:479-499, 558-566`

- [ ] **Step 1: Write failing tests**

Assert the SETUP body contains a non-zero `timingPort` and `timingProtocol: "NTP"` (currently `'None'` with no port, `hap_session.dart:487`), that the socket is bound before SETUP and closed after playback, and that a non-200 SETUP or RECORD **throws** instead of logging a warning and marking the session set up (`:558-566`).

- [ ] **Step 2: Run and confirm failure**

Run: `dart test test/protocols/airplay/auth/hap_session_test.dart -r expanded`
Expected: fails — `timingProtocol` is `None` and errors are swallowed.

- [ ] **Step 3: Implement**

Bind `RawDatagramSocket` on `InternetAddress.anyIPv4:0`, answer timing packets as `pyatv/protocols/raop/protocols/__init__.py:102-140` does, and pass the port through SETUP as in `airplayv2.py:58-73`. Also fix the RTSP URI to use the **sender's** local IP (`hap_session.dart:479-480` vs `pyatv/support/rtsp.py:91-94`).

- [ ] **Step 4: Run the full suite**

Run: `dart test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/src/protocols/airplay/timing_server.dart lib/src/protocols/airplay/auth/hap_session.dart test/
git commit -m "feat: add UDP timing server and negotiate NTP timing in RTSP SETUP"
```

### Task 8: Correlate RTSP responses by CSeq

**Files:**
- Modify: `lib/src/protocols/airplay/auth/hap_session.dart:165, 681-698, 711-754, 782, 898-903`

- [ ] **Step 1: Write a failing test**

Issue a `/play` while the 2-second `/feedback` loop is running and assert `/play` receives its **own** response. Today `_readEncryptedResponse` returns the first frame it decrypts and `_dataArrived` is a single shared completer, so `/play` can receive the feedback 200.

- [ ] **Step 2: Run and confirm failure**

Run: `dart test test/protocols/airplay/auth/hap_session_test.dart -r expanded`
Expected: intermittent or consistent failure — the wrong response is matched.

- [ ] **Step 3: Implement**

Add a pending-request map keyed by CSeq, or serialise writes behind a mutex (`pyatv/support/rtsp.py:292-324`). Also stop `resetRtspSession` (`:898-903`) from zeroing `_cseq` while the feedback loop is live.

- [ ] **Step 4: Run the full suite**

Run: `dart test`
Expected: all pass, repeatedly. Run `dart test -j1` three times to shake out ordering flakes.

- [ ] **Step 5: Commit**

```bash
git add lib/src/protocols/airplay/auth/hap_session.dart test/protocols/airplay/auth/hap_session_test.dart
git commit -m "fix: correlate RTSP responses by CSeq to stop feedback racing playback commands"
```

---

## Chunk 3: Complete the playback sequence

### Task 9: Send the post-`/play` commands, including the mandatory `/rate`

**Files:**
- Modify: `lib/src/protocols/airplay/airplay_media_controller.dart:78-111`
- Modify: `test/protocols/airplay/mock_airplay_server.dart`
- Create: `test/protocols/airplay/airplay_v2_play_sequence_test.dart`

- [ ] **Step 1: Upgrade the mock to AirPlay 2 semantics**

The mock must require transient pairing, reject SETUP without a non-zero `timingPort`, return `/playback-info` as a **binary** plist, and report `rate: 0.0` until `/rate` is called. This last change is what makes the current bug fail a test.

- [ ] **Step 2: Write the failing sequence test**

Assert the exact order: `/play` → `PUT /setProperty?isInterestedInDateRange` → `PUT /setProperty?actionAtItemEnd` → `PUT /setProperty?forwardEndTime` → `PUT /setProperty?reverseEndTime` → `POST /rate?value=1.000000`, and that playback reaches `playing` rather than `paused`.

- [ ] **Step 3: Run and confirm failure**

Run: `dart test test/protocols/airplay/airplay_v2_play_sequence_test.dart -r expanded`
Expected: fails — no `/rate` is ever sent (`pyatv/protocols/raop/protocols/airplayv2.py:261`: *"will start paused otherwise"*).

- [ ] **Step 4: Implement**

`/rate` failure is fatal (`PlaybackException`); `/setProperty` failures are best-effort, log and continue.

- [ ] **Step 5: Run the full suite**

Run: `dart test`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/src/protocols/airplay/airplay_media_controller.dart test/protocols/airplay/
git commit -m "fix: send /rate and setProperty sequence after AirPlay 2 /play"
```

### Task 10: Parse binary-plist `/playback-info` and surface receiver errors

**Files:**
- Modify: `lib/src/protocols/airplay/plist_codec.dart:189-245`
- Modify: `lib/src/protocols/airplay/airplay_media_controller.dart:212`
- Modify: `lib/src/protocols/airplay/airplay_session.dart:274-280, 502-504`

- [ ] **Step 1: Write failing tests**

A binary-plist `/playback-info` body must parse (today `bodyText` runs `utf8.decode` on it, `hap_session.dart:89`, and `plist_codec.dart:12-26` is XML-only). An `error` dict in the response must raise `PlaybackError` with code and domain, as pyatv does at `player.py:98-103`.

- [ ] **Step 2: Run and confirm failure**

Run: `dart test test/protocols/airplay/plist_codec_test.dart -r expanded`
Expected: `FormatException` or an all-zero `PlaybackInfo`.

- [ ] **Step 3: Implement**

Branch on `Content-Type`, sniff the `bplist00` magic as a fallback, and reuse the existing `BinaryPlistDecoder` (`binary_plist.dart:14`) already used at `hap_session.dart:515`. Add an `error` field to `PlaybackInfo`. Stop swallowing poll failures at debug level (`airplay_session.dart:502-504`).

- [ ] **Step 4: Stop discarding `media.startPosition`**

`airplay_session.dart:276, 279` hardcode `0.0`. Also resolve the unit collision: `Start-Position` is a 0.0-1.0 fraction (V1), `Start-Position-Seconds` is absolute (V2). Convert explicitly at the call site and document it.

- [ ] **Step 5: Run the full suite**

Run: `dart test`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/src/protocols/airplay/ test/protocols/airplay/
git commit -m "fix: parse binary-plist playback-info, surface receiver errors, honour startPosition"
```

### Task 11: Verify against real hardware

**Files:**
- Create: `tool/airplay_hardware_check.dart`

- [ ] **Step 1: Write the end-to-end script**

Discover → connect → pair (transient) → SETUP with timing server → RECORD → `/play` → `/rate` → poll `/playback-info` for 30 seconds. Print each request and response with status.

- [ ] **Step 2: Run it against the TV**

Run: `dart run tool/airplay_hardware_check.dart <TV_IP>`
Expected: the video plays and `/playback-info` reports a non-zero `duration` and `rate: 1.0`.

- [ ] **Step 3: Diff against the pyatv trace from Task 1 Step 5**

Any request pyatv sends that this does not, or any header/body difference, is a remaining defect. Fix and re-run before continuing.

- [ ] **Step 4: Append the successful trace to the results doc**

Add it to `doc/specs/2026-07-25-airplay-hardware-results.md`. This is the artefact the repo has never had.

- [ ] **Step 5: Commit**

```bash
git add tool/airplay_hardware_check.dart doc/specs/2026-07-25-airplay-hardware-results.md
git commit -m "test: add AirPlay hardware verification script and record a successful trace"
```

---

## Chunk 4: Documentation and release

### Task 12: Correct the README's AirPlay claims

**Files:**
- Modify: `README.md:22-30, 34-46, 63-70, 336-355`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Replace unverified claims with the recorded result**

Specifically fix these, all of which are currently wrong or unsupported:
- `README.md:65` — "reliable only on Apple TV". No Apple TV has ever been tested; the only hardware in `logs.txt` is a Roku Express, a Google-TV-based TV, and a MacBook Pro.
- `README.md:70, 355` — "`/play` returns 404 on some Google TV devices ... Many Google TV / Android TV devices support only screen mirroring". Both observed devices advertise bit 49 (video V2). The 404 came from sending a **V1** request to a V1-incapable receiver.
- `README.md:336-341` — the modes table lists V1 as "Bit 0, Supported" and V2 as "Bit 49, Supported" with no mention that V2 requires pairing, RTSP setup, a timing server and `/rate`.
- `README.md:340-341` — links point at `docs/FUTURE_WORK.md`; the file is at `doc/FUTURE_WORK.md`. Same stale plural path in `CHANGELOG.md:172-173`.
- Resolve the contradiction with `doc/protocol-references/airplay-protocol.md:691-693`, which recommends targeting third-party receivers first.

- [ ] **Step 2: Add a hardware-tested matrix**

The design doc from 2026-03-14 promised a "manual testing matrix across TV brands" that was never produced. Add one, listing device, firmware, raw `features`, and the verified result per protocol.

- [ ] **Step 3: Add the CHANGELOG entry under `## Unreleased`**

Per `CONTRIBUTING.md:83-90`. Note the behaviour change: AirPlay no longer probes `/play` and will now throw `UnsupportedFeatureException` earlier on receivers that advertise no video bit.

- [ ] **Step 4: Run the exact CI checks from CLAUDE.md**

Run:
```sh
dart pub get --no-example
dart analyze lib/ test/
dart format --set-exit-if-changed lib/ test/
dart test
cd example && flutter pub get && flutter analyze
```
Expected: every command exits `0`. Note `dart analyze` exits 2 on **any** warning, and `flutter analyze` in `example/` fails on **info**-level diagnostics too.

- [ ] **Step 5: Commit and open the PR**

```bash
git add README.md CHANGELOG.md doc/
git commit -m "docs: replace unverified AirPlay claims with recorded hardware results"
git push origin <branch>
```

One feature per PR, per `CONTRIBUTING.md`. Release tags use the `v` prefix (`v0.7.0`) or the publish workflow will not fire.

---

## Notes for the implementing agent

- **`doc/`, singular.** A `docs/` directory breaks `pub publish` with exit 65. Two commits in this repo exist purely to enforce this.
- **The mock server is not evidence.** It has accepted every version of this code while none of them worked on hardware. Any change that only makes mock tests pass has not been verified. Task 9 Step 1 exists to make the mock adversarial rather than accommodating.
- **Do not restore the 404/415 fallback ladder** if something breaks. It is the mechanism that hid this bug for four months. Fix the capability check instead.
- **The Chromecast path already works against this exact TV** (`test/integration/logs.txt` has a complete successful local-file cast to it). If AirPlay proves impossible on this hardware class, that is a legitimate outcome to document, not a failure to work around.
