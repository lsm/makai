const std = @import("std");
const agent = @import("agent");
const ai_types = @import("ai_types");
const tui_runtime = @import("tui_runtime");
const compat = @import("compat");

pub const AppMode = enum {
    normal,
    approval,
    preview,
    session_picker,
    model_picker,
    login_picker,
    permission_picker,
    view_picker,
    thinking_picker,
    login_input,
};

pub const TranscriptKind = enum {
    user,
    assistant,
    thinking,
    tool,
    system,
    @"error",
};

pub const TranscriptVisibilityMode = enum {
    everything,
    verbose,
    balanced,
    chat,

    pub fn next(self: TranscriptVisibilityMode) TranscriptVisibilityMode {
        return switch (self) {
            .everything => .verbose,
            .verbose => .balanced,
            .balanced => .chat,
            .chat => .everything,
        };
    }
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
    /// Wall-clock time (epoch ms) the entry was created, for chat-style
    /// timestamps in the transcript header.
    timestamp_ms: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, kind: TranscriptKind, text: []const u8) !TranscriptEntry {
        var entry = TranscriptEntry{ .kind = kind, .timestamp_ms = compat.time.nowMillis() };
        try entry.text.appendSlice(allocator, text);
        return entry;
    }

    pub fn deinit(self: *TranscriptEntry, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.* = undefined;
    }
};

pub const ProtocolEventEntry = struct {
    text: []u8,
    timestamp_ms: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, event: tui_runtime.TuiEvent) !ProtocolEventEntry {
        return .{
            .text = try formatProtocolEvent(allocator, event),
            .timestamp_ms = compat.time.nowMillis(),
        };
    }

    pub fn deinit(self: *ProtocolEventEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
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
    expanded: bool = false,
    raw_total_bytes: u64 = 0,
    returned_total_bytes: u64 = 0,
    estimated_returned_tokens: u64 = 0,
    artifact_count: u32 = 0,
    artifact_refs: []u8 = &.{},
    truncated: bool = false,
    display_preview: []u8 = &.{},

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
        if (self.display_preview.len > 0) allocator.free(self.display_preview);
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

pub const QueueState = tui_runtime.QueuedCounts;

pub const QueuedPreviewKind = enum {
    steering,
    follow_up,
};

pub const QueuedPreview = struct {
    kind: QueuedPreviewKind,
    text: []u8,

    pub fn init(allocator: std.mem.Allocator, kind: QueuedPreviewKind, text: []const u8) !QueuedPreview {
        return .{
            .kind = kind,
            .text = try allocator.dupe(u8, text),
        };
    }

    pub fn deinit(self: *QueuedPreview, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
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

    pub fn setSessionId(self: *StatusState, allocator: std.mem.Allocator, session_id: []const u8) !void {
        const new_session_id = try allocator.dupe(u8, session_id);
        if (self.session_id.len > 0) allocator.free(self.session_id);
        self.session_id = new_session_id;
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
    model: []u8 = &.{},
    provider: []u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, id: []const u8, label: []const u8) !SessionEntry {
        return initWithDetails(allocator, id, label, "", "");
    }

    pub fn initWithDetails(allocator: std.mem.Allocator, id: []const u8, label: []const u8, model: []const u8, provider: []const u8) !SessionEntry {
        const owned_id = try allocator.dupe(u8, id);
        errdefer allocator.free(owned_id);
        const owned_label = try allocator.dupe(u8, label);
        errdefer allocator.free(owned_label);
        const owned_model = try dupOrEmpty(allocator, model);
        errdefer if (owned_model.len > 0) allocator.free(owned_model);
        const owned_provider = try dupOrEmpty(allocator, provider);
        errdefer if (owned_provider.len > 0) allocator.free(owned_provider);
        return .{
            .id = owned_id,
            .label = owned_label,
            .model = owned_model,
            .provider = owned_provider,
        };
    }

    pub fn matchesQuery(self: SessionEntry, query: []const u8) bool {
        if (query.len == 0) return true;
        return std.ascii.indexOfIgnoreCase(self.label, query) != null or
            std.ascii.indexOfIgnoreCase(self.id, query) != null or
            std.ascii.indexOfIgnoreCase(self.model, query) != null or
            std.ascii.indexOfIgnoreCase(self.provider, query) != null;
    }

    pub fn deinit(self: *SessionEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        if (self.model.len > 0) allocator.free(self.model);
        if (self.provider.len > 0) allocator.free(self.provider);
        self.* = undefined;
    }
};

fn dupOrEmpty(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (value.len == 0) return &.{};
    return allocator.dupe(u8, value);
}

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

    pub fn deleteAfterCursor(self: *ComposerState) bool {
        self.normalizeCursor();
        if (self.cursor >= self.buffer.items.len) return false;
        const end = nextCodepointEnd(self.buffer.items, self.cursor);
        const removed = end - self.cursor;
        std.mem.copyForwards(u8, self.buffer.items[self.cursor..], self.buffer.items[end..]);
        self.buffer.shrinkRetainingCapacity(self.buffer.items.len - removed);
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
    protocol_events: std.ArrayList(ProtocolEventEntry) = .empty,
    registered_tools: std.ArrayList(RegisteredToolEntry) = .empty,
    tools: std.ArrayList(ToolEntry) = .empty,
    sessions: std.ArrayList(SessionEntry) = .empty,
    composer: ComposerState = .{},
    approval: ApprovalState = .{},
    permission_mode: tui_runtime.PermissionMode = .bypass,
    status: StatusState = .{},
    queue: QueueState = .{},
    queued_previews: std.ArrayList(QueuedPreview) = .empty,
    telemetry: TelemetryState = .{},
    preview: PreviewState = .{},
    transcript_mode: TranscriptVisibilityMode = .balanced,
    show_thinking: bool = true,
    thinking_level: ai_types.ThinkingLevel = .low,
    login_input_secret: bool = false,
    /// Monotonic animation counter bumped once per UI tick (~50ms). Views derive
    /// spinner frames and other time-based effects from this so animation stays
    /// in lockstep with the render loop without each view tracking its own clock.
    anim_tick: u64 = 0,
    transcript_scroll: usize = 0,
    tool_scroll: usize = 0,
    session_index: usize = 0,
    session_scroll: usize = 0,
    session_filter: ComposerState = .{},
    menu_index: usize = 0,
    menu_scroll: usize = 0,
    active_user_entry: ?usize = null,
    active_assistant_entry: ?usize = null,
    active_tool_result_entry: ?usize = null,
    /// Set when the user aborts the active turn. Lifecycle events from the
    /// cancelled turn that are drained afterwards must not flip the status bar
    /// back to streaming.
    stream_aborted: bool = false,

    pub fn init(allocator: std.mem.Allocator) AppState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AppState) void {
        for (self.transcript.items) |*entry| entry.deinit(self.allocator);
        self.transcript.deinit(self.allocator);
        for (self.protocol_events.items) |*entry| entry.deinit(self.allocator);
        self.protocol_events.deinit(self.allocator);
        for (self.registered_tools.items) |*tool| tool.deinit(self.allocator);
        self.registered_tools.deinit(self.allocator);
        for (self.tools.items) |*tool| tool.deinit(self.allocator);
        self.tools.deinit(self.allocator);
        for (self.sessions.items) |*session| session.deinit(self.allocator);
        self.sessions.deinit(self.allocator);
        self.session_filter.deinit(self.allocator);
        self.composer.deinit(self.allocator);
        self.approval.deinit(self.allocator);
        self.clearQueuedPreviews();
        self.queued_previews.deinit(self.allocator);
        self.status.deinit(self.allocator);
        self.preview.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn appendTranscript(self: *AppState, kind: TranscriptKind, text: []const u8) !void {
        try self.transcript.append(self.allocator, try TranscriptEntry.init(self.allocator, kind, text));
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
        self.clearProtocolEvents();
        self.transcript_scroll = 0;
        self.clearActiveTranscriptEntries();
    }

    /// Borrowed text of the most recent assistant reply, or null if none exists.
    /// Valid until the transcript is next mutated.
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

    /// Render the whole transcript as plain text with role prefixes. Caller owns
    /// the returned slice.
    pub fn transcriptToText(self: *const AppState, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        for (self.transcript.items, 0..) |entry, idx| {
            if (idx > 0) try buf.append(allocator, '\n');
            const prefix: []const u8 = switch (entry.kind) {
                .user => "> ",
                .assistant => "",
                .thinking => "[thinking] ",
                .tool => "[tool] ",
                .system => "[system] ",
                .@"error" => "[error] ",
            };
            try buf.appendSlice(allocator, prefix);
            try buf.appendSlice(allocator, entry.text.items);
        }
        return buf.toOwnedSlice(allocator);
    }

    pub fn clearTools(self: *AppState) void {
        for (self.tools.items) |*tool| tool.deinit(self.allocator);
        self.tools.clearRetainingCapacity();
        self.tool_scroll = 0;
    }

    pub fn resetReplayState(self: *AppState) void {
        self.clearTranscript();
        self.clearTools();
        self.telemetry = .{};
        self.clearQueuedPreviews();
        self.queue = .{};
        self.status.context_used = 0;
        self.status.turn_count = 0;
        self.status.streaming = false;
        self.stream_aborted = false;
        if (self.status.last_error.len > 0) {
            self.allocator.free(self.status.last_error);
            self.status.last_error = &.{};
        }
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

    pub fn toggleThinking(self: *AppState) void {
        self.show_thinking = !self.show_thinking;
    }

    pub fn setTranscriptMode(self: *AppState, mode: TranscriptVisibilityMode) void {
        self.transcript_mode = mode;
        self.transcript_scroll = 0;
    }

    pub fn cycleTranscriptMode(self: *AppState) TranscriptVisibilityMode {
        self.setTranscriptMode(self.transcript_mode.next());
        return self.transcript_mode;
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

    pub fn pruneQueuedPreviewsToCounts(self: *AppState, counts: tui_runtime.QueuedCounts) void {
        self.pruneQueuedPreviewKind(.steering, counts.steering);
        self.pruneQueuedPreviewKind(.follow_up, counts.follow_up);
    }

    fn pruneQueuedPreviewKind(self: *AppState, kind: QueuedPreviewKind, keep_count: usize) void {
        var existing: usize = 0;
        for (self.queued_previews.items) |preview| {
            if (preview.kind == kind) existing += 1;
        }
        var remove_count = existing -| keep_count;
        var idx: usize = 0;
        while (idx < self.queued_previews.items.len and remove_count > 0) {
            if (self.queued_previews.items[idx].kind != kind) {
                idx += 1;
                continue;
            }
            var removed = self.queued_previews.orderedRemove(idx);
            removed.deinit(self.allocator);
            remove_count -= 1;
        }
    }

    pub fn addQueuedPreview(self: *AppState, kind: QueuedPreviewKind, text: []const u8) !void {
        try self.queued_previews.append(self.allocator, try QueuedPreview.init(self.allocator, kind, text));
    }

    pub fn clearQueuedPreviews(self: *AppState) void {
        for (self.queued_previews.items) |*preview| preview.deinit(self.allocator);
        self.queued_previews.clearRetainingCapacity();
    }

    pub fn consumeQueuedPreviewText(self: *AppState, text: []const u8) bool {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        var idx: usize = 0;
        while (idx < self.queued_previews.items.len) : (idx += 1) {
            if (!std.mem.eql(u8, self.queued_previews.items[idx].text, trimmed)) continue;
            var removed = self.queued_previews.orderedRemove(idx);
            removed.deinit(self.allocator);
            return true;
        }
        return false;
    }

    pub fn applyEvent(self: *AppState, event: tui_runtime.TuiEvent) !void {
        try self.appendProtocolEvent(event);
        if (self.stream_aborted) switch (event) {
            .turn_end, .agent_end, .@"error" => {},
            else => return,
        };
        switch (event) {
            .agent_start => {
                self.status.streaming = true;
                try self.appendTranscript(.system, "agent started");
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
            .tool_call_delta => |payload| try self.appendDelta(.tool, payload.delta.slice()),
            .provider_event => {},
            .message_end => |payload| switch (payload.role) {
                .assistant => try self.finishTranscriptEntry(.assistant, payload.text.slice(), &self.active_assistant_entry),
                .user => try self.finishTranscriptEntryWithOptions(.user, payload.text.slice(), &self.active_user_entry, true),
                .tool_result => try self.finishTranscriptEntry(.tool, payload.text.slice(), &self.active_tool_result_entry),
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
                const summary = try toolSummary(self.allocator, tool.label, payload.args_json.slice());
                defer self.allocator.free(summary);
                try self.appendTranscript(.tool, summary);
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
                const summary = try toolResultSummary(self.allocator, tool.label, payload.result_json.slice(), payload.is_error, payload.raw_total_bytes, payload.returned_total_bytes, payload.estimated_returned_tokens, payload.artifact_count);
                defer self.allocator.free(summary);
                try self.appendTranscript(.tool, summary);
                if (payload.is_error) {
                    const message = try std.fmt.allocPrint(self.allocator, "{s} failed: {s}", .{ tool.label, payload.result_json.slice() });
                    defer self.allocator.free(message);
                    try self.status.setError(self.allocator, message);
                    try self.appendTranscript(.@"error", message);
                }
            },
            .context_usage => |payload| self.applyContextUsage(payload),
            .prompt_segment_usage => |payload| self.applyPromptSegmentUsage(payload),
            .turn_end => {
                self.status.streaming = false;
                self.stream_aborted = false;
                self.cleanupActiveTranscriptEntries();
            },
            .agent_end => |payload| {
                self.status.streaming = false;
                self.stream_aborted = false;
                self.cleanupActiveTranscriptEntries();
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

    pub fn toggleToolExpanded(self: *AppState, index: usize) void {
        if (index >= self.tools.items.len) return;
        self.tools.items[index].expanded = !self.tools.items[index].expanded;
    }

    pub fn toggleLatestToolExpanded(self: *AppState) void {
        if (self.tools.items.len == 0) return;
        self.toggleToolExpanded(self.tools.items.len - 1);
    }

    pub fn setPreview(self: *AppState, kind: PreviewKind, title: []const u8, content: []const u8) !void {
        try self.preview.set(self.allocator, kind, title, content);
        self.mode = .preview;
    }

    pub fn addSession(self: *AppState, id: []const u8, label: []const u8) !void {
        try self.addSessionWithDetails(id, label, "", "");
    }

    pub fn addSessionWithDetails(self: *AppState, id: []const u8, label: []const u8, model: []const u8, provider: []const u8) !void {
        try self.sessions.append(self.allocator, try SessionEntry.initWithDetails(self.allocator, id, label, model, provider));
    }

    pub fn sessionFilterText(self: *const AppState) []const u8 {
        return self.session_filter.text();
    }

    pub fn filteredSessionCount(self: *const AppState) usize {
        const query = self.sessionFilterText();
        var count: usize = 0;
        for (self.sessions.items) |session| {
            if (session.matchesQuery(query)) count += 1;
        }
        return count;
    }

    pub fn sessionRawIndexAtFilteredIndex(self: *const AppState, filtered_index: usize) ?usize {
        const query = self.sessionFilterText();
        var matched: usize = 0;
        for (self.sessions.items, 0..) |session, raw_index| {
            if (!session.matchesQuery(query)) continue;
            if (matched == filtered_index) return raw_index;
            matched += 1;
        }
        return null;
    }

    pub fn sessionFilteredIndexForRawIndex(self: *const AppState, target_raw_index: usize) ?usize {
        const query = self.sessionFilterText();
        var matched: usize = 0;
        for (self.sessions.items, 0..) |session, raw_index| {
            if (!session.matchesQuery(query)) continue;
            if (raw_index == target_raw_index) return matched;
            matched += 1;
        }
        return null;
    }

    pub fn sessionAtFilteredIndex(self: *const AppState, filtered_index: usize) ?*const SessionEntry {
        const raw_index = self.sessionRawIndexAtFilteredIndex(filtered_index) orelse return null;
        return &self.sessions.items[raw_index];
    }

    pub fn clampSessionSelectionToFilter(self: *AppState) void {
        const count = self.filteredSessionCount();
        if (count == 0) {
            self.session_index = 0;
            self.session_scroll = 0;
            return;
        }
        if (self.session_index >= count) self.session_index = count - 1;
        if (self.session_scroll > self.session_index) self.session_scroll = self.session_index;
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
        try self.preview.set(self.allocator, .diff, path, out.items);
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

    fn appendProtocolEvent(self: *AppState, event: tui_runtime.TuiEvent) !void {
        var entry = try ProtocolEventEntry.init(self.allocator, event);
        errdefer entry.deinit(self.allocator);
        try self.protocol_events.append(self.allocator, entry);
    }

    fn clearProtocolEvents(self: *AppState) void {
        for (self.protocol_events.items) |*entry| entry.deinit(self.allocator);
        self.protocol_events.clearRetainingCapacity();
    }

    fn appendDelta(self: *AppState, kind: TranscriptKind, delta: []const u8) !void {
        const index = switch (kind) {
            .assistant => try self.activeOrTrailingEntry(kind, &self.active_assistant_entry),
            .tool => try self.activeOrTrailingEntry(kind, &self.active_tool_result_entry),
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
    }

    fn cleanupActiveTranscriptEntries(self: *AppState) void {
        self.removeEmptyActiveTranscriptEntry(&self.active_user_entry, .user);
        self.removeEmptyActiveTranscriptEntry(&self.active_assistant_entry, .assistant);
        self.removeEmptyActiveTranscriptEntry(&self.active_tool_result_entry, .tool);
        self.clearActiveTranscriptEntries();
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
            try writer.print("{s} [preview {d}->{d} bytes", .{ tool.label, raw_total_bytes, returned_total_bytes });
            if (artifact_refs.len > 0) try writer.writeAll("; artifact available in TUI viewer");
            try writer.writeAll("]");
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

fn formatProtocolEvent(allocator: std.mem.Allocator, event: tui_runtime.TuiEvent) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    switch (event) {
        .agent_start => try writer.writeAll("protocol event: agent_start"),
        .turn_start => try writer.writeAll("protocol event: turn_start"),
        .message_start => |payload| {
            try writer.writeAll("protocol event: message_start");
            try writeEnumProtocolField(writer, "role", payload.role);
        },
        .text_delta => |payload| {
            try writer.writeAll("protocol event: text_delta");
            try writeUsizeProtocolField(writer, "content_index", payload.content_index);
            try writeStringProtocolField(writer, "delta", payload.delta.slice());
        },
        .thinking_delta => |payload| {
            try writer.writeAll("protocol event: thinking_delta");
            try writeUsizeProtocolField(writer, "content_index", payload.content_index);
            try writeStringProtocolField(writer, "delta", payload.delta.slice());
        },
        .tool_call_delta => |payload| {
            try writer.writeAll("protocol event: tool_call_delta");
            try writeUsizeProtocolField(writer, "content_index", payload.content_index);
            try writeStringProtocolField(writer, "delta", payload.delta.slice());
        },
        .provider_event => |payload| {
            try writer.writeAll("protocol event: provider_event");
            try writeStringProtocolField(writer, "event_json", payload.event_json.slice());
        },
        .message_end => |payload| {
            try writer.writeAll("protocol event: message_end");
            try writeEnumProtocolField(writer, "role", payload.role);
            try writeStringProtocolField(writer, "text", payload.text.slice());
            try writeStringProtocolField(writer, "content_json", payload.content_json.slice());
            try writeStringProtocolField(writer, "tool_call_id", payload.tool_call_id.slice());
            try writeStringProtocolField(writer, "tool_name", payload.tool_name.slice());
            try writeStringProtocolField(writer, "args_json", payload.args_json.slice());
            try writeStringProtocolField(writer, "tool_calls_json", payload.tool_calls_json.slice());
            try writeStringProtocolField(writer, "details_json", payload.details_json.slice());
            try writeStringProtocolField(writer, "artifacts_json", payload.artifacts_json.slice());
            try writeEnumProtocolField(writer, "stop_reason", payload.stop_reason);
            try writeBoolProtocolField(writer, "is_error", payload.is_error);
        },
        .tool_approval_requested => |payload| {
            try writer.writeAll("protocol event: tool_approval_requested");
            try writeStringProtocolField(writer, "tool_call_id", payload.tool_call_id.slice());
            try writeStringProtocolField(writer, "tool_name", payload.tool_name.slice());
            try writeStringProtocolField(writer, "args_json", payload.args_json.slice());
        },
        .tool_execution_start => |payload| {
            try writer.writeAll("protocol event: tool_execution_start");
            try writeStringProtocolField(writer, "tool_call_id", payload.tool_call_id.slice());
            try writeStringProtocolField(writer, "tool_name", payload.tool_name.slice());
            try writeStringProtocolField(writer, "args_json", payload.args_json.slice());
        },
        .tool_execution_update => |payload| {
            try writer.writeAll("protocol event: tool_execution_update");
            try writeStringProtocolField(writer, "tool_call_id", payload.tool_call_id.slice());
            try writeStringProtocolField(writer, "tool_name", payload.tool_name.slice());
            try writeStringProtocolField(writer, "args_json", payload.args_json.slice());
            try writeStringProtocolField(writer, "partial_result_json", payload.partial_result_json.slice());
        },
        .tool_execution_end => |payload| {
            try writer.writeAll("protocol event: tool_execution_end");
            try writeStringProtocolField(writer, "tool_call_id", payload.tool_call_id.slice());
            try writeStringProtocolField(writer, "tool_name", payload.tool_name.slice());
            try writeStringProtocolField(writer, "result_json", payload.result_json.slice());
            try writeBoolProtocolField(writer, "is_error", payload.is_error);
            try writeU64ProtocolField(writer, "raw_total_bytes", payload.raw_total_bytes);
            try writeU64ProtocolField(writer, "returned_total_bytes", payload.returned_total_bytes);
            try writeU64ProtocolField(writer, "estimated_returned_tokens", payload.estimated_returned_tokens);
            try writeU32ProtocolField(writer, "artifact_count", payload.artifact_count);
            try writeStringProtocolField(writer, "artifact_refs", payload.artifact_refs.slice());
        },
        .context_usage => |payload| {
            try writer.writeAll("protocol event: context_usage");
            try writeU64ProtocolField(writer, "system_prompt_bytes", payload.system_prompt_bytes);
            try writeU64ProtocolField(writer, "message_bytes", payload.message_bytes);
            try writeU64ProtocolField(writer, "tool_definition_bytes", payload.tool_definition_bytes);
            try writeU64ProtocolField(writer, "total_bytes", payload.total_bytes);
            try writeU64ProtocolField(writer, "estimated_tokens", payload.estimated_tokens);
            try writeU32ProtocolField(writer, "message_count", payload.message_count);
            try writeU32ProtocolField(writer, "tool_count", payload.tool_count);
        },
        .prompt_segment_usage => |payload| {
            try writer.writeAll("protocol event: prompt_segment_usage");
            try writeEnumProtocolField(writer, "segment", payload.segment);
            try writeEnumProtocolField(writer, "cache_role", payload.cache_role);
            try writeU64ProtocolField(writer, "bytes", payload.bytes);
            try writeU64ProtocolField(writer, "estimated_tokens", payload.estimated_tokens);
            try writeU32ProtocolField(writer, "item_count", payload.item_count);
        },
        .turn_end => |payload| {
            try writer.writeAll("protocol event: turn_end");
            try writeEnumProtocolField(writer, "stop_reason", payload.stop_reason);
        },
        .agent_end => |payload| {
            try writer.writeAll("protocol event: agent_end");
            try writeEnumProtocolField(writer, "reason", payload.reason);
        },
        .@"error" => |payload| {
            try writer.writeAll("protocol event: error");
            try writeStringProtocolField(writer, "message", payload.message.slice());
        },
    }

    return out.toOwnedSlice();
}

fn writeStringProtocolField(writer: *std.Io.Writer, field: []const u8, value: []const u8) !void {
    try writer.print("\n{s}=", .{field});
    try writer.print("{f}", .{std.json.fmt(value, .{})});
}

fn writeEnumProtocolField(writer: *std.Io.Writer, field: []const u8, value: anytype) !void {
    try writer.print("\n{s}={s}", .{ field, @tagName(value) });
}

fn writeBoolProtocolField(writer: *std.Io.Writer, field: []const u8, value: bool) !void {
    try writer.print("\n{s}={}", .{ field, value });
}

fn writeUsizeProtocolField(writer: *std.Io.Writer, field: []const u8, value: usize) !void {
    try writer.print("\n{s}={d}", .{ field, value });
}

fn writeU64ProtocolField(writer: *std.Io.Writer, field: []const u8, value: u64) !void {
    try writer.print("\n{s}={d}", .{ field, value });
}

fn writeU32ProtocolField(writer: *std.Io.Writer, field: []const u8, value: u32) !void {
    try writer.print("\n{s}={d}", .{ field, value });
}

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

fn toolSummary(allocator: std.mem.Allocator, name: []const u8, args_json: []const u8) ![]u8 {
    const primary = primaryToolArg(allocator, args_json) catch null;
    defer if (primary) |value| allocator.free(value);
    if (primary) |value| {
        const clipped = try clipSummaryArg(allocator, value);
        defer allocator.free(clipped);
        return std.fmt.allocPrint(allocator, "◈ {s} \"{s}\"", .{ name, clipped });
    }
    return std.fmt.allocPrint(allocator, "◈ {s}", .{name});
}

fn toolResultSummary(allocator: std.mem.Allocator, name: []const u8, result_json: []const u8, is_error: bool, raw_total_bytes: u64, returned_total_bytes: u64, estimated_tokens: u64, artifact_count: u32) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.print("◈ {s} {s}", .{ name, if (is_error) "failed" else "ok" });
    if (raw_total_bytes > 0 or returned_total_bytes > 0) {
        try writer.print(" raw={d}B returned={d}B", .{ raw_total_bytes, returned_total_bytes });
    } else {
        try writer.print(" output={d}B", .{result_json.len});
    }
    if (estimated_tokens > 0) try writer.print(" ~{d} tok", .{estimated_tokens});
    if (artifact_count > 0) try writer.print(" artifacts={d}", .{artifact_count});
    if (raw_total_bytes > returned_total_bytes or artifact_count > 0) try writer.writeAll(" preview-capped");
    if (is_error and result_json.len > 0) {
        const preview = try clipSummaryArg(allocator, result_json);
        defer allocator.free(preview);
        try writer.print(" \"{s}\"", .{preview});
    }
    return out.toOwnedSlice();
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

fn protocolLogText(allocator: std.mem.Allocator, state: *const AppState) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    for (state.protocol_events.items, 0..) |entry, index| {
        if (index > 0) try writer.writeByte('\n');
        try writer.writeAll(entry.text);
    }
    return out.toOwnedSlice();
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

test "AppState protocol log captures every supported TUI event variant" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.applyEvent(.agent_start);
    try state.applyEvent(.turn_start);
    try state.applyEvent(.{ .message_start = .{ .role = .assistant } });

    var text_delta = tui_runtime.TuiEvent{ .text_delta = .{ .content_index = 0, .delta = try ownedText("hello") } };
    defer text_delta.deinit(std.testing.allocator);
    try state.applyEvent(text_delta);

    var thinking_delta = tui_runtime.TuiEvent{ .thinking_delta = .{ .content_index = 1, .delta = try ownedText("plan") } };
    defer thinking_delta.deinit(std.testing.allocator);
    try state.applyEvent(thinking_delta);

    var tool_call_delta = tui_runtime.TuiEvent{ .tool_call_delta = .{ .content_index = 2, .delta = try ownedText("{\"name\":\"shell_execute\"}") } };
    defer tool_call_delta.deinit(std.testing.allocator);
    try state.applyEvent(tool_call_delta);

    var provider_event = tui_runtime.TuiEvent{ .provider_event = .{ .event_json = try ownedText("{\"type\":\"toolcall_end\",\"content_index\":2}") } };
    defer provider_event.deinit(std.testing.allocator);
    try state.applyEvent(provider_event);

    var message_end = tui_runtime.TuiEvent{ .message_end = .{
        .role = .assistant,
        .text = try ownedText("final"),
        .content_json = try ownedText("[{\"type\":\"output_text\"}]"),
        .tool_call_id = try ownedText("call-1"),
        .tool_name = try ownedText("shell_execute"),
        .args_json = try ownedText("{\"command\":\"pwd\"}"),
        .tool_calls_json = try ownedText("[{\"id\":\"call-1\"}]"),
        .details_json = try ownedText("{\"finish\":\"stop\"}"),
        .artifacts_json = try ownedText("[{\"name\":\"out\"}]"),
        .stop_reason = .stop,
        .is_error = false,
    } };
    defer message_end.deinit(std.testing.allocator);
    try state.applyEvent(message_end);

    var approval = tui_runtime.TuiEvent{ .tool_approval_requested = .{
        .tool_call_id = try ownedText("call-1"),
        .tool_name = try ownedText("shell_execute"),
        .args_json = try ownedText("{\"command\":\"pwd\"}"),
    } };
    defer approval.deinit(std.testing.allocator);
    try state.applyEvent(approval);

    var tool_start = tui_runtime.TuiEvent{ .tool_execution_start = .{
        .tool_call_id = try ownedText("call-1"),
        .tool_name = try ownedText("shell_execute"),
        .args_json = try ownedText("{\"command\":\"pwd\"}"),
    } };
    defer tool_start.deinit(std.testing.allocator);
    try state.applyEvent(tool_start);

    var tool_update = tui_runtime.TuiEvent{ .tool_execution_update = .{
        .tool_call_id = try ownedText("call-1"),
        .tool_name = try ownedText("shell_execute"),
        .args_json = try ownedText("{\"command\":\"pwd\"}"),
        .partial_result_json = try ownedText("{\"stdout\":\"/workspace\"}"),
    } };
    defer tool_update.deinit(std.testing.allocator);
    try state.applyEvent(tool_update);

    var tool_end = tui_runtime.TuiEvent{ .tool_execution_end = .{
        .tool_call_id = try ownedText("call-1"),
        .tool_name = try ownedText("shell_execute"),
        .result_json = try ownedText("{\"ok\":true}"),
        .is_error = false,
        .raw_total_bytes = 100,
        .returned_total_bytes = 80,
        .estimated_returned_tokens = 20,
        .artifact_count = 1,
        .artifact_refs = try ownedText("artifact://tool-output/1"),
    } };
    defer tool_end.deinit(std.testing.allocator);
    try state.applyEvent(tool_end);

    try state.applyEvent(.{ .context_usage = .{
        .system_prompt_bytes = 10,
        .message_bytes = 20,
        .tool_definition_bytes = 30,
        .total_bytes = 60,
        .estimated_tokens = 15,
        .message_count = 2,
        .tool_count = 1,
    } });
    try state.applyEvent(.{ .prompt_segment_usage = .{
        .segment = .tool_definitions,
        .cache_role = .stable,
        .bytes = 30,
        .estimated_tokens = 8,
        .item_count = 1,
    } });
    try state.applyEvent(.{ .turn_end = .{ .stop_reason = .stop } });
    try state.applyEvent(.{ .agent_end = .{ .reason = .completed } });

    var error_event = tui_runtime.TuiEvent{ .@"error" = .{ .message = try ownedText("provider failed") } };
    defer error_event.deinit(std.testing.allocator);
    try state.applyEvent(error_event);

    try std.testing.expectEqual(@as(usize, 17), state.protocol_events.items.len);
    const text = try protocolLogText(std.testing.allocator, &state);
    defer std.testing.allocator.free(text);

    const expected = [_][]const u8{
        "protocol event: agent_start",
        "protocol event: turn_start",
        "protocol event: message_start",
        "protocol event: text_delta",
        "protocol event: thinking_delta",
        "protocol event: tool_call_delta",
        "protocol event: provider_event",
        "protocol event: message_end",
        "protocol event: tool_approval_requested",
        "protocol event: tool_execution_start",
        "protocol event: tool_execution_update",
        "protocol event: tool_execution_end",
        "protocol event: context_usage",
        "protocol event: prompt_segment_usage",
        "protocol event: turn_end",
        "protocol event: agent_end",
        "protocol event: error",
        "content_json=\"[{\\\"type\\\":\\\"output_text\\\"}]\"",
        "event_json=\"{\\\"type\\\":\\\"toolcall_end\\\",\\\"content_index\\\":2}\"",
        "artifact_refs=\"artifact://tool-output/1\"",
        "message=\"provider failed\"",
    };
    for (expected) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, text, needle) != null);
    }
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

    var start_event = tui_runtime.TuiEvent{ .tool_execution_start = .{
        .tool_call_id = try ownedText("call-1"),
        .tool_name = try ownedText("shell_command"),
        .args_json = try ownedText("{\"description\":\"Check the current workspace directory\",\"command\":\"pwd\"}"),
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
    try std.testing.expectEqualStrings("Shell Execute", state.tools.items[0].label);
    try std.testing.expect(std.mem.indexOf(u8, state.tools.items[0].output.items, "ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.transcript.items[1].text.items, "◈ Shell Execute \"Check the current workspace directory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.transcript.items[1].text.items, "shell_command") == null);
}

test "AppState strips control bytes from tool summaries" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    var start_event = tui_runtime.TuiEvent{ .tool_execution_start = .{
        .tool_call_id = try ownedText("call-1"),
        .tool_name = try ownedText("shell_command"),
        .args_json = try ownedText("{\"command\":\"before\\u001b[2Jafter\\u0007\"}"),
    } };
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

test "AppState message_end updates active assistant before trailing tool" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.applyEvent(.{ .message_start = .{ .role = .assistant } });
    var text_delta = tui_runtime.TuiEvent{ .text_delta = .{ .content_index = 0, .delta = try ownedText("partial") } };
    defer text_delta.deinit(std.testing.allocator);
    try state.applyEvent(text_delta);

    var tool_delta = tui_runtime.TuiEvent{ .tool_call_delta = .{ .content_index = 1, .delta = try ownedText("{\"name\":\"shell\"}") } };
    defer tool_delta.deinit(std.testing.allocator);
    try state.applyEvent(tool_delta);

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

    try std.testing.expectEqual(@as(usize, 3), state.transcript.items.len);
    try std.testing.expectEqual(TranscriptKind.assistant, state.transcript.items[0].kind);
    try std.testing.expectEqualStrings("final", state.transcript.items[0].text.items);
    try std.testing.expectEqual(TranscriptKind.thinking, state.transcript.items[1].kind);
    try std.testing.expectEqualStrings("plan", state.transcript.items[1].text.items);
    try std.testing.expectEqual(TranscriptKind.tool, state.transcript.items[2].kind);
    try std.testing.expect(std.mem.indexOf(u8, state.transcript.items[2].text.items, "shell") != null);
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

test "AppState toggles thinking visibility" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();
    try std.testing.expect(state.show_thinking);
    state.toggleThinking();
    try std.testing.expect(!state.show_thinking);
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
    try state.addQueuedPreview(.steering, "now");
    try state.addQueuedPreview(.follow_up, "later");

    state.resetReplayState();

    try std.testing.expectEqual(@as(usize, 0), state.queue.total());
    try std.testing.expectEqual(@as(usize, 0), state.queued_previews.items.len);
}

test "AppState keeps queued previews until matching user message is consumed" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.addQueuedPreview(.steering, "steer now");
    try state.addQueuedPreview(.follow_up, "follow later");
    try state.addQueuedPreview(.follow_up, "follow after");

    state.setQueuedCounts(.{ .steering = 1, .follow_up = 2 });
    try std.testing.expectEqual(@as(usize, 3), state.queued_previews.items.len);

    state.setQueuedCounts(.{ .steering = 0, .follow_up = 1 });
    try std.testing.expectEqual(@as(usize, 3), state.queued_previews.items.len);
    try std.testing.expect(state.consumeQueuedPreviewText("steer now"));
    try std.testing.expectEqual(@as(usize, 2), state.queued_previews.items.len);
    try std.testing.expect(state.consumeQueuedPreviewText("follow later"));
    try std.testing.expectEqual(@as(usize, 1), state.queued_previews.items.len);
    try std.testing.expectEqualStrings("follow after", state.queued_previews.items[0].text);
}

test "AppState prunes stale queued previews to authoritative counts" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.addQueuedPreview(.steering, "old steering");
    try state.addQueuedPreview(.follow_up, "old follow");
    try state.addQueuedPreview(.steering, "remaining steering");
    try state.addQueuedPreview(.follow_up, "remaining follow");

    state.pruneQueuedPreviewsToCounts(.{ .steering = 1, .follow_up = 1 });

    try std.testing.expectEqual(@as(usize, 2), state.queued_previews.items.len);
    try std.testing.expectEqual(QueuedPreviewKind.steering, state.queued_previews.items[0].kind);
    try std.testing.expectEqualStrings("remaining steering", state.queued_previews.items[0].text);
    try std.testing.expectEqual(QueuedPreviewKind.follow_up, state.queued_previews.items[1].kind);
    try std.testing.expectEqualStrings("remaining follow", state.queued_previews.items[1].text);
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
    var found_marker = false;
    for (state.transcript.items) |entry| {
        if (std.mem.indexOf(u8, entry.text.items, "artifact available") != null) found_marker = true;
    }
    try std.testing.expect(found_marker);
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

test "transcriptToText renders role-prefixed plain text" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    try state.appendTranscript(.user, "ping");
    try state.appendTranscript(.assistant, "pong");
    try state.appendTranscript(.@"error", "boom");

    const text = try state.transcriptToText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("> ping\npong\n[error] boom", text);
}

test "AppState stream_aborted ignores stale lifecycle events" {
    var state = AppState.init(std.testing.allocator);
    defer state.deinit();

    state.stream_aborted = true;
    try state.applyEvent(.agent_start);
    try std.testing.expect(!state.status.streaming);

    try state.applyEvent(.turn_start);
    try std.testing.expect(!state.status.streaming);

    try state.applyEvent(.{ .agent_end = .{ .reason = .cancelled } });
    try std.testing.expect(!state.status.streaming);
    try std.testing.expect(!state.stream_aborted);
}
