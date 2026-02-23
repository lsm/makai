const std = @import("std");
const provider_types = @import("protocol_types");
pub const OwnedSlice = @import("owned_slice").OwnedSlice;

pub const Uuid = provider_types.Uuid;
pub const generateUuid = provider_types.generateUuid;
pub const uuidToString = provider_types.uuidToString;
pub const parseUuid = provider_types.parseUuid;

pub const PROTOCOL_VERSION: u8 = 1;

pub const AuthStatus = enum {
    authenticated,
    login_required,
    expired,
    refreshing,
    login_in_progress,
    failed,
    unknown,
};

pub const AuthProviderInfo = struct {
    id: OwnedSlice(u8),
    name: OwnedSlice(u8),
    auth_status: AuthStatus,
    last_error: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),

    pub fn deinit(self: *AuthProviderInfo, allocator: std.mem.Allocator) void {
        self.id.deinit(allocator);
        self.name.deinit(allocator);
        self.last_error.deinit(allocator);
        self.* = undefined;
    }
};

pub const AuthProvidersResponse = struct {
    providers: OwnedSlice(AuthProviderInfo),

    pub fn deinit(self: *AuthProvidersResponse, allocator: std.mem.Allocator) void {
        self.providers.deinit(allocator);
        self.* = undefined;
    }
};

pub const AuthLoginStartRequest = struct {
    provider_id: OwnedSlice(u8),

    pub fn deinit(self: *AuthLoginStartRequest, allocator: std.mem.Allocator) void {
        self.provider_id.deinit(allocator);
        self.* = undefined;
    }
};

pub const AuthPromptResponse = struct {
    flow_id: Uuid,
    prompt_id: OwnedSlice(u8),
    answer: OwnedSlice(u8),

    pub fn deinit(self: *AuthPromptResponse, allocator: std.mem.Allocator) void {
        self.prompt_id.deinit(allocator);
        self.answer.deinit(allocator);
        self.* = undefined;
    }
};

pub const AuthCancelRequest = struct {
    flow_id: Uuid,
};

pub const AuthEvent = union(enum) {
    auth_url: struct {
        flow_id: Uuid,
        provider_id: OwnedSlice(u8),
        url: OwnedSlice(u8),
        instructions: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
    },
    prompt: struct {
        flow_id: Uuid,
        prompt_id: OwnedSlice(u8),
        provider_id: OwnedSlice(u8),
        message: OwnedSlice(u8),
        allow_empty: bool = false,
    },
    progress: struct {
        flow_id: Uuid,
        provider_id: OwnedSlice(u8),
        message: OwnedSlice(u8),
    },
    success: struct {
        flow_id: Uuid,
        provider_id: OwnedSlice(u8),
    },
    @"error": struct {
        flow_id: Uuid,
        provider_id: OwnedSlice(u8),
        code: OwnedSlice(u8) = OwnedSlice(u8).initBorrowed(""),
        message: OwnedSlice(u8),
    },

    pub fn deinit(self: *AuthEvent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .auth_url => |*event| {
                event.provider_id.deinit(allocator);
                event.url.deinit(allocator);
                event.instructions.deinit(allocator);
            },
            .prompt => |*event| {
                event.prompt_id.deinit(allocator);
                event.provider_id.deinit(allocator);
                event.message.deinit(allocator);
            },
            .progress => |*event| {
                event.provider_id.deinit(allocator);
                event.message.deinit(allocator);
            },
            .success => |*event| {
                event.provider_id.deinit(allocator);
            },
            .@"error" => |*event| {
                event.provider_id.deinit(allocator);
                event.code.deinit(allocator);
                event.message.deinit(allocator);
            },
        }

        self.* = undefined;
    }
};

pub const AuthLoginStatus = enum {
    success,
    cancelled,
    failed,
};

pub const AuthLoginResult = struct {
    flow_id: Uuid,
    provider_id: OwnedSlice(u8),
    status: AuthLoginStatus,

    pub fn deinit(self: *AuthLoginResult, allocator: std.mem.Allocator) void {
        self.provider_id.deinit(allocator);
        self.* = undefined;
    }
};

pub const Ack = struct {
    acknowledged_id: Uuid,
};

pub const ErrorCode = enum {
    invalid_request,
    unknown_provider,
    flow_not_found,
    invalid_sequence,
    duplicate_sequence,
    sequence_gap,
    internal_error,
    version_mismatch,
};

pub const Nack = struct {
    rejected_id: Uuid,
    reason: OwnedSlice(u8),
    error_code: ?ErrorCode = null,

    pub fn deinit(self: *Nack, allocator: std.mem.Allocator) void {
        self.reason.deinit(allocator);
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

    pub fn deinit(self: *Goodbye, allocator: std.mem.Allocator) void {
        self.reason.deinit(allocator);
        self.* = undefined;
    }
};

pub const Payload = union(enum) {
    // Client -> server
    auth_providers_request: struct {},
    auth_login_start: AuthLoginStartRequest,
    auth_prompt_response: AuthPromptResponse,
    auth_cancel: AuthCancelRequest,

    // Server -> client
    ack: Ack,
    nack: Nack,
    auth_providers_response: AuthProvidersResponse,
    auth_event: AuthEvent,
    auth_login_result: AuthLoginResult,

    // Keepalive / connection
    ping: void,
    pong: Pong,
    goodbye: Goodbye,

    pub fn deinit(self: *Payload, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .auth_login_start => |*payload| payload.deinit(allocator),
            .auth_prompt_response => |*payload| payload.deinit(allocator),
            .nack => |*payload| payload.deinit(allocator),
            .auth_providers_response => |*payload| payload.deinit(allocator),
            .auth_event => |*payload| payload.deinit(allocator),
            .auth_login_result => |*payload| payload.deinit(allocator),
            .pong => |*payload| payload.deinit(allocator),
            .goodbye => |*payload| payload.deinit(allocator),
            .auth_providers_request, .auth_cancel, .ack, .ping => {},
        }
    }
};

pub const Envelope = struct {
    version: u8 = PROTOCOL_VERSION,
    stream_id: Uuid,
    message_id: Uuid,
    sequence: u64,
    in_reply_to: ?Uuid = null,
    timestamp: i64,
    payload: Payload,

    pub fn deinit(self: *Envelope, allocator: std.mem.Allocator) void {
        self.payload.deinit(allocator);
    }
};

test "AuthStatus enum values" {
    try std.testing.expectEqual(AuthStatus.authenticated, .authenticated);
    try std.testing.expectEqual(AuthStatus.login_required, .login_required);
}

test "Payload deinit for auth_login_start" {
    const allocator = std.testing.allocator;
    var payload = Payload{
        .auth_login_start = .{
            .provider_id = OwnedSlice(u8).initOwned(try allocator.dupe(u8, "test-fixture")),
        },
    };
    payload.deinit(allocator);
}
