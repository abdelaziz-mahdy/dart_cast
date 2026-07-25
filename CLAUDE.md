# dart_cast — guidance for Claude

## Before opening a PR: run the exact CI checks locally

CI runs two workflows — `.github/workflows/ci.yml` for the package and
`.github/workflows/build_example.yml` for the Flutter example. Replay all
of these locally before pushing, and only open the PR if every one exits
`0`:

```sh
# Package (workflow: ci.yml)
dart pub get --no-example
dart analyze lib/ test/            # exit 2 on warnings; info is OK
dart format --set-exit-if-changed lib/ test/
dart test

# Example (workflow: build_example.yml)
cd example && flutter pub get && flutter analyze   # exit 1 on *info* too
cd example && flutter build apk --debug            # optional but mirrors CI
```

Things that have actually broken CI here:

- **Pre-existing `warning`-level lints in `lib/` or `test/`.** `dart analyze`
  exits `2` on *any* warning (e.g. `unnecessary_non_null_assertion`). Info-
  level diagnostics are fine; warnings are not. Fix them before pushing — do
  not rely on the merge-base being green.
- **Formatter style changes from SDK bumps.** Bumping `environment.sdk`
  past `3.7.0` switches the default formatter to the new "tall style",
  which rewrites most files. If you touch the SDK constraint, always run
  `dart format lib/ test/` in the same commit — otherwise the format step
  fails on a huge diff unrelated to your actual change.
- **`flutter analyze` is stricter than `dart analyze`.** The example's build
  job fails on *info*-level diagnostics too (exit `1`). Running `dart analyze`
  against `lib/ test/` is not enough — you must also `cd example && flutter
  analyze` before pushing. Common trap: pre-existing `unnecessary_underscores`
  infos that the package analyze step would ignore.

`flutter pub outdated` (run in repo root *and* `example/`) is the canonical
way to decide whether a bump is needed — prefer it over pub.dev scraping.

## Changelog entries are written for readers, not authors

`### Fixed` says what changes for someone *using* the package. `### Breaking`
and `### New` may carry exact API names, because a developer deciding whether to
upgrade needs them. Mechanism belongs in the commit message and, for protocol
work, in `doc/specs/`.

```
- DLNA: seeking works when casting HLS — it previously stopped playback outright
```

not

```
- DLNA: the route advertised DLNA.ORG_OP=01 while serving Accept-Ranges: none,
  so it now advertises time seek and honours TimeSeekRange.dlna.org
```

Nobody scanning a changelog to decide on an upgrade knows what `DLNA.ORG_OP`,
a ChaCha20 nonce or feature bit 43 is, and they should not have to.

## Do not overstate what was tested

This package is cast to physical TVs regularly, and that testing predates any
given session. Never write "first release verified on hardware", "has never
worked on a real device", or similar. If a recorded trace is missing, say the
*result was not recorded* — do not imply the testing never happened.

State only what was measured, name the device, and keep untested paths marked
untested. `README.md`'s protocol table and `doc/specs/*-hardware-results.md` are
the places where hardware claims live; keep them consistent with each other.

## A tool's own arithmetic is not verification

Hardware scripts under `tool/` must judge success on values the **device**
reports, never on a number the tool computed. Both of these shipped a false
PASS during the 0.7.0 work:

- a DLNA seek check added its own offset to the device position and printed
  `position=60s` while the TV sat on a "Loading…" screen
- a duration fix was reported as "the renderer now gets the real duration" when
  the renderer still answered `GetPositionInfo` with 1 second — only *our*
  session value had changed

Rules that follow from that:

- Assert on device-reported progress plus device-reported state (still
  `PLAYING`, position still advancing several seconds later).
- A mock server proves the code does what its author expected, nothing more.
  Make mocks adversarial — `test/protocols/airplay/mock_airplay2_server.dart`
  rejects `SETUP` without a timing port and holds `rate` at 0 until `/rate`.
- `adb exec-out screencap` cannot capture the video plane on a Google TV: a
  black frame is not evidence of a black screen. UI overlays *do* capture, so
  it is still useful for reading pairing codes and transport UI.
- When the user says something did not work, believe them over a green check
  and go find the independent measurement.

## Versioning

Pre-1.0 semver is in force: breaking changes (SDK floor bump, major
dependency bump that's observable through transitive deps) go in a minor
release (`0.X.0`), not a patch.

## Release tags

Release tags use the `v` prefix (`v0.5.0`, not `0.5.0`). The publish workflow
triggers on `v*`; a bare-number tag will not fire it.
