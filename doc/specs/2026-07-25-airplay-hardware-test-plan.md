# AirPlay 2 Hardware Test Plan

**Date:** 2026-07-25
**Status:** Not yet executed — no receiver was available when the code landed
**Applies to:** the AirPlay 2 work in `fix/airplay-v2-capability-driven-play`
**Results go in:** `doc/specs/2026-07-25-airplay-hardware-results.md` (create it during the run)

---

## Why this document exists

The package has 757 passing tests and an AirPlay implementation that has never
once succeeded against a physical receiver. Every one of those tests runs
against a mock. A mock proves the code does what its author expected; it cannot
prove the receiver agrees.

The mock in `test/protocols/airplay/mock_airplay2_server.dart` was written to be
adversarial on purpose — it rejects `SETUP` without a timing port, answers
`/playback-info` as a binary plist, and refuses to leave `rate: 0.0` until
`/rate` arrives. That closes the gap considerably. It does not close it. Three
things remain unverifiable offline:

1. **Transient pairing against a real SRP accessory.** The tests exercise the
   client's SRP arithmetic and assert the exact wire shape (`X-Apple-HKP: 4`,
   `Method 0x00`, `SeqNo 0x01`, `Flags 0x10`, M1–M4 only), but no test verifies
   the *proof* a receiver computes. A padding or byte-order mismatch would pass
   every test here and fail on hardware.
2. **HAP channel encryption keyed from the transient shared secret.** Derived
   from the SRP session key `K`; if `K` differs from the receiver's by one byte,
   the first encrypted frame fails MAC verification.
3. **Whether these receivers implement video URL playback at all.** Both
   advertise bit 49. Advertising it and honouring it are different claims.

Everything below is designed to separate those three from each other, so a
failure points at one cause rather than "AirPlay doesn't work".

---

## Hardware and prerequisites

| Item | Detail |
|---|---|
| TV | TCL / Google TV, "Living room TV", last seen at `192.168.7.200:7000` |
| Second receiver | Roku Express, last seen at `192.168.5.234:7000` |
| Control receiver | macOS AirPlay receiver on the MacBook Pro (`192.168.6.68:7000`) — the only device on the network with bit 0 set |
| Sender | This Mac, on the **same subnet and VLAN** as the TV |
| Reference sender | `pyatv` — `pipx install pyatv` |

Before starting:

- [ ] TV powered on, on the home screen, nothing else casting to it
- [ ] "AirPlay & HomeKit" enabled in the TV's settings
- [ ] AirPlay access control set to **Anyone on the same network** (not
      "Everyone" with a code, and not "Only people sharing this home") — a code
      requirement forces the PIN flow, which is a different code path
- [ ] Mac and TV on the same subnet: `ping 192.168.7.200` succeeds
- [ ] No VPN active on the Mac (it breaks mDNS and makes the sender's local IP
      wrong, which matters — the RTSP URI is built from it)

---

## Gate 0 — ground truth with pyatv (do this first, always)

This is the highest-value step in the whole plan and it takes minutes. It
partitions the problem before any dart_cast code is blamed.

- [ ] **0.1 — Install and confirm**

```bash
pipx install pyatv && atvremote --version
```

- [ ] **0.2 — Scan and record the advertised capabilities**

```bash
atvremote scan
```

Record the TV's identifier, address, and the **full `features` value verbatim**.
Expect `0x...,0x...` matching the `0x000bcf46007f8ad0` captured in
`test/integration/logs.txt`. If it differs, the device's firmware has changed
and every bit-level assumption below needs re-checking.

- [ ] **0.3 — Attempt playback with a full protocol trace**

```bash
atvremote --id <TV_IDENTIFIER> --debug play_url=http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4 2>&1 | tee /tmp/pyatv-airplay-trace.log
```

- [ ] **0.4 — If pairing is requested, complete it and retry 0.3**

```bash
atvremote --id <TV_IDENTIFIER> --protocol airplay pair
```

Transient pairing needs no PIN. If pyatv asks for one, the TV's access control
is not set to "same network" — go back and fix that, because it changes which
code path we are testing.

- [ ] **0.5 — Extract the wire sequence**

```bash
grep -E "(POST|GET|PUT|SETUP|RECORD|ANNOUNCE|/play|/rate|/info|/feedback|setProperty|timingPort|X-Apple-HKP)" /tmp/pyatv-airplay-trace.log
```

**This ordered list is the specification.** Everything dart_cast sends is meant
to reproduce it.

### The gate

| pyatv result | What it means | What to do |
|---|---|---|
| **Video plays** | The receiver is capable. The trace is the acceptance target. | Continue to Phase 1. |
| **pyatv fails too** | The receiver does not implement video URL playback despite advertising bit 49. | **Stop.** Record the finding, and route this device class to Chromecast — `test/integration/logs.txt` already contains a complete successful Chromecast cast to this exact TV. Do not spend effort chasing a path the hardware will not honour. This is a legitimate outcome, not a failure. |

Either way, write the verdict into
`doc/specs/2026-07-25-airplay-hardware-results.md` and commit it before doing
anything else.

---

## Phase 1 — Capability probe (no playback, no pairing)

Purpose: confirm dart_cast reads the same bits pyatv does. If this is wrong,
everything downstream is wrong for the same reason.

- [ ] **1.1 — Run the probe**

```bash
dart run tool/airplay_probe.dart
```

- [ ] **1.2 — Check the output for the TV**

Expected, based on `0x000bcf46007f8ad0`:

| Field | Expected |
|---|---|
| protocol | `AirPlay 2` (bit 38 = 1, bit 48 = 1) |
| video URL playback | `yes, via AirPlay 2 (bit 49)` |
| pairing | `transient (X-Apple-HKP 4, no PIN)` |
| bit 0 `SupportsAirPlayVideoV1` | **absent** from the "bits set" list |
| TCP open | `7000` at minimum |

- [ ] **1.3 — Diff against pyatv's scan from 0.2**

The decoded bit sets must be identical. A mismatch means the parser is wrong —
fix `AirPlayFeatures` before going further, because every decision the package
makes hangs off it.

**Pass criterion:** dart_cast and pyatv agree on every bit, and the verdict line
says video V2 is supported.

---

## Phase 2 — Pairing only (the first thing that can genuinely fail)

Purpose: isolate transient pairing from playback. This is the step with the
highest chance of an offline-invisible bug, so give it its own run.

- [ ] **2.1 — Run the end-to-end check and stop reading at step 3**

```bash
dart run tool/airplay_hardware_check.dart 192.168.7.200
```

- [ ] **2.2 — Read the `3. Connect` section of the output**

| What you see | Diagnosis | Next step |
|---|---|---|
| `pairing successful, creating HAP session` | Transient pairing works. | Continue to Phase 3. |
| `transient pairing M2 is missing salt or public key` | The receiver refused transient pairing outright. | Capture the raw M2. The device may want the PIN flow after all — check its access-control setting first. |
| `transient pairing M4 error: code 2` | `kTLVError_Authentication` — our SRP proof was rejected. | **This is the padding/byte-order risk.** Compare our M3 `PublicKey` and `Proof` against pyatv's for the same salt. The likely culprits are `_bigIntToBytesUnpadded` in `hap_srp.dart` and the `H(N) XOR H(g)` term. |
| `transient pairing M4 error: code 3` | `kTLVError_Backoff` — too many attempts. | Wait, or reboot the TV. Not a code bug. |
| Timeout with no response | The receiver never answered `/pair-setup`. | Confirm port 7000 is open (Phase 1) and no other sender holds the device. |
| `MAC verification failed` *after* pairing reports success | Pairing succeeded but the derived keys differ. | The SRP shared key `K` is right at the TLV level and wrong at the HKDF level. Check that `deriveHapSessionKeys` is fed `K = H(S)` and not `S`. |

**Pass criterion:** the log reaches `HAP encrypted session established` and the
session state becomes `connected`.

---

## Phase 3 — Full playback sequence

- [ ] **3.1 — Run the check with a known-good remote URL**

```bash
dart run tool/airplay_hardware_check.dart 192.168.7.200
```

- [ ] **3.2 — Watch the TV screen, not just the log.** The failure this whole
      change set exists to fix — a missing `/rate` — looks like *success* in the
      log and a black or frozen first frame on the screen.

- [ ] **3.3 — Confirm each step in the output**

| Step | Expected in the log |
|---|---|
| SETUP | `RTSP SETUP (uri=rtsp://<this Mac's IP>/<n>, timingPort=<non-zero>)` then `response: 200` |
| Timing | `AirPlay timing server: answered request 1 from 192.168.7.200:...` — if this line never appears, the receiver is not using the clock we advertised |
| RECORD | `RTSP RECORD response: 200` |
| `/play` | `POST /play` with `response: 200` |
| `/rate` | `POST /rate?value=1.000000` with 200 |
| Polling | `position=` climbing every second, `duration=` non-zero |
| Verdict | `PASS — the receiver is playing the URL.` |

- [ ] **3.4 — If the verdict is `PARTIAL`**

The item loaded but the position is not advancing. That is precisely the
`/rate` signature. Check whether `/rate` was answered 200 and whether it was
sent over RTSP; some receivers only accept it over one transport.

- [ ] **3.5 — Diff against the pyatv trace from 0.5**

Any request pyatv sends that dart_cast does not — or any header or body field
that differs — is a remaining defect. Fix and re-run before moving on. Known
intentional differences to ignore:

- pyatv sends `clientBundleID: dev.pyatv.GPU`; we send `dev.dartcast`.
- pyatv includes timing-telemetry fields in the `/play` body (`secureConnectionMs`,
  `infoMs`, `connectMs`, `authMs`, `bonjourMs`, `postAuthMs`,
  `referenceRestrictions`). They are cosmetic. **If playback fails and nothing
  else explains it, add them** — that is a cheap experiment.

**Pass criterion:** video is visibly playing on the TV, and the tool prints
`PASS`.

---

## Phase 4 — Playback control

Only meaningful once Phase 3 passes.

- [ ] **4.1 — Local file cast** via the example app (`example/`), picking a local
      MP4. Confirms the proxy is reachable from the TV — a different failure mode
      from anything above, since the TV must connect *back* to this Mac.
- [ ] **4.2 — Pause / resume.** The screen must actually freeze and resume, not
      just the log.
- [ ] **4.3 — Seek** to the middle of the file; confirm the picture jumps.
- [ ] **4.4 — Resume from position:** cast with `CastMedia(startPosition: Duration(seconds: 90))`
      and confirm playback begins ~90s in. This path was dropped entirely before
      this change and has never run against hardware.
- [ ] **4.5 — Stop**, then cast again on the same session. Catches state that
      `resetRtspSession` fails to clear.
- [ ] **4.6 — Long run:** leave it playing for 5+ minutes. The `/feedback` loop
      runs every 2 seconds against the same socket as the polling loop; if the
      request serialization is wrong this is where MAC-verification failures
      surface.

---

## Phase 5 — Second receiver and negative cases

- [ ] **5.1 — Repeat Phases 1–3 against the Roku Express** (`192.168.5.234`). Same
      bit profile, different vendor stack. A pass on one and a failure on the
      other is far more informative than either alone.
- [ ] **5.2 — Repeat against the macOS receiver** (`192.168.6.68`). It is the only
      device on the network with bit 0 set, so it is the only way to exercise the
      AirPlay 1 branch on real hardware.
- [ ] **5.3 — Negative case:** point the tool at an audio-only AirPlay receiver if
      one is available. Expect `UnsupportedFeatureException` **before any request
      is sent**, with a message suggesting Chromecast or DLNA.

---

## Recording the result

Create `doc/specs/2026-07-25-airplay-hardware-results.md` containing:

1. Device model and firmware version, for each receiver tested
2. The raw `features` string and the decoded bits
3. Whether pyatv succeeded (Gate 0), with its extracted wire sequence
4. The full `airplay_hardware_check.dart` trace
5. A per-phase pass/fail table
6. For any failure: the exact request that differs from pyatv's

Then update the hardware matrix in `README.md`, replacing the "not yet verified
against hardware" note with what was actually observed. That matrix is the
artefact this repository has never had, and the reason the previous README
claim ("reliable only on Apple TV") was wrong: no Apple TV has ever been tested.

---

## What a failure at each phase means for the code

| Phase that fails | Most likely cause | Where to look |
|---|---|---|
| 1 | Feature parsing | `lib/src/protocols/airplay/airplay_features.dart` |
| 2 | SRP arithmetic or key derivation | `hap_srp.dart`, `airplay_transient_auth.dart`, `deriveHapSessionKeys` |
| 3 SETUP | Timing server or body fields | `timing_server.dart`, `hap_session.dart` SETUP body |
| 3 `/play` | Plist body or headers | `airplay_media_controller.dart` `playV2` |
| 3 stuck at paused | `/rate` transport or format | `sendPostPlaySequence` |
| 3 polling | Binary plist decoding | `plist_codec.dart`, `binary_plist.dart` |
| 4.6 only | Request serialization / nonce desync | `HapSession._serialized`, feedback loop |
| Every phase, one device only | Vendor quirk | Record it in the matrix; do not add a fallback ladder — that is what hid this bug for four months |
