const std = @import("std");
const oap_types = @import("oap_types");

pub const PROTOCOL = oap_types.PROTOCOL;
pub const VERSION = oap_types.VERSION;
pub const PROFILE = "open-agent-protocol.model-provider-core";

pub const SUPPORTED_PROTOCOL_VERSIONS = [_][]const u8{VERSION};

pub const Role = oap_types.Role;
pub const ContentPart = oap_types.ContentPart;
pub const ToolCallPart = oap_types.ToolCallPart;
pub const ToolResultPart = oap_types.ToolResultPart;
pub const Content = oap_types.Content;
pub const Message = oap_types.Message;
pub const Usage = oap_types.Usage;
pub const DetailEntry = oap_types.DetailEntry;

pub const freeStringList = oap_types.freeStringList;
pub const dupeStringList = oap_types.dupeStringList;

pub const Wire = enum {
    @"openai-responses",
    @"anthropic-messages",
    @"openai-chat-completions",
    other,

    pub fn isNamed(self: Wire) bool {
        return self != .other;
    }

    pub fn parse(value: []const u8) ?Wire {
        return std.meta.stringToEnum(Wire, value);
    }

    pub fn toString(self: Wire) []const u8 {
        return @tagName(self);
    }
};

pub const Framing = enum {
    sse,
    ndjson,
    unary,

    pub fn parse(value: []const u8) ?Framing {
        return std.meta.stringToEnum(Framing, value);
    }
};

pub const PartKind = enum {
    text,
    reasoning,
    tool_call,

    pub fn parse(value: []const u8) ?PartKind {
        return std.meta.stringToEnum(PartKind, value);
    }
};

pub const StopReason = enum {
    stop,
    length,
    tool_use,
    content_filter,
    @"error",
    aborted,

    pub fn parse(value: []const u8) ?StopReason {
        return std.meta.stringToEnum(StopReason, value);
    }
};

pub const SnapshotPolicy = enum {
    never,
    on_part_end,
    every_delta,

    pub fn parse(value: []const u8) ?SnapshotPolicy {
        return std.meta.stringToEnum(SnapshotPolicy, value);
    }
};

pub const AuthStatus = enum {
    authenticated,
    login_required,
    expired,
    failed,
    unknown,

    pub fn parse(value: []const u8) ?AuthStatus {
        return std.meta.stringToEnum(AuthStatus, value);
    }
};

pub const ModelLifecycle = enum {
    stable,
    preview,
    deprecated,

    pub fn parse(value: []const u8) ?ModelLifecycle {
        return std.meta.stringToEnum(ModelLifecycle, value);
    }
};

pub const ModelSource = enum {
    discovered,
    fallback,

    pub fn parse(value: []const u8) ?ModelSource {
        return std.meta.stringToEnum(ModelSource, value);
    }
};

pub const ModelCapability = enum {
    chat,
    streaming,
    tools,
    vision,
    reasoning,
    prompt_cache,
    audio_input,
    audio_output,

    pub fn parse(value: []const u8) ?ModelCapability {
        return std.meta.stringToEnum(ModelCapability, value);
    }
};

pub const ReasoningLevel = enum {
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,

    pub fn parse(value: []const u8) ?ReasoningLevel {
        return std.meta.stringToEnum(ReasoningLevel, value);
    }
};

pub const ErrorCode = enum {
    rate_limited,
    provider_unavailable,
    resource_exhausted,
    endpoint_error,
    credential_expired,
    credential_missing,
    credential_rejected,
    invalid_request,
    protocol_violation,
    unsupported_version,
    unsupported_feature,
    model_not_found,
    aborted,

    pub fn parse(value: []const u8) ?ErrorCode {
        return std.meta.stringToEnum(ErrorCode, value);
    }

    pub fn action(self: ErrorCode) ErrorAction {
        return switch (self) {
            .rate_limited, .provider_unavailable, .resource_exhausted, .endpoint_error => .retry,
            .credential_expired => .refresh,
            .credential_missing, .credential_rejected => .authenticate,
            .invalid_request,
            .protocol_violation,
            .unsupported_version,
            .unsupported_feature,
            .model_not_found,
            => .report,
            .aborted => .accept,
        };
    }
};

pub const ErrorAction = enum {
    retry,
    refresh,
    authenticate,
    report,
    accept,
};

pub const ProtocolError = struct {
    code: ErrorCode,
    message: []const u8,
    details: []const DetailEntry = &.{},

    pub fn detail(self: *const ProtocolError, key: []const u8) ?[]const u8 {
        for (self.details) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }

    pub fn deinit(self: *ProtocolError, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        for (self.details) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
        allocator.free(self.details);
    }
};

pub const MaxTokensField = enum {
    max_tokens,
    max_completion_tokens,

    pub fn parse(value: []const u8) ?MaxTokensField {
        return std.meta.stringToEnum(MaxTokensField, value);
    }
};

pub const ThinkingFormat = enum {
    openai,
    zai,
    qwen,

    pub fn parse(value: []const u8) ?ThinkingFormat {
        return std.meta.stringToEnum(ThinkingFormat, value);
    }
};

pub const UsageInStreaming = enum {
    always,
    terminal_only,
    never,

    pub fn parse(value: []const u8) ?UsageInStreaming {
        return std.meta.stringToEnum(UsageInStreaming, value);
    }
};

pub const ToolCallIdFormat = enum {
    unconstrained,
    constrained,

    pub fn parse(value: []const u8) ?ToolCallIdFormat {
        return std.meta.stringToEnum(ToolCallIdFormat, value);
    }

    pub fn toString(self: ToolCallIdFormat) []const u8 {
        return @tagName(self);
    }
};

pub const DEGRADABLE_SNAPSHOT_KEY = "include_snapshot";

pub fn allowsDegraded(keys: []const []const u8, key: []const u8) bool {
    for (keys) |candidate| {
        if (std.mem.eql(u8, candidate, key)) return true;
    }
    return false;
}

pub const CompatibilityFacts = struct {
    max_tokens_field: ?MaxTokensField = null,
    thinking_format: ?ThinkingFormat = null,
    usage_in_streaming: ?UsageInStreaming = null,
    requires_assistant_after_tool_result: ?bool = null,
    requires_tool_result_name: ?bool = null,
    requires_thinking_as_text: ?bool = null,
    supports_strict_mode: ?bool = null,
    supports_store: ?bool = null,
    supports_developer_role: ?bool = null,
    supports_reasoning_effort: ?bool = null,
    tool_call_id_format: ?ToolCallIdFormat = null,
    cache_ttl_control: ?bool = null,

    pub fn isEmpty(self: CompatibilityFacts) bool {
        inline for (@typeInfo(CompatibilityFacts).@"struct".fields) |field| {
            if (@field(self, field.name) != null) return false;
        }
        return true;
    }
};

pub const HeaderPair = struct {
    name: []const u8,
    value: []const u8,

    pub fn deinit(self: *HeaderPair, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

pub fn freeHeaders(allocator: std.mem.Allocator, headers: []const HeaderPair) void {
    for (headers) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
    allocator.free(headers);
}

pub const CREDENTIAL_HEADER_NAMES = [_][]const u8{
    "authorization",
    "proxy-authorization",
    "x-api-key",
    "api-key",
};

pub fn isCredentialHeaderName(name: []const u8) bool {
    for (CREDENTIAL_HEADER_NAMES) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

pub fn looksLikeBearerValue(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len < 7) return false;
    return std.ascii.startsWithIgnoreCase(trimmed, "bearer ");
}

pub fn headerCarriesCredential(header: HeaderPair) bool {
    if (isCredentialHeaderName(header.name)) return true;
    return looksLikeBearerValue(header.value);
}

pub const CredentialGrantChannel = enum {
    none,
    out_of_band,
    on_envelope,

    pub fn parse(value: []const u8) ?CredentialGrantChannel {
        return std.meta.stringToEnum(CredentialGrantChannel, value);
    }
};

pub const GrantKind = enum {
    static,
    refreshable,

    pub fn parse(value: []const u8) ?GrantKind {
        return std.meta.stringToEnum(GrantKind, value);
    }
};

pub fn supportsSnapshotPolicy(policies: []const SnapshotPolicy, policy: SnapshotPolicy) bool {
    for (policies) |candidate| {
        if (candidate == policy) return true;
    }
    return policy == .never;
}

pub const ProviderDescriptor = struct {
    id: []const u8,
    display_name: ?[]const u8 = null,
    wire: Wire,
    wire_id: ?[]const u8 = null,
    framing: Framing,
    endpoint: []const u8,
    headers: []const HeaderPair = &.{},
    compatibility: CompatibilityFacts = .{},
    snapshot_policies: []const SnapshotPolicy = &.{},
    answers_sync: bool = false,
    credential_grant: CredentialGrantChannel = .none,
    grant_kinds: []const GrantKind = &.{},
    allows_anonymous: bool = false,
    round_trips_carry: bool = false,
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,

    pub fn deinit(self: *ProviderDescriptor, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.display_name) |value| allocator.free(value);
        if (self.wire_id) |value| allocator.free(value);
        allocator.free(self.endpoint);
        freeHeaders(allocator, self.headers);
        allocator.free(self.grant_kinds);
        allocator.free(self.snapshot_policies);
    }
};

pub const ParsedModelRef = struct {
    provider_id: []const u8,
    wire: Wire,
    wire_id: ?[]const u8,
    model_id: []const u8,
};

pub fn parseModelRef(model_ref: []const u8) ?ParsedModelRef {
    const slash = std.mem.indexOfScalar(u8, model_ref, '/') orelse return null;
    if (slash == 0) return null;

    const rest = model_ref[slash + 1 ..];
    const at = std.mem.indexOfScalar(u8, rest, '@') orelse return null;
    if (at + 1 >= rest.len) return null;

    const component = rest[0..at];
    if (component.len == 0) return null;
    const wire = parseWireComponent(component) orelse return null;
    const wire_id = wireIdComponent(component);
    if (wire == .other and wire_id == null) return null;
    if (wire != .other and wire_id != null) return null;
    if (wire_id) |value| {
        if (value.len == 0) return null;
    }

    return .{
        .provider_id = model_ref[0..slash],
        .wire = wire,
        .wire_id = wire_id,
        .model_id = rest[at + 1 ..],
    };
}

pub fn parseWireComponent(component: []const u8) ?Wire {
    const colon = std.mem.indexOfScalar(u8, component, ':') orelse return Wire.parse(component);
    return Wire.parse(component[0..colon]);
}

pub fn wireIdComponent(component: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, component, ':') orelse return null;
    if (colon + 1 >= component.len) return null;
    return component[colon + 1 ..];
}

pub const ModelEntry = struct {
    model_ref: []const u8,
    model_id: []const u8,
    display_name: ?[]const u8 = null,
    provider_id: []const u8,
    wire: Wire,
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
    capabilities: []const ModelCapability = &.{},
    lifecycle: ModelLifecycle = .stable,
    source: ModelSource = .discovered,
    reasoning_default: ?ReasoningLevel = null,
    auth_status: AuthStatus = .unknown,

    pub fn deinit(self: *ModelEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.model_ref);
        allocator.free(self.model_id);
        if (self.display_name) |value| allocator.free(value);
        allocator.free(self.provider_id);
        allocator.free(self.capabilities);
    }
};

pub const ReasoningOptions = struct {
    enabled: ?bool = null,
    budget_tokens: ?u32 = null,
    effort: ?[]const u8 = null,

    pub fn deinit(self: *ReasoningOptions, allocator: std.mem.Allocator) void {
        if (self.effort) |value| allocator.free(value);
    }
};

pub const ToolDefinition = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    input_schema_json: ?[]const u8 = null,

    pub fn deinit(self: *ToolDefinition, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.description) |value| allocator.free(value);
        if (self.input_schema_json) |value| allocator.free(value);
    }
};

pub const ToolChoice = union(enum) {
    auto,
    none,
    required,
    function: []const u8,

    pub fn deinit(self: *ToolChoice, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .function => |name| allocator.free(name),
            else => {},
        }
    }
};

pub const DescribeRequest = struct {};

pub const DescribeResponse = struct {
    providers: []ProviderDescriptor = &.{},
    protocol_versions: []const []const u8 = &.{},
    profile_revision: ?[]const u8 = null,

    pub fn deinit(self: *DescribeResponse, allocator: std.mem.Allocator) void {
        for (self.providers) |*descriptor| descriptor.deinit(allocator);
        allocator.free(self.providers);
        freeStringList(allocator, self.protocol_versions);
        if (self.profile_revision) |value| allocator.free(value);
    }
};

pub const ModelsListRequest = struct {
    provider_id: ?[]const u8 = null,

    pub fn deinit(self: *ModelsListRequest, allocator: std.mem.Allocator) void {
        if (self.provider_id) |value| allocator.free(value);
    }
};

pub const ModelsListResponse = struct {
    models: []ModelEntry = &.{},

    pub fn deinit(self: *ModelsListResponse, allocator: std.mem.Allocator) void {
        for (self.models) |*entry| entry.deinit(allocator);
        allocator.free(self.models);
    }
};

pub const CreateRequest = struct {
    model_ref: []const u8,
    messages: []Message = &.{},
    tools: []ToolDefinition = &.{},
    tool_choice: ?ToolChoice = null,
    max_output_tokens: ?u32 = null,
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    output_schema_json: ?[]const u8 = null,
    stream: bool = true,
    reasoning: ?ReasoningOptions = null,
    include_snapshot: SnapshotPolicy = .never,
    headers: []const HeaderPair = &.{},
    credential_ref: ?[]const u8 = null,
    metadata_json: ?[]const u8 = null,
    allow_degraded_features: []const []const u8 = &.{},

    pub fn deinit(self: *CreateRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.model_ref);
        for (self.messages) |*message| message.deinit(allocator);
        allocator.free(self.messages);
        for (self.tools) |*tool| tool.deinit(allocator);
        allocator.free(self.tools);
        if (self.tool_choice) |*choice| choice.deinit(allocator);
        if (self.output_schema_json) |value| allocator.free(value);
        if (self.reasoning) |*value| value.deinit(allocator);
        freeHeaders(allocator, self.headers);
        if (self.credential_ref) |value| allocator.free(value);
        if (self.metadata_json) |value| allocator.free(value);
        freeStringList(allocator, self.allow_degraded_features);
    }
};

pub const CreateResponse = struct {
    accepted: bool,
    honoured: ?SnapshotPolicy = null,
    err: ?ProtocolError = null,

    pub fn deinit(self: *CreateResponse, allocator: std.mem.Allocator) void {
        if (self.err) |*value| value.deinit(allocator);
    }
};

pub const InferenceStarted = struct {
    model_ref: []const u8,
    started_at_ms: i64,

    pub fn deinit(self: *InferenceStarted, allocator: std.mem.Allocator) void {
        allocator.free(self.model_ref);
    }
};

pub const PartStarted = struct {
    part_index: u32,
    part_kind: PartKind,
    tool_call_id: ?[]const u8 = null,
    name: ?[]const u8 = null,

    pub fn deinit(self: *PartStarted, allocator: std.mem.Allocator) void {
        if (self.tool_call_id) |value| allocator.free(value);
        if (self.name) |value| allocator.free(value);
    }
};

pub const PartDelta = struct {
    part_index: u32,
    delta: []const u8,
    snapshot: ?[]Message = null,

    pub fn deinit(self: *PartDelta, allocator: std.mem.Allocator) void {
        allocator.free(self.delta);
        if (self.snapshot) |messages| {
            for (messages) |*message| message.deinit(allocator);
            allocator.free(messages);
        }
    }
};

pub const PartEnded = struct {
    part_index: u32,
    part_kind: PartKind,
    text: ?[]const u8 = null,
    tool_call: ?ToolCallPart = null,
    carry: ?[]const u8 = null,
    snapshot: ?[]Message = null,

    pub fn deinit(self: *PartEnded, allocator: std.mem.Allocator) void {
        if (self.text) |value| allocator.free(value);
        if (self.carry) |value| allocator.free(value);
        if (self.tool_call) |*value| value.deinit(allocator);
        if (self.snapshot) |messages| {
            for (messages) |*message| message.deinit(allocator);
            allocator.free(messages);
        }
    }
};

pub const InferenceCompleted = struct {
    message: Message,
    stop_reason: StopReason,
    usage: ?Usage = null,

    pub fn deinit(self: *InferenceCompleted, allocator: std.mem.Allocator) void {
        self.message.deinit(allocator);
    }
};

pub const InferenceFailed = struct {
    err: ProtocolError,
    usage: ?Usage = null,

    pub fn deinit(self: *InferenceFailed, allocator: std.mem.Allocator) void {
        self.err.deinit(allocator);
    }
};

pub const CancelRequest = struct {
    reason: ?[]const u8 = null,

    pub fn deinit(self: *CancelRequest, allocator: std.mem.Allocator) void {
        if (self.reason) |value| allocator.free(value);
    }
};

pub const CancelResponse = struct {
    accepted: bool,
};

pub const SyncRequest = struct {};

pub const SyncResponse = struct {
    snapshot: ?[]Message = null,

    pub fn deinit(self: *SyncResponse, allocator: std.mem.Allocator) void {
        if (self.snapshot) |messages| {
            for (messages) |*message| message.deinit(allocator);
            allocator.free(messages);
        }
    }
};

pub const CredentialGrantRequest = struct {
    provider_id: []const u8,
    nonce: []const u8,
    ttl_ms: ?u64 = null,
    value: ?[]const u8 = null,

    pub fn deinit(self: *CredentialGrantRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.provider_id);
        allocator.free(self.nonce);
        if (self.value) |v| allocator.free(v);
    }
};

pub const CredentialChannel = struct {
    nonce: []const u8,
    channel: []const u8,

    pub fn deinit(self: *CredentialChannel, allocator: std.mem.Allocator) void {
        allocator.free(self.nonce);
        allocator.free(self.channel);
    }
};

pub const CredentialGrantResponse = struct {
    accepted: bool,
    credential_ref: ?[]const u8 = null,
    expires_at_ms: ?i64 = null,
    err: ?ProtocolError = null,

    pub fn deinit(self: *CredentialGrantResponse, allocator: std.mem.Allocator) void {
        if (self.credential_ref) |value| allocator.free(value);
        if (self.err) |*value| value.deinit(allocator);
    }
};

pub const ErrorEnvelopePayload = struct {
    err: ProtocolError,
    protocol_versions: []const []const u8 = &.{},

    pub fn deinit(self: *ErrorEnvelopePayload, allocator: std.mem.Allocator) void {
        self.err.deinit(allocator);
        freeStringList(allocator, self.protocol_versions);
    }
};

pub const Payload = union(enum) {
    provider_describe_request: DescribeRequest,
    provider_describe_response: DescribeResponse,
    provider_models_list_request: ModelsListRequest,
    provider_models_list_response: ModelsListResponse,
    provider_credential_grant_request: CredentialGrantRequest,
    provider_credential_grant_channel: CredentialChannel,
    provider_credential_grant_response: CredentialGrantResponse,
    inference_create_request: CreateRequest,
    inference_create_response: CreateResponse,
    inference_started: InferenceStarted,
    inference_part_started: PartStarted,
    inference_part_delta: PartDelta,
    inference_part_ended: PartEnded,
    inference_completed: InferenceCompleted,
    inference_failed: InferenceFailed,
    inference_cancel_request: CancelRequest,
    inference_cancel_response: CancelResponse,
    inference_sync_request: SyncRequest,
    inference_sync_response: SyncResponse,
    protocol_error: ErrorEnvelopePayload,

    pub fn typeName(self: Payload) []const u8 {
        return switch (self) {
            .provider_describe_request => "provider.describe.request",
            .provider_describe_response => "provider.describe.response",
            .provider_models_list_request => "provider.models.list.request",
            .provider_models_list_response => "provider.models.list.response",
            .provider_credential_grant_request => "provider.credential.grant.request",
            .provider_credential_grant_channel => "provider.credential.grant.channel",
            .provider_credential_grant_response => "provider.credential.grant.response",
            .inference_create_request => "inference.create.request",
            .inference_create_response => "inference.create.response",
            .inference_started => "inference.started",
            .inference_part_started => "inference.part.started",
            .inference_part_delta => "inference.part.delta",
            .inference_part_ended => "inference.part.ended",
            .inference_completed => "inference.completed",
            .inference_failed => "inference.failed",
            .inference_cancel_request => "inference.cancel.request",
            .inference_cancel_response => "inference.cancel.response",
            .inference_sync_request => "inference.sync.request",
            .inference_sync_response => "inference.sync.response",
            .protocol_error => "error",
        };
    }

    pub fn isScopedEvent(self: Payload) bool {
        return switch (self) {
            .inference_started,
            .inference_part_started,
            .inference_part_delta,
            .inference_part_ended,
            .inference_completed,
            .inference_failed,
            => true,
            else => false,
        };
    }

    pub fn deinit(self: *Payload, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .provider_describe_response => |*value| value.deinit(allocator),
            .provider_models_list_request => |*value| value.deinit(allocator),
            .provider_models_list_response => |*value| value.deinit(allocator),
            .provider_credential_grant_request => |*value| value.deinit(allocator),
            .provider_credential_grant_channel => |*value| value.deinit(allocator),
            .provider_credential_grant_response => |*value| value.deinit(allocator),
            .inference_create_request => |*value| value.deinit(allocator),
            .inference_create_response => |*value| value.deinit(allocator),
            .inference_started => |*value| value.deinit(allocator),
            .inference_part_started => |*value| value.deinit(allocator),
            .inference_part_delta => |*value| value.deinit(allocator),
            .inference_part_ended => |*value| value.deinit(allocator),
            .inference_completed => |*value| value.deinit(allocator),
            .inference_failed => |*value| value.deinit(allocator),
            .inference_cancel_request => |*value| value.deinit(allocator),
            .inference_sync_response => |*value| value.deinit(allocator),
            .protocol_error => |*value| value.deinit(allocator),
            .provider_describe_request,
            .inference_cancel_response,
            .inference_sync_request,
            => {},
        }
    }
};

pub fn payloadTypeFromName(name: []const u8) ?std.meta.Tag(Payload) {
    const table = [_]struct { name: []const u8, tag: std.meta.Tag(Payload) }{
        .{ .name = "provider.describe.request", .tag = .provider_describe_request },
        .{ .name = "provider.describe.response", .tag = .provider_describe_response },
        .{ .name = "provider.models.list.request", .tag = .provider_models_list_request },
        .{ .name = "provider.models.list.response", .tag = .provider_models_list_response },
        .{ .name = "provider.credential.grant.request", .tag = .provider_credential_grant_request },
        .{ .name = "provider.credential.grant.channel", .tag = .provider_credential_grant_channel },
        .{ .name = "provider.credential.grant.response", .tag = .provider_credential_grant_response },
        .{ .name = "inference.create.request", .tag = .inference_create_request },
        .{ .name = "inference.create.response", .tag = .inference_create_response },
        .{ .name = "inference.started", .tag = .inference_started },
        .{ .name = "inference.part.started", .tag = .inference_part_started },
        .{ .name = "inference.part.delta", .tag = .inference_part_delta },
        .{ .name = "inference.part.ended", .tag = .inference_part_ended },
        .{ .name = "inference.completed", .tag = .inference_completed },
        .{ .name = "inference.failed", .tag = .inference_failed },
        .{ .name = "inference.cancel.request", .tag = .inference_cancel_request },
        .{ .name = "inference.cancel.response", .tag = .inference_cancel_response },
        .{ .name = "inference.sync.request", .tag = .inference_sync_request },
        .{ .name = "inference.sync.response", .tag = .inference_sync_response },
        .{ .name = "error", .tag = .protocol_error },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.tag;
    }
    return null;
}

pub const Envelope = struct {
    id: []const u8,
    payload: Payload,
    sequence: ?u64 = null,
    timestamp_ms: ?i64 = null,
    in_reply_to: ?[]const u8 = null,
    inference_id: ?[]const u8 = null,
    capability_revision: ?[]const u8 = null,

    pub fn deinit(self: *Envelope, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.in_reply_to) |value| allocator.free(value);
        if (self.inference_id) |value| allocator.free(value);
        if (self.capability_revision) |value| allocator.free(value);
        self.payload.deinit(allocator);
    }
};

test "error codes sort onto the five recipient actions" {
    try std.testing.expectEqual(ErrorAction.retry, ErrorCode.rate_limited.action());
    try std.testing.expectEqual(ErrorAction.retry, ErrorCode.provider_unavailable.action());
    try std.testing.expectEqual(ErrorAction.refresh, ErrorCode.credential_expired.action());
    try std.testing.expectEqual(ErrorAction.authenticate, ErrorCode.credential_missing.action());
    try std.testing.expectEqual(ErrorAction.authenticate, ErrorCode.credential_rejected.action());
    try std.testing.expectEqual(ErrorAction.report, ErrorCode.protocol_violation.action());
    try std.testing.expectEqual(ErrorAction.accept, ErrorCode.aborted.action());
}

test "credential header detection catches the named cases and bearer values" {
    try std.testing.expect(isCredentialHeaderName("Authorization"));
    try std.testing.expect(isCredentialHeaderName("proxy-authorization"));
    try std.testing.expect(isCredentialHeaderName("X-Api-Key"));
    try std.testing.expect(isCredentialHeaderName("api-key"));
    try std.testing.expect(!isCredentialHeaderName("X-Tenant"));

    try std.testing.expect(headerCarriesCredential(.{ .name = "X-Custom", .value = "Bearer abc123" }));
    try std.testing.expect(!headerCarriesCredential(.{ .name = "X-Tenant", .value = "acme" }));
}

test "every payload tag round-trips through its wire name" {
    inline for (@typeInfo(std.meta.Tag(Payload)).@"enum".fields) |field| {
        const tag: std.meta.Tag(Payload) = @enumFromInt(field.value);
        const name = typeNameForTag(tag);
        const parsed = payloadTypeFromName(name) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(tag, parsed);
    }
}

test "the profile names the model provider core and not agent control" {
    try std.testing.expectEqualStrings("open-agent-protocol.model-provider-core", PROFILE);
    try std.testing.expect(!std.mem.eql(u8, PROFILE, oap_types.PROFILE));
}

fn typeNameForTag(tag: std.meta.Tag(Payload)) []const u8 {
    return switch (tag) {
        .provider_describe_request => "provider.describe.request",
        .provider_describe_response => "provider.describe.response",
        .provider_models_list_request => "provider.models.list.request",
        .provider_models_list_response => "provider.models.list.response",
        .provider_credential_grant_request => "provider.credential.grant.request",
        .provider_credential_grant_channel => "provider.credential.grant.channel",
        .provider_credential_grant_response => "provider.credential.grant.response",
        .inference_create_request => "inference.create.request",
        .inference_create_response => "inference.create.response",
        .inference_started => "inference.started",
        .inference_part_started => "inference.part.started",
        .inference_part_delta => "inference.part.delta",
        .inference_part_ended => "inference.part.ended",
        .inference_completed => "inference.completed",
        .inference_failed => "inference.failed",
        .inference_cancel_request => "inference.cancel.request",
        .inference_cancel_response => "inference.cancel.response",
        .inference_sync_request => "inference.sync.request",
        .inference_sync_response => "inference.sync.response",
        .protocol_error => "error",
    };
}
