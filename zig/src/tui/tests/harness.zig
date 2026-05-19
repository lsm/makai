const std = @import("std");
const tui_runtime = @import("tui_runtime");
const tui_session = @import("tui_session");
const mock_provider = @import("tui_tests_mock_provider");
const mock_transport = @import("tui_tests_mock_transport");
const fixtures = @import("tui_tests_fixtures");

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

fn drainUntilAgentEnd(session: *TuiSession, summary: *EventSummary) void {
    while (session.waitEvent()) |event| {
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
                break;
            },
            else => {},
        }
    }
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
    drainUntilAgentEnd(&session, &summary);
    try std.testing.expect(summary.turn_start);
    try std.testing.expect(summary.assistant_start);
    try std.testing.expect(summary.text_delta);
    try std.testing.expect(summary.assistant_end);
    try std.testing.expect(summary.turn_end);
    try std.testing.expect(summary.agent_end);
    try std.testing.expectEqual(@as(usize, 1), provider.call_count);

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
    drainUntilAgentEnd(&cancel_session, &cancel_summary);
    try std.testing.expect(cancel_summary.agent_end);
    try std.testing.expect(cancel_summary.cancelled);
}

test "tool execution fixtures run shell read edit and search" {
    var state = fixtures.ToolFixtureState{};
    fixtures.setActiveState(&state);
    const tools = fixtures.tools(&state);
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
    try std.testing.expectEqual(@as(usize, 4), state.total());
    try std.testing.expectEqual(@as(usize, 2), provider.call_count);
}

test "tool fixture error case emits error tool end" {
    var state = fixtures.ToolFixtureState{};
    fixtures.setActiveState(&state);
    const tools = fixtures.tools(&state);
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
    try std.testing.expectEqual(@as(usize, 1), state.shell_count);
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

test "tool approval approve runs tool and reject skips executor" {
    const models = [_]@TypeOf(mock_provider.test_model){mock_provider.test_model};

    var approve_tool_state = fixtures.ToolFixtureState{};
    fixtures.setActiveState(&approve_tool_state);
    const approve_tools = fixtures.tools(&approve_tool_state);
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
    try std.testing.expectEqual(@as(usize, 1), approve_tool_state.shell_count);

    var reject_tool_state = fixtures.ToolFixtureState{};
    fixtures.setActiveState(&reject_tool_state);
    const reject_tools = fixtures.tools(&reject_tool_state);
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
    try std.testing.expectEqual(@as(usize, 0), reject_tool_state.shell_count);
}

test "mock transport supports protocol harness FIFO" {
    var transport = mock_transport.MockTransport.init(std.testing.allocator);
    defer transport.deinit();

    try transport.enqueueInbound("frame-a");
    try transport.enqueueInbound("frame-b");
    var receiver = transport.receiver();
    const frame_a = (try receiver.read(std.testing.allocator)).?;
    defer std.testing.allocator.free(frame_a);
    const frame_b = (try receiver.read(std.testing.allocator)).?;
    defer std.testing.allocator.free(frame_b);
    try std.testing.expectEqualStrings("frame-a", frame_a);
    try std.testing.expectEqualStrings("frame-b", frame_b);

    var sender = transport.sender();
    try sender.write("client-frame");
    try std.testing.expectEqual(@as(usize, 1), transport.outboundCount());
    try std.testing.expectEqualStrings("client-frame", transport.outboundFrame(0));
}

test {
    _ = tui_session;
}
