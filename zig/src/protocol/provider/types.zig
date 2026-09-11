const std = @import("std");
const ai_types = @import("ai_types");
const owned_slice_mod = @import("owned_slice");
const model_catalog_types = @import("model_catalog_types");
const compat = @import("compat");

pub const OwnedSlice = owned_slice_mod.OwnedSlice;
pub const PROTOCOL_VERSION: u8 = 1;
pub const SUPPORTED_PROTOCOL_VERSIONS = [_][]const u8{"1"};
pub const AuthStatus = model_catalog_types.AuthStatus;
pub const ModelLifecycle = model_catalog_types.ModelLifecycle;
pub const ModelSource = model_catalog_types.ModelSource;
pub const ModelCapability = model_catalog_types.ModelCapability;
pub const ReasoningLevel = model_catalog_types.ReasoningLevel;
pub const MetadataEntry = model_catalog_types.MetadataEntry;
pub const ModelDescriptor = model_catalog_types.ModelDescriptor;
pub const ModelsResponse = model_catalog_types.ModelsResponse;

pub const Ulid = [16]u8;

pub const SESSION_ID_LENGTH: usize = 21;
pub const SESSION_ID_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
pub const SessionId = [SESSION_ID_LENGTH]u8;

fn generateSessionIdWithRandomInt(random_int_range_less_than: fn (comptime type, usize) usize) SessionId {
    var session_id: SessionId = undefined;
    for (&session_id) |*byte| {
        const idx = random_int_range_less_than(usize, SESSION_ID_ALPHABET.len);
        byte.* = SESSION_ID_ALPHABET[idx];
    }
    return session_id;
}

pub fn generateSessionId() SessionId {
    return generateSessionIdWithRandomInt(compat.random.secureIntRangeLessThan);
}

pub fn sessionIdToString(session_id: SessionId, allocator: std.mem.Allocator) ![]const u8 {
    return allocator.dupe(u8, session_id[0..]);
}

pub fn parseSessionId(str: []const u8) ?SessionId {
    if (str.len != SESSION_ID_LENGTH) return null;
    var session_id: SessionId = undefined;
    for (str, 0..) |c, i| {
        switch (c) {
            '0'...'9', 'A'...'Z', 'a'...'z' => session_id[i] = c,
            else => return null,
        }
    }
    return session_id;
}

const ULID_ENCODE = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

fn ulidDecode(c: u8) ?u5 {
    return switch (c) {
        '0', 'O', 'o' => 0,
        '1', 'I', 'i', 'L', 'l' => 1,
        '2'...'9' => @intCast(c - '0'),
        'A', 'a' => 10,
        'B', 'b' => 11,
        'C', 'c' => 12,
        'D', 'd' => 13,
        'E', 'e' => 14,
        'F', 'f' => 15,
        'G', 'g' => 16,
        'H', 'h' => 17,
        'J', 'j' => 18,
        'K', 'k' => 19,
        'M', 'm' => 20,
        'N', 'n' => 21,
        'P', 'p' => 22,
        'Q', 'q' => 23,
        'R', 'r' => 24,
        'S', 's' => 25,
        'T', 't' => 26,
        'V', 'v' => 27,
        'W', 'w' => 28,
        'X', 'x' => 29,
        'Y', 'y' => 30,
        'Z', 'z' => 31,
        else => null,
    };
}

fn generateUlidWithRandom(fill_random: fn ([]u8) void) Ulid {
    var ulid: Ulid = undefined;

    const now_ms: u64 = @intCast(@max(compat.time.nowMillis(), 0));
    ulid[0] = @intCast((now_ms >> 40) & 0xff);
    ulid[1] = @intCast((now_ms >> 32) & 0xff);
    ulid[2] = @intCast((now_ms >> 24) & 0xff);
    ulid[3] = @intCast((now_ms >> 16) & 0xff);
    ulid[4] = @intCast((now_ms >> 8) & 0xff);
    ulid[5] = @intCast(now_ms & 0xff);
    fill_random(ulid[6..16]);

    return ulid;
}

pub fn generateUlid() Ulid {
    return generateUlidWithRandom(compat.random.fillSecureBytes);
}

pub fn ulidToString(ulid: Ulid, allocator: std.mem.Allocator) ![]const u8 {
    const result = try allocator.alloc(u8, 26);
    return ulidToBuffer(ulid, @ptrCast(result.ptr));
}

pub fn ulidToBuffer(ulid: Ulid, result: *[26]u8) []const u8 {
    for (result, 0..) |*out, i| {
        var value: u5 = 0;
        for (0..5) |j| {
            const padded_bit = i * 5 + j;
            value <<= 1;
            if (padded_bit >= 2) {
                const data_bit = padded_bit - 2;
                const byte_index = data_bit / 8;
                const bit_index: u3 = @intCast(7 - (data_bit % 8));
                value |= @intCast((ulid[byte_index] >> bit_index) & 1);
            }
        }
        out.* = ULID_ENCODE[value];
    }
    return result;
}

pub fn parseUlid(str: []const u8) ?Ulid {
    if (str.len != 26) return null;

    var values: [26]u5 = undefined;
    for (str, 0..) |c, i| values[i] = ulidDecode(c) orelse return null;
    if (values[0] > 7) return null;

    var ulid: Ulid = [_]u8{0} ** 16;
    for (values, 0..) |value, i| {
        for (0..5) |j| {
            const padded_bit = i * 5 + j;
            if (padded_bit < 2) continue;
            const bit_index: u3 = @intCast(4 - j);
            if (((value >> bit_index) & 1) == 0) continue;
            const data_bit = padded_bit - 2;
            const byte_index = data_bit / 8;
            const dest_bit: u3 = @intCast(7 - (data_bit % 8));
            ulid[byte_index] |= @as(u8, 1) << dest_bit;
        }
    }
    return ulid;
}

pub const Envelope = struct {
    version: u8 = 1,
    stream_id: Ulid,
    message_id: Ulid,
    sequence: u64,
    in_reply_to: ?Ulid = null,
    timestamp: i64,
    payload: Payload,

    pub fn deinit(self: *Envelope, allocator: std.mem.Allocator) void {
        self.payload.deinit(allocator);
    }
};

pub const Payload = union(enum) {
    stream_request: StreamRequest,
    complete_request: CompleteRequest,
    abort_request: AbortRequest,
    models_request: ModelsRequest,

    ack: Ack,
    nack: Nack,
    event: ai_types.AssistantMessageEvent,
    result: ai_types.AssistantMessage,
    stream_error: StreamError,
    models_response: ModelsResponse,

    ping: void,
    pong: Pong,

    goodbye: Goodbye,
    sync_request: SyncRequest,
    sync: Sync,

    pub fn deinit(self: *Payload, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .stream_request => |*req| req.deinit(allocator),
            .complete_request => |*req| req.deinit(allocator),
            .abort_request => |*req| req.deinit(allocator),
            .models_request => |*req| req.deinit(allocator),
            .nack => |*n| n.deinit(allocator),
            .event => |*e| deinitEvent(allocator, e),
            .result => |*r| r.deinit(allocator),
            .stream_error => |*err| err.deinit(allocator),
            .models_response => |*res| res.deinit(allocator),
            .pong => |*p| p.deinit(allocator),
            .goodbye => |*g| g.deinit(allocator),
            .sync => |*s| s.deinit(allocator),
            .ack, .ping, .sync_request => {},
        }
    }
};

pub fn deinitEvent(allocator: std.mem.Allocator, event: *ai_types.AssistantMessageEvent) void {
    ai_types.deinitAssistantMessageEvent(allocator, event);
}

pub const StreamRequest = struct {
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions = null,
    include_partial: bool = false,

    pub fn deinit(self: *StreamRequest, allocator: std.mem.Allocator) void {
        self.model.deinit(allocator);
        self.context.deinit(allocator);
        if (self.options) |*opts| {
            opts.deinit(allocator);
        }
    }
};

pub const CompleteRequest = struct {
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions = null,

    pub fn deinit(self: *CompleteRequest, allocator: std.mem.Allocator) void {
        self.model.deinit(allocator);
        self.context.deinit(allocator);
        if (self.options) |*opts| {
            opts.deinit(allocator);
        }
    }
};

pub const AbortRequest = struct {
    target_stream_id: Ulid,
    reason: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),

    pub fn getReason(self: *const AbortRequest) ?[]const u8 {
        const r = self.reason.slice();
        return if (r.len > 0) r else null;
    }

    pub fn deinit(self: *AbortRequest, allocator: std.mem.Allocator) void {
        self.reason.deinit(allocator);
        self.* = undefined;
    }
};

pub const Ack = struct {
    acknowledged_id: Ulid,
};

pub const Nack = struct {
    rejected_id: Ulid,
    reason: OwnedSlice(u8),
    error_code: ?ErrorCode = null,
    supported_versions: OwnedSlice(OwnedSlice(u8)) = OwnedSlice(OwnedSlice(u8)).initBorrowed(&.{}),

    pub fn deinit(self: *Nack, allocator: std.mem.Allocator) void {
        self.reason.deinit(allocator);
        self.supported_versions.deinit(allocator);
        self.* = undefined;
    }
};

pub const ErrorCode = enum {
    invalid_request,
    model_not_found,
    provider_error,
    rate_limited,
    internal_error,
    stream_not_found,
    stream_already_exists,
    version_mismatch,
    invalid_sequence,
    duplicate_sequence,
    sequence_gap,
    not_implemented,
    auth_required,
    auth_refresh_failed,
    auth_expired,
    stream_cancelled,
};

pub const StreamError = struct {
    code: ErrorCode,
    message: OwnedSlice(u8),

    pub fn deinit(self: *StreamError, allocator: std.mem.Allocator) void {
        self.message.deinit(allocator);
        self.* = undefined;
    }
};

pub const Pong = struct {
    ping_id: OwnedSlice(u8),

    pub fn deinit(self: *Pong, allocator: std.mem.Allocator) void {
        self.ping_id.deinit(allocator);
        self.* = undefined;
    }
};

pub const Goodbye = struct {
    reason: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),

    pub fn getReason(self: *const Goodbye) ?[]const u8 {
        const r = self.reason.slice();
        return if (r.len > 0) r else null;
    }

    pub fn deinit(self: *Goodbye, allocator: std.mem.Allocator) void {
        self.reason.deinit(allocator);
        self.* = undefined;
    }
};

pub const SyncRequest = struct {
    target_stream_id: Ulid,
};

pub const Sync = struct {
    target_stream_id: Ulid,
    partial: ?ai_types.AssistantMessage = null,

    pub fn deinit(self: *Sync, allocator: std.mem.Allocator) void {
        if (self.partial) |*p| {
            p.deinit(allocator);
        }
    }
};

pub const ModelsRequest = struct {
    provider_id: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    api: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    model_id: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    include_deprecated: bool = false,
    include_login_required: bool = true,

    pub fn getProviderId(self: *const ModelsRequest) ?[]const u8 {
        const value = self.provider_id.slice();
        return if (value.len > 0) value else null;
    }

    pub fn getApi(self: *const ModelsRequest) ?[]const u8 {
        const value = self.api.slice();
        return if (value.len > 0) value else null;
    }

    pub fn getModelId(self: *const ModelsRequest) ?[]const u8 {
        const value = self.model_id.slice();
        return if (value.len > 0) value else null;
    }

    pub fn deinit(self: *ModelsRequest, allocator: std.mem.Allocator) void {
        self.provider_id.deinit(allocator);
        self.api.deinit(allocator);
        self.model_id.deinit(allocator);
    }
};

test "ModelsRequest getters return null for empty borrowed filters" {
    const req = ModelsRequest{};
    try std.testing.expect(req.getProviderId() == null);
    try std.testing.expect(req.getApi() == null);
    try std.testing.expect(req.getModelId() == null);
}

test "ModelsRequest deinit frees owned filter strings" {
    const allocator = std.testing.allocator;

    var req = ModelsRequest{
        .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "anthropic")),
        .api = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "anthropic-messages")),
        .model_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "claude:sonnet-4-5")),
    };

    try std.testing.expectEqualStrings("anthropic", req.getProviderId().?);
    try std.testing.expectEqualStrings("anthropic-messages", req.getApi().?);
    try std.testing.expectEqualStrings("claude:sonnet-4-5", req.getModelId().?);

    req.deinit(allocator);
}

fn deterministicSessionIndex(comptime T: type, upper_bound: T) T {
    _ = upper_bound;
    return 0;
}

fn fillDeterministicUlidBytes(buf: []u8) void {
    for (buf, 0..) |*byte, i| {
        byte.* = @intCast(i);
    }
}

test "generateSessionId produces 21-character alphanumeric NanoID" {
    const session_id = generateSessionId();
    const str = try sessionIdToString(session_id, std.testing.allocator);
    defer std.testing.allocator.free(str);

    try std.testing.expectEqual(@as(usize, SESSION_ID_LENGTH), str.len);
    for (str) |c| {
        switch (c) {
            '0'...'9', 'A'...'Z', 'a'...'z' => {},
            else => return error.InvalidSessionIdCharacter,
        }
        try std.testing.expect(c != '_');
        try std.testing.expect(c != '-');
    }

    const parsed = parseSessionId(str);
    try std.testing.expect(parsed != null);
    try std.testing.expectEqualSlices(u8, &session_id, &parsed.?);
}

test "generateSessionIdWithRandomInt is deterministic for test seam" {
    const session_id = generateSessionIdWithRandomInt(deterministicSessionIndex);
    const str = try sessionIdToString(session_id, std.testing.allocator);
    defer std.testing.allocator.free(str);

    try std.testing.expectEqualStrings("000000000000000000000", str);
}

test "generateUlid produces valid ULID" {
    const ulid = generateUlid();
    const now_ms: u64 = @intCast(@max(compat.time.nowMillis(), 0));
    const ulid_ms = (@as(u64, ulid[0]) << 40) |
        (@as(u64, ulid[1]) << 32) |
        (@as(u64, ulid[2]) << 24) |
        (@as(u64, ulid[3]) << 16) |
        (@as(u64, ulid[4]) << 8) |
        @as(u64, ulid[5]);

    try std.testing.expect(ulid_ms <= now_ms);
    try std.testing.expect(now_ms - ulid_ms < 1_000);

    const ulid2 = generateUlid();
    try std.testing.expect(!std.mem.eql(u8, &ulid, &ulid2));
}

test "generateUlidWithRandom is deterministic for test seam" {
    const ulid = generateUlidWithRandom(fillDeterministicUlidBytes);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 }, ulid[6..16]);
}

test "ulidToString and parseUlid roundtrip" {
    const ulid = generateUlid();
    const str = try ulidToString(ulid, std.testing.allocator);
    defer std.testing.allocator.free(str);

    try std.testing.expectEqual(@as(usize, 26), str.len);
    for (str) |c| {
        try std.testing.expect(ulidDecode(c) != null);
    }

    const parsed = parseUlid(str);
    try std.testing.expect(parsed != null);
    try std.testing.expectEqualSlices(u8, &ulid, &parsed.?);

    const known_ulid: Ulid = .{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10 };
    const known_str = try ulidToString(known_ulid, std.testing.allocator);
    defer std.testing.allocator.free(known_str);
    try std.testing.expectEqualStrings("014D2PF2DBSQQZXQ5TK1V58CGG", known_str);

    var known_buffer: [26]u8 = undefined;
    try std.testing.expectEqualStrings(known_str, ulidToBuffer(known_ulid, &known_buffer));

    const parsed_known = parseUlid(known_str);
    try std.testing.expect(parsed_known != null);
    try std.testing.expectEqualSlices(u8, &known_ulid, &parsed_known.?);
}

test "parseUlid returns null for invalid strings" {
    try std.testing.expect(parseUlid("018D2PF2DBSQQZWQ5TK1V58CG") == null);
    try std.testing.expect(parseUlid("014D2PF2DBSQQZXQ5TK1V58CGG0") == null);

    try std.testing.expect(parseUlid("018D2PF2DBSQQZWQ5TK1V58CGU") == null);
    try std.testing.expect(parseUlid("018D2PF2DBSQQZWQ5TK1V58CG-") == null);

    try std.testing.expect(parseUlid("8ZZZZZZZZZZZZZZZZZZZZZZZZZ") == null);

    try std.testing.expect(parseUlid("0I8D2PF2DBSQQZWQ5TK1V58CGG") != null);

    try std.testing.expect(parseUlid("") == null);
}

test "ErrorCode enum values match protocol spec" {
    const codes = [_]ErrorCode{
        .invalid_request,
        .model_not_found,
        .provider_error,
        .rate_limited,
        .internal_error,
        .stream_not_found,
        .stream_already_exists,
        .version_mismatch,
        .invalid_sequence,
        .duplicate_sequence,
        .sequence_gap,
        .not_implemented,
        .auth_required,
        .auth_refresh_failed,
        .auth_expired,
        .stream_cancelled,
    };

    try std.testing.expectEqual(@as(usize, 16), codes.len);

    inline for (codes) |code| {
        _ = code;
    }
}

test "Envelope with ping payload" {
    const ulid = generateUlid();
    var envelope = Envelope{
        .stream_id = ulid,
        .message_id = generateUlid(),
        .sequence = 1,
        .timestamp = compat.time.nowMillis(),
        .payload = .ping,
    };

    envelope.deinit(std.testing.allocator);
}

test "Nack deinit frees reason and supported_versions" {
    const reason = try std.testing.allocator.dupe(u8, "Test error reason");
    var nack = Nack{
        .rejected_id = generateUlid(),
        .reason = OwnedSlice(u8).initOwned(reason),
        .error_code = .invalid_request,
    };

    nack.deinit(std.testing.allocator);
}

test "StreamError deinit frees message" {
    const msg = try std.testing.allocator.dupe(u8, "Provider error");
    var stream_err = StreamError{
        .code = .provider_error,
        .message = OwnedSlice(u8).initOwned(msg),
    };

    stream_err.deinit(std.testing.allocator);
}

test "AbortRequest deinit frees reason" {
    const reason = try std.testing.allocator.dupe(u8, "User cancelled");
    var abort = AbortRequest{
        .target_stream_id = generateUlid(),
        .reason = OwnedSlice(u8).initOwned(reason),
    };

    abort.deinit(std.testing.allocator);
}

test "AbortRequest deinit handles empty reason" {
    var abort = AbortRequest{
        .target_stream_id = generateUlid(),
    };

    abort.deinit(std.testing.allocator);
}

test "Payload deinit handles all variants" {
    var ping_payload: Payload = .ping;
    ping_payload.deinit(std.testing.allocator);

    const ping_id = try std.testing.allocator.dupe(u8, "test-ping-123");
    var pong_payload: Payload = .{ .pong = .{ .ping_id = OwnedSlice(u8).initOwned(ping_id) } };
    pong_payload.deinit(std.testing.allocator);

    var ack_payload: Payload = .{ .ack = .{ .acknowledged_id = generateUlid() } };
    ack_payload.deinit(std.testing.allocator);
}

test "Pong deinit frees ping_id" {
    const ping_id = try std.testing.allocator.dupe(u8, "test-ping-id");
    var pong = Pong{ .ping_id = OwnedSlice(u8).initOwned(ping_id) };
    pong.deinit(std.testing.allocator);
}

test "Goodbye deinit frees reason" {
    const reason = try std.testing.allocator.dupe(u8, "Server shutting down");
    var goodbye = Goodbye{ .reason = OwnedSlice(u8).initOwned(reason) };
    goodbye.deinit(std.testing.allocator);
}

test "Goodbye deinit handles empty reason" {
    var goodbye = Goodbye{};
    goodbye.deinit(std.testing.allocator);
}

test "Sync deinit handles partial" {
    const partial = ai_types.AssistantMessage{
        .content = &.{},
        .api = "",
        .provider = "",
        .model = "",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
        .is_owned = false,
    };
    var sync = Sync{
        .target_stream_id = generateUlid(),
        .partial = partial,
    };
    sync.deinit(std.testing.allocator);
}

test "Sync deinit handles null partial" {
    var sync = Sync{
        .target_stream_id = generateUlid(),
        .partial = null,
    };
    sync.deinit(std.testing.allocator);
}

test "SyncRequest has target_stream_id" {
    const target_id = generateUlid();
    const sync_req = SyncRequest{ .target_stream_id = target_id };
    try std.testing.expectEqualSlices(u8, &target_id, &sync_req.target_stream_id);
}

test "StreamRequest deinit with owned strings frees memory" {
    const model = ai_types.Model{
        .id = try std.testing.allocator.dupe(u8, "gpt-4"),
        .name = try std.testing.allocator.dupe(u8, "GPT-4"),
        .api = try std.testing.allocator.dupe(u8, "openai-completions"),
        .provider = try std.testing.allocator.dupe(u8, "openai"),
        .base_url = try std.testing.allocator.dupe(u8, "https://api.openai.com"),
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 0,
        .max_tokens = 0,
        .is_owned = true,
    };

    const sys_prompt = try std.testing.allocator.dupe(u8, "Be helpful");
    const messages = try std.testing.allocator.alloc(ai_types.Message, 0);

    const context = ai_types.Context{
        .system_prompt = ai_types.OwnedSlice(u8).initOwned(sys_prompt),
        .messages = messages,
        .tools = null,
        .is_owned = true,
    };

    var req = StreamRequest{
        .model = model,
        .context = context,
        .options = null,
        .include_partial = false,
    };

    req.deinit(std.testing.allocator);
}

test "CompleteRequest deinit with owned strings frees memory" {
    const model = ai_types.Model{
        .id = try std.testing.allocator.dupe(u8, "claude-3"),
        .name = try std.testing.allocator.dupe(u8, "Claude 3"),
        .api = try std.testing.allocator.dupe(u8, "anthropic-messages"),
        .provider = try std.testing.allocator.dupe(u8, "anthropic"),
        .base_url = try std.testing.allocator.dupe(u8, "https://api.anthropic.com"),
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 0,
        .max_tokens = 0,
        .is_owned = true,
    };

    const messages = try std.testing.allocator.alloc(ai_types.Message, 0);
    const context = ai_types.Context{
        .system_prompt = ai_types.OwnedSlice(u8).initBorrowed(""),
        .messages = messages,
        .tools = null,
        .is_owned = true,
    };

    var req = CompleteRequest{
        .model = model,
        .context = context,
        .options = null,
    };

    req.deinit(std.testing.allocator);
}

test "StreamRequest deinit with borrowed strings does not free" {
    const model = ai_types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 0,
        .max_tokens = 0,
        .is_owned = false,
    };

    const context = ai_types.Context{
        .system_prompt = ai_types.OwnedSlice(u8).initBorrowed("Be helpful"),
        .messages = &.{},
        .tools = null,
        .is_owned = false,
    };

    var req = StreamRequest{
        .model = model,
        .context = context,
        .options = null,
        .include_partial = false,
    };

    req.deinit(std.testing.allocator);
}
