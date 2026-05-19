const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const event_stream_mod = @import("event_stream");
const types = @import("agent_types");
const agent_loop = @import("agent_loop");

fn defaultIo() std.Io {
    return if (@import("builtin").is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

// Re-export types
pub const AgentEvent = types.AgentEvent;
pub const AgentEventStream = types.AgentEventStream;
pub const AgentLoopResult = types.AgentLoopResult;
pub const AgentTool = types.AgentTool;
const Listener = struct {
    callback: *const fn (ctx: ?*anyopaque, event: AgentEvent) void,
    ctx: ?*anyopaque = null,
};
pub const AgentToolResult = types.AgentToolResult;
pub const AgentState = types.AgentState;
pub const AgentContext = types.AgentContext;
pub const QueueMode = types.QueueMode;
pub const ProtocolClient = types.ProtocolClient;
pub const TransformContextFn = types.TransformContextFn;
pub const ConvertToLlmFn = types.ConvertToLlmFn;
pub const GetApiKeyFn = types.GetApiKeyFn;
pub const GetSteeringMessagesFn = types.GetSteeringMessagesFn;
pub const GetFollowUpMessagesFn = types.GetFollowUpMessagesFn;

/// Options for creating an Agent
pub const AgentOptions = struct {
    // Initial state
    initial_state: ?AgentState = null,

    // Protocol client (required) - single interface to provider layer
    protocol: ProtocolClient,

    // Message transformation
    convert_to_llm_fn: ?ConvertToLlmFn = null,
    convert_to_llm_ctx: ?*anyopaque = null,
    transform_context_fn: ?TransformContextFn = null,
    transform_context_ctx: ?*anyopaque = null,

    // Queue modes
    steering_mode: QueueMode = .one_at_a_time,
    follow_up_mode: QueueMode = .one_at_a_time,

    // Provider options
    session_id: ?[]const u8 = null,
    get_api_key_fn: ?GetApiKeyFn = null,
    get_api_key_ctx: ?*anyopaque = null,
    thinking_budgets: ?ai_types.ThinkingBudgets = null,
    max_retry_delay_ms: ?u32 = 60_000,
};

/// High-level Agent class that manages state, subscriptions, and message queues.
/// Provides a stateful wrapper around the low-level agent loop.
pub const Agent = struct {
    const ContinueRequest = struct {
        messages: []ai_types.Message,
        skip_steering: bool,
    };

    // Internal state
    _state: AgentState,
    _allocator: std.mem.Allocator,

    // Protocol client (single interface to provider layer)
    _protocol: ProtocolClient,

    // Subscribers
    _listeners: std.ArrayList(Listener),

    // Control
    _cancel_token: ?ai_types.CancelToken,
    _is_running: bool,

    // Message queues
    _steering_queue: std.ArrayList(ai_types.Message),
    _follow_up_queue: std.ArrayList(ai_types.Message),
    _steering_mode: QueueMode,
    _follow_up_mode: QueueMode,

    // Run context for skip flag (thread-safe per-agent)
    _skip_initial_steering_poll: bool,

    // Configuration
    _convert_to_llm_fn: ?ConvertToLlmFn,
    _convert_to_llm_ctx: ?*anyopaque,
    _transform_context_fn: ?TransformContextFn,
    _transform_context_ctx: ?*anyopaque,
    _session_id: ?[]const u8,
    _get_api_key_fn: ?GetApiKeyFn,
    _get_api_key_ctx: ?*anyopaque,
    _thinking_budgets: ?ai_types.ThinkingBudgets,
    _max_retry_delay_ms: ?u32,

    // Async support
    _thread: ?std.Thread,
    _done_event: std.Io.Event,
    _mutex: std.Io.Mutex,

    // === Lifecycle ===

    /// Initialize a new Agent with the given options.
    pub fn init(allocator: std.mem.Allocator, options: AgentOptions) Agent {
        var initial_state = options.initial_state;
        if (initial_state == null) {
            initial_state = AgentState.init(allocator);
        }

        return .{
            ._state = initial_state.?,
            ._allocator = allocator,
            ._protocol = options.protocol,
            ._listeners = std.ArrayList(Listener).empty,
            ._cancel_token = null,
            ._is_running = false,
            ._steering_queue = std.ArrayList(ai_types.Message).empty,
            ._follow_up_queue = std.ArrayList(ai_types.Message).empty,
            ._steering_mode = options.steering_mode,
            ._follow_up_mode = options.follow_up_mode,
            ._skip_initial_steering_poll = false,
            ._convert_to_llm_fn = options.convert_to_llm_fn,
            ._convert_to_llm_ctx = options.convert_to_llm_ctx,
            ._transform_context_fn = options.transform_context_fn,
            ._transform_context_ctx = options.transform_context_ctx,
            ._session_id = options.session_id,
            ._get_api_key_fn = options.get_api_key_fn,
            ._get_api_key_ctx = options.get_api_key_ctx,
            ._thinking_budgets = options.thinking_budgets,
            ._max_retry_delay_ms = options.max_retry_delay_ms,
            ._thread = null,
            ._done_event = .is_set,
            ._mutex = .init,
        };
    }

    /// Free all resources owned by the Agent.
    /// Waits for any running operation to complete.
    pub fn deinit(self: *Agent) void {
        // Wait for any running thread to complete
        if (self._thread != null) {
            self.waitForIdle();
        }

        // Clear queues
        self.clearAllQueues();
        self._steering_queue.deinit(self._allocator);
        self._follow_up_queue.deinit(self._allocator);

        // Clear listeners
        self._listeners.deinit(self._allocator);

        // Clear state
        self._state.deinit();

        // Free session_id if owned
        if (self._session_id) |sid| {
            self._allocator.free(sid);
        }

        // Poison freed memory to catch use-after-free in debug builds
        self.* = undefined;
    }

    // === Subscribe ===

    fn legacyListenerShim(ctx: ?*anyopaque, event: AgentEvent) void {
        const callback: *const fn (event: AgentEvent) void = @ptrCast(@alignCast(ctx.?));
        callback(event);
    }

    /// Subscribe to agent events.
    /// Returns a token that can be used to unsubscribe.
    pub fn subscribe(self: *Agent, callback: *const fn (event: AgentEvent) void) void {
        self.subscribeWithContext(@constCast(@ptrCast(callback)), legacyListenerShim);
    }

    /// Subscribe to agent events with caller context.
    pub fn subscribeWithContext(
        self: *Agent,
        ctx: ?*anyopaque,
        callback: *const fn (ctx: ?*anyopaque, event: AgentEvent) void,
    ) void {
        self._listeners.append(self._allocator, .{ .callback = callback, .ctx = ctx }) catch {};
    }

    /// Unsubscribe from agent events.
    pub fn unsubscribe(self: *Agent, callback: *const fn (event: AgentEvent) void) void {
        for (self._listeners.items, 0..) |listener, i| {
            if (listener.callback == legacyListenerShim and listener.ctx == @as(?*anyopaque, @constCast(@ptrCast(callback)))) {
                _ = self._listeners.orderedRemove(i);
                return;
            }
        }
    }

    /// Unsubscribe a contextual agent event listener.
    pub fn unsubscribeWithContext(self: *Agent, ctx: ?*anyopaque, callback: *const fn (ctx: ?*anyopaque, event: AgentEvent) void) void {
        for (self._listeners.items, 0..) |listener, i| {
            if (listener.callback == callback and listener.ctx == ctx) {
                _ = self._listeners.orderedRemove(i);
                return;
            }
        }
    }

    // === State Accessors ===

    /// Get the current state (read-only view).
    pub fn state(self: Agent) AgentState {
        return self._state;
    }

    /// Check if the agent is currently streaming.
    pub fn isStreaming(self: Agent) bool {
        return self._state.is_streaming;
    }

    /// Check if there are queued messages.
    pub fn hasQueuedMessages(self: Agent) bool {
        return self._steering_queue.items.len > 0 or self._follow_up_queue.items.len > 0;
    }

    // === State Mutators ===

    /// Set the system prompt.
    pub fn setSystemPrompt(self: *Agent, system_prompt: []const u8) !void {
        if (self._state.system_prompt.len > 0) {
            self._allocator.free(self._state.system_prompt);
        }
        self._state.system_prompt = try self._allocator.dupe(u8, system_prompt);
    }

    /// Set the model.
    pub fn setModel(self: *Agent, model: ai_types.Model) void {
        self._state.model = model;
    }

    /// Set the thinking level.
    pub fn setThinkingLevel(self: *Agent, level: ai_types.ThinkingLevel) void {
        self._state.thinking_level = level;
    }

    /// Set the tools.
    pub fn setTools(self: *Agent, tools: []const AgentTool) void {
        self._state.tools = tools;
    }

    /// Set the steering mode.
    pub fn setSteeringMode(self: *Agent, mode: QueueMode) void {
        self._steering_mode = mode;
    }

    /// Get the steering mode.
    pub fn getSteeringMode(self: Agent) QueueMode {
        return self._steering_mode;
    }

    /// Set the follow-up mode.
    pub fn setFollowUpMode(self: *Agent, mode: QueueMode) void {
        self._follow_up_mode = mode;
    }

    /// Get the follow-up mode.
    pub fn getFollowUpMode(self: Agent) QueueMode {
        return self._follow_up_mode;
    }

    /// Replace all messages with the given slice.
    pub fn replaceMessages(self: *Agent, messages: []const ai_types.Message) !void {
        // Clear existing messages
        for (self._state.messages.items) |*msg| {
            msg.deinit(self._allocator);
        }
        self._state.messages.clearRetainingCapacity();

        // Add new messages (deep copy)
        for (messages) |msg| {
            try self._state.messages.append(self._allocator, msg);
        }
    }

    /// Append a message to the conversation.
    pub fn appendMessage(self: *Agent, message: ai_types.Message) !void {
        try self._state.messages.append(self._allocator, message);
    }

    /// Clear all messages.
    pub fn clearMessages(self: *Agent) void {
        for (self._state.messages.items) |*msg| {
            msg.deinit(self._allocator);
        }
        self._state.messages.clearRetainingCapacity();
    }

    // === Message Queues ===

    /// Queue a steering message to interrupt the agent mid-run.
    /// Delivered after current tool execution, skips remaining tools.
    /// Thread-safe: can be called while agent is running.
    pub fn steer(self: *Agent, message: ai_types.Message) !void {
        self._mutex.lockUncancelable(defaultIo());
        defer self._mutex.unlock(defaultIo());
        try self._steering_queue.append(self._allocator, message);
    }

    /// Queue a follow-up message to be processed after the agent finishes.
    /// Delivered only when agent has no more tool calls or steering messages.
    /// Thread-safe: can be called while agent is running.
    pub fn followUp(self: *Agent, message: ai_types.Message) !void {
        self._mutex.lockUncancelable(defaultIo());
        defer self._mutex.unlock(defaultIo());
        try self._follow_up_queue.append(self._allocator, message);
    }

    /// Clear the steering queue.
    pub fn clearSteeringQueue(self: *Agent) void {
        self._mutex.lockUncancelable(defaultIo());
        defer self._mutex.unlock(defaultIo());
        for (self._steering_queue.items) |*msg| {
            msg.deinit(self._allocator);
        }
        self._steering_queue.clearRetainingCapacity();
    }

    /// Clear the follow-up queue.
    pub fn clearFollowUpQueue(self: *Agent) void {
        self._mutex.lockUncancelable(defaultIo());
        defer self._mutex.unlock(defaultIo());
        for (self._follow_up_queue.items) |*msg| {
            msg.deinit(self._allocator);
        }
        self._follow_up_queue.clearRetainingCapacity();
    }

    /// Clear all message queues.
    pub fn clearAllQueues(self: *Agent) void {
        self._mutex.lockUncancelable(defaultIo());
        defer self._mutex.unlock(defaultIo());
        for (self._steering_queue.items) |*msg| {
            msg.deinit(self._allocator);
        }
        self._steering_queue.clearRetainingCapacity();
        for (self._follow_up_queue.items) |*msg| {
            msg.deinit(self._allocator);
        }
        self._follow_up_queue.clearRetainingCapacity();
    }

    // === Control Flow ===

    /// Send a prompt to start a new conversation turn.
    /// Accepts:
    ///   - []const u8 (string) - creates a user message with text
    ///   - []const ai_types.Message - array of messages
    ///   - ai_types.Message - single message
    /// Returns error if already streaming.
    pub fn prompt(self: *Agent, message_or_messages: anytype) !void {
        if (self._state.is_streaming) {
            return error.AgentAlreadyStreaming;
        }

        const T = @TypeOf(message_or_messages);
        const messages: []const ai_types.Message = switch (T) {
            []const u8, *const []const u8 => blk: {
                // String input - create a user message
                const text = if (T == *const []const u8) message_or_messages.* else message_or_messages;
                const msg = ai_types.Message{
                    .user = .{
                        .content = .{ .text = text },
                        .timestamp = compat.time.nowMillis(),
                    },
                };
                break :blk @as([]const ai_types.Message, &.{msg});
            },
            []const ai_types.Message => message_or_messages,
            ai_types.Message => blk: {
                // Single message - need to create a temporary array
                // Note: caller retains ownership of the message
                break :blk @as([]const ai_types.Message, &.{message_or_messages});
            },
            else => @compileError("prompt expects a string, Message, or []const Message"),
        };

        try self.runLoop(messages);
    }

    /// Send a prompt with text and optional images.
    /// Creates a user message with content parts (text + images).
    /// Returns error if already streaming.
    pub fn promptWithImages(
        self: *Agent,
        text: []const u8,
        images: ?[]const ai_types.ImageContent,
    ) !void {
        if (self._state.is_streaming) {
            return error.AgentAlreadyStreaming;
        }

        // Build content parts
        var content_parts: std.ArrayList(ai_types.UserContentPart) = .empty;
        defer content_parts.deinit(self._allocator);

        // Add text part
        try content_parts.append(self._allocator, .{
            .text = .{ .text = text },
        });

        // Add image parts if provided
        if (images) |imgs| {
            for (imgs) |img| {
                try content_parts.append(self._allocator, .{
                    .image = img,
                });
            }
        }

        const msg = ai_types.Message{
            .user = .{
                .content = .{ .parts = content_parts.items },
                .timestamp = compat.time.nowMillis(),
            },
        };

        try self.runLoop(&.{msg});
    }

    /// Continue from current context (for retries and queued messages).
    pub fn continueFromContext(self: *Agent) !void {
        if (self._state.is_streaming) {
            return error.AgentAlreadyStreaming;
        }

        const messages = self._state.messages.items;
        if (messages.len == 0) {
            return error.NoMessagesToContinue;
        }

        // Check if last message is from assistant
        if (messages[messages.len - 1] == .assistant) {
            // First check steering queue
            if (self._steering_queue.items.len > 0) {
                const steering = try self.dequeueSteeringMessages();
                defer if (steering) |s| self._allocator.free(s);

                var run_messages: ?[]const ai_types.Message = if (steering) |s| s else null;
                try self.runLoopInternal(
                    &run_messages,
                    .{ .skip_initial_steering_poll = true },
                );
                return;
            }

            // Then check follow-up queue
            if (self._follow_up_queue.items.len > 0) {
                const follow_up = try self.dequeueFollowUpMessages();
                defer if (follow_up) |f| self._allocator.free(f);

                var run_messages: ?[]const ai_types.Message = if (follow_up) |f| f else null;
                try self.runLoopInternal(
                    &run_messages,
                    .{},
                );
                return;
            }

            return error.CannotContinueFromAssistant;
        }

        var run_messages: ?[]const ai_types.Message = null;
        try self.runLoopInternal(&run_messages, .{});
    }

    /// Abort the current operation.
    pub fn abort(self: *Agent) void {
        if (self._cancel_token) |token| {
            token.cancelled.store(true, .release);
        }
    }

    /// Check if the agent is currently idle (not streaming).
    pub fn isIdle(self: *Agent) bool {
        self._mutex.lockUncancelable(defaultIo());
        defer self._mutex.unlock(defaultIo());
        return !self._state.is_streaming;
    }

    fn prepareContinueFromContextLocked(self: *Agent) !ContinueRequest {
        const messages = self._state.messages.items;
        if (messages.len == 0) {
            return error.NoMessagesToContinue;
        }

        if (messages[messages.len - 1] == .assistant) {
            if (self._steering_queue.items.len > 0) {
                const steering = try self.dequeueSteeringMessagesLocked();
                return .{ .messages = steering, .skip_steering = true };
            }

            if (self._follow_up_queue.items.len > 0) {
                const follow_up = try self.dequeueFollowUpMessagesLocked();
                return .{ .messages = follow_up, .skip_steering = false };
            }

            return error.CannotContinueFromAssistant;
        }

        return .{ .messages = try self._allocator.alloc(ai_types.Message, 0), .skip_steering = false };
    }

    /// Continue from current context asynchronously.
    /// Use waitForIdle() to block until completion.
    pub fn continueFromContextAsync(self: *Agent) !void {
        self._mutex.lockUncancelable(defaultIo());
        defer self._mutex.unlock(defaultIo());

        if (self._state.is_streaming or self._thread != null) {
            return error.AgentAlreadyStreaming;
        }

        const request = try self.prepareContinueFromContextLocked();
        errdefer {
            for (request.messages) |*msg| msg.deinit(self._allocator);
            self._allocator.free(request.messages);
        }

        self._done_event.reset();
        self._state.is_streaming = true;
        errdefer self._state.is_streaming = false;
        self._thread = try std.Thread.spawn(.{}, runLoopThread, .{ self, request.messages, request.skip_steering });
    }

    /// Wait for the agent to become idle.
    /// Blocks until the current operation completes.
    /// Returns immediately if not streaming.
    pub fn waitForIdle(self: *Agent) void {
        self._mutex.lockUncancelable(defaultIo());
        const should_wait = self._state.is_streaming or self._thread != null;
        self._mutex.unlock(defaultIo());

        if (!should_wait) {
            return;
        }

        // Wait for the done event (blocks until set)
        self._done_event.waitUncancelable(defaultIo());

        // Join the thread if it exists
        self._mutex.lockUncancelable(defaultIo());
        defer self._mutex.unlock(defaultIo());

        if (self._thread) |t| {
            t.join();
            self._thread = null;
        }
    }

    /// Send a prompt asynchronously. Returns immediately.
    /// Use waitForIdle() to block until completion.
    /// Returns error if already streaming.
    pub fn promptAsync(self: *Agent, message_or_messages: anytype) !void {
        self._mutex.lockUncancelable(defaultIo());
        defer self._mutex.unlock(defaultIo());

        if (self._state.is_streaming or self._thread != null) {
            return error.AgentAlreadyStreaming;
        }

        const messages: []const ai_types.Message = switch (@TypeOf(message_or_messages)) {
            []const ai_types.Message => message_or_messages,
            ai_types.Message => blk: {
                // Single message - need to create a temporary array
                break :blk @as([]const ai_types.Message, &.{message_or_messages});
            },
            else => @compileError("promptAsync expects a Message or []const Message"),
        };

        // Deep copy messages for thread ownership
        const owned_messages = try self.copyMessagesForThread(messages);

        // Reset done event and set streaming flag
        self._done_event.reset();
        self._state.is_streaming = true;

        // Spawn thread
        self._thread = try std.Thread.spawn(.{}, runLoopThread, .{ self, owned_messages, false });
    }

    /// Deep copy messages for thread ownership
    fn copyMessagesForThread(self: *Agent, messages: []const ai_types.Message) ![]ai_types.Message {
        const owned = try self._allocator.alloc(ai_types.Message, messages.len);
        for (messages, 0..) |msg, i| {
            owned[i] = try self.cloneMessage(msg);
        }
        return owned;
    }

    /// Clone a message with owned strings
    fn cloneMessage(self: *Agent, msg: ai_types.Message) !ai_types.Message {
        return switch (msg) {
            .user => |u| .{ .user = .{
                .content = try self.cloneUserContent(u.content),
                .timestamp = u.timestamp,
            } },
            .assistant => |a| .{ .assistant = try self.cloneAssistantMessage(a) },
            .tool_result => |t| .{ .tool_result = try self.cloneToolResultMessage(t) },
        };
    }

    fn cloneUserContent(self: *Agent, content: ai_types.UserContent) !ai_types.UserContent {
        return switch (content) {
            .text => |t| .{ .text = try self._allocator.dupe(u8, t) },
            .parts => |parts| blk: {
                var cloned_parts = try self._allocator.alloc(ai_types.UserContentPart, parts.len);
                for (parts, 0..) |p, i| {
                    cloned_parts[i] = try self.cloneUserContentPart(p);
                }
                break :blk .{ .parts = cloned_parts };
            },
        };
    }

    fn cloneUserContentPart(self: *Agent, part: ai_types.UserContentPart) !ai_types.UserContentPart {
        return switch (part) {
            .text => |t| .{ .text = .{ .text = try self._allocator.dupe(u8, t.text) } },
            .image => |i| .{ .image = .{
                .data = try self._allocator.dupe(u8, i.data),
                .mime_type = try self._allocator.dupe(u8, i.mime_type),
            } },
        };
    }

    fn cloneAssistantMessage(self: *Agent, msg: ai_types.AssistantMessage) !ai_types.AssistantMessage {
        return ai_types.cloneAssistantMessage(self._allocator, msg);
    }

    fn cloneToolResultMessage(self: *Agent, msg: ai_types.ToolResultMessage) !ai_types.ToolResultMessage {
        var content = try self._allocator.alloc(ai_types.UserContentPart, msg.content.len);
        var initialized: usize = 0;
        errdefer {
            for (content[0..initialized]) |*part| part.deinit(self._allocator);
            self._allocator.free(content);
        }
        for (msg.content, 0..) |c, i| {
            content[i] = .{ .text = .{ .text = try self._allocator.dupe(u8, c.text.text) } };
            initialized += 1;
        }

        const details_json = if (msg.getDetailsJson()) |d|
            ai_types.OwnedSlice(u8).initOwned(try self._allocator.dupe(u8, d))
        else
            ai_types.OwnedSlice(u8).initBorrowed("");
        errdefer {
            var mutable = details_json;
            mutable.deinit(self._allocator);
        }

        const artifacts = try self.cloneArtifactReferences(msg.artifacts.slice());
        errdefer {
            var mutable = ai_types.OwnedSlice(ai_types.ArtifactReference).initOwned(artifacts);
            mutable.deinit(self._allocator);
        }

        const tool_call_id = try self._allocator.dupe(u8, msg.tool_call_id);
        errdefer self._allocator.free(tool_call_id);
        const tool_name = try self._allocator.dupe(u8, msg.tool_name);
        errdefer self._allocator.free(tool_name);

        return .{
            .tool_call_id = tool_call_id,
            .tool_name = tool_name,
            .content = content,
            .details_json = details_json,
            .artifacts = ai_types.OwnedSlice(ai_types.ArtifactReference).initOwned(artifacts),
            .is_error = msg.is_error,
            .timestamp = msg.timestamp,
        };
    }

    fn cloneArtifactReferences(self: *Agent, artifacts: []const ai_types.ArtifactReference) ![]ai_types.ArtifactReference {
        const cloned = try self._allocator.alloc(ai_types.ArtifactReference, artifacts.len);
        var initialized: usize = 0;
        errdefer {
            for (cloned[0..initialized]) |*artifact| artifact.deinit(self._allocator);
            self._allocator.free(cloned);
        }

        for (artifacts, 0..) |artifact, i| {
            cloned[i] = try self.cloneArtifactReference(artifact);
            initialized += 1;
        }

        return cloned;
    }

    fn cloneArtifactReference(self: *Agent, artifact: ai_types.ArtifactReference) !ai_types.ArtifactReference {
        const artifact_id = try self._allocator.dupe(u8, artifact.artifact_id);
        errdefer self._allocator.free(artifact_id);

        const uri = if (artifact.getUri()) |value|
            ai_types.OwnedSlice(u8).initOwned(try self._allocator.dupe(u8, value))
        else
            ai_types.OwnedSlice(u8).initBorrowed("");
        errdefer {
            var mutable = uri;
            mutable.deinit(self._allocator);
        }

        const mime_type = if (artifact.getMimeType()) |value|
            ai_types.OwnedSlice(u8).initOwned(try self._allocator.dupe(u8, value))
        else
            ai_types.OwnedSlice(u8).initBorrowed("");
        errdefer {
            var mutable = mime_type;
            mutable.deinit(self._allocator);
        }

        const sha256 = if (artifact.getSha256()) |value|
            ai_types.OwnedSlice(u8).initOwned(try self._allocator.dupe(u8, value))
        else
            ai_types.OwnedSlice(u8).initBorrowed("");
        errdefer {
            var mutable = sha256;
            mutable.deinit(self._allocator);
        }

        const description = if (artifact.getDescription()) |value|
            ai_types.OwnedSlice(u8).initOwned(try self._allocator.dupe(u8, value))
        else
            ai_types.OwnedSlice(u8).initBorrowed("");

        return .{
            .artifact_id = artifact_id,
            .uri = uri,
            .mime_type = mime_type,
            .byte_size = artifact.byte_size,
            .sha256 = sha256,
            .description = description,
        };
    }

    /// Thread entry point for async execution
    fn runLoopThread(self: *Agent, messages: []ai_types.Message, skip_steering: bool) void {
        var messages_owned = true;
        defer {
            if (messages_owned) {
                for (messages) |*m| {
                    m.deinit(self._allocator);
                }
            }
            self._allocator.free(messages);

            // Signal completion
            self._done_event.set(defaultIo());

            // Update state under lock
            self._mutex.lockUncancelable(defaultIo());
            self._state.is_streaming = false;
            self._mutex.unlock(defaultIo());
        }

        if (messages.len > 0 and self._state.model == null) {
            return;
        }

        var run_messages: ?[]const ai_types.Message = if (messages.len > 0) messages else null;
        if (messages.len == 0 and self._state.messages.items.len == 0) {
            return;
        }

        // Run the loop. runLoopInternal only clears run_messages after the
        // prompt slice has been consumed successfully. If an error occurs before
        // that transfer, messages_owned remains true and the thread cleanup
        // frees the cloned payloads here.
        self.runLoopInternal(
            &run_messages,
            .{ .skip_initial_steering_poll = skip_steering },
        ) catch {};
        messages_owned = run_messages != null;
    }

    /// Reset all state (clear messages, queues, error).
    pub fn reset(self: *Agent) void {
        self.clearMessages();
        self.clearAllQueues();
        self._state.is_streaming = false;
        self._state.stream_message = null;
        self._state.pending_tool_calls.clearRetainingCapacity();
        self._state.error_message.deinit(self._allocator);
        self._state.error_message = types.OwnedSlice(u8).initBorrowed("");
    }

    // === Internal ===

    const RunLoopOptions = struct {
        skip_initial_steering_poll: bool = false,
    };

    fn runLoop(self: *Agent, messages: []const ai_types.Message) !void {
        var run_messages: ?[]const ai_types.Message = messages;
        try self.runLoopInternal(&run_messages, .{});
    }

    fn runLoopInternal(
        self: *Agent,
        messages: *?[]const ai_types.Message,
        options: RunLoopOptions,
    ) !void {
        const model = self._state.model orelse return error.NoModelConfigured;

        // Set up cancel token
        var cancelled = std.atomic.Value(bool).init(false);
        self._cancel_token = .{ .cancelled = &cancelled };
        self._state.is_streaming = true;
        errdefer {
            self._state.is_streaming = false;
            self._cancel_token = null;
        }
        self._state.stream_message = null;
        self._state.error_message.deinit(self._allocator);
        self._state.error_message = types.OwnedSlice(u8).initBorrowed("");

        // Set skip flag for this run (stored in agent, not global)
        self._skip_initial_steering_poll = options.skip_initial_steering_poll;

        // Build context
        var context = AgentContext.init(self._allocator);
        defer context.deinit();

        context.system_prompt = types.OwnedSlice(u8).initBorrowed(self._state.system_prompt);
        context.tools = self._state.tools;

        // Copy existing state messages into the loop context. AgentContext owns
        // its messages and frees them on deinit, while AgentState also owns its
        // history, so context must receive independent clones.
        for (self._state.messages.items) |msg| {
            try context.appendMessage(try self.cloneMessage(msg));
        }

        // Build config. Agent remains auth-agnostic; provider layer owns credentials.
        const config = agent_loop.AgentLoopConfig{
            .model = model,
            .protocol = self._protocol,
            .tools = self._state.tools,
            .temperature = null,
            .max_tokens = null,
            .api_key = null,
            .cancel_token = self._cancel_token,
            .max_iterations = null,
            .session_id = self._session_id,
            .thinking_budgets = self._thinking_budgets,
            .max_retry_delay_ms = self._max_retry_delay_ms,
            .transform_context_fn = self._transform_context_fn,
            .transform_context_ctx = self._transform_context_ctx,
            .get_steering_messages_fn = getSteeringMessages,
            .get_steering_messages_ctx = self,
            .get_follow_up_messages_fn = getFollowUpMessages,
            .get_follow_up_messages_ctx = self,
            .convert_to_llm_fn = self._convert_to_llm_fn,
            .convert_to_llm_ctx = self._convert_to_llm_ctx,
            .get_api_key_fn = self._get_api_key_fn,
            .get_api_key_ctx = self._get_api_key_ctx,
        };

        // Track how many messages context has before the loop so we can tell
        // whether any prompts were actually consumed.
        const initial_message_count = context.messages.items.len;

        // Run loop
        const stream = if (messages.*) |msgs|
            try agent_loop.agentLoop(self._allocator, msgs, &context, config)
        else
            try agent_loop.agentLoopContinue(self._allocator, &context, config);

        defer {
            stream.deinit();
            self._allocator.destroy(stream);
        }

        // Process events
        while (stream.wait()) |event| {
            // Update internal state based on events
            switch (event) {
                .message_start => |e| {
                    self._state.stream_message = e.message;
                },
                .message_update => |e| {
                    self._state.stream_message = .{ .assistant = e.message };
                },
                .message_end => |e| {
                    // Add an owned copy to Agent state; event payloads may be borrowed
                    // from loop context/provider buffers and are freed elsewhere.
                    try self._state.messages.append(self._allocator, try self.cloneMessage(e.message));
                    self._state.stream_message = null;
                },
                .tool_execution_start => |e| {
                    try self._state.pending_tool_calls.put(e.tool_call_id, {});
                },
                .tool_execution_end => |e| {
                    _ = self._state.pending_tool_calls.remove(e.tool_call_id);
                },
                .turn_end => |e| {
                    if (e.message.getErrorMessage()) |err| {
                        self._state.error_message.deinit(self._allocator);
                        self._state.error_message = types.OwnedSlice(u8).initOwned(try self._allocator.dupe(u8, err));
                    }
                },
                .agent_end => {
                    self._state.is_streaming = false;
                    self._state.stream_message = null;
                },
                else => {},
            }

            // Emit to listeners
            self.emit(event);
        }

        // Transfer ownership if any prompts were actually consumed (appended to
        // context). This avoids a double-free when consumed prompts were
        // shallow-copied into context, while still letting the caller clean up
        // unconsumed prompts on early failure.
        if (context.messages.items.len > initial_message_count) {
            messages.* = null;
        }

        // Surface background-loop errors so callers do not receive ok when the
        // agent loop aborted. completeWithError sets err_msg; complete(result)
        // with an error stop_reason is checked via getResult(); a completed
        // stream with neither result nor error (e.g., OOM in completeWithError)
        // is also treated as failure.
        if (stream.getError() != null) {
            return error.AgentLoopFailed;
        }
        if (stream.getResult()) |result| {
            if (result.final_message.stop_reason == .@"error") {
                return error.AgentLoopFailed;
            }
        } else if (stream.isDone()) {
            return error.AgentLoopFailed;
        }

        self._state.is_streaming = false;
        self._cancel_token = null;
    }

    fn emit(self: *Agent, event: AgentEvent) void {
        for (self._listeners.items) |listener| {
            listener.callback(listener.ctx, event);
        }
    }

    fn dequeueSteeringMessagesLocked(self: *Agent) ![]ai_types.Message {
        if (self._steering_mode == .one_at_a_time) {
            const first = self._steering_queue.orderedRemove(0);
            const result = try self._allocator.alloc(ai_types.Message, 1);
            result[0] = first;
            return result;
        }

        const count = self._steering_queue.items.len;
        const result = try self._allocator.alloc(ai_types.Message, count);
        for (self._steering_queue.items, 0..) |msg, i| {
            result[i] = msg;
        }
        self._steering_queue.clearRetainingCapacity();
        return result;
    }

    fn dequeueSteeringMessages(self: *Agent) !?[]ai_types.Message {
        self._mutex.lockUncancelable(defaultIo());
        defer self._mutex.unlock(defaultIo());

        if (self._steering_queue.items.len == 0) return null;
        return try self.dequeueSteeringMessagesLocked();
    }

    fn dequeueFollowUpMessagesLocked(self: *Agent) ![]ai_types.Message {
        if (self._follow_up_mode == .one_at_a_time) {
            const first = self._follow_up_queue.orderedRemove(0);
            const result = try self._allocator.alloc(ai_types.Message, 1);
            result[0] = first;
            return result;
        }

        const count = self._follow_up_queue.items.len;
        const result = try self._allocator.alloc(ai_types.Message, count);
        for (self._follow_up_queue.items, 0..) |msg, i| {
            result[i] = msg;
        }
        self._follow_up_queue.clearRetainingCapacity();
        return result;
    }

    fn dequeueFollowUpMessages(self: *Agent) !?[]ai_types.Message {
        self._mutex.lockUncancelable(defaultIo());
        defer self._mutex.unlock(defaultIo());

        if (self._follow_up_queue.items.len == 0) return null;
        return try self.dequeueFollowUpMessagesLocked();
    }

    // === Static Callbacks ===

    fn getSteeringMessages(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!?[]ai_types.Message {
        _ = allocator; // Used by dequeueSteeringMessages internally
        const self: *Agent = @ptrCast(@alignCast(ctx));

        // Check skip flag stored in agent instance (thread-safe per-agent)
        if (self._skip_initial_steering_poll) {
            self._skip_initial_steering_poll = false;
            return null;
        }

        return self.dequeueSteeringMessages();
    }

    fn getFollowUpMessages(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!?[]ai_types.Message {
        _ = allocator; // Used by dequeueFollowUpMessages
        const self: *Agent = @ptrCast(@alignCast(ctx));
        return self.dequeueFollowUpMessages();
    }
};

// ============================================================================
// Tests
// ============================================================================

// Mock protocol for testing - just returns an error since we're testing state management
fn mockStreamFn(
    ctx: ?*anyopaque,
    model: ai_types.Model,
    context: ai_types.Context,
    options: types.ProtocolOptions,
    allocator: std.mem.Allocator,
) anyerror!*event_stream_mod.AssistantMessageEventStream {
    _ = ctx;
    _ = model;
    _ = context;
    _ = options;
    _ = allocator;
    return error.NotImplemented;
}

fn createMockProtocol() types.ProtocolClient {
    return .{
        .stream_fn = mockStreamFn,
        .ctx = null,
    };
}

test "Agent init and deinit" {
    var agent = Agent.init(std.testing.allocator, .{ .protocol = createMockProtocol() });
    defer agent.deinit();

    try std.testing.expect(!agent.isStreaming());
    try std.testing.expect(!agent.hasQueuedMessages());
}

test "Agent setSystemPrompt" {
    var agent = Agent.init(std.testing.allocator, .{ .protocol = createMockProtocol() });
    defer agent.deinit();

    try agent.setSystemPrompt("You are helpful.");
    try std.testing.expectEqualStrings("You are helpful.", agent._state.system_prompt);

    // Overwrite
    try agent.setSystemPrompt("New prompt");
    try std.testing.expectEqualStrings("New prompt", agent._state.system_prompt);
}

test "Agent message queues" {
    var agent = Agent.init(std.testing.allocator, .{ .protocol = createMockProtocol() });
    defer agent.deinit();

    // Use owned strings since clearAllQueues will try to free them
    // Create separate messages for each queue to avoid double-free
    const text1 = try std.testing.allocator.dupe(u8, "test1");
    const msg1 = ai_types.Message{
        .user = .{
            .content = .{ .text = text1 },
            .timestamp = 0,
        },
    };

    const text2 = try std.testing.allocator.dupe(u8, "test2");
    const msg2 = ai_types.Message{
        .user = .{
            .content = .{ .text = text2 },
            .timestamp = 0,
        },
    };

    try agent.steer(msg1);
    try std.testing.expect(agent.hasQueuedMessages());

    try agent.followUp(msg2);
    try std.testing.expect(agent.hasQueuedMessages());

    agent.clearAllQueues();
    try std.testing.expect(!agent.hasQueuedMessages());
}

test "Agent queue modes" {
    var agent = Agent.init(std.testing.allocator, .{ .protocol = createMockProtocol() });
    defer agent.deinit();

    agent.setSteeringMode(.all);
    try std.testing.expectEqual(QueueMode.all, agent.getSteeringMode());

    agent.setFollowUpMode(.one_at_a_time);
    try std.testing.expectEqual(QueueMode.one_at_a_time, agent.getFollowUpMode());
}

test "Agent reset" {
    var agent = Agent.init(std.testing.allocator, .{ .protocol = createMockProtocol() });
    defer agent.deinit();

    // Use owned strings since reset will try to free them
    // Create separate messages for each queue to avoid double-free
    const text1 = try std.testing.allocator.dupe(u8, "test1");
    const msg1 = ai_types.Message{
        .user = .{
            .content = .{ .text = text1 },
            .timestamp = 0,
        },
    };

    const text2 = try std.testing.allocator.dupe(u8, "test2");
    const msg2 = ai_types.Message{
        .user = .{
            .content = .{ .text = text2 },
            .timestamp = 0,
        },
    };

    try agent.appendMessage(msg1);
    try agent.steer(msg2);

    agent.reset();

    try std.testing.expectEqual(@as(usize, 0), agent._state.messages.items.len);
    try std.testing.expect(!agent.hasQueuedMessages());
}

test "Agent subscribe and unsubscribe" {
    var agent = Agent.init(std.testing.allocator, .{ .protocol = createMockProtocol() });
    defer agent.deinit();

    const callback = struct {
        fn onEvent(event: AgentEvent) void {
            _ = event;
            // Increment would need external state - this is just a compile check
        }
    }.onEvent;

    agent.subscribe(callback);
    try std.testing.expectEqual(@as(usize, 1), agent._listeners.items.len);

    agent.unsubscribe(callback);
    try std.testing.expectEqual(@as(usize, 0), agent._listeners.items.len);
}

test "Agent isIdle and waitForIdle" {
    var agent = Agent.init(std.testing.allocator, .{ .protocol = createMockProtocol() });
    defer agent.deinit();

    // Agent starts idle
    try std.testing.expect(agent.isIdle());

    // waitForIdle should return immediately when idle
    agent.waitForIdle();

    // Still idle after waitForIdle
    try std.testing.expect(agent.isIdle());
}

fn delayedErrorStreamFn(
    ctx: ?*anyopaque,
    model: ai_types.Model,
    context: ai_types.Context,
    options: types.ProtocolOptions,
    allocator: std.mem.Allocator,
) anyerror!*event_stream_mod.AssistantMessageEventStream {
    _ = ctx;
    _ = model;
    _ = context;
    _ = options;

    defaultIo().sleep(.fromNanoseconds(10 * std.time.ns_per_ms), .boot) catch {};

    const stream = try allocator.create(event_stream_mod.AssistantMessageEventStream);
    stream.* = event_stream_mod.AssistantMessageEventStream.init(allocator);
    const message = ai_types.AssistantMessage{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .@"error",
        .error_message = ai_types.OwnedSlice(u8).initBorrowed("test done"),
        .timestamp = 0,
    };
    stream.push(.{ .done = .{ .reason = .@"error", .message = message } }) catch {};
    stream.complete(message);
    return stream;
}

fn createDelayedErrorProtocol() types.ProtocolClient {
    return .{
        .stream_fn = delayedErrorStreamFn,
        .ctx = null,
    };
}

const test_model = ai_types.Model{
    .id = "test-model",
    .name = "Test Model",
    .api = "test-api",
    .provider = "test-provider",
    .base_url = "https://example.invalid",
    .reasoning = false,
    .input = &.{"text"},
    .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
    .context_window = 8192,
    .max_tokens = 1024,
};

test "Agent async completion signals waitForIdle" {
    var agent = Agent.init(std.testing.allocator, .{ .protocol = createDelayedErrorProtocol() });
    defer agent.deinit();
    agent.setModel(test_model);

    try agent.promptAsync(@as([]const ai_types.Message, &.{}));

    agent.waitForIdle();

    try std.testing.expect(agent.isIdle());
    try std.testing.expect(agent._thread == null);
}

test "Agent continueFromContextAsync mirrors sync resume checks" {
    var agent = Agent.init(std.testing.allocator, .{ .protocol = createDelayedErrorProtocol() });
    defer agent.deinit();
    agent.setModel(test_model);

    const assistant = ai_types.Message{ .assistant = .{
        .content = &.{},
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    } };
    try agent.appendMessage(assistant);

    try std.testing.expectError(error.CannotContinueFromAssistant, agent.continueFromContextAsync());

    const steering_text = try std.testing.allocator.dupe(u8, "steer");
    try agent.steer(.{ .user = .{ .content = .{ .text = steering_text }, .timestamp = 1 } });
    try agent.continueFromContextAsync();
    try std.testing.expect(agent.isStreaming());
    agent.waitForIdle();
    try std.testing.expectEqual(@as(usize, 0), agent._steering_queue.items.len);
}

test "Agent cloneMessage" {
    var agent = Agent.init(std.testing.allocator, .{ .protocol = createMockProtocol() });
    defer agent.deinit();

    const original = ai_types.Message{
        .user = .{
            .content = .{ .text = "Hello, world!" },
            .timestamp = 12345,
        },
    };

    var cloned = try agent.cloneMessage(original);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expect(cloned == .user);
    try std.testing.expectEqualStrings("Hello, world!", cloned.user.content.text);
}

test "Agent cloneMessage preserves assistant signatures" {
    var agent = Agent.init(std.testing.allocator, .{ .protocol = createMockProtocol() });
    defer agent.deinit();

    const content = [_]ai_types.AssistantContent{
        .{ .text = .{ .text = "text", .text_signature = "text-sig" } },
        .{ .thinking = .{ .thinking = "thought", .thinking_signature = "thinking-sig" } },
        .{ .tool_call = .{ .id = "tool-id", .name = "tool", .arguments_json = "{}", .thought_signature = "thought-sig" } },
    };
    const original = ai_types.Message{ .assistant = .{
        .content = &content,
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 12345,
    } };

    var cloned = try agent.cloneMessage(original);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expect(cloned == .assistant);
    try std.testing.expectEqualStrings("text-sig", cloned.assistant.content[0].text.text_signature.?);
    try std.testing.expectEqualStrings("thinking-sig", cloned.assistant.content[1].thinking.thinking_signature.?);
    try std.testing.expectEqualStrings("thought-sig", cloned.assistant.content[2].tool_call.thought_signature.?);
}
