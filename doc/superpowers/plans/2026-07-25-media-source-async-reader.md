# MediaSource Async Reader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a `MediaSource` reader open asynchronously, so sources backed by
Android `content://`, network handles or decrypt handshakes stop needing a
`Stream.fromFuture(...).asyncExpand(...)` workaround.

**Architecture:** Widen the `MediaSourceReader` typedef from
`Stream<List<int>>` to `FutureOr<Stream<List<int>>>` and `await` it at its one
call site. Non-breaking by construction — a `Stream` already satisfies
`FutureOr<Stream>` — so no existing implementation changes.

**Tech Stack:** Dart 3.7, `dart:async`, `package:test`

**Spec:** `doc/superpowers/specs/2026-07-25-media-source-async-reader-design.md`

## Global Constraints

- Docs live in `doc/`, never `docs/` — a `docs/` directory breaks
  `pub publish` with exit 65.
- CI gates that must all exit `0` before pushing:
  `dart analyze lib/ test/` (exits 2 on any warning), `dart format
  --set-exit-if-changed lib/ test/`, `dart test`, and
  `cd example && flutter analyze` (exits 1 on *info* too).
- Never rewrite git history: no `commit --amend`, no `push --force`.
- Release tags use the `v` prefix (`v0.7.3`); a bare-number tag will not fire
  the publish workflow.
- Pre-1.0 semver: this is a patch (`0.7.3`) because no caller can break.
- The source, not the proxy, is responsible for returning exactly
  `[start, end)`. Do not add truncation to the proxy.

---

### Task 1: Widen the reader typedef and await it

**Files:**
- Modify: `lib/src/core/media_source.dart` (the `MediaSourceReader` typedef and
  the `read` doc comment)
- Modify: `lib/src/core/http10_file_server.dart:129`
- Test: `test/core/media_source_test.dart`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `typedef MediaSourceReader = FutureOr<Stream<List<int>>>
  Function(int start, int end);` — exported from `package:dart_cast/dart_cast.dart`
  via the existing `export 'src/core/media_source.dart';`.

- [ ] **Step 1: Write the failing tests**

Add to `test/core/media_source_test.dart`, inside the existing
`group('serving a registered source', ...)`:

```dart
    test('accepts a reader that opens asynchronously', () async {
      // saf_stream, network handles and decrypt handshakes all have to open
      // something before they can read. Requiring a synchronous Stream forced
      // those callers through Stream.fromFuture(...).asyncExpand(...).
      final url = proxy.registerSource(
        MediaSource(
          length: payload.length,
          contentType: 'video/mp4',
          read: (start, end) async {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            return Stream.value(payload.sublist(start, end));
          },
        ),
      );

      final response = await fetch(url, range: 'bytes=100-199');
      final body = await response.fold<List<int>>(
        <int>[],
        (a, b) => a..addAll(b),
      );

      expect(response.statusCode, equals(206));
      expect(body, equals(payload.sublist(100, 200)));
    });

    test('accepts an async* reader', () async {
      // The natural shape once the reader may be asynchronous: open, then
      // yield while honouring the requested range.
      final url = proxy.registerSource(
        MediaSource(
          length: payload.length,
          contentType: 'video/mp4',
          read: (start, end) async* {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            var offset = start;
            while (offset < end) {
              final chunkEnd = (offset + 64) < end ? offset + 64 : end;
              yield payload.sublist(offset, chunkEnd);
              offset = chunkEnd;
            }
          },
        ),
      );

      final response = await fetch(url);
      final body = await response.fold<List<int>>(
        <int>[],
        (a, b) => a..addAll(b),
      );

      expect(response.statusCode, equals(200));
      expect(body, equals(payload));
    });

    test('a synchronous reader still works', () async {
      // The non-breaking guarantee, asserted rather than assumed.
      final url = proxy.registerSource(
        MediaSource(
          length: payload.length,
          contentType: 'video/mp4',
          read: (start, end) => Stream.value(payload.sublist(start, end)),
        ),
      );

      final response = await fetch(url, range: 'bytes=0-9');
      final body = await response.fold<List<int>>(
        <int>[],
        (a, b) => a..addAll(b),
      );

      expect(response.statusCode, equals(206));
      expect(body, equals(payload.sublist(0, 10)));
    });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `dart test test/core/media_source_test.dart -r expanded`

Expected: the two async cases fail to compile — the analyzer reports the
`async`/`async*` closures return `Future<Stream<List<int>>>` /
`Stream<List<int>>` where `Stream<List<int>>` is required. The synchronous case
passes already.

- [ ] **Step 3: Widen the typedef**

In `lib/src/core/media_source.dart`, replace the typedef and extend its doc
comment:

```dart
/// Reads a byte range from a [MediaSource].
///
/// [start] is inclusive and [end] is **exclusive**, matching
/// [File.openRead]. A source is asked for ranges whenever the cast device
/// seeks, so this must be able to start from an arbitrary offset — returning
/// the whole payload and ignoring the arguments will break seeking.
///
/// May return the stream directly, or a `Future` of one for sources that have
/// to open something first — an Android `content://` URI, a network handle, a
/// decrypt handshake. An `async` or `async*` function satisfies this.
///
/// **The stream must contain exactly `end - start` bytes.** The proxy has
/// already sent that as `Content-Length` and does not truncate. A source that
/// streams to end-of-file regardless of [end] — which is the default behaviour
/// of most "open a stream at this offset" APIs — will corrupt the response and
/// break seeking.
typedef MediaSourceReader =
    FutureOr<Stream<List<int>>> Function(int start, int end);
```

Add the `dart:async` import at the top of the file if it is not already there:

```dart
import 'dart:async';
import 'dart:io';
```

- [ ] **Step 4: Await at the call site**

In `lib/src/core/http10_file_server.dart`, replace line 129:

```dart
    // Stream the requested range. `end` is inclusive here, and
    // MediaSourceReader takes an exclusive end, matching File.openRead.
    await source.read(start, end + 1).pipe(socket);
```

with:

```dart
    // Stream the requested range. `end` is inclusive here, and
    // MediaSourceReader takes an exclusive end, matching File.openRead.
    // The reader may open asynchronously, so resolve it before piping.
    final stream = await source.read(start, end + 1);
    await stream.pipe(socket);
```

`serveSource` is already `async`, so nothing else changes.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `dart test test/core/media_source_test.dart -r expanded`
Expected: PASS — all cases, including the pre-existing range, suffix, 416, HEAD
and lazy-read tests.

- [ ] **Step 6: Run the full CI gates**

Run each, all must exit `0`:

```sh
dart analyze lib/ test/ tool/
dart format --set-exit-if-changed lib/ test/
dart test
cd example && flutter analyze
```

Expected: analyze and format clean; every test passes. `tool/` must analyze
cleanly too — `tool/chromecast_hardware_check.dart` builds a `MediaSource` and
proves the widening did not break an existing caller.

- [ ] **Step 7: Commit**

```bash
git add lib/src/core/media_source.dart lib/src/core/http10_file_server.dart test/core/media_source_test.dart
git commit -m "feat: allow MediaSource readers to open asynchronously

saf_stream's read APIs are both asynchronous, so a source backed by an
Android content:// URI could not satisfy the synchronous reader signature
without a Stream.fromFuture(...).asyncExpand(...) dance this package imposed
on it. The same applies to any source that must open a handle first.

MediaSourceReader now returns FutureOr<Stream<List<int>>>, so an async or
async* function satisfies it directly. Non-breaking: a Stream already
satisfies FutureOr<Stream>, so every existing implementation compiles
unchanged, which the retained synchronous-reader test asserts.

Truncation stays the source's responsibility. The proxy has already sent
Content-Length and does not police the stream, so the doc comment now states
the exact-length requirement plainly — an asynchronously opened source is
precisely the kind that streams to EOF by default."
```

---

### Task 2: Release 0.7.3

**Files:**
- Modify: `pubspec.yaml` (the `version:` line)
- Modify: `CHANGELOG.md` (new section above `## 0.7.2`)

**Interfaces:**
- Consumes: the widened typedef from Task 1.
- Produces: tag `v0.7.3`, which fires `.github/workflows/publish.yml`.

- [ ] **Step 1: Add the changelog entry**

Insert above the `## 0.7.2` heading in `CHANGELOG.md`:

```markdown
## 0.7.3

### New
- `MediaSource` readers may now open asynchronously — an `async` or `async*` function satisfies the reader, so sources backed by Android `content://` URIs, network handles or a decrypt handshake no longer need a `Stream.fromFuture(...)` workaround ([#12](https://github.com/abdelaziz-mahdy/dart_cast/issues/12)). Existing synchronous readers are unaffected

```

- [ ] **Step 2: Bump the version**

In `pubspec.yaml`, change `version: 0.7.2` to `version: 0.7.3`.

- [ ] **Step 3: Re-run the CI gates**

```sh
dart analyze lib/ test/ tool/
dart format --set-exit-if-changed lib/ test/
dart test
```

Expected: all exit `0`.

- [ ] **Step 4: Commit and push**

```bash
git add CHANGELOG.md pubspec.yaml
git commit -m "chore: release 0.7.3

Patch: MediaSource readers may open asynchronously. Additive only — a
synchronous reader still satisfies the widened typedef."
git push
```

- [ ] **Step 5: Wait for CI on main to pass**

Run: `gh run list --branch main --limit 2`
Expected: both `CI` and `Build Example` show `success`.

Do not tag before this. A Windows-only failure has already reached `main` once
in this repo when a local run was treated as sufficient.

- [ ] **Step 6: Tag and push**

```bash
git tag -a v0.7.3 -m "Release 0.7.3

MediaSource readers may open asynchronously, so sources backed by Android
content:// URIs, network handles or a decrypt handshake no longer need a
Stream.fromFuture workaround. Non-breaking: synchronous readers are
unaffected."
git push origin v0.7.3
```

- [ ] **Step 7: Confirm the package actually published**

Run:

```sh
curl -s https://pub.dev/api/packages/dart_cast | python3 -c "import sys,json;print(json.load(sys.stdin)['latest']['version'])"
```

Expected: `0.7.3`.

A green publish workflow is not the same as a published package — check the
registry itself.

- [ ] **Step 8: Reply on issue #12**

```bash
gh issue comment 12 --body "Shipped in 0.7.3 — \`MediaSourceReader\` now returns \`FutureOr<Stream<List<int>>>\`, so an \`async\`/\`async*\` function satisfies it and the \`Stream.fromFuture(...)\` dance is gone.

One thing to watch when adapting \`readFileStream\`: it streams to end-of-file, but the reader must return exactly \`end - start\` bytes, because the proxy has already sent that as \`Content-Length\` and does not truncate. Over-delivering breaks seeking. An \`async*\` reader handles it:

\`\`\`dart
read: (start, end) async* {
  var remaining = end - start;
  final stream = await safStream.readFileStream(uri, start: start);
  await for (final chunk in stream) {
    if (remaining <= 0) break;   // break also closes the upstream
    yield chunk.length <= remaining ? chunk : chunk.sublist(0, remaining);
    remaining -= chunk.length;
  }
}
\`\`\`

That answers your \`bufferSize\`/close question too — leave \`bufferSize\` at its default and let \`break\` cancel the subscription."
```

---

## Self-Review

**Spec coverage:** typedef widening (Task 1 Step 3), call-site await (Task 1
Step 4), unchanged truncation contract documented (Task 1 Step 3 doc comment),
both required tests plus an `async*` case (Task 1 Step 1), 0.7.3 patch release
(Task 2). Excluded items — `count` helper, proxy-side truncation — appear in no
task, which matches the spec's Scope section.

**Placeholder scan:** every step carries the literal code, command or expected
output. No TBD, no "similar to Task N".

**Type consistency:** `MediaSourceReader` is spelled identically in the typedef,
the tests and the issue reply; `source.read(start, end + 1)` matches the
inclusive-to-exclusive conversion already in `serveSource`.
