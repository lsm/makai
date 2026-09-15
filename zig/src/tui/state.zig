const std = @import("std");
const agent = @import("agent");
const ai_types = @import("ai_types");
const tui_runtime = @import("tui_runtime");
const compat = @import("compat");

pub const AppMode = enum {
    normal,
    approval,
    session_picker,
    picker,
    login_input,
};

pub const PickerKind = enum {
    model,
    login,
    permission,
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
    interrupted,
};

pub const ApprovalStatus = enum {
    none,
    pending,
    approved,
    rejected,
};

pub const TranscriptEntry = struct {
    kind: TranscriptKind,
    text: std.ArrayList(u8) = .empty,
    timestamp_ms: i64 = 0,
    tool_summary: bool = false,
    tool_call_id: []u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, kind: TranscriptKind, text: []const u8) !TranscriptEntry {
        var entry = TranscriptEntry{ .kind = kind, .timestamp_ms = compat.time.nowMillis() };
        try entry.text.appendSlice(allocator, text);
        return entry;
    }

    pub fn deinit(self: *TranscriptEntry, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        if (self.tool_call_id.len > 0) allocator.free(self.tool_call_id);
        self.* = undefined;
    }
};

pub const RegisteredToolEntry = struct {
    name: []u8,
    label: []u8,
    short_description: []u8,

    pub fn init(allocator: std.mem.Allocator, tool: agent.AgentTool) !RegisteredToolEntry {
        const name = try allocator.dupe(u8, tool.name);
        errdefer allocator.free(name);
        const label = try allocator.dupe(u8, tool.label);
        errdefer allocator.free(label);
        const short_description = try allocator.dupe(u8, tool.short_description orelse "");
        errdefer allocator.free(short_description);
        return .{
            .name = name,
            .label = label,
            .short_description = short_description,
        };
    }

    pub fn deinit(self: *RegisteredToolEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.label);
        allocator.free(self.short_description);
        self.* = undefined;
    }
};

pub const ToolEntry = struct {
    id: []u8,
    name: []u8,
    label: []u8,
    args_json: []u8,
    output: std.ArrayList(u8) = .empty,
    status: ToolStatus = .pending,
    raw_total_bytes: u64 = 0,
    returned_total_bytes: u64 = 0,
    estimated_returned_tokens: u64 = 0,
    artifact_count: u32 = 0,
    artifact_refs: []u8 = &.{},
    truncated: bool = false,
    error_detail_readable: bool = false,

    pub fn init(allocator: std.mem.Allocator, id: []const u8, name: []const u8, label: []const u8, args_json: []const u8, status: ToolStatus) !ToolEntry {
        return .{
            .id = try allocator.dupe(u8, id),
            .name = try allocator.dupe(u8, name),
            .label = try allocator.dupe(u8, label),
            .args_json = try allocator.dupe(u8, args_json),
            .status = status,
        };
    }

    pub fn deinit(self: *ToolEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.label);
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
    scope_hint: []u8 = &.{},
    always: bool = false,

    pub fn deinit(self: *ApprovalState, allocator: std.mem.Allocator) void {
        if (self.tool_call_id.len > 0) allocator.free(self.tool_call_id);
        if (self.tool_name.len > 0) allocator.free(self.tool_name);
        if (self.args_json.len > 0) allocator.free(self.args_json);
        if (self.scope_hint.len > 0) allocator.free(self.scope_hint);
        self.* = .{};
    }

    pub fn setPending(self: *ApprovalState, allocator: std.mem.Allocator, tool_call_id: []const u8, tool_name: []const u8, display_name: []const u8, args_json: []const u8) !void {
        self.deinit(allocator);
        const scope_hint = try approvalScopeHint(allocator, display_name, args_json);
        errdefer allocator.free(scope_hint);
        self.* = .{
            .status = .pending,
            .tool_call_id = try allocator.dupe(u8, tool_call_id),
            .tool_name = try allocator.dupe(u8, tool_name),
            .args_json = try allocator.dupe(u8, args_json),
            .scope_hint = scope_hint,
        };
    }
};

pub const TelemetryState = struct {
    estimated_tokens: u64 = 0,
    context_window: u64 = 0,
};

pub const QueueState = tui_runtime.QueuedCounts;

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

    pub fn setSessionId(self: *StatusState, allocator: std.mem.Allocator, session_id: []const u8) !void {
        const new_session_id = try allocator.dupe(u8, session_id);
        if (self.session_id.len > 0) allocator.free(self.session_id);
        self.session_id = new_session_id;
    }
};

pub const PreviewState = struct {
    content: []u8 = &.{},

    pub fn deinit(self: *PreviewState, allocator: std.mem.Allocator) void {
        if (self.content.len > 0) allocator.free(self.content);
        self.* = .{};
    }

    pub fn set(self: *PreviewState, allocator: std.mem.Allocator, content: []const u8) !void {
        const owned = try allocator.dupe(u8, content);
        self.deinit(allocator);
        self.* = .{ .content = owned };
    }
};

pub const SessionEntry = struct {
    id: []u8,
    label: []u8,

    pub fn init(allocator: std.mem.Allocator, id: []const u8, label: []const u8) !SessionEntry {
        const owned_id = try allocator.dupe(u8, id);
        errdefer allocator.free(owned_id);
        const owned_label = try allocator.dupe(u8, label);
        return .{ .id = owned_id, .label = owned_label };
    }

    pub fn deinit(self: *SessionEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        self.* = undefined;
    }
};

pub const ComposerState = struct {
    buffer: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    history: std.ArrayList([]u8) = .empty,
    history_index: ?usize = null,
    history_draft: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *ComposerState, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
        for (self.history.items) |item| allocator.free(item);
        self.history.deinit(allocator);
        self.history_draft.deinit(allocator);
        self.* = undefined;
    }

    pub fn clear(self: *ComposerState) void {
        self.buffer.clearRetainingCapacity();
        self.cursor = 0;
        self.history_index = null;
        self.history_draft.clearRetainingCapacity();
    }

    pub fn text(self: ComposerState) []const u8 {
        return self.buffer.items;
    }

    pub fn normalizeCursor(self: *ComposerState) void {
        self.cursor = utf8BoundaryAtOrBefore(self.buffer.items, @min(self.cursor, self.buffer.items.len));
    }

    pub fn insertSlice(self: *ComposerState, allocator: std.mem.Allocator, bytes: []const u8) !void {
        self.normalizeCursor();
        try self.buffer.insertSlice(allocator, self.cursor, bytes);
        self.cursor += bytes.len;
    }

    pub fn deleteBeforeCursor(self: *ComposerState) bool {
        self.normalizeCursor();
        if (self.cursor == 0) return false;
        const start = previousCodepointStart(self.buffer.items, self.cursor);
        const removed = self.cursor - start;
        std.mem.copyForwards(u8, self.buffer.items[start..], self.buffer.items[self.cursor..]);
        self.buffer.shrinkRetainingCapacity(self.buffer.items.len - removed);
        self.cursor = start;
        return true;
    }

    pub fn moveCursorPrev(self: *ComposerState) bool {
        self.normalizeCursor();
        if (self.cursor == 0) return false;
        self.cursor = previousCodepointStart(self.buffer.items, self.cursor);
        return true;
    }

    pub fn moveCursorNext(self: *ComposerState) bool {
        self.normalizeCursor();
        if (self.cursor >= self.buffer.items.len) return false;
        self.cursor = nextCodepointEnd(self.buffer.items, self.cursor);
        return true;
    }

    pub fn moveCursorHome(self: *ComposerState) void {
        self.cursor = 0;
    }

    pub fn moveCursorEnd(self: *ComposerState) void {
        self.cursor = self.buffer.items.len;
    }
};

fn previousCodepointStart(text: []const u8, cursor: usize) usize {
    if (cursor == 0) return 0;
    var idx = @min(cursor, text.len) - 1;
    while (idx > 0 and (text[idx] & 0b1100_0000) == 0b1000_0000) idx -= 1;
    return idx;
}

fn nextCodepointEnd(text: []const u8, cursor: usize) usize {
    const idx = utf8BoundaryAtOrBefore(text, @min(cursor, text.len));
    if (idx >= text.len) return text.len;
    const len = std.unicode.utf8ByteSequenceLength(text[idx]) catch 1;
    return @min(text.len, idx + len);
}

fn utf8BoundaryAtOrBefore(text: []const u8, index: usize) usize {
    var idx = @min(index, text.len);
    while (idx > 0 and idx < text.len and (text[idx] & 0b1100_0000) == 0b1000_0000) idx -= 1;
    return idx;
}

const max_hashline_preview_bytes: usize = 20 * 1024;
const hashline_preview_truncated_marker = "\n... preview truncated ...\n";

pub const AppState = struct {
    allocator: std.mem.Allocator,
    mode: AppMode = .normal,
    transcript: std.ArrayList(TranscriptEntry) = .empty,
    registered_tools: std.ArrayList(RegisteredToolEntry) = .empty,
    tools: std.ArrayList(ToolEntry) = .empty,
    sessions: std.ArrayList(SessionEntry) = .empty,
    composer: ComposerState = .{},
    approval: ApprovalState = .{},
    permission_mode: tui_runtime.PermissionMode = .bypass,
    status: StatusState = .{},
    queue: QueueState = .{},
    telemetry: TelemetryState = .{},
    preview: PreviewState = .{},
    thinking_level: ai_types.ThinkingLevel = .low,
    login_input_secret: bool = false,
    anim_tick: u64 = 0,
    transcript_scroll: usize = 0,
    session_index: usize = 0,
    session_scroll: usize = 0,
    menu_index: usize = 0,
    menu_scroll: usize = 0,
    picker_kind: PickerKind = .model,
    active_user_entry: ?usize = null,
    active_assistant_entry: ?usize = null,
    active_tool_result_entry: ?usize = null,
    active_tool_summary_entry: ?usize = null,
    last_tool_calls_json: []u8 = &.{},
    stream_aborted: bool = false,
    dropped_event_count: u64 = 0,
    backpressure_active: bool = false,
    pending_steers: std.ArrayList([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) AppState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AppState) void {
        for (self.transcript.items) |*entry| entry.deinit(self.allocator);
        self.transcript.deinit(self.allocator);
        for (self.registered_tools.items) |*tool| tool.deinit(self.allocator);
        self.registered_tools.deinit(self.allocator);
        for (self.tools.items) |*tool| tool.deinit(self.allocator);
        self.tools.deinit(self.allocator);
        for (self.sessions.items) |*session| session.deinit(self.allocator);
        self.sessions.deinit(self.allocator);
        self.composer.deinit(self.allocator);
        self.approval.deinit(self.allocator);
        self.status.deinit(self.allocator);
        self.preview.deinit(self.allocator);
        self.clearPendingSteers();
        self.pending_steers.deinit(self.allocator);
        if (self.last_tool_calls_json.len > 0) self.allocator.free(self.last_tool_calls_json);
        self.* = undefined;
    }

    pub fn appendTranscript(self: *AppState, kind: TranscriptKind, text: []const u8) !void {
        try self.transcript.append(self.allocator, try TranscriptEntry.init(self.allocator, kind, text));
    }

    pub fn appendToolSummaryTranscript(self: *AppState, text: []const u8, tool_call_id: []const u8) !void {
        var entry = try TranscriptEntry.init(self.allocator, .tool, text);
        errdefer entry.deinit(self.allocator);
        entry.tool_summary = true;
        if (tool_call_id.len > 0) entry.tool_call_id = try self.allocator.dupe(u8, tool_call_id);
        try self.transcript.append(self.allocator, entry);
    }

    pub fn setRegisteredTools(self: *AppState, tools: []const agent.AgentTool) !void {
        for (self.registered_tools.items) |*tool| tool.deinit(self.allocator);
        self.registered_tools.clearRetainingCapacity();
        try self.registered_tools.ensureTotalCapacity(self.allocator, tools.len);
        for (tools) |tool| self.registered_tools.appendAssumeCapacity(try RegisteredToolEntry.init(self.allocator, tool));
    }

    pub fn toolLabel(self: *const AppState, name: []const u8) []const u8 {
        for (self.registered_tools.items) |tool| {
            if (std.mem.eql(u8, tool.name, name)) return tool.label;
        }
        return name;
    }

    pub fn clearTranscript(self: *AppState) void {
        for (self.transcript.items) |*entry| entry.deinit(self.allocator);
        self.transcript.clearRetainingCapacity();
        self.transcript_scroll = 0;
        self.clearActiveTranscriptEntries();
        self.clearPendingSteers();
    }

    pub fn lastAssistantText(self: *const AppState) ?[]const u8 {
        var i = self.transcript.items.len;
        while (i > 0) {
            i -= 1;
            if (self.transcript.items[i].kind == .assistant) {
                return self.transcript.items[i].text.items;
            }
        }
        return null;
    }

    pub fn clearTools(self: *AppState) void {
        for (self.tools.items) |*tool| tool.deinit(self.allocator);
        self.tools.clearRetainingCapacity();
    }

    pub fn resetReplayState(self: *AppState) void {
        self.clearTranscript();
        self.clearTools();
        self.telemetry = .{};
        self.queue = .{};
        self.status.context_used = 0;
        self.status.turn_count = 0;
        self.status.streaming = false;
        self.stream_aborted = false;
        if (self.status.last_error.len > 0) {
            self.allocator.free(self.status.last_error);
            self.status.last_error = &.{};
        }
        self.dropped_event_count = 0;
        self.backpressure_active = false;
        if (self.last_tool_calls_json.len > 0) {
            self.allocator.free(self.last_tool_calls_json);
            self.last_tool_calls_json = &.{};
        }
    }

    pub fn appendUserMessage(self: *AppState, text: []const u8) !void {
        try self.appendTranscript(.user, text);
    }

    pub fn appendSteeredMessage(self: *AppState, text: []const u8) !void {
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.pending_steers.append(self.allocator, owned);
        errdefer _ = self.pending_steers.pop();
        try self.appendUserMessage(text);
        if (self.active_user_entry) |index| {
            if (index < self.transcript.items.len and self.transcript.items[index].kind == .user) return;
        }
        self.active_user_entry = self.transcript.items.len - 1;
    }

    pub fn takePendingSteer(self: *AppState, text: []const u8) bool {
        if (self.pending_steers.items.len == 0) return false;
        if (!std.mem.eql(u8, self.pending_steers.items[0], text)) return false;
        const matched = self.pending_steers.orderedRemove(0);
        self.allocator.free(matched);
        return true;
    }

    pub fn clearPendingSteers(self: *AppState) void {
        for (self.pending_steers.items) |pending| self.allocator.free(pending);
        self.pending_steers.clearRetainingCapacity();
    }

    pub fn submitComposer(self: *AppState) !?[]u8 {
        const raw = std.mem.trim(u8, self.composer.buffer.items, " \t\r\n");
        if (raw.len == 0) {
            self.composer.clear();
            return null;
        }
        const submitted = try self.allocator.dupe(u8, raw);
        errdefer self.allocator.free(submitted);
        try self.recordComposerHistory(submitted);
        self.composer.clear();
        try self.appendUserMessage(submitted);
        return submitted;
    }

    pub fn recordComposerHistory(self: *AppState, text: []const u8) !void {
        const raw = std.mem.trim(u8, text, " \t\r\n");
        if (raw.len == 0) return;
        try self.composer.history.append(self.allocator, try self.allocator.dupe(u8, raw));
        self.composer.history_index = null;
        self.composer.history_draft.clearRetainingCapacity();
    }

    pub fn replaceComposerBuffer(self: *AppState, text: []const u8) !void {
        self.composer.buffer.clearRetainingCapacity();
        try self.composer.buffer.appendSlice(self.allocator, text);
        self.composer.cursor = self.composer.buffer.items.len;
    }

    pub fn composerHistoryPrev(self: *AppState) !bool {
        if (self.composer.history.items.len == 0) return false;
        if (self.composer.history_index) |index| {
            if (index == 0) return false;
            const next_index = index - 1;
            self.composer.history_index = next_index;
            try self.replaceComposerBuffer(self.composer.history.items[next_index]);
            return true;
        }
        self.composer.history_draft.clearRetainingCapacity();
        try self.composer.history_draft.appendSlice(self.allocator, self.composer.buffer.items);
        const next_index = self.composer.history.items.len - 1;
        self.composer.history_index = next_index;
        try self.replaceComposerBuffer(self.composer.history.items[next_index]);
        return true;
    }

    pub fn composerHistoryNext(self: *AppState) !bool {
        const current = self.composer.history_index orelse return false;
        if (current + 1 >= self.composer.history.items.len) {
            self.composer.history_index = null;
            try self.replaceComposerBuffer(self.composer.history_draft.items);
            self.composer.history_draft.clearRetainingCapacity();
            return true;
        }
        const next_index = current + 1;
        self.composer.history_index = next_index;
        try self.replaceComposerBuffer(self.composer.history.items[next_index]);
        return true;
    }

    pub fn cycleThinkingLevel(self: *AppState) ai_types.ThinkingLevel {
        self.thinking_level = switch (self.thinking_level) {
            .off, .minimal => .low,
            .low => .medium,
            .medium => .high,
            .high => .xhigh,
            .xhigh => .off,
        };
        return self.thinking_level;
    }

    pub fn setQueuedCounts(self: *AppState, counts: tui_runtime.QueuedCounts) void {
        self.queue = counts;
    }

    pub fn applyEvent(self: *AppState, event: tui_runtime.TuiEvent) !void {
        if (self.stream_aborted) switch (event) {
            .turn_end, .agent_end, .@"error", .system_warning, .backpressure_status => {},
            else => return,
        };
        switch (event) {
            .agent_start => {
                self.status.streaming = true;
            },
            .turn_start => {
                self.status.streaming = true;
                self.status.turn_count += 1;
                self.cleanupActiveTranscriptEntries();
            },
            .message_start => |payload| switch (payload.role) {
                .assistant => self.active_assistant_entry = try self.appendEmptyTranscript(.assistant),
                .user => self.active_user_entry = try self.ensureTrailingEntry(.user),
                .tool_result => self.active_tool_result_entry = try self.appendEmptyTranscript(.tool),
            },
            .text_delta => |payload| try self.appendDelta(.assistant, payload.delta.slice()),
            .thinking_delta => |payload| try self.appendDelta(.thinking, payload.delta.slice()),
            .tool_call_delta => {},
            .provider_event => {},
            .message_end => |payload| switch (payload.role) {
                .assistant => {
                    try self.finishTranscriptEntry(.assistant, payload.text.slice(), &self.active_assistant_entry);
                    try self.rememberToolCalls(payload.tool_calls_json.slice());
                },
                .user => try self.finishTranscriptEntryWithOptions(.user, payload.text.slice(), &self.active_user_entry, true),
                .tool_result => {
                    const suppress_text = if (self.findTool(payload.tool_call_id.slice())) |tool| tool.status == .@"error" and tool.error_detail_readable else false;
                    try self.finishToolResultEntry(if (suppress_text) "" else payload.text.slice(), payload.tool_call_id.slice());
                },
            },
            .tool_approval_requested => |payload| {
                const label = self.toolLabel(payload.tool_name.slice());
                try self.approval.setPending(self.allocator, payload.tool_call_id.slice(), payload.tool_name.slice(), label, payload.args_json.slice());
                if (std.mem.eql(u8, payload.tool_name.slice(), "hashline_edit")) try self.setHashlinePreview(payload.args_json.slice());
                self.mode = .approval;
                _ = try self.upsertTool(payload.tool_call_id.slice(), payload.tool_name.slice(), payload.args_json.slice(), .pending);
            },
            .tool_execution_start => |payload| {
                const tool = try self.upsertTool(payload.tool_call_id.slice(), payload.tool_name.slice(), payload.args_json.slice(), .running);
                const summary = try toolInvocation(self.allocator, tool.label, payload.args_json.slice());
                defer self.allocator.free(summary);
                try self.appendToolSummaryTranscript(summary, payload.tool_call_id.slice());
                self.active_tool_summary_entry = self.transcript.items.len - 1;
            },
            .tool_execution_update => |payload| {
                const tool = try self.upsertTool(payload.tool_call_id.slice(), payload.tool_name.slice(), payload.args_json.slice(), .running);
                if (tool.output.items.len > 0) try tool.output.append(self.allocator, '\n');
                try tool.output.appendSlice(self.allocator, payload.partial_result_json.slice());
            },
            .tool_execution_end => |payload| {
                const status: ToolStatus = if (payload.is_error) .@"error" else .done;
                const tool = try self.upsertTool(payload.tool_call_id.slice(), payload.tool_name.slice(), "", status);
                if (tool.args_json.len == 0) {
                    if (try self.recoverToolArgs(tool.id)) |args| {
                        self.allocator.free(tool.args_json);
                        tool.args_json = args;
                    }
                }
                if (tool.output.items.len > 0) try tool.output.append(self.allocator, '\n');
                try tool.output.appendSlice(self.allocator, payload.result_json.slice());
                try self.applyToolTelemetry(tool, payload.raw_total_bytes, payload.returned_total_bytes, payload.estimated_returned_tokens, payload.artifact_count, payload.artifact_refs.slice());
                const summary = try toolResultSummary(self.allocator, tool.label, tool.args_json, payload.result_json.slice(), payload.is_error, payload.raw_total_bytes, payload.returned_total_bytes, payload.estimated_returned_tokens, payload.artifact_count);
                defer self.allocator.free(summary);
                try self.finalizeToolSummaryEntry(summary, tool.id);
                tool.error_detail_readable = false;
                if (payload.is_error) {
                    const unwrapped = try toolErrorMessage(self.allocator, payload.result_json.slice());
                    defer if (unwrapped) |message| self.allocator.free(message);
                    tool.error_detail_readable = unwrapped != null;
                    const raw_detail = if (unwrapped) |message| message else payload.result_json.slice();
                    const detail = try sanitizeTerminalText(self.allocator, raw_detail);
                    defer self.allocator.free(detail);
                    const message = try std.fmt.allocPrint(self.allocator, "{s} failed: {s}", .{ tool.label, detail });
                    defer self.allocator.free(message);
                    try self.status.setError(self.allocator, message);
                    try self.appendTranscript(.@"error", message);
                }
            },
            .context_usage => |payload| self.applyContextUsage(payload),
            .prompt_segment_usage => {},
            .system_warning => |payload| try self.appendTranscript(.@"error", payload.message.slice()),
            .backpressure_status => |payload| {
                self.backpressure_active = payload.active;
                self.dropped_event_count = payload.dropped_count;
            },
            .turn_end => {
                self.status.streaming = false;
                self.stream_aborted = false;
                self.cleanupActiveTranscriptEntries();
            },
            .agent_end => |payload| {
                self.status.streaming = false;
                self.stream_aborted = false;
                try self.finalizeInterruptedTools();
                switch (payload.reason) {
                    .completed => {},
                    .cancelled => try self.appendTranscript(.system, "agent cancelled"),
                    .@"error" => {
                        if (self.status.last_error.len == 0) {
                            try self.status.setError(self.allocator, "agent ended with error, but no error details were provided");
                            try self.appendTranscript(.@"error", self.status.last_error);
                        }
                    },
                }
            },
            .@"error" => |payload| {
                self.cleanupActiveTranscriptEntries();
                self.stream_aborted = false;
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


    pub fn addSession(self: *AppState, id: []const u8, label: []const u8) !void {
        var entry = try SessionEntry.init(self.allocator, id, label);
        errdefer entry.deinit(self.allocator);
        try self.sessions.append(self.allocator, entry);
    }

    fn setHashlinePreview(self: *AppState, args_json: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, args_json, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const obj = parsed.value.object;
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
        try appendHashlinePreview(&out, self.allocator, header);
        if (std.mem.eql(u8, operation, "delete_range")) {
            const row = try std.fmt.allocPrint(self.allocator, "- lines {d}..{d}\n", .{ start_line, end_line });
            defer self.allocator.free(row);
            try appendHashlinePreview(&out, self.allocator, row);
        } else {
            var line_no: usize = if (std.mem.eql(u8, operation, "insert_after")) end_line + 1 else start_line;
            var lines = std.mem.splitScalar(u8, replacement, '\n');
            while (lines.next()) |line| {
                if (line.len == 0 and line.ptr == replacement.ptr + replacement.len) break;
                const row = try std.fmt.allocPrint(self.allocator, "+ {d}|{s}\n", .{ line_no, line });
                defer self.allocator.free(row);
                try appendHashlinePreview(&out, self.allocator, row);
                line_no += 1;
                if (out.items.len >= max_hashline_preview_bytes) {
                    try markHashlinePreviewTruncated(&out);
                    break;
                }
            }
        }
        try self.preview.set(self.allocator, out.items);
    }

    fn ensureTrailingEntry(self: *AppState, kind: TranscriptKind) !usize {
        if (self.transcript.items.len == 0 or self.transcript.items[self.transcript.items.len - 1].kind != kind) {
            return try self.appendEmptyTranscript(kind);
        }
        return self.transcript.items.len - 1;
    }

    fn appendEmptyTranscript(self: *AppState, kind: TranscriptKind) !usize {
        try self.appendTranscript(kind, "");
        return self.transcript.items.len - 1;
    }

    fn appendDelta(self: *AppState, kind: TranscriptKind, delta: []const u8) !void {
        const index = switch (kind) {
            .assistant => try self.activeOrTrailingEntry(kind, &self.active_assistant_entry),
            else => try self.ensureTrailingEntry(kind),
        };
        try self.transcript.items[index].text.appendSlice(self.allocator, delta);
    }

    fn activeOrTrailingEntry(self: *AppState, kind: TranscriptKind, active_entry: *?usize) !usize {
        if (active_entry.*) |index| {
            if (index < self.transcript.items.len and self.transcript.items[index].kind == kind) return index;
            active_entry.* = null;
        }
        const index = try self.ensureTrailingEntry(kind);
        active_entry.* = index;
        return index;
    }

    fn finishTranscriptEntry(self: *AppState, kind: TranscriptKind, text: []const u8, active_entry: ?*?usize) !void {
        return self.finishTranscriptEntryWithOptions(kind, text, active_entry, false);
    }

    fn finishTranscriptEntryWithOptions(self: *AppState, kind: TranscriptKind, text: []const u8, active_entry: ?*?usize, dedupe_trailing: bool) !void {
        if (text.len == 0) {
            if (active_entry) |entry| {
                if (entry.*) |index| {
                    if (index < self.transcript.items.len and self.transcript.items[index].kind == kind and self.transcript.items[index].text.items.len == 0) {
                        self.removeTranscriptEntry(index);
                    }
                }
                entry.* = null;
            }
            return;
        }

        if (active_entry) |entry| {
            if (entry.*) |index| {
                if (index < self.transcript.items.len and self.transcript.items[index].kind == kind) {
                    try self.replaceEntryText(index, text);
                    entry.* = null;
                    return;
                }
            }
            entry.* = null;
        }

        if (dedupe_trailing and self.transcript.items.len > 0 and self.transcript.items[self.transcript.items.len - 1].kind == kind and std.mem.eql(u8, self.transcript.items[self.transcript.items.len - 1].text.items, text)) return;
        try self.appendTranscript(kind, text);
    }

    fn clearActiveTranscriptEntries(self: *AppState) void {
        self.active_user_entry = null;
        self.active_assistant_entry = null;
        self.active_tool_result_entry = null;
        self.active_tool_summary_entry = null;
    }

    fn cleanupActiveTranscriptEntries(self: *AppState) void {
        self.removeEmptyActiveTranscriptEntry(&self.active_user_entry, .user);
        self.removeEmptyActiveTranscriptEntry(&self.active_assistant_entry, .assistant);
        self.removeEmptyActiveTranscriptEntry(&self.active_tool_result_entry, .tool);
        self.removeEmptyActiveTranscriptEntry(&self.active_tool_summary_entry, .tool);
        self.clearActiveTranscriptEntries();
    }

    fn finalizeToolSummaryEntry(self: *AppState, summary: []const u8, tool_call_id: []const u8) !void {
        if (self.active_tool_summary_entry) |index| {
            self.active_tool_summary_entry = null;
            if (index < self.transcript.items.len and self.transcript.items[index].kind == .tool) {
                try self.replaceEntryText(index, summary);
                try self.setEntryToolId(index, tool_call_id);
                return;
            }
        }
        try self.appendToolSummaryTranscript(summary, tool_call_id);
    }

    fn removeEmptyActiveTranscriptEntry(self: *AppState, active_entry: *?usize, kind: TranscriptKind) void {
        if (active_entry.*) |index| {
            if (index < self.transcript.items.len and self.transcript.items[index].kind == kind and self.transcript.items[index].text.items.len == 0) {
                self.removeTranscriptEntry(index);
            }
        }
    }

    fn removeTranscriptEntry(self: *AppState, index: usize) void {
        var entry = self.transcript.orderedRemove(index);
        entry.deinit(self.allocator);
        self.adjustActiveTranscriptEntryAfterRemove(&self.active_user_entry, index);
        self.adjustActiveTranscriptEntryAfterRemove(&self.active_assistant_entry, index);
        self.adjustActiveTranscriptEntryAfterRemove(&self.active_tool_result_entry, index);
        self.adjustActiveTranscriptEntryAfterRemove(&self.active_tool_summary_entry, index);
    }

    fn adjustActiveTranscriptEntryAfterRemove(self: *AppState, active_entry: *?usize, removed_index: usize) void {
        _ = self;
        if (active_entry.*) |index| {
            active_entry.* = if (index == removed_index) null else if (index > removed_index) index - 1 else index;
        }
    }

    fn replaceEntryText(self: *AppState, index: usize, text: []const u8) !void {
        const entry = &self.transcript.items[index];
        if (std.mem.eql(u8, entry.text.items, text)) return;
        entry.text.clearRetainingCapacity();
        try entry.text.appendSlice(self.allocator, text);
    }

    fn applyContextUsage(self: *AppState, payload: anytype) void {
        self.telemetry.estimated_tokens = payload.estimated_tokens;
        self.telemetry.context_window = self.status.context_limit;
        self.status.context_used = @intCast(payload.estimated_tokens);
    }

    fn applyToolTelemetry(self: *AppState, tool: *ToolEntry, raw_total_bytes: u64, returned_total_bytes: u64, estimated_returned_tokens: u64, artifact_count: u32, artifact_refs: []const u8) !void {
        tool.raw_total_bytes = raw_total_bytes;
        tool.returned_total_bytes = returned_total_bytes;
        tool.estimated_returned_tokens = estimated_returned_tokens;
        tool.artifact_count = artifact_count;
        tool.truncated = raw_total_bytes > returned_total_bytes or artifact_count > 0;
        if (tool.artifact_refs.len > 0) self.allocator.free(tool.artifact_refs);
        tool.artifact_refs = try self.allocator.dupe(u8, artifact_refs);
    }

    fn findTool(self: *AppState, id: []const u8) ?*ToolEntry {
        for (self.tools.items) |*tool| {
            if (std.mem.eql(u8, tool.id, id)) return tool;
        }
        return null;
    }

    pub fn lookupTool(self: *const AppState, id: []const u8) ?*const ToolEntry {
        for (self.tools.items) |*tool| {
            if (std.mem.eql(u8, tool.id, id)) return tool;
        }
        return null;
    }

    pub fn finalizeInterruptedTools(self: *AppState) !void {
        self.cleanupActiveTranscriptEntries();
        for (self.tools.items) |*tool| {
            if (tool.status != .pending and tool.status != .running) continue;
            tool.status = .interrupted;
            const invocation = try toolInvocation(self.allocator, tool.label, tool.args_json);
            defer self.allocator.free(invocation);
            const message = try std.fmt.allocPrint(self.allocator, "{s} interrupted", .{invocation});
            defer self.allocator.free(message);
            var i = self.transcript.items.len;
            while (i > 0) {
                i -= 1;
                const entry = &self.transcript.items[i];
                if (entry.kind != .tool or !entry.tool_summary) continue;
                if (!std.mem.eql(u8, entry.tool_call_id, tool.id)) continue;
                try self.replaceEntryText(i, message);
                break;
            }
        }
    }

    fn rememberToolCalls(self: *AppState, tool_calls_json: []const u8) !void {
        if (tool_calls_json.len == 0) return;
        const owned = try self.allocator.dupe(u8, tool_calls_json);
        if (self.last_tool_calls_json.len > 0) self.allocator.free(self.last_tool_calls_json);
        self.last_tool_calls_json = owned;
    }

    fn recoverToolArgs(self: *AppState, tool_call_id: []const u8) !?[]u8 {
        if (self.last_tool_calls_json.len == 0 or tool_call_id.len == 0) return null;
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, self.last_tool_calls_json, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .array) return null;
        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const id = jsonString(item.object, "id") orelse continue;
            if (!std.mem.eql(u8, id, tool_call_id)) continue;
            const args = jsonString(item.object, "arguments_json") orelse return null;
            if (args.len == 0) return null;
            return try self.allocator.dupe(u8, args);
        }
        return null;
    }

    fn finishToolResultEntry(self: *AppState, text: []const u8, tool_call_id: []const u8) !void {
        if (text.len == 0) {
            if (self.active_tool_result_entry) |index| {
                if (index < self.transcript.items.len and self.transcript.items[index].kind == .tool and self.transcript.items[index].text.items.len == 0) {
                    self.removeTranscriptEntry(index);
                }
                self.active_tool_result_entry = null;
            }
            return;
        }
        if (self.active_tool_result_entry) |index| {
            if (index < self.transcript.items.len and self.transcript.items[index].kind == .tool) {
                try self.replaceEntryText(index, text);
                try self.setEntryToolId(index, tool_call_id);
                self.active_tool_result_entry = null;
                return;
            }
            self.active_tool_result_entry = null;
        }
        try self.appendTranscript(.tool, text);
        try self.setEntryToolId(self.transcript.items.len - 1, tool_call_id);
    }

    fn setEntryToolId(self: *AppState, index: usize, tool_call_id: []const u8) !void {
        if (tool_call_id.len == 0) return;
        const entry = &self.transcript.items[index];
        if (std.mem.eql(u8, entry.tool_call_id, tool_call_id)) return;
        const owned = try self.allocator.dupe(u8, tool_call_id);
        if (entry.tool_call_id.len > 0) self.allocator.free(entry.tool_call_id);
        entry.tool_call_id = owned;
    }

    pub fn upsertToolForTest(self: *AppState, id: []const u8, name: []const u8, args_json: []const u8, status: ToolStatus) !*ToolEntry {
        return try self.upsertTool(id, name, args_json, status);
    }

    fn upsertTool(self: *AppState, id: []const u8, name: []const u8, args_json: []const u8, status: ToolStatus) !*ToolEntry {
        const label = self.toolLabel(name);
        if (self.findTool(id)) |tool| {
            tool.status = status;
            if (!std.mem.eql(u8, tool.label, label)) {
                self.allocator.free(tool.label);
                tool.label = try self.allocator.dupe(u8, label);
            }
            if (args_json.len > 0 and !std.mem.eql(u8, tool.args_json, args_json)) {
                self.allocator.free(tool.args_json);
                tool.args_json = try self.allocator.dupe(u8, args_json);
            }
            return tool;
        }
        try self.tools.append(self.allocator, try ToolEntry.init(self.allocator, id, name, label, args_json, status));
        return &self.tools.items[self.tools.items.len - 1];
    }
};

fn approvalScopeHint(allocator: std.mem.Allocator, tool_name: []const u8, args_json: []const u8) ![]u8 {
    const safe_tool_name = try sanitizeTerminalText(allocator, tool_name);
    defer allocator.free(safe_tool_name);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch return std.fmt.allocPrint(allocator, "{s} (one tool call)", .{safe_tool_name});
    defer parsed.deinit();
    if (parsed.value != .object) return std.fmt.allocPrint(allocator, "{s} (one tool call)", .{safe_tool_name});
    const obj = parsed.value.object;
    if (firstJsonString(obj, &.{ "path", "file_path", "target_path", "cwd" })) |path| {
        const safe_path = try sanitizeTerminalText(allocator, path);
        defer allocator.free(safe_path);
        return std.fmt.allocPrint(allocator, "{s} path {s}", .{ safe_tool_name, safe_path });
    }
    if (firstJsonString(obj, &.{ "command", "cmd", "script" })) |command| {
        const safe_command = try sanitizeTerminalText(allocator, command);
        defer allocator.free(safe_command);
        return std.fmt.allocPrint(allocator, "{s} command {s}", .{ safe_tool_name, safe_command });
    }
    return std.fmt.allocPrint(allocator, "{s} (one tool call)", .{safe_tool_name});
}

fn sanitizeTerminalText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        switch (c) {
            '\n', '\r', '\t' => {
                try writer.writeByte(' ');
                i += 1;
                continue;
            },
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {
                i += 1;
                continue;
            },
            else => {},
        }
        const len = std.unicode.utf8ByteSequenceLength(c) catch {
            i += 1;
            continue;
        };
        if (i + len > text.len) break;
        const codepoint = std.unicode.utf8Decode(text[i .. i + len]) catch {
            i += 1;
            continue;
        };
        if (codepoint < 0x20 or codepoint == 0x7f or (codepoint >= 0x80 and codepoint <= 0x9f)) {
            i += len;
            continue;
        }
        try writer.writeAll(text[i .. i + len]);
        i += len;
    }
    return out.toOwnedSlice();
}

fn firstJsonString(obj: std.json.ObjectMap, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
        if (jsonString(obj, key)) |value| return value;
    }
    return null;
}

fn appendHashlinePreview(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    if (out.items.len >= max_hashline_preview_bytes) return;
    const remaining = max_hashline_preview_bytes - out.items.len;
    if (text.len <= remaining) {
        try out.appendSlice(allocator, text);
        return;
    }
    if (remaining > 0) try out.appendSlice(allocator, text[0..remaining]);
    try markHashlinePreviewTruncated(out);
}

fn markHashlinePreviewTruncated(out: *std.ArrayList(u8)) !void {
    if (out.items.len < hashline_preview_truncated_marker.len) return;
    const marker_start = out.items.len - hashline_preview_truncated_marker.len;
    @memcpy(out.items[marker_start..], hashline_preview_truncated_marker);
}

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

fn toolInvocation(allocator: std.mem.Allocator, name: []const u8, args_json: []const u8) ![]u8 {
    const primary = primaryToolArg(allocator, args_json) catch null;
    defer if (primary) |value| allocator.free(value);
    if (primary) |value| {
        const clipped = try clipSummaryArg(allocator, value);
        defer allocator.free(clipped);
        return std.fmt.allocPrint(allocator, "◈ {s} \"{s}\"", .{ name, clipped });
    }
    return std.fmt.allocPrint(allocator, "◈ {s}", .{name});
}

fn toolResultSummary(allocator: std.mem.Allocator, name: []const u8, args_json: []const u8, result_json: []const u8, is_error: bool, raw_total_bytes: u64, returned_total_bytes: u64, estimated_tokens: u64, artifact_count: u32) ![]u8 {
    const invocation = try toolInvocation(allocator, name, args_json);
    defer allocator.free(invocation);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.print("{s} {s}", .{ invocation, if (is_error) "failed" else "ok" });
    if (raw_total_bytes > 0 or returned_total_bytes > 0) {
        try writer.print(" raw={d}B returned={d}B", .{ raw_total_bytes, returned_total_bytes });
    } else {
        try writer.print(" output={d}B", .{result_json.len});
    }
    if (estimated_tokens > 0) try writer.print(" ~{d} tok", .{estimated_tokens});
    if (artifact_count > 0) try writer.print(" artifacts={d} on disk", .{artifact_count});
    if (raw_total_bytes > returned_total_bytes or artifact_count > 0) try writer.writeAll(" preview-capped");
    if (is_error and result_json.len > 0) {
        const unwrapped = try toolErrorMessage(allocator, result_json);
        defer if (unwrapped) |message| allocator.free(message);
        const preview_source = if (unwrapped) |message| message else result_json;
        const preview = try clipSummaryArg(allocator, preview_source);
        defer allocator.free(preview);
        try writer.print(" \"{s}\"", .{preview});
    }
    return out.toOwnedSlice();
}

fn toolErrorMessage(allocator: std.mem.Allocator, result_json: []const u8) !?[]u8 {
    if (result_json.len == 0) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, result_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const message = jsonString(parsed.value.object, "err") orelse return null;
    if (message.len == 0) return null;
    return try allocator.dupe(u8, message);
}

fn primaryToolArg(allocator: std.mem.Allocator, args_json: []const u8) !?[]u8 {
    if (args_json.len == 0) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const keys = [_][]const u8{ "description", "command", "path", "query", "pattern", "file", "operation" };
    for (keys) |key| {
        if (jsonString(parsed.value.object, key)) |value| {
            if (value.len > 0) return try allocator.dupe(u8, value);
        }
    }
    return null;
}

fn clipSummaryArg(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    var width: usize = 0;
    var i: usize = 0;
    while (i < value.len and width < 48) {
        const c = value[i];
        if (c == '\n' or c == '\r' or c == '\t') {
            try writer.writeByte(' ');
            width += 1;
            i += 1;
            continue;
        }
        if (c < 0x20 or c == 0x7f) {
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        if (i + len > value.len) break;
        if (len == 1) {
            try writer.writeByte(c);
        } else {
            const codepoint = std.unicode.utf8Decode(value[i .. i + len]) catch {
                i += 1;
                continue;
            };
            if (codepoint < 0x20 or codepoint == 0x7f or (codepoint >= 0x80 and codepoint <= 0x9f)) {
                i += len;
                continue;
            }
            try writer.writeAll(value[i .. i + len]);
        }
        width += 1;
        i += len;
    }
    if (i < value.len) try writer.writeAll("…");
    return out.toOwnedSlice();
}

fn ownedText(text: []const u8) !@import("owned_slice").OwnedSlice(u8) {
    return @import("owned_slice").OwnedSlice(u8).initOwned(try std.testing.allocator.dupe(u8, text));
}

fn toolStartEvent(id: []const u8, name: []const u8, args_json: []const u8) !tui_runtime.TuiEvent {
    return .{ .tool_execution_start = .{
        .tool_call_id = try ownedText(id),
        .tool_name = try ownedText(name),
        .args_json = try ownedText(args_json),
    } };
}

fn toolEndEvent(id: []const u8, name: []const u8, result_json: []const u8, is_error: bool) !tui_runtime.TuiEvent {
    return .{ .tool_execution_end = .{
        .tool_call_id = try ownedText(id),
        .tool_name = try ownedText(name),
        .result_json = try ownedText(result_json),
        .is_error = is_error,
    } };
}


pub fn noopToolForTest(
    tool_call_id: []const u8,
    args_json: []const u8,
    cancel_token: ?ai_types.CancelToken,
    on_update_ctx: ?*anyopaque,
    on_update: ?agent.ToolUpdateCallback,
    allocator: std.mem.Allocator,
) anyerror!agent.AgentToolResult {
    _ = tool_call_id;
    _ = args_json;
    _ = cancel_token;
    _ = on_update_ctx;
    _ = on_update;
    _ = allocator;
    return error.NotImplemented;
}


test "AppState applies transcript and tool events" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    const tools = [_]agent.AgentTool{.{
        .label = "Shell Execute",
        .name = "shell_command",
        .description = "Run shell command",
        .short_description = "Run shell",
        .parameters_schema_json = "{}",
        .execute = noopToolForTest,
    }};
    try state.setRegisteredTools(&tools);

    var text_event = tui_runtime.TuiEvent{ .text_delta = .{ .content_index = 0, .delta = try ownedText("hello") } };
    defer text_event.deinit(std.testing.allocator);
    try state.applyEvent(text_event);

    try std.testing.expectEqual(@as(usize, 1), state.transcript.items.len);
    try std.testing.expectEqual(TranscriptKind.assistant, state.transcript.items[0].kind);
    try std.testing.expectEqualStrings("hello", state.transcript.items[0].text.items);

    var final_text_event = tui_runtime.TuiEvent{ .message_end = .{ .role = .assistant, .text = try ownedText("hello world") } };
    defer final_text_event.deinit(std.testing.allocator);
    try state.applyEvent(final_text_event);

    try std.testing.expectEqual(@as(usize, 1), state.transcript.items.len);
    try std.testing.expectEqual(TranscriptKind.assistant, state.transcript.items[0].kind);
    try std.testing.expectEqualStrings("hello world", state.transcript.items[0].text.items);

    var start_event = try toolStartEvent("call-1", "shell_command", "{\"description\":\"Check the current workspace directory\",\"command\":\"pwd\"}");
    defer start_event.deinit(std.testing.allocator);
    try state.applyEvent(start_event);

    try std.testing.expectEqual(@as(usize, 2), state.transcript.items.len);
    try std.testing.expectEqual(TranscriptKind.tool, state.transcript.items[1].kind);
    try std.testing.expect(state.transcript.items[1].tool_summary);
    try std.testing.expect(std.mem.indexOf(u8, state.transcript.items[1].text.items, "◈ Shell Execute \"Check the current workspace directory\"") != null);
    try std.testing.expectEqual(@as(usize, 1), state.active_tool_summary_entry.?);

    var end_event = try toolEndEvent("call-1", "shell_command", "{\"ok\":true}", false);
    defer end_event.deinit(std.testing.allocator);
    try state.applyEvent(end_event);

    try std.testing.expectEqual(@as(usize, 1), state.tools.items.len);
    try std.testing.expectEqual(ToolStatus.done, state.tools.items[0].status);
    try std.testing.expectEqualStrings("Shell Execute", state.tools.items[0].label);
    try std.testing.expect(std.mem.indexOf(u8, state.tools.items[0].output.items, "ok") != null);
    try std.testing.expectEqual(@as(usize, 2), state.transcript.items.len);
    try std.testing.expect(std.mem.indexOf(u8, state.transcript.items[1].text.items, "◈ Shell Execute \"Check the current workspace directory\" ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.transcript.items[1].text.items, "shell_command") == null);
    try std.testing.expect(state.active_tool_summary_entry == null);
}

test "AppState strips control bytes from tool summaries" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    var start_event = try toolStartEvent("call-1", "shell_command", "{\"command\":\"before\\u001b[2Jafter\\u0007\"}");
    defer start_event.deinit(std.testing.allocator);
    try state.applyEvent(start_event);

    try std.testing.expect(std.mem.indexOfScalar(u8, state.transcript.items[0].text.items, 0x1b) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, state.transcript.items[0].text.items, 0x07) == null);
    try std.testing.expect(std.mem.indexOf(u8, state.transcript.items[0].text.items, "before[2Jafter") != null);
}

test "AppState finalizes transcript from message_end text" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    var assistant_end = tui_runtime.TuiEvent{ .message_end = .{ .role = .assistant, .text = try ownedText("final response") } };
    defer assistant_end.deinit(std.testing.allocator);
    try state.applyEvent(assistant_end);

    try std.testing.expectEqual(@as(usize, 1), state.transcript.items.len);
    try std.testing.expectEqual(TranscriptKind.assistant, state.transcript.items[0].kind);
    try std.testing.expectEqualStrings("final response", state.transcript.items[0].text.items);
}

test "AppState message_end does not duplicate streamed transcript" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    var delta_a = tui_runtime.TuiEvent{ .text_delta = .{ .content_index = 0, .delta = try ownedText("hel") } };
    defer delta_a.deinit(std.testing.allocator);
    try state.applyEvent(delta_a);

    var delta_b = tui_runtime.TuiEvent{ .text_delta = .{ .content_index = 0, .delta = try ownedText("lo") } };
    defer delta_b.deinit(std.testing.allocator);
    try state.applyEvent(delta_b);

    var assistant_end = tui_runtime.TuiEvent{ .message_end = .{ .role = .assistant, .text = try ownedText("hello") } };
    defer assistant_end.deinit(std.testing.allocator);
    try state.applyEvent(assistant_end);

    try std.testing.expectEqual(@as(usize, 1), state.transcript.items.len);
    try std.testing.expectEqualStrings("hello", state.transcript.items[0].text.items);
}

test "AppState message_end user text avoids duplicate submitted message" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.appendUserMessage("hello");
    var user_end = tui_runtime.TuiEvent{ .message_end = .{ .role = .user, .text = try ownedText("hello") } };
    defer user_end.deinit(std.testing.allocator);
    try state.applyEvent(user_end);

    try std.testing.expectEqual(@as(usize, 1), state.transcript.items.len);
    try std.testing.expectEqual(TranscriptKind.user, state.transcript.items[0].kind);
    try std.testing.expectEqualStrings("hello", state.transcript.items[0].text.items);
}

test "AppState user message_start and message_end do not leave empty transcript row" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.applyEvent(.{ .message_start = .{ .role = .user } });
    var user_end = tui_runtime.TuiEvent{ .message_end = .{ .role = .user, .text = try ownedText("queued prompt") } };
    defer user_end.deinit(std.testing.allocator);
    try state.applyEvent(user_end);

    try std.testing.expectEqual(@as(usize, 1), state.transcript.items.len);
    try std.testing.expectEqual(TranscriptKind.user, state.transcript.items[0].kind);
    try std.testing.expectEqualStrings("queued prompt", state.transcript.items[0].text.items);
}

test "AppState appendSteeredMessage echoes and tracks pending steer" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.appendSteeredMessage("steer mid turn");
    try std.testing.expectEqual(@as(usize, 1), state.transcript.items.len);
    try std.testing.expectEqual(TranscriptKind.user, state.transcript.items[0].kind);
    try std.testing.expectEqualStrings("steer mid turn", state.transcript.items[0].text.items);
    try std.testing.expectEqual(@as(usize, 1), state.pending_steers.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.active_user_entry.?);

    try state.appendSteeredMessage("steer again");
    try std.testing.expectEqual(@as(usize, 2), state.transcript.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.active_user_entry.?);

    try std.testing.expect(state.takePendingSteer("steer mid turn"));
    try std.testing.expect(state.takePendingSteer("steer again"));
    try std.testing.expect(!state.takePendingSteer("steer again"));
    try std.testing.expectEqual(@as(usize, 0), state.pending_steers.items.len);
}

test "AppState takePendingSteer only matches the queued head" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.appendSteeredMessage("first steer");
    try state.appendSteeredMessage("second steer");
    try std.testing.expect(!state.takePendingSteer("second steer"));
    try std.testing.expect(state.takePendingSteer("first steer"));
    try std.testing.expect(state.takePendingSteer("second steer"));
    try std.testing.expectEqual(@as(usize, 0), state.pending_steers.items.len);
}

test "AppState clearTranscript drops pending steers" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.appendSteeredMessage("aborted steer");
    state.clearTranscript();
    try std.testing.expectEqual(@as(usize, 0), state.transcript.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.pending_steers.items.len);
    try std.testing.expect(state.active_user_entry == null);

    try state.appendUserMessage("aborted steer");
    try std.testing.expectEqual(@as(usize, 1), state.transcript.items.len);
    try std.testing.expectEqualStrings("aborted steer", state.transcript.items[0].text.items);
}

test "AppState message_end updates active assistant before trailing tool" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.applyEvent(.{ .message_start = .{ .role = .assistant } });
    var text_delta = tui_runtime.TuiEvent{ .text_delta = .{ .content_index = 0, .delta = try ownedText("partial") } };
    defer text_delta.deinit(std.testing.allocator);
    try state.applyEvent(text_delta);

    var tool_start = try toolStartEvent("call-1", "shell", "{\"command\":\"ls\"}");
    defer tool_start.deinit(std.testing.allocator);
    try state.applyEvent(tool_start);

    var assistant_end = tui_runtime.TuiEvent{ .message_end = .{ .role = .assistant, .text = try ownedText("final assistant") } };
    defer assistant_end.deinit(std.testing.allocator);
    try state.applyEvent(assistant_end);

    try std.testing.expectEqual(@as(usize, 2), state.transcript.items.len);
    try std.testing.expectEqual(TranscriptKind.assistant, state.transcript.items[0].kind);
    try std.testing.expectEqualStrings("final assistant", state.transcript.items[0].text.items);
    try std.testing.expectEqual(TranscriptKind.tool, state.transcript.items[1].kind);
    try std.testing.expect(std.mem.indexOf(u8, state.transcript.items[1].text.items, "shell") != null);
}

test "AppState message_end-only assistant appends after prior assistant" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.appendTranscript(.assistant, "previous response");
    var assistant_end = tui_runtime.TuiEvent{ .message_end = .{ .role = .assistant, .text = try ownedText("next response") } };
    defer assistant_end.deinit(std.testing.allocator);
    try state.applyEvent(assistant_end);

    try std.testing.expectEqual(@as(usize, 2), state.transcript.items.len);
    try std.testing.expectEqualStrings("previous response", state.transcript.items[0].text.items);
    try std.testing.expectEqualStrings("next response", state.transcript.items[1].text.items);
}

test "AppState message_start opens fresh assistant row after prior assistant" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.appendTranscript(.assistant, "previous response");
    try state.applyEvent(.{ .message_start = .{ .role = .assistant } });
    var assistant_end = tui_runtime.TuiEvent{ .message_end = .{ .role = .assistant, .text = try ownedText("next response") } };
    defer assistant_end.deinit(std.testing.allocator);
    try state.applyEvent(assistant_end);

    try std.testing.expectEqual(@as(usize, 2), state.transcript.items.len);
    try std.testing.expectEqualStrings("previous response", state.transcript.items[0].text.items);
    try std.testing.expectEqualStrings("next response", state.transcript.items[1].text.items);
}

test "AppState removes empty assistant placeholder on empty message_end" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.appendTranscript(.assistant, "previous response");
    try state.applyEvent(.{ .message_start = .{ .role = .assistant } });
    var assistant_end = tui_runtime.TuiEvent{ .message_end = .{ .role = .assistant, .text = try ownedText("") } };
    defer assistant_end.deinit(std.testing.allocator);
    try state.applyEvent(assistant_end);

    try std.testing.expectEqual(@as(usize, 1), state.transcript.items.len);
    try std.testing.expectEqual(TranscriptKind.assistant, state.transcript.items[0].kind);
    try std.testing.expectEqualStrings("previous response", state.transcript.items[0].text.items);
}

test "AppState removes empty assistant placeholder on aborted turn" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.appendTranscript(.assistant, "previous response");
    try state.applyEvent(.{ .message_start = .{ .role = .assistant } });
    try state.applyEvent(tui_runtime.TuiEvent{ .agent_end = .{ .reason = .cancelled } });

    try std.testing.expectEqual(@as(usize, 2), state.transcript.items.len);
    try std.testing.expectEqual(TranscriptKind.assistant, state.transcript.items[0].kind);
    try std.testing.expectEqualStrings("previous response", state.transcript.items[0].text.items);
    try std.testing.expectEqual(TranscriptKind.system, state.transcript.items[1].kind);
    try std.testing.expectEqualStrings("agent cancelled", state.transcript.items[1].text.items);
}

test "AppState finalizes active assistant after reasoning and tool deltas" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.applyEvent(.{ .message_start = .{ .role = .assistant } });
    var thinking_delta = tui_runtime.TuiEvent{ .thinking_delta = .{ .content_index = 0, .delta = try ownedText("plan") } };
    defer thinking_delta.deinit(std.testing.allocator);
    try state.applyEvent(thinking_delta);
    var tool_delta = tui_runtime.TuiEvent{ .tool_call_delta = .{ .content_index = 1, .delta = try ownedText("{\"name\":\"shell\"}") } };
    defer tool_delta.deinit(std.testing.allocator);
    try state.applyEvent(tool_delta);
    var text_delta = tui_runtime.TuiEvent{ .text_delta = .{ .content_index = 2, .delta = try ownedText("partial") } };
    defer text_delta.deinit(std.testing.allocator);
    try state.applyEvent(text_delta);
    var assistant_end = tui_runtime.TuiEvent{ .message_end = .{ .role = .assistant, .text = try ownedText("final") } };
    defer assistant_end.deinit(std.testing.allocator);
    try state.applyEvent(assistant_end);

    try std.testing.expectEqual(@as(usize, 2), state.transcript.items.len);
    try std.testing.expectEqual(TranscriptKind.assistant, state.transcript.items[0].kind);
    try std.testing.expectEqualStrings("final", state.transcript.items[0].text.items);
    try std.testing.expectEqual(TranscriptKind.thinking, state.transcript.items[1].kind);
    try std.testing.expectEqualStrings("plan", state.transcript.items[1].text.items);
}

test "AppState keeps identical inline assistant message_end turns" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    var first_end = tui_runtime.TuiEvent{ .message_end = .{ .role = .assistant, .text = try ownedText("Done") } };
    defer first_end.deinit(std.testing.allocator);
    try state.applyEvent(first_end);
    var second_end = tui_runtime.TuiEvent{ .message_end = .{ .role = .assistant, .text = try ownedText("Done") } };
    defer second_end.deinit(std.testing.allocator);
    try state.applyEvent(second_end);

    try std.testing.expectEqual(@as(usize, 2), state.transcript.items.len);
    try std.testing.expectEqualStrings("Done", state.transcript.items[0].text.items);
    try std.testing.expectEqualStrings("Done", state.transcript.items[1].text.items);
}

test "AppState clears stale active assistant before next inline message_end" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.applyEvent(.{ .message_start = .{ .role = .assistant } });
    var partial = tui_runtime.TuiEvent{ .text_delta = .{ .content_index = 0, .delta = try ownedText("interrupted") } };
    defer partial.deinit(std.testing.allocator);
    try state.applyEvent(partial);
    try state.applyEvent(.{ .agent_end = .{ .reason = .@"error" } });

    var assistant_end = tui_runtime.TuiEvent{ .message_end = .{ .role = .assistant, .text = try ownedText("next response") } };
    defer assistant_end.deinit(std.testing.allocator);
    try state.applyEvent(assistant_end);

    try std.testing.expectEqual(@as(usize, 3), state.transcript.items.len);
    try std.testing.expectEqualStrings("interrupted", state.transcript.items[0].text.items);
    try std.testing.expectEqual(TranscriptKind.@"error", state.transcript.items[1].kind);
    try std.testing.expectEqualStrings("agent ended with error, but no error details were provided", state.transcript.items[1].text.items);
    try std.testing.expectEqualStrings("next response", state.transcript.items[2].text.items);
}

test "AppState does not append generic agent error after detailed error event" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    var error_event = tui_runtime.TuiEvent{ .@"error" = .{ .message = try ownedText("provider failed: bad request") } };
    defer error_event.deinit(std.testing.allocator);
    try state.applyEvent(error_event);
    try state.applyEvent(.{ .agent_end = .{ .reason = .@"error" } });

    try std.testing.expectEqual(@as(usize, 1), state.transcript.items.len);
    try std.testing.expectEqual(TranscriptKind.@"error", state.transcript.items[0].kind);
    try std.testing.expectEqualStrings("provider failed: bad request", state.transcript.items[0].text.items);
}

test "AppState clones registered tool metadata" {
    const tools = [_]agent.AgentTool{
        .{
            .label = "Shell Execute",
            .name = "shell_execute",
            .description = "Run command",
            .short_description = "Run shell commands",
            .parameters_schema_json = "{}",
            .execute = noopToolForTest,
        },
        .{
            .label = "Workspace Info",
            .name = "workspace_info",
            .description = "Show workspace",
            .parameters_schema_json = "{}",
            .execute = noopToolForTest,
        },
    };
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.setRegisteredTools(&tools);
    try std.testing.expectEqual(@as(usize, 2), state.registered_tools.items.len);
    try std.testing.expectEqualStrings("shell_execute", state.registered_tools.items[0].name);
    try std.testing.expectEqualStrings("Shell Execute", state.registered_tools.items[0].label);
    try std.testing.expectEqualStrings("Run shell commands", state.registered_tools.items[0].short_description);
    try std.testing.expectEqualStrings("", state.registered_tools.items[1].short_description);

    const replacement = [_]agent.AgentTool{.{
        .label = "File Read",
        .name = "file_read",
        .description = "Read file",
        .short_description = "Read files",
        .parameters_schema_json = "{}",
        .execute = noopToolForTest,
    }};
    try state.setRegisteredTools(&replacement);
    try std.testing.expectEqual(@as(usize, 1), state.registered_tools.items.len);
    try std.testing.expectEqualStrings("file_read", state.registered_tools.items[0].name);
}

test "AppState tool_result message_end updates active tool entry only" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.appendTranscript(.tool, "shell_execute");
    try state.applyEvent(.{ .message_start = .{ .role = .tool_result } });
    var tool_result_a = tui_runtime.TuiEvent{ .message_end = .{ .role = .tool_result, .text = try ownedText("first result") } };
    defer tool_result_a.deinit(std.testing.allocator);
    try state.applyEvent(tool_result_a);

    try state.appendTranscript(.tool, "file_read");
    try state.applyEvent(.{ .message_start = .{ .role = .tool_result } });
    var tool_result_b = tui_runtime.TuiEvent{ .message_end = .{ .role = .tool_result, .text = try ownedText("second result") } };
    defer tool_result_b.deinit(std.testing.allocator);
    try state.applyEvent(tool_result_b);

    try std.testing.expectEqual(@as(usize, 4), state.transcript.items.len);
    try std.testing.expectEqualStrings("shell_execute", state.transcript.items[0].text.items);
    try std.testing.expectEqualStrings("first result", state.transcript.items[1].text.items);
    try std.testing.expectEqualStrings("file_read", state.transcript.items[2].text.items);
    try std.testing.expectEqualStrings("second result", state.transcript.items[3].text.items);
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

    var insert_after_event = tui_runtime.TuiEvent{ .tool_approval_requested = .{
        .tool_call_id = try ownedText("call-hash-insert-after"),
        .tool_name = try ownedText("hashline_edit"),
        .args_json = try ownedText("{\"path\":\"src/main.zig\",\"operation\":\"insert_after\",\"start_line\":10,\"start_hash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"replacement\":\"inserted\"}"),
    } };
    defer insert_after_event.deinit(std.testing.allocator);
    try state.applyEvent(insert_after_event);
    try std.testing.expect(std.mem.indexOf(u8, state.preview.content, "+ 11|inserted") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.preview.content, "+ 10|inserted") == null);

    var blank_line_event = tui_runtime.TuiEvent{ .tool_approval_requested = .{
        .tool_call_id = try ownedText("call-hash-blank"),
        .tool_name = try ownedText("hashline_edit"),
        .args_json = try ownedText("{\"path\":\"src/main.zig\",\"operation\":\"replace_range\",\"start_line\":2,\"start_hash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"replacement\":\"line1\\n\\nline3\"}"),
    } };
    defer blank_line_event.deinit(std.testing.allocator);
    try state.applyEvent(blank_line_event);
    try std.testing.expect(std.mem.indexOf(u8, state.preview.content, "+ 3|") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.preview.content, "+ 4|line3") != null);

    var large_replacement = try std.ArrayList(u8).initCapacity(std.testing.allocator, max_hashline_preview_bytes + 4096);
    defer large_replacement.deinit(std.testing.allocator);
    while (large_replacement.items.len < max_hashline_preview_bytes + 4096) {
        try large_replacement.appendSlice(std.testing.allocator, "large replacement line\n");
    }
    const large_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"src/main.zig\",\"operation\":\"replace_range\",\"start_line\":2,\"start_hash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"replacement\":{f}}}", .{std.json.fmt(large_replacement.items, .{})});
    defer std.testing.allocator.free(large_args);
    var large_event = tui_runtime.TuiEvent{ .tool_approval_requested = .{
        .tool_call_id = try ownedText("call-hash-large"),
        .tool_name = try ownedText("hashline_edit"),
        .args_json = try ownedText(large_args),
    } };
    defer large_event.deinit(std.testing.allocator);
    try state.applyEvent(large_event);
    try std.testing.expect(state.preview.content.len <= max_hashline_preview_bytes);
    try std.testing.expect(std.mem.indexOf(u8, state.preview.content, "preview truncated") != null);

    try std.testing.expectEqual(AppMode.approval, state.mode);
    try std.testing.expectEqual(ApprovalStatus.pending, state.approval.status);
    try std.testing.expectEqualStrings("hashline_edit", state.approval.tool_name);
    try std.testing.expectEqualStrings("call-hash-large", state.approval.tool_call_id);

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

test "Composer history navigation recalls entries and restores draft" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.composer.history.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "first"));
    try state.composer.history.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "second"));
    try state.composer.buffer.appendSlice(std.testing.allocator, "draft");

    try std.testing.expect(try state.composerHistoryPrev());
    try std.testing.expectEqualStrings("second", state.composer.text());
    try std.testing.expect(try state.composerHistoryPrev());
    try std.testing.expectEqualStrings("first", state.composer.text());
    try std.testing.expect(!try state.composerHistoryPrev());
    try std.testing.expectEqualStrings("first", state.composer.text());
    try std.testing.expect(try state.composerHistoryNext());
    try std.testing.expectEqualStrings("second", state.composer.text());
    try std.testing.expect(try state.composerHistoryNext());
    try std.testing.expectEqualStrings("draft", state.composer.text());
}

test "Composer cursor edits within the draft" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.composer.insertSlice(std.testing.allocator, "abc");
    try std.testing.expectEqual(@as(usize, 3), state.composer.cursor);
    try std.testing.expect(state.composer.moveCursorPrev());
    try state.composer.insertSlice(std.testing.allocator, "X");
    try std.testing.expectEqualStrings("abXc", state.composer.text());
    try std.testing.expect(state.composer.deleteBeforeCursor());
    try std.testing.expectEqualStrings("abc", state.composer.text());
    state.composer.moveCursorHome();
    try std.testing.expect(!state.composer.deleteBeforeCursor());
    try state.composer.insertSlice(std.testing.allocator, "λ");
    try std.testing.expectEqualStrings("λabc", state.composer.text());
    try std.testing.expectEqual(@as(usize, "λ".len), state.composer.cursor);
}

test "AppState cycles thinking levels for TUI shortcut" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try std.testing.expectEqual(ai_types.ThinkingLevel.low, state.thinking_level);
    try std.testing.expectEqual(ai_types.ThinkingLevel.medium, state.cycleThinkingLevel());
    try std.testing.expectEqual(ai_types.ThinkingLevel.high, state.cycleThinkingLevel());
    try std.testing.expectEqual(ai_types.ThinkingLevel.xhigh, state.cycleThinkingLevel());
    try std.testing.expectEqual(ai_types.ThinkingLevel.off, state.cycleThinkingLevel());
    try std.testing.expectEqual(ai_types.ThinkingLevel.low, state.cycleThinkingLevel());
}

test "AppState reset replay clears stale queue counts" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    state.queue = .{ .steering = 1, .follow_up = 2 };

    state.resetReplayState();

    try std.testing.expectEqual(@as(usize, 0), state.queue.total());
}

test "AppState reset replay clears backpressure state" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    state.dropped_event_count = 5;
    state.backpressure_active = true;

    state.resetReplayState();

    try std.testing.expectEqual(@as(u64, 0), state.dropped_event_count);
    try std.testing.expect(!state.backpressure_active);
}

test "AppState stream_aborted still applies backpressure status and warning" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    state.stream_aborted = true;

    try state.applyEvent(.{ .backpressure_status = .{ .active = true, .dropped_count = 4 } });
    try std.testing.expect(state.backpressure_active);
    try std.testing.expectEqual(@as(u64, 4), state.dropped_event_count);

    var warning = tui_runtime.TuiEvent{ .system_warning = .{ .message = try ownedText("warn") } };
    defer warning.deinit(std.testing.allocator);
    try state.applyEvent(warning);

    try std.testing.expectEqual(@as(usize, 1), state.transcript.items.len);
    try std.testing.expectEqualStrings("warn", state.transcript.items[0].text.items);
}

test "AppState applies thinking tool call and lifecycle events" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.applyEvent(.{ .agent_start = .{} });
    try std.testing.expect(state.status.streaming);
    try std.testing.expectEqual(@as(usize, 0), state.transcript.items.len);

    var thinking_event = tui_runtime.TuiEvent{ .thinking_delta = .{ .content_index = 0, .delta = try ownedText("plan") } };
    defer thinking_event.deinit(std.testing.allocator);
    try state.applyEvent(thinking_event);

    var call_event = tui_runtime.TuiEvent{ .tool_call_delta = .{ .content_index = 1, .delta = try ownedText("{\"name\":\"shell\"}") } };
    defer call_event.deinit(std.testing.allocator);
    try state.applyEvent(call_event);

    try std.testing.expectEqual(@as(usize, 1), state.transcript.items.len);
    try std.testing.expectEqual(TranscriptKind.thinking, state.transcript.items[0].kind);
    try std.testing.expectEqualStrings("plan", state.transcript.items[0].text.items);

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
    try std.testing.expectEqual(@as(u64, 2000), state.telemetry.context_window);
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
    try std.testing.expectEqual(@as(usize, 1), state.transcript.items.len);
    try std.testing.expect(std.mem.indexOf(u8, state.transcript.items[0].text.items, "artifacts=1 on disk") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.transcript.items[0].text.items, "◈ shell_command ok") != null);
}


test "AppState appends visible transcript row for tool execution errors" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    var end_event = tui_runtime.TuiEvent{ .tool_execution_end = .{
        .tool_call_id = try ownedText("call-error"),
        .tool_name = try ownedText("shell_command"),
        .result_json = try ownedText("OutOfMemory"),
        .is_error = true,
    } };
    defer end_event.deinit(std.testing.allocator);
    try state.applyEvent(end_event);

    try std.testing.expectEqual(@as(usize, 1), state.tools.items.len);
    try std.testing.expectEqual(ToolStatus.@"error", state.tools.items[0].status);
    try std.testing.expectEqual(TranscriptKind.@"error", state.transcript.items[state.transcript.items.len - 1].kind);
    try std.testing.expect(std.mem.indexOf(u8, state.transcript.items[state.transcript.items.len - 1].text.items, "shell_command failed: OutOfMemory") != null);
}

test "AppState unwraps tool error envelope for display" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    var start_event = try toolStartEvent("call-err", "workspace_list", "{\"workspace_root\":\"/tmp\"}");
    defer start_event.deinit(std.testing.allocator);
    try state.applyEvent(start_event);

    var end_event = try toolEndEvent("call-err", "workspace_list", "{\"ok\":false,\"err\":\"FileNotFound\",\"duration_ms\":2}", true);
    defer end_event.deinit(std.testing.allocator);
    try state.applyEvent(end_event);

    try std.testing.expectEqual(@as(usize, 2), state.transcript.items.len);
    try std.testing.expect(std.mem.indexOf(u8, state.transcript.items[0].text.items, "◈ workspace_list failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.transcript.items[0].text.items, "\"FileNotFound\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.transcript.items[0].text.items, "{\"ok\":false") == null);
    try std.testing.expectEqual(TranscriptKind.@"error", state.transcript.items[1].kind);
    try std.testing.expectEqualStrings("workspace_list failed: FileNotFound", state.transcript.items[1].text.items);
}

test "AppState renders one summary line per tool call across a turn" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try state.appendUserMessage("run two tools");

    const calls = [_]struct { id: []const u8, name: []const u8 }{
        .{ .id = "call-a", .name = "workspace_info" },
        .{ .id = "call-b", .name = "workspace_list" },
    };
    for (calls) |call| {
        var start_event = try toolStartEvent(call.id, call.name, "{\"workspace_root\":\"/tmp\"}");
        defer start_event.deinit(std.testing.allocator);
        try state.applyEvent(start_event);
        var end_event = try toolEndEvent(call.id, call.name, "{\"ok\":true}", false);
        defer end_event.deinit(std.testing.allocator);
        try state.applyEvent(end_event);
    }

    var tool_rows: usize = 0;
    for (state.transcript.items) |entry| {
        if (entry.kind == .tool) tool_rows += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), tool_rows);
    try std.testing.expect(std.mem.indexOf(u8, state.transcript.items[1].text.items, "◈ workspace_info ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.transcript.items[2].text.items, "◈ workspace_list ok") != null);
}

test "AppState sanitizes unwrapped tool error messages" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    var end_event = try toolEndEvent("call-esc", "shell_command", "{\"ok\":false,\"err\":\"before\\u001b[2Jafter\\u0007\"}", true);
    defer end_event.deinit(std.testing.allocator);
    try state.applyEvent(end_event);

    try std.testing.expectEqual(@as(usize, 2), state.transcript.items.len);
    for (state.transcript.items) |entry| {
        try std.testing.expect(std.mem.indexOfScalar(u8, entry.text.items, 0x1b) == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, entry.text.items, 0x07) == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, state.transcript.items[0].text.items, "before[2Jafter") != null);
    try std.testing.expectEqual(TranscriptKind.@"error", state.transcript.items[1].kind);
    try std.testing.expect(std.mem.indexOf(u8, state.transcript.items[1].text.items, "shell_command failed: before[2Jafter") != null);
}

test "AppState drops redundant result text for failed tool calls" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    var start_event = try toolStartEvent("call-f", "shell", "{\"command\":\"ls\"}");
    defer start_event.deinit(std.testing.allocator);
    try state.applyEvent(start_event);
    var end_event = try toolEndEvent("call-f", "shell", "{\"ok\":false,\"err\":\"FileNotFound\"}", true);
    defer end_event.deinit(std.testing.allocator);
    try state.applyEvent(end_event);

    try state.applyEvent(.{ .message_start = .{ .role = .tool_result } });
    var result_end = tui_runtime.TuiEvent{ .message_end = .{ .role = .tool_result, .tool_call_id = try ownedText("call-f"), .text = try ownedText("Tool execution failed: FileNotFound") } };
    defer result_end.deinit(std.testing.allocator);
    try state.applyEvent(result_end);

    try std.testing.expectEqual(@as(usize, 2), state.transcript.items.len);
    try std.testing.expect(std.mem.indexOf(u8, state.transcript.items[0].text.items, "◈ shell \"ls\" failed") != null);
    try std.testing.expectEqual(TranscriptKind.@"error", state.transcript.items[1].kind);
    try std.testing.expect(std.mem.indexOf(u8, state.transcript.items[1].text.items, "Tool execution failed") == null);
    try std.testing.expect(state.active_tool_result_entry == null);
}

test "AppState keeps readable text for rejected tool calls" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    var start_event = try toolStartEvent("call-r", "shell", "{\"command\":\"true\"}");
    defer start_event.deinit(std.testing.allocator);
    try state.applyEvent(start_event);
    var end_event = try toolEndEvent("call-r", "shell", "{\"rejected\":true}", true);
    defer end_event.deinit(std.testing.allocator);
    try state.applyEvent(end_event);

    try state.applyEvent(.{ .message_start = .{ .role = .tool_result } });
    var result_end = tui_runtime.TuiEvent{ .message_end = .{ .role = .tool_result, .tool_call_id = try ownedText("call-r"), .text = try ownedText("Tool execution rejected by user") } };
    defer result_end.deinit(std.testing.allocator);
    try state.applyEvent(result_end);

    try std.testing.expectEqual(@as(usize, 3), state.transcript.items.len);
    try std.testing.expect(std.mem.indexOf(u8, state.transcript.items[0].text.items, "failed") != null);
    try std.testing.expectEqual(TranscriptKind.@"error", state.transcript.items[1].kind);
    try std.testing.expectEqual(TranscriptKind.tool, state.transcript.items[2].kind);
    try std.testing.expectEqualStrings("Tool execution rejected by user", state.transcript.items[2].text.items);
    try std.testing.expectEqualStrings("call-r", state.transcript.items[2].tool_call_id);
    try std.testing.expect(!state.tools.items[0].error_detail_readable);
}

test "AppState recovers replayed tool arguments from assistant tool calls" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.applyEvent(.{ .message_start = .{ .role = .assistant } });
    var assistant_end = tui_runtime.TuiEvent{ .message_end = .{ .role = .assistant, .text = try ownedText(""), .tool_calls_json = try ownedText("[{\"type\":\"tool_call\",\"id\":\"call-old\",\"name\":\"shell\",\"arguments_json\":\"{\\\"command\\\":\\\"pwd\\\"}\"]") } };
    defer assistant_end.deinit(std.testing.allocator);
    try state.applyEvent(assistant_end);

    var end_event = try toolEndEvent("call-old", "shell", "{\"ok\":true}", false);
    defer end_event.deinit(std.testing.allocator);
    try state.applyEvent(end_event);

    try std.testing.expectEqual(@as(usize, 1), state.transcript.items.len);
    try std.testing.expectEqualStrings("{\"command\":\"pwd\"}", state.tools.items[0].args_json);
    try std.testing.expect(std.mem.indexOf(u8, state.transcript.items[0].text.items, "◈ shell \"pwd\" ok") != null);
    try std.testing.expectEqualStrings("call-old", state.transcript.items[0].tool_call_id);
}

test "AppState finalizes unmatched replayed tool starts as interrupted" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    var start_event = try toolStartEvent("call-i", "shell", "{\"command\":\"ls\"}");
    defer start_event.deinit(std.testing.allocator);
    try state.applyEvent(start_event);
    try std.testing.expect(state.active_tool_summary_entry != null);

    try state.finalizeInterruptedTools();

    try std.testing.expect(state.active_tool_summary_entry == null);
    try std.testing.expectEqual(ToolStatus.interrupted, state.tools.items[0].status);
    try std.testing.expectEqual(@as(usize, 1), state.transcript.items.len);
    try std.testing.expectEqualStrings("◈ shell \"ls\" interrupted", state.transcript.items[0].text.items);
}

test "AppState finalizes running tools as interrupted on cancelled agent end" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    var start_event = try toolStartEvent("call-x", "shell", "{\"command\":\"ls\"}");
    defer start_event.deinit(std.testing.allocator);
    try state.applyEvent(start_event);

    try state.applyEvent(tui_runtime.TuiEvent{ .agent_end = .{ .reason = .cancelled } });

    try std.testing.expectEqual(ToolStatus.interrupted, state.tools.items[0].status);
    try std.testing.expect(std.mem.indexOf(u8, state.transcript.items[0].text.items, "interrupted") != null);
    try std.testing.expectEqual(TranscriptKind.system, state.transcript.items[1].kind);
}

test "lastAssistantText returns the most recent assistant reply" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try std.testing.expect(state.lastAssistantText() == null);

    try state.appendTranscript(.user, "hello");
    try state.appendTranscript(.assistant, "first reply");
    try state.appendTranscript(.user, "again");
    try state.appendTranscript(.assistant, "second reply");
    try state.appendTranscript(.system, "noise");

    try std.testing.expectEqualStrings("second reply", state.lastAssistantText().?);
}

test "AppState stream_aborted ignores stale lifecycle events" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    state.stream_aborted = true;
    try state.applyEvent(.{ .agent_start = .{} });
    try std.testing.expect(!state.status.streaming);

    try state.applyEvent(.{ .turn_start = .{} });
    try std.testing.expect(!state.status.streaming);

    try state.applyEvent(.{ .agent_end = .{ .reason = .cancelled } });
    try std.testing.expect(!state.status.streaming);
    try std.testing.expect(!state.stream_aborted);
}

test "AppState surfaces system_warning as visible warning transcript entry" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    var warning = tui_runtime.TuiEvent{ .system_warning = .{ .message = try ownedText("Warning: 5 events dropped due to backpressure") } };
    defer warning.deinit(std.testing.allocator);
    try state.applyEvent(warning);

    try std.testing.expectEqual(@as(usize, 1), state.transcript.items.len);
    try std.testing.expectEqual(TranscriptKind.@"error", state.transcript.items[0].kind);
    try std.testing.expectEqualStrings("Warning: 5 events dropped due to backpressure", state.transcript.items[0].text.items);
}

test "AppState updates backpressure status fields" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.applyEvent(.{ .backpressure_status = .{ .active = true, .dropped_count = 3 } });
    try std.testing.expect(state.backpressure_active);
    try std.testing.expectEqual(@as(u64, 3), state.dropped_event_count);

    try state.applyEvent(.{ .backpressure_status = .{ .active = false, .dropped_count = 3 } });
    try std.testing.expect(!state.backpressure_active);
    try std.testing.expectEqual(@as(u64, 3), state.dropped_event_count);
}

