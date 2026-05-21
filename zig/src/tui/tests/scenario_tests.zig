const std = @import("std");
const compat = @import("compat");
const tui_runtime = @import("tui_runtime");
const tui_session = @import("tui_session");
const session_store = @import("tui_session_store");
const mock_provider = @import("tui_tests_mock_provider");
const fixtures = @import("tui_tests_fixtures");
const ai_types = @import("ai_types");

const TuiRuntime = tui_runtime.TuiRuntime;
const TuiSession = tui_runtime.TuiSession;
const ToolApprovalDecision = tui_runtime.ToolApprovalDecision;
const ToolApprovalRequest = tui_runtime.ToolApprovalRequest;

const EventSummary = struct {
    turn_start: bool = false,
    assistant_start: bool = false,
    text_delta: bool = false,
    assistant_end: bool = false,
    turn_end: bool = false,
    agent_end: bool = false,
    cancelled: bool = false,
};

fn drainUntilAgentEnd(session: *TuiSession, summary: *EventSummary) !void {
    var waits: usize = 0;
    while (waits < 1_000) : (waits += 1) {
        if (session.waitEvent()) |event| {
            var ev = event;
            defer ev.deinit(std.testing.allocator);
            switch (ev) {
                .turn_start => summary.turn_start = true,
                .message_start => |payload| {
                    if (payload.role == .assistant) summary.assistant_start = true;
                },
                .text_delta => summary.text_delta = true,
                .message_end => |payload| {
                    if (payload.role == .assistant) summary.assistant_end = true;
                },
                .turn_end => summary.turn_end = true,
                .agent_end => |payload| {
                    summary.agent_end = true;
                    summary.cancelled = payload.reason == .cancelled;
                    return;
                },
                else => {},
            }
        } else {
            compat.time.sleepMs(1);
        }
    }
    return error.AgentEndTimeout;
}

test "local runtime lifecycle submits turn and supports cancel" {
    const text_steps = [_]mock_provider.ResponseStep{.{ .text = fixtures.expected_text }};
    var provider = mock_provider.MockProvider.init(.{ .steps = &text_steps });
    const models = [_]@TypeOf(mock_provider.test_model){mock_provider.test_model};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{
        .protocol = provider.protocolClient(),
        .models = &models,
        .run_async = false,
    });
    defer runtime.deinit();

    var session = runtime.createSession();
    try session.start();
    try session.submitTurn("hello");

    var summary = EventSummary{};
    try drainUntilAgentEnd(&session, &summary);
    try std.testing.expect(summary.turn_start);
    try std.testing.expect(summary.assistant_start);
    try std.testing.expect(summary.text_delta);
    try std.testing.expect(summary.assistant_end);
    try std.testing.expect(summary.turn_end);
    try std.testing.expect(summary.agent_end);
    try std.testing.expectEqual(@as(usize, 1), provider.call_count);
    try std.testing.expectEqualStrings(mock_provider.test_model.id, provider.last_model_id);
    try std.testing.expectEqual(@as(usize, 1), provider.last_message_count);

    const cancel_steps = [_]mock_provider.ResponseStep{.{ .wait_for_cancel = {} }};
    var cancel_provider = mock_provider.MockProvider.init(.{ .steps = &cancel_steps });
    var cancel_runtime = try TuiRuntime.init(std.testing.allocator, .{
        .protocol = cancel_provider.protocolClient(),
        .models = &models,
        .run_async = true,
    });
    defer cancel_runtime.deinit();

    var cancel_session = cancel_runtime.createSession();
    try cancel_session.start();
    try cancel_session.submitTurn("wait");
    cancel_session.cancel();
    if (cancel_runtime.local_agent) |*local| local.waitForIdle();

    var cancel_summary = EventSummary{};
    try drainUntilAgentEnd(&cancel_session, &cancel_summary);
    try std.testing.expect(cancel_summary.agent_end);
    try std.testing.expect(cancel_summary.cancelled);
}

test "tool execution fixtures run shell read edit and search" {
    const tools = fixtures.tools();
    const steps = [_]mock_provider.ResponseStep{
        .{ .tool_calls = &fixtures.phase1_tool_calls },
        .{ .text = fixtures.final_text },
    };
    var provider = mock_provider.MockProvider.init(.{ .steps = &steps });
    const models = [_]@TypeOf(mock_provider.test_model){mock_provider.test_model};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{
        .protocol = provider.protocolClient(),
        .models = &models,
        .tools = &tools,
        .run_async = false,
    });
    defer runtime.deinit();

    var session = runtime.createSession();
    try session.start();
    try session.submitTurn("use tools");

    var starts: usize = 0;
    var successful_ends: usize = 0;
    var updates: usize = 0;
    while (session.waitEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        switch (ev) {
            .tool_execution_start => starts += 1,
            .tool_execution_update => updates += 1,
            .tool_execution_end => |payload| {
                if (!payload.is_error) successful_ends += 1;
            },
            .agent_end => break,
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 4), starts);
    try std.testing.expectEqual(@as(usize, 4), successful_ends);
    try std.testing.expectEqual(@as(usize, 4), updates);
    try std.testing.expectEqual(@as(usize, 2), provider.call_count);
}

test "tool fixture error case emits error tool end" {
    const tools = fixtures.tools();
    const steps = [_]mock_provider.ResponseStep{
        .{ .tool_calls = &fixtures.error_tool_calls },
        .{ .text = fixtures.final_text },
    };
    var provider = mock_provider.MockProvider.init(.{ .steps = &steps });
    const models = [_]@TypeOf(mock_provider.test_model){mock_provider.test_model};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{
        .protocol = provider.protocolClient(),
        .models = &models,
        .tools = &tools,
        .run_async = false,
    });
    defer runtime.deinit();

    var session = runtime.createSession();
    try session.start();
    try session.submitTurn("fail tool");

    var saw_error = false;
    while (session.waitEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        switch (ev) {
            .tool_execution_end => |payload| saw_error = payload.is_error,
            .agent_end => break,
            else => {},
        }
    }

    try std.testing.expect(saw_error);
}

const ApprovalState = struct {
    decision: ToolApprovalDecision,
    calls: usize = 0,
};

fn approvalCallback(ctx: ?*anyopaque, request: ToolApprovalRequest) ToolApprovalDecision {
    _ = request;
    const state: *ApprovalState = @ptrCast(@alignCast(ctx.?));
    state.calls += 1;
    return state.decision;
}

test "provider error injection propagates through session" {
    const steps = [_]mock_provider.ResponseStep{.{ .provider_error = "fixture provider error" }};
    var provider = mock_provider.MockProvider.init(.{ .steps = &steps });
    const models = [_]@TypeOf(mock_provider.test_model){mock_provider.test_model};
    var runtime = try TuiRuntime.init(std.testing.allocator, .{
        .protocol = provider.protocolClient(),
        .models = &models,
        .run_async = false,
    });
    defer runtime.deinit();

    var session = runtime.createSession();
    try session.start();
    try std.testing.expectError(error.AgentLoopFailed, session.submitTurn("trigger provider error"));

    var saw_error_end = false;
    while (session.waitEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        switch (ev) {
            .agent_end => |payload| {
                saw_error_end = payload.reason == .@"error";
                break;
            },
            else => {},
        }
    }

    try std.testing.expect(saw_error_end);
    try std.testing.expectEqual(@as(usize, 1), provider.call_count);
}


test "tool approval approve runs tool and reject skips executor" {
    const models = [_]@TypeOf(mock_provider.test_model){mock_provider.test_model};

    const approve_tools = fixtures.tools();
    const approve_steps = [_]mock_provider.ResponseStep{
        .{ .tool_calls = &fixtures.approval_tool_calls },
        .{ .text = fixtures.final_text },
    };
    var approve_provider = mock_provider.MockProvider.init(.{ .steps = &approve_steps });
    var approve_state = ApprovalState{ .decision = .approve };
    var approve_runtime = try TuiRuntime.init(std.testing.allocator, .{
        .protocol = approve_provider.protocolClient(),
        .models = &models,
        .tools = &approve_tools,
        .tool_approval_ctx = &approve_state,
        .tool_approval_callback = approvalCallback,
        .run_async = false,
    });
    defer approve_runtime.deinit();

    var approve_session = approve_runtime.createSession();
    try approve_session.start();
    try approve_session.submitTurn("approve tool");

    var approve_requested = false;
    var approve_tool_ok = false;
    while (approve_session.waitEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        switch (ev) {
            .tool_approval_requested => approve_requested = true,
            .tool_execution_end => |payload| approve_tool_ok = !payload.is_error,
            .agent_end => break,
            else => {},
        }
    }
    try std.testing.expect(approve_requested);
    try std.testing.expect(approve_tool_ok);
    try std.testing.expectEqual(@as(usize, 1), approve_state.calls);

    const reject_tools = fixtures.tools();
    const reject_steps = [_]mock_provider.ResponseStep{
        .{ .tool_calls = &fixtures.approval_tool_calls },
        .{ .text = fixtures.final_text },
    };
    var reject_provider = mock_provider.MockProvider.init(.{ .steps = &reject_steps });
    var reject_state = ApprovalState{ .decision = .reject };
    var reject_runtime = try TuiRuntime.init(std.testing.allocator, .{
        .protocol = reject_provider.protocolClient(),
        .models = &models,
        .tools = &reject_tools,
        .tool_approval_ctx = &reject_state,
        .tool_approval_callback = approvalCallback,
        .run_async = false,
    });
    defer reject_runtime.deinit();

    var reject_session = reject_runtime.createSession();
    try reject_session.start();
    try reject_session.submitTurn("reject tool");

    var reject_requested = false;
    var reject_tool_error = false;
    while (reject_session.waitEvent()) |event| {
        var ev = event;
        defer ev.deinit(std.testing.allocator);
        switch (ev) {
            .tool_approval_requested => reject_requested = true,
            .tool_execution_end => |payload| reject_tool_error = payload.is_error,
            .agent_end => break,
            else => {},
        }
    }
    try std.testing.expect(reject_requested);
    try std.testing.expect(reject_tool_error);
    try std.testing.expectEqual(@as(usize, 1), reject_state.calls);
}

fn tmpSessionBase(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "sessions" });
    errdefer allocator.free(base);
    try compat.fs.createDir(compat.fs.getCwd(), base);
    return base;
}

fn ownedText(text: []const u8) !@import("owned_slice").OwnedSlice(u8) {
    return @import("owned_slice").OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, text));
}

const alternate_model = ai_types.Model{
    .id = "alternate-tui-model",
    .name = "Alternate TUI Model",
    .api = "tui-fixture-api",
    .provider = "tui-fixture-provider",
    .base_url = "https://example.invalid",
    .reasoning = false,
    .input = &.{"text"},
    .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
    .context_window = 8192,
    .max_tokens = 1024,
};

test "runtime persistence full save and resume cycle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpSessionBase(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(base);

    var store = try session_store.Store.init(std.testing.allocator, base);
    defer store.deinit();

    var meta = session_store.SessionMetadata{
        .session_id = try std.testing.allocator.dupe(u8, "resume-cycle"),
        .model = try std.testing.allocator.dupe(u8, mock_provider.test_model.id),
        .provider = try std.testing.allocator.dupe(u8, mock_provider.test_model.provider),
        .created_at = 1,
        .last_active = 1,
        .turn_count = 1,
        .working_dir = try std.testing.allocator.dupe(u8, "."),
    };
    defer meta.deinit(std.testing.allocator);

    try store.save(meta, .{ .message_start = .{ .role = .user } });
    var user_end = tui_session.TuiEvent{ .message_end = .{ .role = .user, .text = try ownedText("hello") } };
    defer user_end.deinit(std.testing.allocator);
    try store.save(meta, user_end);
    try store.save(meta, .{ .message_start = .{ .role = .assistant } });
    var assistant_a = tui_session.TuiEvent{ .text_delta = .{ .content_index = 0, .delta = try ownedText("hel") } };
    defer assistant_a.deinit(std.testing.allocator);
    try store.save(meta, assistant_a);
    var assistant_b = tui_session.TuiEvent{ .text_delta = .{ .content_index = 0, .delta = try ownedText("lo") } };
    defer assistant_b.deinit(std.testing.allocator);
    try store.save(meta, assistant_b);
    try store.save(meta, .{ .message_end = .{ .role = .assistant } });

    const steps = [_]mock_provider.ResponseStep{.{ .text = fixtures.expected_text }};
    var provider = mock_provider.MockProvider.init(.{ .steps = &steps });
    const models = [_]ai_types.Model{ alternate_model, mock_provider.test_model };
    var runtime = try TuiRuntime.init(std.testing.allocator, .{
        .protocol = provider.protocolClient(),
        .models = &models,
        .initial_model_id = alternate_model.id,
        .run_async = false,
    });
    defer runtime.deinit();

    var loaded = try store.resumeSession("resume-cycle", &runtime);
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), loaded.messages.items.len);
    try std.testing.expect(loaded.messages.items[0] == .user);
    try std.testing.expectEqualStrings("hello", loaded.messages.items[0].user.content.text);
    try std.testing.expect(loaded.messages.items[1] == .assistant);
    try std.testing.expectEqualStrings("hello", loaded.messages.items[1].assistant.content[0].text.text);
    try std.testing.expectEqualStrings(mock_provider.test_model.id, loaded.messages.items[1].assistant.model);
    try std.testing.expectEqualStrings(mock_provider.test_model.id, runtime.currentModel().?.id);

    var session = runtime.createSession();
    try session.submitTurn("again");
    var summary = EventSummary{};
    try drainUntilAgentEnd(&session, &summary);
    try std.testing.expect(summary.agent_end);
    try std.testing.expectEqual(@as(usize, 3), provider.last_message_count);
}

test "session persistence reconstructs tool call before tool result" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpSessionBase(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(base);
    var store = try session_store.Store.init(std.testing.allocator, base);
    defer store.deinit();
    var meta = session_store.SessionMetadata{
        .session_id = try std.testing.allocator.dupe(u8, "tool-cycle"),
        .model = try std.testing.allocator.dupe(u8, mock_provider.test_model.id),
        .provider = try std.testing.allocator.dupe(u8, mock_provider.test_model.provider),
        .created_at = 1,
        .last_active = 1,
        .turn_count = 1,
        .working_dir = try std.testing.allocator.dupe(u8, "."),
    };
    defer meta.deinit(std.testing.allocator);

    try store.save(meta, .{ .message_start = .{ .role = .assistant } });
    var assistant_tool = tui_session.TuiEvent{ .message_end = .{
        .role = .assistant,
        .tool_call_id = try ownedText("call-1"),
        .tool_name = try ownedText("demo_tool"),
        .args_json = try ownedText("{\"x\":1}"),
    } };
    defer assistant_tool.deinit(std.testing.allocator);
    try store.save(meta, assistant_tool);
    var tool_result = tui_session.TuiEvent{ .tool_execution_end = .{
        .tool_call_id = try ownedText("call-1"),
        .tool_name = try ownedText("demo_tool"),
        .result_json = try ownedText("{\"ok\":true}"),
        .is_error = false,
    } };
    defer tool_result.deinit(std.testing.allocator);
    try store.save(meta, tool_result);

    var loaded = try store.load("tool-cycle");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), loaded.messages.items.len);
    try std.testing.expect(loaded.messages.items[0] == .assistant);
    try std.testing.expect(loaded.messages.items[0].assistant.content[0] == .tool_call);
    try std.testing.expectEqualStrings("call-1", loaded.messages.items[0].assistant.content[0].tool_call.id);
    try std.testing.expect(loaded.messages.items[1] == .tool_result);
    try std.testing.expectEqualStrings("call-1", loaded.messages.items[1].tool_result.tool_call_id);
}

test {
    _ = tui_session;
}
