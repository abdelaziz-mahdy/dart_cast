# MediaSource: allow readers to open asynchronously

**Date:** 2026-07-25
**Status:** Approved
**Target release:** 0.7.3 (patch — no behaviour change, strictly more accepted)

## Problem

`MediaSource` shipped in 0.7.0 so applications can cast bytes the package
cannot open itself — Android `content://` URIs, Flutter assets, decrypted
content. Its reader is synchronous:

```dart
typedef MediaSourceReader = Stream<List<int>> Function(int start, int end);
```

The first user to adapt it ([#12](https://github.com/abdelaziz-mahdy/dart_cast/issues/12))
hit a mismatch immediately. `saf_stream` exposes:

```dart
Future<Uint8List>         readFileBytes(String uri, {int? start, int? count})
Future<Stream<Uint8List>> readFileStream(String uri, {int? bufferSize, int? start})
```

Both are asynchronous. A source that must *open* something before it can read —
SAF, a network handle, a decrypt handshake — cannot satisfy a synchronous
signature without ceremony:

```dart
read: (start, end) => Stream.fromFuture(saf.readFileStream(uri, start: start))
    .asyncExpand((s) => s)
    .transform(truncateTo(end - start))
```

That reads like a workaround because it is one, and the awkwardness is imposed
by this package rather than by the plugin.

## Design

Widen the reader to permit an asynchronous open.

```dart
typedef MediaSourceReader =
    FutureOr<Stream<List<int>>> Function(int start, int end);
```

A source may now be an `async` function or an `async*` generator:

```dart
read: (start, end) async* {
  var remaining = end - start;
  final stream = await saf.readFileStream(uri, start: start);
  await for (final chunk in stream) {
    if (remaining <= 0) break;
    yield chunk.length <= remaining ? chunk : chunk.sublist(0, remaining);
    remaining -= chunk.length;
  }
}
```

### Why this is not breaking

`Stream<List<int>>` already satisfies `FutureOr<Stream<List<int>>>`. Every
existing implementation keeps compiling unchanged: `MediaSource.bytes`,
`MediaSource.file`, the test sources, and the reader in
`tool/chromecast_hardware_check.dart`. Callers gain an option; none lose one.

**Corrected during implementation.** That claim holds for anyone *supplying* a
reader, which is the normal way the API is used. It does not hold for anyone
*calling* `source.read(...)` directly: the result is now a `FutureOr` and must
be awaited before the stream is usable. The only in-tree caller is
`Http10FileServer.serveSource`, and one test that read a source directly needed
the same one-line change. `MediaSource.read` is a public field, so a consumer
could in principle be affected — worth naming rather than glossing.

### `async*` readers need a declared return type

Also found during implementation: an inline `async*` closure does not infer
correctly against a `FutureOr` context. Dart resolves

```dart
read: (start, end) async* { ... }
```

to `Stream<FutureOr<Stream<List<int>>>>` and rejects the argument. An `async*`
reader must therefore be a function with a declared signature:

```dart
Stream<List<int>> readRange(int start, int end) async* { ... }
```

`async` (non-generator) closures infer fine. The doc comment shows both shapes,
because this is exactly the trap the reporting user would hit first.

### Call site

One place consumes the reader:

```dart
// lib/src/core/http10_file_server.dart:129
await source.read(start, end + 1).pipe(socket);
```

becomes

```dart
final stream = await source.read(start, end + 1);
await stream.pipe(socket);
```

`serveSource` is already `async`, so nothing restructures.

### Contract: unchanged

The source still returns **exactly** `[start, end)`. The proxy trusts it and
does not truncate.

This is deliberate. Truncating defensively in the proxy would make careless
adapters work, but it would also absorb a real mistake silently — and the proxy
cannot distinguish "over-delivered" from "returned the wrong offset entirely",
so it would only mask the benign half of the problem.

The doc comment must state the requirement plainly, because an asynchronously
opened source is precisely the kind that streams to EOF by default. A reader
that ignores `end` will over-deliver against the `Content-Length` already sent,
corrupting the response and breaking seeking.

## Testing

Two tests, both aimed at the widening itself:

1. **An asynchronous reader serves correctly**, including a mid-file range —
   proving `Future<Stream>` is genuinely accepted end to end, not merely
   accepted by the type checker.
2. **A synchronous reader still works** — the non-breaking guarantee asserted
   rather than assumed.

Existing `media_source_test.dart` coverage (ranges, suffix ranges, 416, HEAD,
lazy reads, transformer routing) continues to exercise the synchronous path.

## Scope

Explicitly **not** included, each additive later if a second user asks:

- a `count`-shaped convenience constructor for plugins that speak
  `start + count` rather than `start + end` — `count = end - start` is one
  subtraction, not worth public surface
- proxy-side truncation — rejected above
- any change to `CastMedia.source` or `MediaProxy.registerSource`

## Risks

Low. The type widening cannot break a caller, and the single call site is
covered by existing tests. The residual risk is documentation: adapter authors
who skip the contract note will write a reader that over-delivers. That risk
exists today and is unchanged by this work.
