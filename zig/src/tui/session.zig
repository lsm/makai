const std = @import("std");
const ai_types = @import("ai_types");
const event_stream = @import("event_stream");
const OwnedSlice = @import("owned_slice").OwnedSlice;

pub const TuiEndReason = enum {
    completed,
    cancelled,
    @"error",
};

pub const ToolApprovalDecision = enum {
    approve,
    reject,
    approve_always,
    reject_always,
};

pub const ToolApprovalRequest = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    args_json: []const u8,
};

pub const ToolApprovalCallback = *const fn (
    ctx: ?*anyopaque,
    request: ToolApprovalRequest,
) ToolApprovalDecision;

pub const TuiEvent = union(enum) {
    agent_start: void,
    turn_start: void,
    message_start: struct { role: MessageRole },
    text_delta: struct { content_index: usize, delta: OwnedSlice(u8) },
    thinking_delta: struct { content_index: usize, delta: OwnedSlice(u8) },
    tool_call_delta: struct { content_index: usize, delta: OwnedSlice(u8) },
    message_end: struct { role: MessageRole },
    tool_approval_requested: struct {
        tool_call_id: OwnedSlice(u8),
        tool_name: OwnedSlice(u8),
        args_json: OwnedSlice(u8),
    },
    tool_execution_start: struct {
        tool_call_id: OwnedSlice(u8),
        tool_name: OwnedSlice(u8),
        args_json: OwnedSlice(u8),
    },
    tool_execution_update: struct {
        tool_call_id: OwnedSlice(u8),
        tool_name: OwnedSlice(u8),
        args_json: OwnedSlice(u8),
        partial_result_json: OwnedSlice(u8),
    },
    tool_execution_end: struct {
        tool_call_id: OwnedSlice(u8),
        tool_name: OwnedSlice(u8),
        result_json: OwnedSlice(u8),
        is_error: bool,
    },
    turn_end: struct { stop_reason: ai_types.StopReason },
    agent_end: struct { reason: TuiEndReason },
    @"error": struct { message: OwnedSlice(u8) },

    pub const MessageRole = enum {
        user,
        assistant,
        tool_result,
    };

    pub fn deinit(self: *TuiEvent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text_delta => |*p| p.delta.deinit(allocator),
            .thinking_delta => |*p| p.delta.deinit(allocator),
            .tool_call_delta => |*p| p.delta.deinit(allocator),
            .tool_approval_requested => |*p| {
                p.tool_call_id.deinit(allocator);
                p.tool_name.deinit(allocator);
                p.args_json.deinit(allocator);
            },
            .tool_execution_start => |*p| {
                p.tool_call_id.deinit(allocator);
                p.tool_name.deinit(allocator);
                p.args_json.deinit(allocator);
            },
            .tool_execution_update => |*p| {
                p.tool_call_id.deinit(allocator);
                p.tool_name.deinit(allocator);
                p.args_json.deinit(allocator);
                p.partial_result_json.deinit(allocator);
            },
            .tool_execution_end => |*p| {
                p.tool_call_id.deinit(allocator);
                p.tool_name.deinit(allocator);
                p.result_json.deinit(allocator);
            },
            .@"error" => |*p| p.message.deinit(allocator),
            else => {},
        }
    }
};

pub const TuiSessionResult = struct {
    reason: TuiEndReason = .completed,

    pub fn deinit(self: *TuiSessionResult, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

pub const TuiEventStream = event_stream.EventStream(TuiEvent, TuiSessionResult);

pub const TuiSessionOps = struct {
    start: *const fn (ctx: ?*anyopaque) anyerror!void = undefined,
    resume_session: *const fn (ctx: ?*anyopaque) anyerror!void = undefined,
    cancel: *const fn (ctx: ?*anyopaque) void = undefined,
    submit_turn: *const fn (ctx: ?*anyopaque, text: []const u8) anyerror!void = undefined,
    switch_model: *const fn (ctx: ?*anyopaque, model_id: []const u8) anyerror!void = undefined,
    current_model: *const fn (ctx: ?*anyopaque) ?ai_types.Model = undefined,
    decide_tool_approval: *const fn (ctx: ?*anyopaque, tool_call_id: []const u8, decision: ToolApprovalDecision) anyerror!void = undefined,
    stream_events: *const fn (ctx: ?*anyopaque) *TuiEventStream = undefined,
};

pub const TuiSession = struct {
    ctx: ?*anyopaque,
    ops: TuiSessionOps,

    pub fn start(self: *TuiSession) !void {
        try self.ops.start(self.ctx);
    }

    pub fn resumeSession(self: *TuiSession) !void {
        try self.ops.resume_session(self.ctx);
    }

    pub fn cancel(self: *TuiSession) void {
        self.ops.cancel(self.ctx);
    }

    pub fn submitTurn(self: *TuiSession, text: []const u8) !void {
        try self.ops.submit_turn(self.ctx, text);
    }

    pub fn switchModel(self: *TuiSession, model_id: []const u8) !void {
        try self.ops.switch_model(self.ctx, model_id);
    }

    pub fn currentModel(self: *TuiSession) ?ai_types.Model {
        return self.ops.current_model(self.ctx);
    }

    pub fn decideToolApproval(self: *TuiSession, tool_call_id: []const u8, decision: ToolApprovalDecision) !void {
        try self.ops.decide_tool_approval(self.ctx, tool_call_id, decision);
    }

    pub fn streamEvents(self: *TuiSession) *TuiEventStream {
        return self.ops.stream_events(self.ctx);
    }

    pub fn popEvent(self: *TuiSession) ?TuiEvent {
        return self.streamEvents().poll();
    }

    pub fn waitEvent(self: *TuiSession) ?TuiEvent {
        return self.streamEvents().wait();
    }
};

test "TuiEvent deinit handles owned strings" {
    var event = TuiEvent{ .text_delta = .{
        .content_index = 0,
        .delta = OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, "hello")),
    } };
    event.deinit(std.testing.allocator);
}
