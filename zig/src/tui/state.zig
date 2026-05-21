const std = @import("std");
const tui_runtime = @import("tui_runtime");

pub const AppMode = enum {
    normal,
    approval,
    preview,
    session_picker,
};

pub const TranscriptKind = enum {
    user,
    assistant,
    thinking,
    tool,
    system,
    @"error",
};

pub const ToolStatus = enum {
    pending,
    running,
    done,
    @"error",
};

pub const ApprovalStatus = enum {
    none,
    pending,
    approved,
    rejected,
};

pub const PreviewKind = enum {
    diff,
    file,
    artifact,
};

pub const TranscriptEntry = struct {
    kind: TranscriptKind,
    text: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, kind: TranscriptKind, text: []const u8) !TranscriptEntry {
        var entry = TranscriptEntry{ .kind = kind };
        try entry.text.appendSlice(allocator, text);
        return entry;
    }

    pub fn deinit(self: *TranscriptEntry, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.* = undefined;
    }
};

pub const ToolEntry = struct {
    id: []u8,
    name: []u8,
    args_json: []u8,
    output: std.ArrayList(u8) = .empty,
    status: ToolStatus = .pending,
    expanded: bool = false,
    raw_total_bytes: u64 = 0,
    returned_total_bytes: u64 = 0,
    estimated_returned_tokens: u64 = 0,
    artifact_count: u32 = 0,
    artifact_refs: []u8 = &.{},
    truncated: bool = false,

    pub fn init(allocator: std.mem.Allocator, id: []const u8, name: []const u8, args_json: []const u8, status: ToolStatus) !ToolEntry {
        return .{
            .id = try allocator.dupe(u8, id),
            .name = try allocator.dupe(u8, name),
            .args_json = try allocator.dupe(u8, args_json),
            .status = status,
        };
    }

    pub fn deinit(self: *ToolEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.args_json);
        self.output.deinit(allocator);
        if (self.artifact_refs.len > 0) allocator.free(self.artifact_refs);
        self.* = undefined;
    }
};

pub const ApprovalState = struct {
    status: ApprovalStatus = .none,
    tool_call_id: []u8 = &.{},
    tool_name: []u8 = &.{},
    args_json: []u8 = &.{},
    always: bool = false,

    pub fn deinit(self: *ApprovalState, allocator: std.mem.Allocator) void {
        if (self.tool_call_id.len > 0) allocator.free(self.tool_call_id);
        if (self.tool_name.len > 0) allocator.free(self.tool_name);
        if (self.args_json.len > 0) allocator.free(self.args_json);
        self.* = .{};
    }

    pub fn setPending(self: *ApprovalState, allocator: std.mem.Allocator, tool_call_id: []const u8, tool_name: []const u8, args_json: []const u8) !void {
        self.deinit(allocator);
        self.* = .{
            .status = .pending,
            .tool_call_id = try allocator.dupe(u8, tool_call_id),
            .tool_name = try allocator.dupe(u8, tool_name),
            .args_json = try allocator.dupe(u8, args_json),
        };
    }
};

pub const PromptSegmentState = struct {
    bytes: u64 = 0,
    estimated_tokens: u64 = 0,
    item_count: u32 = 0,
    cache_role: tui_runtime.TuiEvent.PromptSegmentCacheRole = .dynamic,
    seen: bool = false,
};

pub const TelemetryState = struct {
    system_prompt_bytes: u64 = 0,
    message_bytes: u64 = 0,
    tool_definition_bytes: u64 = 0,
    total_bytes: u64 = 0,
    estimated_tokens: u64 = 0,
    context_window: u64 = 0,
    message_count: u32 = 0,
    tool_count: u32 = 0,
    system_prompt: PromptSegmentState = .{},
    messages: PromptSegmentState = .{},
    tool_definitions: PromptSegmentState = .{},

    pub fn segment(self: *TelemetryState, kind: tui_runtime.TuiEvent.PromptSegmentKind) *PromptSegmentState {
        return switch (kind) {
            .system_prompt => &self.system_prompt,
            .message_history => &self.messages,
            .tool_definitions => &self.tool_definitions,
        };
    }
};

pub const StatusState = struct {
    model: []u8 = &.{},
    provider: []u8 = &.{},
    session_id: []u8 = &.{},
    context_used: usize = 0,
    context_limit: usize = 0,
    turn_count: usize = 0,
    streaming: bool = false,
    last_error: []u8 = &.{},

    pub fn deinit(self: *StatusState, allocator: std.mem.Allocator) void {
        if (self.model.len > 0) allocator.free(self.model);
        if (self.provider.len > 0) allocator.free(self.provider);
        if (self.session_id.len > 0) allocator.free(self.session_id);
        if (self.last_error.len > 0) allocator.free(self.last_error);
        self.* = .{};
    }

    pub fn setModel(self: *StatusState, allocator: std.mem.Allocator, model: []const u8, provider: []const u8) !void {
        try self.setModelWithContext(allocator, model, provider, 0);
    }

    pub fn setModelWithContext(self: *StatusState, allocator: std.mem.Allocator, model: []const u8, provider: []const u8, context_limit: usize) !void {
        if (self.model.len > 0) allocator.free(self.model);
        if (self.provider.len > 0) allocator.free(self.provider);
        self.model = try allocator.dupe(u8, model);
        self.provider = try allocator.dupe(u8, provider);
        self.context_limit = context_limit;
    }

    pub fn setError(self: *StatusState, allocator: std.mem.Allocator, message: []const u8) !void {
        if (self.last_error.len > 0) allocator.free(self.last_error);
        self.last_error = try allocator.dupe(u8, message);
    }
};

pub const PreviewState = struct {
    kind: PreviewKind = .file,
    title: []u8 = &.{},
    content: []u8 = &.{},
    scroll: usize = 0,

    pub fn deinit(self: *PreviewState, allocator: std.mem.Allocator) void {
        if (self.title.len > 0) allocator.free(self.title);
        if (self.content.len > 0) allocator.free(self.content);
        self.* = .{};
    }

    pub fn set(self: *PreviewState, allocator: std.mem.Allocator, kind: PreviewKind, title: []const u8, content: []const u8) !void {
        self.deinit(allocator);
        self.* = .{
            .kind = kind,
            .title = try allocator.dupe(u8, title),
            .content = try allocator.dupe(u8, content),
            .scroll = 0,
        };
    }
};

pub const SessionEntry = struct {
    id: []u8,
    label: []u8,

    pub fn init(allocator: std.mem.Allocator, id: []const u8, label: []const u8) !SessionEntry {
        return .{ .id = try allocator.dupe(u8, id), .label = try allocator.dupe(u8, label) };
    }

    pub fn deinit(self: *SessionEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        self.* = undefined;
    }
};

pub const ComposerState = struct {
    buffer: std.ArrayList(u8) = .empty,
    history: std.ArrayList([]u8) = .empty,
    history_index: ?usize = null,

    pub fn deinit(self: *ComposerState, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
        for (self.history.items) |item| allocator.free(item);
        self.history.deinit(allocator);
        self.* = undefined;
    }

    pub fn clear(self: *ComposerState) void {
        self.buffer.clearRetainingCapacity();
        self.history_index = null;
    }

    pub fn text(self: ComposerState) []const u8 {
        return self.buffer.items;
    }
};

pub const AppState = struct {
    allocator: std.mem.Allocator,
    mode: AppMode = .normal,
    transcript: std.ArrayList(TranscriptEntry) = .empty,
    tools: std.ArrayList(ToolEntry) = .empty,
    sessions: std.ArrayList(SessionEntry) = .empty,
    composer: ComposerState = .{},
    approval: ApprovalState = .{},
    status: StatusState = .{},
    telemetry: TelemetryState = .{},
    preview: PreviewState = .{},
    transcript_scroll: usize = 0,
    tool_scroll: usize = 0,
    session_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator) AppState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AppState) void {
        for (self.transcript.items) |*entry| entry.deinit(self.allocator);
        self.transcript.deinit(self.allocator);
        for (self.tools.items) |*tool| tool.deinit(self.allocator);
        self.tools.deinit(self.allocator);
        for (self.sessions.items) |*session| session.deinit(self.allocator);
        self.sessions.deinit(self.allocator);
        self.composer.deinit(self.allocator);
        self.approval.deinit(self.allocator);
        self.status.deinit(self.allocator);
        self.preview.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn appendTranscript(self: *AppState, kind: TranscriptKind, text: []const u8) !void {
        try self.transcript.append(self.allocator, try TranscriptEntry.init(self.allocator, kind, text));
    }

    pub fn clearTranscript(self: *AppState) void {
        for (self.transcript.items) |*entry| entry.deinit(self.allocator);
        self.transcript.clearRetainingCapacity();
        self.transcript_scroll = 0;
    }

    pub fn appendUserMessage(self: *AppState, text: []const u8) !void {
        try self.appendTranscript(.user, text);
    }

    pub fn submitComposer(self: *AppState) !?[]u8 {
        const raw = std.mem.trim(u8, self.composer.buffer.items, " \t\r\n");
        if (raw.len == 0) {
            self.composer.clear();
            return null;
        }
        const submitted = try self.allocator.dupe(u8, raw);
        errdefer self.allocator.free(submitted);
        try self.composer.history.append(self.allocator, try self.allocator.dupe(u8, submitted));
        self.composer.clear();
        try self.appendUserMessage(submitted);
        return submitted;
    }

    pub fn applyEvent(self: *AppState, event: tui_runtime.TuiEvent) !void {
        switch (event) {
            .agent_start => {
                self.status.streaming = true;
                try self.appendTranscript(.system, "agent started");
            },
            .turn_start => {
                self.status.streaming = true;
                self.status.turn_count += 1;
            },
            .message_start => |payload| switch (payload.role) {
                .assistant => try self.ensureTrailingEntry(.assistant),
                .user => try self.ensureTrailingEntry(.user),
                .tool_result => try self.ensureTrailingEntry(.tool),
            },
            .text_delta => |payload| try self.appendDelta(.assistant, payload.delta.slice()),
            .thinking_delta => |payload| try self.appendDelta(.thinking, payload.delta.slice()),
            .tool_call_delta => |payload| try self.appendDelta(.tool, payload.delta.slice()),
            .message_end => {},
            .tool_approval_requested => |payload| {
                try self.approval.setPending(self.allocator, payload.tool_call_id.slice(), payload.tool_name.slice(), payload.args_json.slice());
                if (std.mem.eql(u8, payload.tool_name.slice(), "hashline_edit")) try self.setHashlinePreview(payload.args_json.slice());
                self.mode = .approval;
                _ = try self.upsertTool(payload.tool_call_id.slice(), payload.tool_name.slice(), payload.args_json.slice(), .pending);
            },
            .tool_execution_start => |payload| {
                const tool = try self.upsertTool(payload.tool_call_id.slice(), payload.tool_name.slice(), payload.args_json.slice(), .running);
                tool.expanded = true;
                try self.appendTranscript(.tool, payload.tool_name.slice());
            },
            .tool_execution_update => |payload| {
                const tool = try self.upsertTool(payload.tool_call_id.slice(), payload.tool_name.slice(), payload.args_json.slice(), .running);
                if (tool.output.items.len > 0) try tool.output.append(self.allocator, '\n');
                try tool.output.appendSlice(self.allocator, payload.partial_result_json.slice());
            },
            .tool_execution_end => |payload| {
                const status: ToolStatus = if (payload.is_error) .@"error" else .done;
                const tool = try self.upsertTool(payload.tool_call_id.slice(), payload.tool_name.slice(), "", status);
                if (tool.output.items.len > 0) try tool.output.append(self.allocator, '\n');
                try tool.output.appendSlice(self.allocator, payload.result_json.slice());
                try self.applyToolTelemetry(tool, payload.raw_total_bytes, payload.returned_total_bytes, payload.estimated_returned_tokens, payload.artifact_count, payload.artifact_refs.slice());
                if (payload.is_error) try self.status.setError(self.allocator, payload.result_json.slice());
            },
            .context_usage => |payload| self.applyContextUsage(payload),
            .prompt_segment_usage => |payload| self.applyPromptSegmentUsage(payload),
            .turn_end => self.status.streaming = false,
            .agent_end => |payload| {
                self.status.streaming = false;
                switch (payload.reason) {
                    .completed => {},
                    .cancelled => try self.appendTranscript(.system, "agent cancelled"),
                    .@"error" => try self.status.setError(self.allocator, "agent error"),
                }
            },
            .@"error" => |payload| {
                try self.status.setError(self.allocator, payload.message.slice());
                try self.appendTranscript(.@"error", payload.message.slice());
            },
        }
    }

    pub fn setApprovalDecision(self: *AppState, approved: bool, always: bool) void {
        self.approval.status = if (approved) .approved else .rejected;
        self.approval.always = always;
        self.mode = .normal;
    }

    pub fn toggleToolExpanded(self: *AppState, index: usize) void {
        if (index >= self.tools.items.len) return;
        self.tools.items[index].expanded = !self.tools.items[index].expanded;
    }

    pub fn setPreview(self: *AppState, kind: PreviewKind, title: []const u8, content: []const u8) !void {
        try self.preview.set(self.allocator, kind, title, content);
        self.mode = .preview;
    }

    pub fn addSession(self: *AppState, id: []const u8, label: []const u8) !void {
        try self.sessions.append(self.allocator, try SessionEntry.init(self.allocator, id, label));
    }

    fn setHashlinePreview(self: *AppState, args_json: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, args_json, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const obj = parsed.value.object;
        const path = jsonString(obj, "path") orelse "(unknown)";
        const operation = jsonString(obj, "operation") orelse "hashline_edit";
        const start_line = jsonUsize(obj, "start_line") orelse 0;
        const end_line = jsonUsize(obj, "end_line") orelse start_line;
        const start_hash = jsonString(obj, "start_hash") orelse "";
        const end_hash = jsonString(obj, "end_hash") orelse start_hash;
        const replacement = jsonString(obj, "replacement") orelse "";

        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.allocator);
        const header = try std.fmt.allocPrint(self.allocator, "hashline edit preview\noperation: {s}\nrange: {d}:{s}..{d}:{s}\n", .{ operation, start_line, start_hash, end_line, end_hash });
        defer self.allocator.free(header);
        try out.appendSlice(self.allocator, header);
        if (std.mem.eql(u8, operation, "delete_range")) {
            const row = try std.fmt.allocPrint(self.allocator, "- lines {d}..{d}\n", .{ start_line, end_line });
            defer self.allocator.free(row);
            try out.appendSlice(self.allocator, row);
        } else {
            var line_no = start_line;
            var lines = std.mem.splitScalar(u8, replacement, '\n');
            while (lines.next()) |line| {
                if (line.len == 0 and line.ptr == replacement.ptr + replacement.len) break;
                const row = try std.fmt.allocPrint(self.allocator, "+ {d}|{s}\n", .{ line_no, line });
                defer self.allocator.free(row);
                try out.appendSlice(self.allocator, row);
                line_no += 1;
            }
        }
        try self.preview.set(self.allocator, .diff, path, out.items);
    }

    fn ensureTrailingEntry(self: *AppState, kind: TranscriptKind) !void {
        if (self.transcript.items.len > 0 and self.transcript.items[self.transcript.items.len - 1].kind == kind) return;
        try self.appendTranscript(kind, "");
    }

    fn appendDelta(self: *AppState, kind: TranscriptKind, delta: []const u8) !void {
        try self.ensureTrailingEntry(kind);
        try self.transcript.items[self.transcript.items.len - 1].text.appendSlice(self.allocator, delta);
    }

    fn applyContextUsage(self: *AppState, payload: anytype) void {
        self.telemetry.system_prompt_bytes = payload.system_prompt_bytes;
        self.telemetry.message_bytes = payload.message_bytes;
        self.telemetry.tool_definition_bytes = payload.tool_definition_bytes;
        self.telemetry.total_bytes = payload.total_bytes;
        self.telemetry.estimated_tokens = payload.estimated_tokens;
        self.telemetry.message_count = payload.message_count;
        self.telemetry.tool_count = payload.tool_count;
        self.telemetry.context_window = self.status.context_limit;
        self.status.context_used = @intCast(payload.estimated_tokens);
    }

    fn applyPromptSegmentUsage(self: *AppState, payload: anytype) void {
        const segment = self.telemetry.segment(payload.segment);
        segment.* = .{
            .bytes = payload.bytes,
            .estimated_tokens = payload.estimated_tokens,
            .item_count = payload.item_count,
            .cache_role = payload.cache_role,
            .seen = true,
        };
    }

    fn applyToolTelemetry(self: *AppState, tool: *ToolEntry, raw_total_bytes: u64, returned_total_bytes: u64, estimated_returned_tokens: u64, artifact_count: u32, artifact_refs: []const u8) !void {
        tool.raw_total_bytes = raw_total_bytes;
        tool.returned_total_bytes = returned_total_bytes;
        tool.estimated_returned_tokens = estimated_returned_tokens;
        tool.artifact_count = artifact_count;
        tool.truncated = raw_total_bytes > returned_total_bytes or artifact_count > 0;
        if (tool.artifact_refs.len > 0) self.allocator.free(tool.artifact_refs);
        tool.artifact_refs = try self.allocator.dupe(u8, artifact_refs);
        if (tool.truncated) {
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            defer out.deinit();
            const writer = &out.writer;
            try writer.print("{s} [truncated {d}->{d} bytes; show full", .{ tool.name, raw_total_bytes, returned_total_bytes });
            if (artifact_refs.len > 0) try writer.print(": {s}", .{artifact_refs});
            try writer.writeByte(']');
            const indicator = try out.toOwnedSlice();
            defer self.allocator.free(indicator);
            try self.appendTranscript(.tool, indicator);
        }
    }

    fn findTool(self: *AppState, id: []const u8) ?*ToolEntry {
        for (self.tools.items) |*tool| {
            if (std.mem.eql(u8, tool.id, id)) return tool;
        }
        return null;
    }

    pub fn upsertToolForTest(self: *AppState, id: []const u8, name: []const u8, args_json: []const u8, status: ToolStatus) !*ToolEntry {
        return try self.upsertTool(id, name, args_json, status);
    }

    fn upsertTool(self: *AppState, id: []const u8, name: []const u8, args_json: []const u8, status: ToolStatus) !*ToolEntry {
        if (self.findTool(id)) |tool| {
            tool.status = status;
            if (args_json.len > 0 and !std.mem.eql(u8, tool.args_json, args_json)) {
                self.allocator.free(tool.args_json);
                tool.args_json = try self.allocator.dupe(u8, args_json);
            }
            return tool;
        }
        try self.tools.append(self.allocator, try ToolEntry.init(self.allocator, id, name, args_json, status));
        return &self.tools.items[self.tools.items.len - 1];
    }
};

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn jsonUsize(obj: std.json.ObjectMap, key: []const u8) ?usize {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |i| if (i < 0) null else @intCast(i),
        .number_string => |s| std.fmt.parseUnsigned(usize, s, 10) catch null,
        else => null,
    };
}

fn ownedText(text: []const u8) !@import("owned_slice").OwnedSlice(u8) {
    return @import("owned_slice").OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, text));
}

test "AppState applies transcript and tool events" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    var text_event = tui_runtime.TuiEvent{ .text_delta = .{ .content_index = 0, .delta = try ownedText("hello") } };
    defer text_event.deinit(std.testing.allocator);
    try state.applyEvent(text_event);

    try std.testing.expectEqual(@as(usize, 1), state.transcript.items.len);
    try std.testing.expectEqual(TranscriptKind.assistant, state.transcript.items[0].kind);
    try std.testing.expectEqualStrings("hello", state.transcript.items[0].text.items);

    var start_event = tui_runtime.TuiEvent{ .tool_execution_start = .{
        .tool_call_id = try ownedText("call-1"),
        .tool_name = try ownedText("shell_command"),
        .args_json = try ownedText("{\"command\":\"pwd\"}"),
    } };
    defer start_event.deinit(std.testing.allocator);
    try state.applyEvent(start_event);

    var end_event = tui_runtime.TuiEvent{ .tool_execution_end = .{
        .tool_call_id = try ownedText("call-1"),
        .tool_name = try ownedText("shell_command"),
        .result_json = try ownedText("{\"ok\":true}"),
        .is_error = false,
    } };
    defer end_event.deinit(std.testing.allocator);
    try state.applyEvent(end_event);

    try std.testing.expectEqual(@as(usize, 1), state.tools.items.len);
    try std.testing.expectEqual(ToolStatus.done, state.tools.items[0].status);
    try std.testing.expect(std.mem.indexOf(u8, state.tools.items[0].output.items, "ok") != null);
}

test "AppState approval flow transitions pending to approved and rejected" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    var approval_event = tui_runtime.TuiEvent{ .tool_approval_requested = .{
        .tool_call_id = try ownedText("call-2"),
        .tool_name = try ownedText("edit_file"),
        .args_json = try ownedText("{\"path\":\"README.md\"}"),
    } };
    defer approval_event.deinit(std.testing.allocator);
    try state.applyEvent(approval_event);

    var hashline_event = tui_runtime.TuiEvent{ .tool_approval_requested = .{
        .tool_call_id = try ownedText("call-hash"),
        .tool_name = try ownedText("hashline_edit"),
        .args_json = try ownedText("{\"path\":\"src/main.zig\",\"operation\":\"replace_range\",\"start_line\":2,\"start_hash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"replacement\":\"new line\"}"),
    } };
    defer hashline_event.deinit(std.testing.allocator);
    try state.applyEvent(hashline_event);
    try std.testing.expect(std.mem.indexOf(u8, state.preview.content, "hashline edit preview") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.preview.content, "+ 2|new line") != null);

    var blank_line_event = tui_runtime.TuiEvent{ .tool_approval_requested = .{
        .tool_call_id = try ownedText("call-hash-blank"),
        .tool_name = try ownedText("hashline_edit"),
        .args_json = try ownedText("{\"path\":\"src/main.zig\",\"operation\":\"replace_range\",\"start_line\":2,\"start_hash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"replacement\":\"line1\\n\\nline3\"}"),
    } };
    defer blank_line_event.deinit(std.testing.allocator);
    try state.applyEvent(blank_line_event);
    try std.testing.expect(std.mem.indexOf(u8, state.preview.content, "+ 3|") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.preview.content, "+ 4|line3") != null);

    try std.testing.expectEqual(AppMode.approval, state.mode);
    try std.testing.expectEqual(ApprovalStatus.pending, state.approval.status);
    try std.testing.expectEqualStrings("hashline_edit", state.approval.tool_name);
    try std.testing.expectEqualStrings("call-hash-blank", state.approval.tool_call_id);

    state.setApprovalDecision(true, true);
    try std.testing.expectEqual(AppMode.normal, state.mode);
    try std.testing.expectEqual(ApprovalStatus.approved, state.approval.status);
    try std.testing.expect(state.approval.always);

    state.setApprovalDecision(false, false);
    try std.testing.expectEqual(ApprovalStatus.rejected, state.approval.status);
    try std.testing.expect(!state.approval.always);
}

test "Composer submission stores history and user transcript" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.composer.buffer.appendSlice(std.testing.allocator, " hello makai ");
    const submitted = (try state.submitComposer()).?;
    defer std.testing.allocator.free(submitted);

    try std.testing.expectEqualStrings("hello makai", submitted);
    try std.testing.expectEqual(@as(usize, 1), state.composer.history.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.transcript.items.len);
    try std.testing.expectEqual(TranscriptKind.user, state.transcript.items[0].kind);
    try std.testing.expectEqualStrings("hello makai", state.transcript.items[0].text.items);
}

test "AppState applies thinking tool call and lifecycle events" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.applyEvent(.agent_start);
    try std.testing.expect(state.status.streaming);
    try std.testing.expectEqual(TranscriptKind.system, state.transcript.items[0].kind);

    var thinking_event = tui_runtime.TuiEvent{ .thinking_delta = .{ .content_index = 0, .delta = try ownedText("plan") } };
    defer thinking_event.deinit(std.testing.allocator);
    try state.applyEvent(thinking_event);

    var call_event = tui_runtime.TuiEvent{ .tool_call_delta = .{ .content_index = 1, .delta = try ownedText("{\"name\":\"shell\"}") } };
    defer call_event.deinit(std.testing.allocator);
    try state.applyEvent(call_event);

    try std.testing.expectEqual(TranscriptKind.thinking, state.transcript.items[1].kind);
    try std.testing.expectEqualStrings("plan", state.transcript.items[1].text.items);
    try std.testing.expectEqual(TranscriptKind.tool, state.transcript.items[2].kind);
    try std.testing.expectEqualStrings("{\"name\":\"shell\"}", state.transcript.items[2].text.items);

    try state.applyEvent(tui_runtime.TuiEvent{ .agent_end = .{ .reason = .cancelled } });
    try std.testing.expect(!state.status.streaming);
    try std.testing.expectEqualStrings("agent cancelled", state.transcript.items[state.transcript.items.len - 1].text.items);
}

test "AppState appends tool execution updates" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    var update_event = tui_runtime.TuiEvent{ .tool_execution_update = .{
        .tool_call_id = try ownedText("call-3"),
        .tool_name = try ownedText("search"),
        .args_json = try ownedText("{\"query\":\"tui\"}"),
        .partial_result_json = try ownedText("{\"match\":1}"),
    } };
    defer update_event.deinit(std.testing.allocator);
    try state.applyEvent(update_event);

    try std.testing.expectEqual(@as(usize, 1), state.tools.items.len);
    try std.testing.expectEqual(ToolStatus.running, state.tools.items[0].status);
    try std.testing.expectEqualStrings("{\"match\":1}", state.tools.items[0].output.items);
}

test "AppState token counters update from context usage events" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    state.status.context_limit = 2000;

    try state.applyEvent(.{ .context_usage = .{
        .system_prompt_bytes = 100,
        .message_bytes = 300,
        .tool_definition_bytes = 200,
        .total_bytes = 600,
        .estimated_tokens = 150,
        .message_count = 4,
        .tool_count = 2,
    } });

    try std.testing.expectEqual(@as(usize, 150), state.status.context_used);
    try std.testing.expectEqual(@as(u64, 150), state.telemetry.estimated_tokens);
    try std.testing.expectEqual(@as(u64, 600), state.telemetry.total_bytes);
    try std.testing.expectEqual(@as(u64, 2000), state.telemetry.context_window);
    try std.testing.expectEqual(@as(u32, 4), state.telemetry.message_count);
}

test "AppState parses prompt segment usage events" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.applyEvent(.{ .prompt_segment_usage = .{
        .segment = .system_prompt,
        .cache_role = .stable,
        .bytes = 80,
        .estimated_tokens = 20,
        .item_count = 1,
    } });
    try state.applyEvent(.{ .prompt_segment_usage = .{
        .segment = .message_history,
        .cache_role = .dynamic,
        .bytes = 240,
        .estimated_tokens = 60,
        .item_count = 3,
    } });

    try std.testing.expect(state.telemetry.system_prompt.seen);
    try std.testing.expectEqual(@as(u64, 80), state.telemetry.system_prompt.bytes);
    try std.testing.expectEqual(tui_runtime.TuiEvent.PromptSegmentCacheRole.stable, state.telemetry.system_prompt.cache_role);
    try std.testing.expect(state.telemetry.messages.seen);
    try std.testing.expectEqual(@as(u64, 60), state.telemetry.messages.estimated_tokens);
    try std.testing.expectEqual(tui_runtime.TuiEvent.PromptSegmentCacheRole.dynamic, state.telemetry.messages.cache_role);
}

test "AppState detects truncated tool execution end events" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    var end_event = tui_runtime.TuiEvent{ .tool_execution_end = .{
        .tool_call_id = try ownedText("call-trunc"),
        .tool_name = try ownedText("shell_command"),
        .result_json = try ownedText("{\"summary\":true}"),
        .is_error = false,
        .raw_total_bytes = 4096,
        .returned_total_bytes = 512,
        .estimated_returned_tokens = 128,
        .artifact_count = 1,
        .artifact_refs = try ownedText("artifact://tool-output/1"),
    } };
    defer end_event.deinit(std.testing.allocator);
    try state.applyEvent(end_event);

    try std.testing.expectEqual(@as(usize, 1), state.tools.items.len);
    try std.testing.expect(state.tools.items[0].truncated);
    try std.testing.expectEqual(@as(u64, 4096), state.tools.items[0].raw_total_bytes);
    try std.testing.expectEqualStrings("artifact://tool-output/1", state.tools.items[0].artifact_refs);
    try std.testing.expect(std.mem.indexOf(u8, state.transcript.items[state.transcript.items.len - 1].text.items, "show full") != null);
}
