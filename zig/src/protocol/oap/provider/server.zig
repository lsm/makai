const std = @import("std");
const oap_types = @import("oap_types");
const types = @import("oap_provider_types");
const envelope = @import("oap_provider_envelope");
const compat = @import("compat");

pub const GrantChannel = enum {
    out_of_band,
    on_envelope,
    unsupported,
};

pub const Options = struct {
    capability_revision: []const u8 = "r1",
    grant_channel: GrantChannel = .unsupported,
    default_grant_ttl_ms: u64 = 300_000,
};

pub const GrantedCredential = struct {
    reference: []const u8,
    provider_id: []const u8,
    nonce: []const u8,
    expires_at_ms: ?i64,
    non_persistable: bool = true,

    pub fn deinit(self: *GrantedCredential, allocator: std.mem.Allocator) void {
        allocator.free(self.reference);
        allocator.free(self.provider_id);
        allocator.free(self.nonce);
        self.* = undefined;
    }
};

pub const Server = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    options: Options,
    providers: std.ArrayList(types.ProviderDescriptor),
    models: std.ArrayList(types.ModelEntry),
    grants: std.ArrayList(GrantedCredential),
    outbound: std.ArrayList([]const u8),
    next_grant_ordinal: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, options: Options) Self {
        return .{
            .allocator = allocator,
            .options = options,
            .providers = std.ArrayList(types.ProviderDescriptor).empty,
            .models = std.ArrayList(types.ModelEntry).empty,
            .grants = std.ArrayList(GrantedCredential).empty,
            .outbound = std.ArrayList([]const u8).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.providers.items) |*descriptor| descriptor.deinit(self.allocator);
        self.providers.deinit(self.allocator);
        for (self.models.items) |*entry| entry.deinit(self.allocator);
        self.models.deinit(self.allocator);
        for (self.grants.items) |*grant| grant.deinit(self.allocator);
        self.grants.deinit(self.allocator);
        for (self.outbound.items) |line| self.allocator.free(line);
        self.outbound.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addProvider(self: *Self, descriptor: types.ProviderDescriptor) !void {
        try self.providers.append(self.allocator, descriptor);
    }

    pub fn addModel(self: *Self, entry: types.ModelEntry) !void {
        try self.models.append(self.allocator, entry);
    }

    pub fn popOutbound(self: *Self) ?[]const u8 {
        if (self.outbound.items.len == 0) return null;
        return self.outbound.orderedRemove(0);
    }

    pub fn findProvider(self: *Self, id: []const u8) ?*types.ProviderDescriptor {
        for (self.providers.items) |*descriptor| {
            if (std.mem.eql(u8, descriptor.id, id)) return descriptor;
        }
        return null;
    }

    pub fn findGrant(self: *Self, reference: []const u8) ?*GrantedCredential {
        for (self.grants.items) |*grant| {
            if (std.mem.eql(u8, grant.reference, reference)) return grant;
        }
        return null;
    }

    pub fn releaseGrants(self: *Self) void {
        for (self.grants.items) |*grant| grant.deinit(self.allocator);
        self.grants.clearRetainingCapacity();
    }

    fn push(self: *Self, env: types.Envelope) !void {
        const line = try envelope.serializeEnvelope(env, self.allocator);
        errdefer self.allocator.free(line);
        try self.outbound.append(self.allocator, line);
    }

    fn nextId(self: *Self) ![]const u8 {
        var raw: [16]u8 = undefined;
        compat.random.fillSecureBytes(&raw);
        const hex = std.fmt.bytesToHex(raw, .lower);
        return self.allocator.dupe(u8, &hex);
    }

    pub fn emitError(
        self: *Self,
        code: types.ErrorCode,
        message: []const u8,
        in_reply_to: ?[]const u8,
    ) !void {
        const id = try self.nextId();
        errdefer self.allocator.free(id);
        const owned_message = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(owned_message);
        const reply = if (in_reply_to) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (reply) |value| self.allocator.free(value);

        var versions = try self.allocator.alloc([]const u8, 1);
        errdefer self.allocator.free(versions);
        versions[0] = try self.allocator.dupe(u8, types.VERSION);

        var env = types.Envelope{
            .id = id,
            .in_reply_to = reply,
            .payload = .{ .protocol_error = .{
                .err = .{ .code = code, .message = owned_message },
                .protocol_versions = versions,
            } },
        };
        defer env.deinit(self.allocator);
        try self.push(env);
    }

    pub fn handleLine(self: *Self, line: []const u8) !void {
        var env = envelope.deserializeEnvelope(line, self.allocator) catch |err| {
            const declared_id = declaredId(line, self.allocator);
            defer if (declared_id) |value| self.allocator.free(value);
            try self.emitDecodeError(err, declared_id);
            return;
        };
        defer env.deinit(self.allocator);
        try self.handleEnvelope(env);
    }

    fn emitDecodeError(self: *Self, err: anyerror, in_reply_to: ?[]const u8) !void {
        const code: types.ErrorCode = switch (err) {
            envelope.DecodeError.VersionMismatch => .unsupported_version,
            envelope.DecodeError.CredentialInHeaders => .invalid_request,
            envelope.DecodeError.UnknownEnvelopeType => .invalid_request,
            envelope.DecodeError.ProfileMismatch, envelope.DecodeError.ProtocolMismatch => .protocol_violation,
            envelope.DecodeError.MissingField, envelope.DecodeError.InvalidField => .invalid_request,
            else => .protocol_violation,
        };
        const message = switch (err) {
            envelope.DecodeError.CredentialInHeaders => "a credential must not travel in request headers; use provider.credential.grant.request",
            envelope.DecodeError.ProfileMismatch => "this endpoint serves open-agent-protocol 0.1 model-provider-core only",
            envelope.DecodeError.VersionMismatch => "unsupported protocol version",
            envelope.DecodeError.UnknownEnvelopeType => "unrecognized envelope type for this profile",
            else => "envelope could not be decoded",
        };
        try self.emitError(code, message, in_reply_to);
    }

    pub fn handleEnvelope(self: *Self, env: types.Envelope) !void {
        switch (env.payload) {
            .provider_describe_request => try self.handleDescribe(env),
            .provider_models_list_request => |list_request| try self.handleModelsList(env, list_request),
            .provider_credential_grant_request => |grant_request| try self.handleGrant(env, grant_request),
            .inference_create_request => |create_request| try self.handleCreate(env, create_request),
            .inference_sync_request => try self.handleSyncUnsupported(env),
            else => try self.emitError(
                .invalid_request,
                "this envelope is not accepted by the implementation in its current state",
                env.id,
            ),
        }
    }

    fn handleDescribe(self: *Self, env: types.Envelope) !void {
        const id = try self.nextId();
        errdefer self.allocator.free(id);
        const reply = try self.allocator.dupe(u8, env.id);
        errdefer self.allocator.free(reply);

        var descriptors = try self.allocator.alloc(types.ProviderDescriptor, self.providers.items.len);
        var built: usize = 0;
        errdefer {
            for (descriptors[0..built]) |*descriptor| descriptor.deinit(self.allocator);
            self.allocator.free(descriptors);
        }
        for (self.providers.items, 0..) |descriptor, index| {
            descriptors[index] = try cloneDescriptor(self.allocator, descriptor);
            built += 1;
        }

        const revision = try self.allocator.dupe(u8, self.options.capability_revision);
        errdefer self.allocator.free(revision);

        var versions = try self.allocator.alloc([]const u8, 1);
        errdefer self.allocator.free(versions);
        versions[0] = try self.allocator.dupe(u8, types.VERSION);

        var response = types.Envelope{
            .id = id,
            .in_reply_to = reply,
            .payload = .{ .provider_describe_response = .{
                .providers = descriptors,
                .capability_revision = revision,
                .protocol_versions = versions,
            } },
        };
        defer response.deinit(self.allocator);
        try self.push(response);
    }

    fn handleModelsList(self: *Self, env: types.Envelope, list_request: types.ModelsListRequest) !void {
        if (list_request.provider_id) |filter| {
            if (self.findProvider(filter) == null) {
                try self.emitError(.model_not_found, "no such provider", env.id);
                return;
            }
        }

        const id = try self.nextId();
        errdefer self.allocator.free(id);
        const reply = try self.allocator.dupe(u8, env.id);
        errdefer self.allocator.free(reply);

        var matching: usize = 0;
        for (self.models.items) |entry| {
            if (self.entryMatches(entry, list_request.provider_id)) matching += 1;
        }

        var entries = try self.allocator.alloc(types.ModelEntry, matching);
        var built: usize = 0;
        errdefer {
            for (entries[0..built]) |*entry| entry.deinit(self.allocator);
            self.allocator.free(entries);
        }
        for (self.models.items) |entry| {
            if (!self.entryMatches(entry, list_request.provider_id)) continue;
            entries[built] = try cloneModelEntry(self.allocator, entry);
            built += 1;
        }

        const revision = try self.allocator.dupe(u8, self.options.capability_revision);
        errdefer self.allocator.free(revision);

        var response = types.Envelope{
            .id = id,
            .in_reply_to = reply,
            .payload = .{ .provider_models_list_response = .{
                .models = entries,
                .capability_revision = revision,
            } },
        };
        defer response.deinit(self.allocator);
        try self.push(response);
    }

    fn entryMatches(self: *Self, entry: types.ModelEntry, filter: ?[]const u8) bool {
        _ = self;
        const wanted = filter orelse return true;
        return std.mem.eql(u8, entry.provider_id, wanted);
    }

    fn handleGrant(self: *Self, env: types.Envelope, grant_request: types.CredentialGrantRequest) !void {
        if (self.options.grant_channel == .unsupported) {
            try self.emitGrantRefusal(
                env,
                .unsupported_feature,
                "this implementation does not accept caller-held credentials",
            );
            return;
        }

        if (self.findProvider(grant_request.provider_id) == null) {
            try self.emitGrantRefusal(env, .model_not_found, "no such provider");
            return;
        }

        if (self.options.grant_channel == .out_of_band and grant_request.value != null) {
            try self.emitGrantRefusal(
                env,
                .invalid_request,
                "this binding carries the credential out of band; the grant envelope must not carry a value",
            );
            return;
        }

        if (self.options.grant_channel == .on_envelope and grant_request.value == null) {
            try self.emitGrantRefusal(
                env,
                .invalid_request,
                "this binding has no side channel; the grant envelope must carry the value",
            );
            return;
        }

        const reference = try std.fmt.allocPrint(
            self.allocator,
            "grant:{s}:{d}",
            .{ grant_request.provider_id, self.next_grant_ordinal },
        );
        errdefer self.allocator.free(reference);
        self.next_grant_ordinal += 1;

        const provider_id = try self.allocator.dupe(u8, grant_request.provider_id);
        errdefer self.allocator.free(provider_id);
        const nonce = try self.allocator.dupe(u8, grant_request.nonce);
        errdefer self.allocator.free(nonce);

        const ttl = grant_request.ttl_ms orelse self.options.default_grant_ttl_ms;
        const expires_at: i64 = compat.time.nowMillis() + @as(i64, @intCast(ttl));

        try self.grants.append(self.allocator, .{
            .reference = reference,
            .provider_id = provider_id,
            .nonce = nonce,
            .expires_at_ms = expires_at,
            .non_persistable = true,
        });

        const id = try self.nextId();
        errdefer self.allocator.free(id);
        const reply = try self.allocator.dupe(u8, env.id);
        errdefer self.allocator.free(reply);
        const echoed = try self.allocator.dupe(u8, reference);
        errdefer self.allocator.free(echoed);

        var response = types.Envelope{
            .id = id,
            .in_reply_to = reply,
            .payload = .{ .provider_credential_grant_response = .{
                .credential_ref = echoed,
                .expires_at_ms = expires_at,
            } },
        };
        defer response.deinit(self.allocator);
        try self.push(response);
    }

    fn emitGrantRefusal(
        self: *Self,
        env: types.Envelope,
        code: types.ErrorCode,
        message: []const u8,
    ) !void {
        const id = try self.nextId();
        errdefer self.allocator.free(id);
        const reply = try self.allocator.dupe(u8, env.id);
        errdefer self.allocator.free(reply);
        const owned_message = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(owned_message);

        var response = types.Envelope{
            .id = id,
            .in_reply_to = reply,
            .payload = .{ .provider_credential_grant_response = .{
                .err = .{ .code = code, .message = owned_message },
            } },
        };
        defer response.deinit(self.allocator);
        try self.push(response);
    }

    fn resolveProviderId(model_ref: []const u8) ?[]const u8 {
        const slash = std.mem.indexOfScalar(u8, model_ref, '/') orelse return null;
        if (slash == 0) return null;
        return model_ref[0..slash];
    }

    fn handleCreate(self: *Self, env: types.Envelope, create_request: types.CreateRequest) !void {
        const provider_id = resolveProviderId(create_request.model_ref) orelse {
            try self.emitCreateRefusal(env, .invalid_request, "model_ref must be provider_id/wire@model_id");
            return;
        };

        const descriptor = self.findProvider(provider_id) orelse {
            try self.emitCreateRefusal(env, .model_not_found, "no such provider");
            return;
        };

        if (create_request.credential_ref) |reference| {
            if (self.findGrant(reference) == null and !descriptor.allows_anonymous) {
                try self.emitCreateRefusal(env, .credential_missing, "credential_ref names no credential this implementation holds");
                return;
            }
        }

        if (!descriptor.snapshot_policies.supports(create_request.include_snapshot)) {
            if (!types.allowsDegraded(create_request.allow_degraded_features, types.DEGRADABLE_SNAPSHOT_KEY)) {
                try self.emitCreateRefusal(
                    env,
                    .unsupported_feature,
                    "this provider does not offer the requested include_snapshot policy",
                );
                return;
            }
        }

        try self.emitCreateRefusal(env, .provider_unavailable, "no inference backend is attached to this endpoint");
    }

    fn emitCreateRefusal(
        self: *Self,
        env: types.Envelope,
        code: types.ErrorCode,
        message: []const u8,
    ) !void {
        const id = try self.nextId();
        errdefer self.allocator.free(id);
        const reply = try self.allocator.dupe(u8, env.id);
        errdefer self.allocator.free(reply);
        const owned_message = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(owned_message);

        var response = types.Envelope{
            .id = id,
            .in_reply_to = reply,
            .payload = .{ .inference_create_response = .{
                .accepted = false,
                .err = .{ .code = code, .message = owned_message },
            } },
        };
        defer response.deinit(self.allocator);
        try self.push(response);
    }

    fn handleSyncUnsupported(self: *Self, env: types.Envelope) !void {
        const id = try self.nextId();
        errdefer self.allocator.free(id);
        const reply = try self.allocator.dupe(u8, env.id);
        errdefer self.allocator.free(reply);

        var response = types.Envelope{
            .id = id,
            .in_reply_to = reply,
            .inference_id = if (env.inference_id) |value| try self.allocator.dupe(u8, value) else null,
            .payload = .{ .inference_sync_response = .{ .snapshot = null } },
        };
        defer response.deinit(self.allocator);
        try self.push(response);
    }
};

fn declaredId(line: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get("id") orelse return null;
    if (value != .string) return null;
    return allocator.dupe(u8, value.string) catch null;
}

pub fn cloneDescriptor(
    allocator: std.mem.Allocator,
    descriptor: types.ProviderDescriptor,
) !types.ProviderDescriptor {
    const id = try allocator.dupe(u8, descriptor.id);
    errdefer allocator.free(id);
    const display_name = if (descriptor.display_name) |value| try allocator.dupe(u8, value) else null;
    errdefer if (display_name) |value| allocator.free(value);
    const endpoint = try allocator.dupe(u8, descriptor.endpoint);
    errdefer allocator.free(endpoint);
    const headers = try cloneHeaders(allocator, descriptor.headers);
    errdefer types.freeHeaders(allocator, headers);
    const policies = try allocator.dupe(types.SnapshotPolicy, descriptor.snapshot_policies.policies);
    errdefer allocator.free(policies);

    return types.ProviderDescriptor{
        .id = id,
        .display_name = display_name,
        .wire = descriptor.wire,
        .framing = descriptor.framing,
        .endpoint = endpoint,
        .headers = headers,
        .compatibility = descriptor.compatibility,
        .snapshot_policies = .{
            .policies = policies,
            .answers_sync = descriptor.snapshot_policies.answers_sync,
        },
        .credential_grant = descriptor.credential_grant,
        .allows_anonymous = descriptor.allows_anonymous,
        .context_window = descriptor.context_window,
        .max_output_tokens = descriptor.max_output_tokens,
    };
}

pub fn cloneHeaders(
    allocator: std.mem.Allocator,
    headers: []const types.HeaderPair,
) ![]const types.HeaderPair {
    const out = try allocator.alloc(types.HeaderPair, headers.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        allocator.free(out);
    }
    for (headers, 0..) |header, index| {
        const name = try allocator.dupe(u8, header.name);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, header.value);
        out[index] = .{ .name = name, .value = value };
        built += 1;
    }
    return out;
}

pub fn cloneModelEntry(allocator: std.mem.Allocator, entry: types.ModelEntry) !types.ModelEntry {
    const model_ref = try allocator.dupe(u8, entry.model_ref);
    errdefer allocator.free(model_ref);
    const model_id = try allocator.dupe(u8, entry.model_id);
    errdefer allocator.free(model_id);
    const display_name = if (entry.display_name) |value| try allocator.dupe(u8, value) else null;
    errdefer if (display_name) |value| allocator.free(value);
    const provider_id = try allocator.dupe(u8, entry.provider_id);
    errdefer allocator.free(provider_id);
    const capabilities = try allocator.dupe(types.ModelCapability, entry.capabilities);

    return types.ModelEntry{
        .model_ref = model_ref,
        .model_id = model_id,
        .display_name = display_name,
        .provider_id = provider_id,
        .wire = entry.wire,
        .context_window = entry.context_window,
        .max_output_tokens = entry.max_output_tokens,
        .capabilities = capabilities,
        .lifecycle = entry.lifecycle,
        .source = entry.source,
        .reasoning_default = entry.reasoning_default,
        .auth_status = entry.auth_status,
    };
}

fn testServer(allocator: std.mem.Allocator, options: Options) !Server {
    var server = Server.init(allocator, options);
    errdefer server.deinit();

    const provider_id = try allocator.dupe(u8, "ollama-local");
    errdefer allocator.free(provider_id);
    const endpoint = try allocator.dupe(u8, "http://127.0.0.1:11434");
    errdefer allocator.free(endpoint);
    const policies = try allocator.dupe(types.SnapshotPolicy, &.{ .never, .on_part_end });
    errdefer allocator.free(policies);

    try server.addProvider(.{
        .id = provider_id,
        .credential_grant = switch (options.grant_channel) {
            .unsupported => .none,
            .out_of_band => .out_of_band,
            .on_envelope => .on_envelope,
        },
        .wire = .@"openai-chat-completions",
        .framing = .ndjson,
        .endpoint = endpoint,
        .allows_anonymous = true,
        .snapshot_policies = .{ .policies = policies, .answers_sync = false },
    });

    const model_ref = try allocator.dupe(u8, "ollama-local/openai-chat-completions@gemma");
    errdefer allocator.free(model_ref);
    const model_id = try allocator.dupe(u8, "gemma");
    errdefer allocator.free(model_id);
    const model_provider_id = try allocator.dupe(u8, "ollama-local");
    errdefer allocator.free(model_provider_id);
    const capabilities = try allocator.dupe(types.ModelCapability, &.{ .chat, .streaming });
    errdefer allocator.free(capabilities);

    try server.addModel(.{
        .model_ref = model_ref,
        .model_id = model_id,
        .provider_id = model_provider_id,
        .wire = .@"openai-chat-completions",
        .capabilities = capabilities,
        .source = .discovered,
        .auth_status = .authenticated,
    });

    return server;
}

fn decodeOnly(allocator: std.mem.Allocator, server: *Server) !types.Envelope {
    const line = server.popOutbound() orelse return error.TestExpectedOutbound;
    defer allocator.free(line);
    return try envelope.deserializeEnvelope(line, allocator);
}

fn makeRequest(allocator: std.mem.Allocator, type_name: []const u8, payload: []const u8, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"{s}\",\"type\":\"{s}\",\"id\":\"{s}\",\"payload\":{s}}}",
        .{ types.PROFILE, type_name, id, payload },
    );
}

test "describe answers with the configured providers and the versions it speaks" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{});
    defer server.deinit();

    const line = try makeRequest(allocator, "provider.describe.request", "{}", "q1");
    defer allocator.free(line);
    try server.handleLine(line);

    var response = try decodeOnly(allocator, &server);
    defer response.deinit(allocator);

    const payload = response.payload.provider_describe_response;
    try std.testing.expectEqualStrings("q1", response.in_reply_to.?);
    try std.testing.expectEqual(@as(usize, 1), payload.providers.len);
    try std.testing.expectEqualStrings("ollama-local", payload.providers[0].id);
    try std.testing.expectEqual(types.Framing.ndjson, payload.providers[0].framing);
    try std.testing.expect(payload.providers[0].allows_anonymous);
    try std.testing.expectEqual(@as(usize, 1), payload.protocol_versions.len);
    try std.testing.expectEqualStrings("0.1", payload.protocol_versions[0]);
}

test "models list filters by provider and refuses one it never described" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{});
    defer server.deinit();

    const matching = try makeRequest(allocator, "provider.models.list.request", "{\"provider_id\":\"ollama-local\"}", "q1");
    defer allocator.free(matching);
    try server.handleLine(matching);

    var response = try decodeOnly(allocator, &server);
    defer response.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), response.payload.provider_models_list_response.models.len);
    try std.testing.expectEqual(
        types.ModelSource.discovered,
        response.payload.provider_models_list_response.models[0].source,
    );

    const unknown = try makeRequest(allocator, "provider.models.list.request", "{\"provider_id\":\"nope\"}", "q2");
    defer allocator.free(unknown);
    try server.handleLine(unknown);

    var refusal = try decodeOnly(allocator, &server);
    defer refusal.deinit(allocator);
    try std.testing.expectEqual(types.ErrorCode.model_not_found, refusal.payload.protocol_error.err.code);
    try std.testing.expectEqualStrings("q2", refusal.in_reply_to.?);
}

test "a grant is refused with unsupported_feature rather than accepted and ignored" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .grant_channel = .unsupported });
    defer server.deinit();

    const line = try makeRequest(
        allocator,
        "provider.credential.grant.request",
        "{\"provider_id\":\"ollama-local\",\"nonce\":\"n1\"}",
        "q1",
    );
    defer allocator.free(line);
    try server.handleLine(line);

    var response = try decodeOnly(allocator, &server);
    defer response.deinit(allocator);

    const payload = response.payload.provider_credential_grant_response;
    try std.testing.expect(payload.credential_ref == null);
    try std.testing.expectEqual(types.ErrorCode.unsupported_feature, payload.err.?.code);
    try std.testing.expectEqual(@as(usize, 0), server.grants.items.len);
}

test "an out of band binding refuses a grant envelope that carries the value" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .grant_channel = .out_of_band });
    defer server.deinit();

    const with_value = try makeRequest(
        allocator,
        "provider.credential.grant.request",
        "{\"provider_id\":\"ollama-local\",\"nonce\":\"n1\",\"value\":\"sk-secret\"}",
        "q1",
    );
    defer allocator.free(with_value);
    try server.handleLine(with_value);

    var refusal = try decodeOnly(allocator, &server);
    defer refusal.deinit(allocator);
    try std.testing.expectEqual(
        types.ErrorCode.invalid_request,
        refusal.payload.provider_credential_grant_response.err.?.code,
    );
    try std.testing.expectEqual(@as(usize, 0), server.grants.items.len);

    const nonce_only = try makeRequest(
        allocator,
        "provider.credential.grant.request",
        "{\"provider_id\":\"ollama-local\",\"nonce\":\"n1\"}",
        "q2",
    );
    defer allocator.free(nonce_only);
    try server.handleLine(nonce_only);

    var granted = try decodeOnly(allocator, &server);
    defer granted.deinit(allocator);
    const reference = granted.payload.provider_credential_grant_response.credential_ref.?;
    try std.testing.expect(reference.len > 0);
    try std.testing.expectEqual(@as(usize, 1), server.grants.items.len);
}

test "every granted credential is marked non persistable and released with the connection" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .grant_channel = .on_envelope });
    defer server.deinit();

    const line = try makeRequest(
        allocator,
        "provider.credential.grant.request",
        "{\"provider_id\":\"ollama-local\",\"nonce\":\"n1\",\"value\":\"sk-secret\"}",
        "q1",
    );
    defer allocator.free(line);
    try server.handleLine(line);

    var response = try decodeOnly(allocator, &server);
    defer response.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), server.grants.items.len);
    try std.testing.expect(server.grants.items[0].non_persistable);
    try std.testing.expect(server.grants.items[0].expires_at_ms != null);

    const reference = response.payload.provider_credential_grant_response.credential_ref.?;
    try std.testing.expect(server.findGrant(reference) != null);

    server.releaseGrants();
    try std.testing.expectEqual(@as(usize, 0), server.grants.items.len);
    try std.testing.expect(server.findGrant(reference) == null);
}

test "an on envelope binding refuses a grant with no value rather than inventing one" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .grant_channel = .on_envelope });
    defer server.deinit();

    const line = try makeRequest(
        allocator,
        "provider.credential.grant.request",
        "{\"provider_id\":\"ollama-local\",\"nonce\":\"n1\"}",
        "q1",
    );
    defer allocator.free(line);
    try server.handleLine(line);

    var response = try decodeOnly(allocator, &server);
    defer response.deinit(allocator);
    try std.testing.expectEqual(
        types.ErrorCode.invalid_request,
        response.payload.provider_credential_grant_response.err.?.code,
    );
}

test "the agent control profile is refused and the refusal names the caller's envelope" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{});
    defer server.deinit();

    const line = try std.fmt.allocPrint(
        allocator,
        "{{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"{s}\",\"type\":\"capabilities.request\",\"id\":\"q9\",\"payload\":{{}}}}",
        .{oap_types.PROFILE},
    );
    defer allocator.free(line);
    try server.handleLine(line);

    var response = try decodeOnly(allocator, &server);
    defer response.deinit(allocator);
    try std.testing.expectEqual(types.ErrorCode.protocol_violation, response.payload.protocol_error.err.code);
    try std.testing.expectEqualStrings("q9", response.in_reply_to.?);
}

test "a credential in caller headers is refused with the correct alternative named" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{});
    defer server.deinit();

    const line = try makeRequest(
        allocator,
        "inference.create.request",
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[],\"headers\":{\"X-Api-Key\":\"sk\"}}",
        "q1",
    );
    defer allocator.free(line);
    try server.handleLine(line);

    var response = try decodeOnly(allocator, &server);
    defer response.deinit(allocator);
    const err = response.payload.protocol_error.err;
    try std.testing.expectEqual(types.ErrorCode.invalid_request, err.code);
    try std.testing.expect(std.mem.indexOf(u8, err.message, "provider.credential.grant.request") != null);
    try std.testing.expectEqualStrings("q1", response.in_reply_to.?);
}

test "an unsupported snapshot policy is refused unless the caller allows degrading" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{});
    defer server.deinit();

    const strict = try makeRequest(
        allocator,
        "inference.create.request",
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[],\"include_snapshot\":\"every_delta\"}",
        "q1",
    );
    defer allocator.free(strict);
    try server.handleLine(strict);

    var refusal = try decodeOnly(allocator, &server);
    defer refusal.deinit(allocator);
    try std.testing.expectEqual(
        types.ErrorCode.unsupported_feature,
        refusal.payload.inference_create_response.err.?.code,
    );
    try std.testing.expect(!refusal.payload.inference_create_response.accepted);

    const degradable = try makeRequest(
        allocator,
        "inference.create.request",
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[]," ++
            "\"include_snapshot\":\"every_delta\",\"allow_degraded_features\":[\"include_snapshot\"]}",
        "q2",
    );
    defer allocator.free(degradable);
    try server.handleLine(degradable);

    var past_negotiation = try decodeOnly(allocator, &server);
    defer past_negotiation.deinit(allocator);
    try std.testing.expectEqual(
        types.ErrorCode.provider_unavailable,
        past_negotiation.payload.inference_create_response.err.?.code,
    );
}

test "a supported snapshot policy needs no degrade permission" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{});
    defer server.deinit();

    const line = try makeRequest(
        allocator,
        "inference.create.request",
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[],\"include_snapshot\":\"on_part_end\"}",
        "q1",
    );
    defer allocator.free(line);
    try server.handleLine(line);

    var response = try decodeOnly(allocator, &server);
    defer response.deinit(allocator);
    try std.testing.expectEqual(
        types.ErrorCode.provider_unavailable,
        response.payload.inference_create_response.err.?.code,
    );
}

test "a refusal allocates no inference and is correlated by in_reply_to alone" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{});
    defer server.deinit();

    const line = try makeRequest(
        allocator,
        "inference.create.request",
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[]}",
        "q1",
    );
    defer allocator.free(line);
    try server.handleLine(line);

    var response = try decodeOnly(allocator, &server);
    defer response.deinit(allocator);

    try std.testing.expect(response.inference_id == null);
    try std.testing.expect(response.payload.inference_create_response.inference_id == null);
    try std.testing.expectEqualStrings("q1", response.in_reply_to.?);
}

test "a model ref naming no described provider is refused before anything is spent" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{});
    defer server.deinit();

    const unknown = try makeRequest(
        allocator,
        "inference.create.request",
        "{\"model_ref\":\"nope/openai-responses@m\",\"messages\":[]}",
        "q1",
    );
    defer allocator.free(unknown);
    try server.handleLine(unknown);

    var refusal = try decodeOnly(allocator, &server);
    defer refusal.deinit(allocator);
    try std.testing.expectEqual(
        types.ErrorCode.model_not_found,
        refusal.payload.inference_create_response.err.?.code,
    );

    const malformed = try makeRequest(
        allocator,
        "inference.create.request",
        "{\"model_ref\":\"noslash\",\"messages\":[]}",
        "q2",
    );
    defer allocator.free(malformed);
    try server.handleLine(malformed);

    var invalid = try decodeOnly(allocator, &server);
    defer invalid.deinit(allocator);
    try std.testing.expectEqual(
        types.ErrorCode.invalid_request,
        invalid.payload.inference_create_response.err.?.code,
    );
}

test "a credential ref naming no held grant is refused on a provider that needs one" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .grant_channel = .out_of_band });
    defer server.deinit();

    try server.addProvider(.{
        .id = try allocator.dupe(u8, "acme"),
        .wire = .@"anthropic-messages",
        .framing = .sse,
        .endpoint = try allocator.dupe(u8, "https://acme.test"),
        .allows_anonymous = false,
    });

    const line = try makeRequest(
        allocator,
        "inference.create.request",
        "{\"model_ref\":\"acme/anthropic-messages@m\",\"messages\":[],\"credential_ref\":\"grant:acme:99\"}",
        "q1",
    );
    defer allocator.free(line);
    try server.handleLine(line);

    var refusal = try decodeOnly(allocator, &server);
    defer refusal.deinit(allocator);
    try std.testing.expectEqual(
        types.ErrorCode.credential_missing,
        refusal.payload.inference_create_response.err.?.code,
    );
    try std.testing.expectEqual(
        types.ErrorAction.authenticate,
        refusal.payload.inference_create_response.err.?.code.action(),
    );
}

test "describe tells a caller which grant tier the binding uses before it sends anything" {
    const allocator = std.testing.allocator;

    var silent = try testServer(allocator, .{ .grant_channel = .unsupported });
    defer silent.deinit();
    const q1 = try makeRequest(allocator, "provider.describe.request", "{}", "q1");
    defer allocator.free(q1);
    try silent.handleLine(q1);
    var silent_response = try decodeOnly(allocator, &silent);
    defer silent_response.deinit(allocator);
    try std.testing.expectEqual(
        types.CredentialGrantChannel.none,
        silent_response.payload.provider_describe_response.providers[0].credential_grant,
    );

    var side_channel = try testServer(allocator, .{ .grant_channel = .out_of_band });
    defer side_channel.deinit();
    const q2 = try makeRequest(allocator, "provider.describe.request", "{}", "q2");
    defer allocator.free(q2);
    try side_channel.handleLine(q2);
    var side_response = try decodeOnly(allocator, &side_channel);
    defer side_response.deinit(allocator);
    try std.testing.expectEqual(
        types.CredentialGrantChannel.out_of_band,
        side_response.payload.provider_describe_response.providers[0].credential_grant,
    );
}

test "an accepted response must name its inference and a refusal must not" {
    const allocator = std.testing.allocator;

    const refusal_with_id =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++
        "\",\"type\":\"inference.create.response\",\"id\":\"m1\",\"payload\":{\"accepted\":false,\"inference_id\":\"inf1\"}}";
    try std.testing.expectError(
        envelope.DecodeError.InvalidField,
        envelope.deserializeEnvelope(refusal_with_id, allocator),
    );

    const accepted_without_id =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++
        "\",\"type\":\"inference.create.response\",\"id\":\"m1\",\"payload\":{\"accepted\":true}}";
    try std.testing.expectError(
        envelope.DecodeError.MissingField,
        envelope.deserializeEnvelope(accepted_without_id, allocator),
    );
}
