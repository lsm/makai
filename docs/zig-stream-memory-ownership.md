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

1. **Event strings are borrowed.** Delta text, tool-call ids/names/arguments,
   and the `partial` message inside every `AssistantMessageEvent` point into
   provider-managed buffers. Never free them, and never keep them past your
   poll loop without copying.
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
| `AssistantMessageEvent` from `wait()`/`poll()` | producer (borrowed slices) | producer's buffers — **not** the stream, **not** you | only after copying |
| `AssistantMessage` from `getResult()` | producer (borrowed view of the stream's internal copy) | `EventStream.deinit()` | no — read-only, do not deinit |
| `AssistantMessage` from `cloneResult()` | you (deep copy) | you, via `AssistantMessage.deinit()` | yes |
| `ToolCall` from `cloneToolCall()` | you (deep copy) | you, via `deinitToolCall()` | yes |

The stream itself never frees event strings (they are borrowed), and it does
free the completed result in `deinit()` — the result a provider passed to
`complete()` is transferred to the stream.

## The safe consumer pattern

One complete, leak-free flow (mirrored by the unit test
`AssistantMessageStream safe consumer flow` in `zig/src/event_stream.zig`):

```zig
const std = @import("std");
const ai_types = @import("ai_types");

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
        .toolcall_end => |tc| try tool_calls.append(
            allocator,
            try ai_types.cloneToolCall(allocator, tc.tool_call),
        ),
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
   or mock, allocate every block string with `allocator.dupe` and set
   `.is_owned = true` (dupe the `api`/`provider`/`model` strings too, as all
   built-in providers do).
2. **`done` event / `getResult()` aliasing.** The message inside a `done`
   event and the value returned by `getResult()` share memory with the stream's
   internal result. Keeping either past `s.deinit()` dangles; freeing either
   double-frees when the stream deinits its copy. Use `cloneResult()` (or
   `ai_types.cloneAssistantMessage`) to own the data.
3. **`toolcall_end` aliasing.** A `toolcall_end` event's `tool_call` strings
   (`id`, `name`, `arguments_json`, `thought_signature`) share storage with the
   completed result's `tool_call` blocks. Same rule: deep-copy with
   `ai_types.cloneToolCall(allocator, tc.tool_call)` when collecting calls, and
   free the copies with `ai_types.deinitToolCall`.

## Helper API reference

| Helper | Purpose |
| --- | --- |
| `EventStream.cloneResult(allocator)` | Deep copy of the completed result (`!?AssistantMessage`, `error{OutOfMemory}`). `null` if the stream has not completed or completed with an error. Available on `AssistantMessageStream` (result type `AssistantMessage`). |
| `ai_types.cloneToolCall(allocator, tool_call)` | Deep copy of a `ToolCall` (owned by you, free with `deinitToolCall`). |
| `ai_types.cloneAssistantMessage(allocator, msg)` | Deep copy of any `AssistantMessage` (sets `is_owned = true`). |
| `ai_types.cloneAssistantMessageEvent(allocator, event)` | Deep copy of a whole event, including its `partial` message. Use when forwarding events across a lifetime boundary. |

## Provider-side notes

If you implement the provider side (custom API registration or test mocks):

- `push()` stores the event as-is by default: the event's strings must outlive
  until the consumer polls them. For producer threads that exit early (protocol
  forwarding), construct the stream with `owns_events = true` and a
  `clone_event_fn` so `push()` deep-copies into stream-owned storage.
- The `AssistantMessage` given to `complete()` is transferred to the stream:
  `EventStream.deinit()` calls `AssistantMessage.deinit()` on it, which frees
  every content-block string unconditionally and frees `api`/`provider`/`model`
  only when `is_owned` is true. Empty content (`&.{}`) and empty strings are
  always safe.
