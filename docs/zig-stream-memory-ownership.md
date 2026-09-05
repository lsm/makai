# Zig stream/result memory ownership

This document is for consumers of the Makai Zig package: code that starts a
provider stream (`stream(...)` / `streamSimple(...)` or a registered provider's
`stream` function), polls the returned `AssistantMessageStream` for events, and
reads the final `AssistantMessage` result. Makai does not use a garbage
collector or arena-by-default; string fields inside events and results are
`[]const u8` slices whose ownership follows the rules below. Violating them
produces use-after-free / bus errors, not compile errors.

Module names below (`ai_types`, `event_stream`) refer to the Makai modules under
`zig/src/` — map them into your build the same way Makai's own `build.zig` does.

## TL;DR

1. **Event strings are usually borrowed.** Delta text, tool-call
   ids/names/arguments, and the `partial` message inside every
   `AssistantMessageEvent` point into producer-managed memory. Never free
   them yourself (unless the stream owns its events — see
   [Borrowed vs owned event streams](#borrowed-vs-owned-event-streams)), and
   never keep them past your poll loop without copying.
2. **`wait()` returning `null` is the completion signal.** Do not wait for a
   `done` event — several providers never push one.
3. **Take the result with `s.cloneResult(allocator)`.** The copy is fully
   owned (`is_owned = true`), survives `s.deinit()`, and is the only result
   value you should call `AssistantMessage.deinit()` on.
4. **Providers must hand `complete()` a fully heap-owned result.** If you
   implement your own provider (or a test mock), every content-block string
   must be allocated with the stream's allocator, because the stream frees
   them at `deinit()`.

## Who owns what

| Value | Strings allocated by | Freed by | Safe to keep? |
| --- | --- | --- | --- |
| Event from a **borrowed-event** stream (`stream.owns_events == false`, the default) | producer (borrowed slices) | producer's buffers — **not** the stream, **not** you | only after copying |
| Event from an **owned-event** stream (`stream.owns_events == true`, e.g. OpenAI Completions) | the stream (deep-copied on `push()`) | **you**, via `ai_types.deinitAssistantMessageEvent`, for each polled event; the stream frees only events still queued at `deinit()` | yes |
| `AssistantMessage` from `getResult()` | producer (borrowed view of the stream's internal copy) | `EventStream.deinit()` | no — read-only, do not deinit |
| `AssistantMessage` from `cloneResult()` | you (deep copy) | you, via `AssistantMessage.deinit()` | yes |
| `ToolCall` from `cloneToolCall()` | you (deep copy) | you, via `deinitToolCall()` | yes |

The completed result is transferred to the stream: `EventStream.deinit()`
frees it. Event handling depends on the stream's `owns_events` flag — check it
before writing your poll loop.

## The safe consumer pattern

One complete, leak-free flow (mirrored by the unit test
`AssistantMessageStream safe consumer flow` in `zig/src/event_stream.zig`):

```zig
const std = @import("std");
const ai_types = @import("ai_types"); // zig/src/ai_types.zig
const makai_stream = @import("stream"); // zig/src/stream.zig

const allocator = gpa.allocator();

// Start a stream through the registry facade (or a provider directly).
const s = try makai_stream.stream(registry, model, context, options, allocator);
defer {
    s.deinit(); // frees the stream's internal result copy
    allocator.destroy(s);
}

// State you keep across the stream must be copied out of the borrowed events.
var text = std.ArrayList(u8).empty;
defer text.deinit(allocator);

var tool_calls = std.ArrayList(ai_types.ToolCall).empty;
defer {
    for (tool_calls.items) |*tc| ai_types.deinitToolCall(allocator, tc);
    tool_calls.deinit(allocator);
}

// 1) Drain events until wait() returns null. That null — not a `done` event —
//    is the completion signal.
while (s.wait()) |event| {
    switch (event) {
        // Delta strings are borrowed: copy them as you consume them.
        .text_delta => |d| try text.appendSlice(allocator, d.delta),
        // tool_call strings share storage with the result: deep-copy to keep.
        // The errdefer releases the copy if the append itself fails.
        .toolcall_end => |tc| {
            var owned = try ai_types.cloneToolCall(allocator, tc.tool_call);
            errdefer ai_types.deinitToolCall(allocator, &owned);
            try tool_calls.append(allocator, owned);
        },
        else => {},
    }
}

// 2) An error-completed stream has no result; check getError() first.
if (s.getError()) |msg| return error.StreamFailed;

// 3) One call: take a caller-owned copy of the result. It stays valid after
//    s.deinit() (the deferred deinit above is fine).
var result = (try s.cloneResult(allocator)) orelse return error.NoResult;
defer result.deinit(allocator);

// Everything below is fully owned: `result`, `text`, `tool_calls`.
for (result.content) |block| {
    switch (block) {
        .text => |t| std.debug.print("{s}", .{t.text}),
        else => {},
    }
}
```

`poll()` / `pollBatch()` return the same borrowed events as `wait()`; the same
copy-on-keep rule applies. If you prefer non-blocking polling, loop until
`poll()` returns `null` **and** `isDone()` is true.

## Borrowed vs owned event streams

The sample above assumes the default: a **borrowed-event** stream
(`owns_events == false`), where the stream stores pushed events as-is and never
frees their strings. You copy what you keep; you never free the event itself.

Some streams are **owned-event** streams (`owns_events == true`, e.g. OpenAI
Completions, or any provider started with `requires_owned_stream_events: true`
in `StreamOptions`): `push()` deep-copies each event into stream-owned storage.
There the obligations flip — after processing each polled event you must free
it with `ai_types.deinitAssistantMessageEvent(allocator, &event)`. Events still
queued when the stream dies are freed by `EventStream.deinit()`.

```zig
if (s.owns_events) {
    while (s.wait()) |event| {
        var ev = event;
        defer ai_types.deinitAssistantMessageEvent(allocator, &ev);
        // ... process ev (strings are owned by the event; still copy to keep
        // them past the defer) ...
    }
}
```

If your consumer may lag the producer (UI buffering, slow sinks), prefer
`requires_owned_stream_events: true` where the provider supports it: with
borrowed events the producer is responsible for keeping the backing storage
alive until you drain the queue, and not every provider upholds that for the
full queue lifetime yet (the Anthropic direct path frees its delta storage when
its producer thread exits — #192). Owned events remove that race at the cost of
one deep copy per event.

## Completion is `wait()` → `null` → result, not a `done` event

The `done` variant of `AssistantMessageEvent` exists, but providers are not
required to push it. The built-in Anthropic Messages and OpenAI Completions
providers deliberately complete their streams with `complete()` only, because a
`done` event's `message` would alias the very same `AssistantMessage` handed to
`complete()` — freeing both would double-free. Treat `done` as informational:
handle it if you receive it, never gate completion on it.

`markThreadDone()` (used with `wait_for_thread_on_deinit`) is likewise not a
result signal — some producers mark the thread done *before* publishing the
final result. Gate on `wait()` → `null` (blocking) or `isDone()` plus a drained
queue (polling), then read `getError()` / `cloneResult()`.

## The three traps these rules prevent

1. **Bus error at exit with a hand-written mock provider.** The result passed
   to `complete()` has its content-block strings freed unconditionally by
   `AssistantMessage.deinit()` — the `is_owned` flag only guards
   `api`/`provider`/`model`. A result whose block strings are string literals
   (read-only memory) crashes when the stream deinits. If you write a provider
   or mock, allocate every block string with `allocator.dupe`, and dupe
   `api`/`provider`/`model` as well, setting `.is_owned = true` — the pattern
   every built-in provider uses on its main result path. (Passing borrowed
   `api`/`provider`/`model` with `is_owned = false` is only safe when the
   content blocks are empty or the borrowed strings outlive the stream.)
2. **`done` event / `getResult()` aliasing.** The message inside a `done`
   event and the value returned by `getResult()` share memory with the stream's
   internal result. Keeping either past `s.deinit()` dangles; freeing either
   double-frees when the stream deinits its copy. Use `cloneResult()` (or
   `ai_types.cloneAssistantMessage`) to own the data.
3. **`toolcall_end` aliasing.** On a borrowed-event stream, a `toolcall_end`
   event's `tool_call` strings (`id`, `name`, `arguments_json`,
   `thought_signature`) share storage with the completed result's `tool_call`
   blocks. Same rule: deep-copy with
   `ai_types.cloneToolCall(allocator, tc.tool_call)` when collecting calls, and
   free the copies with `ai_types.deinitToolCall`.

## Helper API reference

| Helper | Purpose |
| --- | --- |
| `EventStream.cloneResult(allocator)` | Deep copy of the completed result (`!?AssistantMessage`, `error{OutOfMemory}`). `null` if the stream has not completed or carries an error (`getError()` non-null — the error wins over a late result). Available on `AssistantMessageStream` (result type `AssistantMessage`). |
| `ai_types.cloneToolCall(allocator, tool_call)` | Deep copy of a `ToolCall` (owned by you, free with `deinitToolCall`). |
| `ai_types.cloneAssistantMessage(allocator, msg)` | Deep copy of any `AssistantMessage` (sets `is_owned = true`). |
| `ai_types.cloneAssistantMessageEvent(allocator, event)` | Deep copy of a whole event, including its `partial` message. Use when forwarding events across a lifetime boundary. |

## Provider-side notes

If you implement the provider side (custom API registration or test mocks):

- `push()` stores the event as-is by default: the event's strings must outlive
  until the consumer polls them — the producer is responsible for keeping the
  backing storage alive until the queue is drained (this is the obligation the
  Anthropic direct path currently misses, #192). For producer threads that
  exit before the consumer drains (protocol forwarding, short-lived workers),
  construct the stream with `owns_events = true` and a `clone_event_fn` so
  `push()` deep-copies into stream-owned storage — and document the consumer's
  `deinitAssistantMessageEvent` obligation that comes with it. OpenAI
  Completions (`pushOwnedEvent`) is the in-tree example.
- The `AssistantMessage` given to `complete()` is transferred to the stream:
  `EventStream.deinit()` calls `AssistantMessage.deinit()` on it, which frees
  every content-block string unconditionally and frees `api`/`provider`/`model`
  only when `is_owned` is true. Empty content (`&.{}`) and empty strings are
  always safe. Duplicate `api`/`provider`/`model` before freeing the model the
  strings came from — the published result outlives the producer thread.
