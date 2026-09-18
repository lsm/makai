const std = @import("std");
const oap_types = @import("oap_types");
const types = @import("oap_provider_types");
const envelope = @import("oap_provider_envelope");
const compat = @import("compat");
const ai_content = @import("ai_types");

pub const GrantChannel = enum {
    out_of_band,
    on_envelope,
    unsupported,
};

pub const Options = struct {
    capability_revision: []const u8 = "r1",
    grant_channel: GrantChannel = .unsupported,
    default_grant_ttl_ms: u64 = 300_000,
    accepts_inference: bool = false,
    resolves_own_credentials: bool = false,
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

pub const ActiveInference = struct {
    id: []const u8,
    model_ref: []const u8,
    messages: []oap_types.Message = &.{},
    max_output_tokens: ?u32 = null,
    temperature: ?f32 = null,
    include_snapshot: types.SnapshotPolicy,
    next_sequence: u64 = 1,
    open_part: ?u32 = null,
    open_part_kind: types.PartKind = .text,
    open_tool_call_id: ?[]const u8 = null,
    open_tool_name: ?[]const u8 = null,
    closed_parts: std.ArrayList(oap_types.ContentPart),
    text: std.ArrayList(u8),
    terminal_emitted: bool = false,
    cancel_requested: bool = false,

    pub fn deinit(self: *ActiveInference, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.model_ref);
        for (self.messages) |*message| message.deinit(allocator);
        allocator.free(self.messages);
        if (self.open_tool_call_id) |value| allocator.free(value);
        if (self.open_tool_name) |value| allocator.free(value);
        for (self.closed_parts.items) |*part| part.deinit(allocator);
        self.closed_parts.deinit(allocator);
        self.text.deinit(allocator);
        self.* = undefined;
    }
};

pub const GRANT_ARRIVAL_DEADLINE_MS: i64 = 30_000;

pub const PendingGrant = struct {
    nonce: []const u8,
    provider_id: []const u8,
    request_id: []const u8,
    ttl_ms: ?u64,
    announced_at_ms: ?i64 = null,

    pub fn deinit(self: *PendingGrant, allocator: std.mem.Allocator) void {
        allocator.free(self.nonce);
        allocator.free(self.provider_id);
        allocator.free(self.request_id);
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
    active: std.ArrayList(ActiveInference),
    pending_starts: std.ArrayList([]const u8),
    pending_grants: std.ArrayList(PendingGrant),
    next_grant_ordinal: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, options: Options) Self {
        return .{
            .allocator = allocator,
            .options = options,
            .providers = std.ArrayList(types.ProviderDescriptor).empty,
            .models = std.ArrayList(types.ModelEntry).empty,
            .grants = std.ArrayList(GrantedCredential).empty,
            .outbound = std.ArrayList([]const u8).empty,
            .active = std.ArrayList(ActiveInference).empty,
            .pending_starts = std.ArrayList([]const u8).empty,
            .pending_grants = std.ArrayList(PendingGrant).empty,
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
        for (self.active.items) |*inference| inference.deinit(self.allocator);
        self.active.deinit(self.allocator);
        for (self.pending_starts.items) |id| self.allocator.free(id);
        self.pending_starts.deinit(self.allocator);
        for (self.pending_grants.items) |*grant| grant.deinit(self.allocator);
        self.pending_grants.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addProvider(self: *Self, descriptor: types.ProviderDescriptor) !void {
        try self.providers.append(self.allocator, descriptor);
    }

    pub fn addModel(self: *Self, entry: types.ModelEntry) !void {
        try self.models.append(self.allocator, entry);
    }

    pub fn popPendingStart(self: *Self) ?[]const u8 {
        if (self.pending_starts.items.len == 0) return null;
        return self.pending_starts.orderedRemove(0);
    }

    pub fn nextUnannouncedGrant(self: *Self) ?*PendingGrant {
        for (self.pending_grants.items) |*grant| {
            if (grant.announced_at_ms == null) return grant;
        }
        return null;
    }

    pub fn findPendingGrant(self: *Self, nonce: []const u8) ?*PendingGrant {
        for (self.pending_grants.items) |*grant| {
            if (std.mem.eql(u8, grant.nonce, nonce)) return grant;
        }
        return null;
    }

    fn burnPendingGrant(self: *Self, nonce: []const u8) void {
        for (self.pending_grants.items, 0..) |*grant, index| {
            if (!std.mem.eql(u8, grant.nonce, nonce)) continue;
            var removed = self.pending_grants.orderedRemove(index);
            removed.deinit(self.allocator);
            return;
        }
    }

    pub fn announceChannel(self: *Self, nonce: []const u8, channel: []const u8) !void {
        const grant = self.findPendingGrant(nonce) orelse return error.UnknownNonce;
        if (grant.announced_at_ms != null) return error.ChannelAlreadyAnnounced;
        grant.announced_at_ms = compat.time.nowMillis();

        const id = try self.nextId();
        errdefer self.allocator.free(id);
        const owned_nonce = try self.allocator.dupe(u8, nonce);
        errdefer self.allocator.free(owned_nonce);
        const owned_channel = try self.allocator.dupe(u8, channel);
        errdefer self.allocator.free(owned_channel);
        const reply = try self.allocator.dupe(u8, grant.request_id);
        errdefer self.allocator.free(reply);

        var env = types.Envelope{
            .id = id,
            .in_reply_to = reply,
            .payload = .{ .provider_credential_grant_channel = .{
                .nonce = owned_nonce,
                .channel = owned_channel,
            } },
        };
        defer env.deinit(self.allocator);
        try self.push(env);
    }

    pub fn expiredGrantNonce(self: *Self, now_ms: i64) ?[]const u8 {
        for (self.pending_grants.items) |*grant| {
            const announced = grant.announced_at_ms orelse continue;
            if (now_ms - announced >= GRANT_ARRIVAL_DEADLINE_MS) return grant.nonce;
        }
        return null;
    }

    pub fn completeGrant(self: *Self, nonce: []const u8) ![]const u8 {
        const grant = self.findPendingGrant(nonce) orelse return error.UnknownNonce;

        const reference = try std.fmt.allocPrint(
            self.allocator,
            "grant:{s}:{d}",
            .{ grant.provider_id, self.next_grant_ordinal },
        );
        errdefer self.allocator.free(reference);
        self.next_grant_ordinal += 1;

        const provider_id = try self.allocator.dupe(u8, grant.provider_id);
        errdefer self.allocator.free(provider_id);
        const stored_nonce = try self.allocator.dupe(u8, nonce);
        errdefer self.allocator.free(stored_nonce);

        const ttl = grant.ttl_ms orelse self.options.default_grant_ttl_ms;
        const expires_at: i64 = compat.time.nowMillis() + @as(i64, @intCast(ttl));

        try self.grants.append(self.allocator, .{
            .reference = reference,
            .provider_id = provider_id,
            .nonce = stored_nonce,
            .expires_at_ms = expires_at,
            .non_persistable = true,
        });

        const id = try self.nextId();
        errdefer self.allocator.free(id);
        const reply = try self.allocator.dupe(u8, grant.request_id);
        errdefer self.allocator.free(reply);
        const echoed = try self.allocator.dupe(u8, reference);
        errdefer self.allocator.free(echoed);

        var response = types.Envelope{
            .id = id,
            .in_reply_to = reply,
            .payload = .{ .provider_credential_grant_response = .{
                .accepted = true,
                .credential_ref = echoed,
                .expires_at_ms = expires_at,
            } },
        };
        defer response.deinit(self.allocator);
        try self.push(response);

        const settled = try self.allocator.dupe(u8, reference);
        self.burnPendingGrant(nonce);
        return settled;
    }

    pub fn refuseGrant(self: *Self, nonce: []const u8, message: []const u8) !void {
        const grant = self.findPendingGrant(nonce) orelse return error.UnknownNonce;

        const id = try self.nextId();
        errdefer self.allocator.free(id);
        const reply = try self.allocator.dupe(u8, grant.request_id);
        errdefer self.allocator.free(reply);
        const owned_message = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(owned_message);

        var response = types.Envelope{
            .id = id,
            .in_reply_to = reply,
            .payload = .{ .provider_credential_grant_response = .{
                .accepted = false,
                .err = .{ .code = .credential_rejected, .message = owned_message },
            } },
        };
        defer response.deinit(self.allocator);
        try self.push(response);
        self.burnPendingGrant(nonce);
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
            .inference_cancel_request => try self.handleCancel(env),
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
            .capability_revision = revision,
            .payload = .{ .provider_describe_response = .{
                .providers = descriptors,
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
            .capability_revision = revision,
            .payload = .{ .provider_models_list_response = .{
                .models = entries,
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

        if (self.options.grant_channel == .out_of_band) {
            if (grant_request.value != null) {
                try self.emitGrantRefusal(
                    env,
                    .invalid_request,
                    "this binding carries the credential out of band; the grant envelope must not carry a value",
                );
                return;
            }
            if (self.findPendingGrant(grant_request.nonce) != null) {
                try self.emitGrantRefusal(env, .invalid_request, "this nonce is already in flight");
                return;
            }

            const pending_nonce = try self.allocator.dupe(u8, grant_request.nonce);
            errdefer self.allocator.free(pending_nonce);
            const pending_provider = try self.allocator.dupe(u8, grant_request.provider_id);
            errdefer self.allocator.free(pending_provider);
            const pending_request = try self.allocator.dupe(u8, env.id);
            errdefer self.allocator.free(pending_request);

            try self.pending_grants.append(self.allocator, .{
                .nonce = pending_nonce,
                .provider_id = pending_provider,
                .request_id = pending_request,
                .ttl_ms = grant_request.ttl_ms,
            });
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
                .accepted = true,
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
                .accepted = false,
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
        } else if (!descriptor.allows_anonymous and !self.options.resolves_own_credentials) {
            try self.emitCreateRefusal(env, .credential_missing, "this provider needs a credential and the request named none");
            return;
        }

        if (!types.supportsSnapshotPolicy(descriptor.snapshot_policies, create_request.include_snapshot)) {
            if (!types.allowsDegraded(create_request.allow_degraded_features, types.DEGRADABLE_SNAPSHOT_KEY)) {
                try self.emitCreateRefusal(
                    env,
                    .unsupported_feature,
                    "this provider does not offer the requested include_snapshot policy",
                );
                return;
            }
        }

        if (create_request.tools.len > 0 or create_request.tool_choice != null) {
            try self.emitCreateRefusal(env, .unsupported_feature, "this endpoint does not forward tools to a provider");
            return;
        }

        if (!create_request.stream) {
            try self.emitCreateRefusal(env, .unsupported_feature, "this endpoint streams every inference and cannot answer unary");
            return;
        }

        if (create_request.top_p != null) {
            try self.emitCreateRefusal(env, .unsupported_feature, "this endpoint does not forward top_p");
            return;
        }

        if (create_request.headers.len > 0) {
            try self.emitCreateRefusal(env, .unsupported_feature, "this endpoint does not forward request headers to a provider");
            return;
        }

        for (create_request.messages) |message| {
            if (messageCarriesNonText(message)) {
                try self.emitCreateRefusal(
                    env,
                    .unsupported_feature,
                    "this endpoint forwards text content only; a tool call, tool result or reasoning part cannot be carried",
                );
                return;
            }
        }

        if (create_request.output_schema_json != null) {
            try self.emitCreateRefusal(env, .unsupported_feature, "this endpoint does not forward a structured output schema");
            return;
        }

        if (create_request.reasoning != null) {
            try self.emitCreateRefusal(env, .unsupported_feature, "this endpoint does not forward reasoning controls");
            return;
        }

        if (!self.options.accepts_inference) {
            try self.emitCreateRefusal(env, .provider_unavailable, "no inference backend is attached to this endpoint");
            return;
        }

        var honoured = create_request.include_snapshot;
        if (!types.supportsSnapshotPolicy(descriptor.snapshot_policies, create_request.include_snapshot)) honoured = .never;

        const inference_id = try self.nextId();
        errdefer self.allocator.free(inference_id);
        const model_ref = try self.allocator.dupe(u8, create_request.model_ref);
        errdefer self.allocator.free(model_ref);
        const messages = try cloneMessages(self.allocator, create_request.messages);
        errdefer {
            for (messages) |*message| message.deinit(self.allocator);
            self.allocator.free(messages);
        }

        try self.active.append(self.allocator, .{
            .id = inference_id,
            .model_ref = model_ref,
            .messages = messages,
            .max_output_tokens = create_request.max_output_tokens,
            .temperature = create_request.temperature,
            .include_snapshot = honoured,
            .closed_parts = std.ArrayList(oap_types.ContentPart).empty,
            .text = std.ArrayList(u8).empty,
        });

        const queued = try self.allocator.dupe(u8, inference_id);
        errdefer self.allocator.free(queued);
        try self.pending_starts.append(self.allocator, queued);

        const id = try self.nextId();
        errdefer self.allocator.free(id);
        const reply = try self.allocator.dupe(u8, env.id);
        errdefer self.allocator.free(reply);
        const scope = try self.allocator.dupe(u8, inference_id);
        errdefer self.allocator.free(scope);

        var response = types.Envelope{
            .id = id,
            .in_reply_to = reply,
            .inference_id = scope,
            .payload = .{ .inference_create_response = .{
                .accepted = true,
                .honoured = honoured,
            } },
        };
        defer response.deinit(self.allocator);
        try self.push(response);
    }

    pub fn findInference(self: *Self, id: []const u8) ?*ActiveInference {
        for (self.active.items) |*inference| {
            if (std.mem.eql(u8, inference.id, id)) return inference;
        }
        return null;
    }

    fn pushScoped(self: *Self, inference: *ActiveInference, payload: types.Payload) !void {
        const id = try self.nextId();
        errdefer self.allocator.free(id);
        const scope = try self.allocator.dupe(u8, inference.id);
        errdefer self.allocator.free(scope);

        var env = types.Envelope{
            .id = id,
            .inference_id = scope,
            .sequence = inference.next_sequence,
            .timestamp_ms = compat.time.nowMillis(),
            .payload = payload,
        };
        defer env.deinit(self.allocator);
        try self.push(env);
        inference.next_sequence += 1;
    }

    fn snapshotIfDue(self: *Self, inference: *ActiveInference, at_part_end: bool) !?[]oap_types.Message {
        const due = switch (inference.include_snapshot) {
            .never => false,
            .on_part_end => at_part_end,
            .every_delta => true,
        };
        if (!due) return null;

        return try self.buildSnapshot(inference);
    }

    fn buildSnapshot(self: *Self, inference: *ActiveInference) !?[]oap_types.Message {
        var parts = std.ArrayList(oap_types.ContentPart).empty;
        errdefer {
            for (parts.items) |*part| part.deinit(self.allocator);
            parts.deinit(self.allocator);
        }

        for (inference.closed_parts.items) |part| {
            try parts.append(self.allocator, try clonePart(self.allocator, part));
        }

        if (inference.open_part != null) {
            const accumulated = inference.text.items;
            switch (inference.open_part_kind) {
                .text => {
                    const owned = try self.allocator.dupe(u8, accumulated);
                    errdefer self.allocator.free(owned);
                    try parts.append(self.allocator, .{ .text = owned });
                },
                .reasoning => {
                    const owned = try self.allocator.dupe(u8, accumulated);
                    errdefer self.allocator.free(owned);
                    try parts.append(self.allocator, .{ .reasoning = owned });
                },
                .tool_call => {
                    const id = try self.allocator.dupe(u8, inference.open_tool_call_id orelse "");
                    errdefer self.allocator.free(id);
                    const name = try self.allocator.dupe(u8, inference.open_tool_name orelse "");
                    errdefer self.allocator.free(name);
                    const empty = try self.allocator.dupe(u8, "");
                    errdefer self.allocator.free(empty);
                    const partial = try self.allocator.dupe(u8, accumulated);
                    try parts.append(self.allocator, .{ .tool_call = .{
                        .tool_call_id = id,
                        .name = name,
                        .arguments_json = empty,
                        .arguments_partial = partial,
                    } });
                },
            }
        }

        const owned_parts = try parts.toOwnedSlice(self.allocator);
        errdefer {
            for (owned_parts) |*part| part.deinit(self.allocator);
            self.allocator.free(owned_parts);
        }

        const content = try contentFromParts(self.allocator, owned_parts);
        const messages = try self.allocator.alloc(oap_types.Message, 1);
        messages[0] = .{ .role = .assistant, .content = content };
        return messages;
    }

    pub fn noteStarted(self: *Self, inference_id: []const u8) !void {
        const inference = self.findInference(inference_id) orelse return error.UnknownInference;
        const model_ref = try self.allocator.dupe(u8, inference.model_ref);
        errdefer self.allocator.free(model_ref);
        try self.pushScoped(inference, .{ .inference_started = .{
            .model_ref = model_ref,
            .started_at_ms = compat.time.nowMillis(),
        } });
    }

    pub fn notePartStarted(
        self: *Self,
        inference_id: []const u8,
        part_index: u32,
        part_kind: types.PartKind,
        tool_call_id: ?[]const u8,
        name: ?[]const u8,
    ) !void {
        const inference = self.findInference(inference_id) orelse return error.UnknownInference;
        if (inference.open_part != null) return error.PartAlreadyOpen;
        if (part_kind == .tool_call and (tool_call_id == null or name == null)) return error.ToolCallIdentityRequired;
        if (part_kind != .tool_call and (tool_call_id != null or name != null)) return error.ToolCallIdentityRefused;

        const owned_id = if (tool_call_id) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (owned_id) |value| self.allocator.free(value);
        const owned_name = if (name) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (owned_name) |value| self.allocator.free(value);

        inference.open_part = part_index;
        inference.open_part_kind = part_kind;
        inference.text.clearRetainingCapacity();
        if (inference.open_tool_call_id) |value| self.allocator.free(value);
        if (inference.open_tool_name) |value| self.allocator.free(value);
        inference.open_tool_call_id = if (tool_call_id) |value| try self.allocator.dupe(u8, value) else null;
        inference.open_tool_name = if (name) |value| try self.allocator.dupe(u8, value) else null;
        try self.pushScoped(inference, .{ .inference_part_started = .{
            .part_index = part_index,
            .part_kind = part_kind,
            .tool_call_id = owned_id,
            .name = owned_name,
        } });
    }

    pub fn notePartDelta(self: *Self, inference_id: []const u8, part_index: u32, delta: []const u8) !void {
        const inference = self.findInference(inference_id) orelse return error.UnknownInference;
        const open = inference.open_part orelse return error.NoOpenPart;
        if (open != part_index) return error.PartIndexMismatch;

        try inference.text.appendSlice(self.allocator, delta);
        const owned_delta = try self.allocator.dupe(u8, delta);
        errdefer self.allocator.free(owned_delta);
        const snapshot = try self.snapshotIfDue(inference, false);
        errdefer if (snapshot) |messages| {
            for (messages) |*message| message.deinit(self.allocator);
            self.allocator.free(messages);
        };

        try self.pushScoped(inference, .{ .inference_part_delta = .{
            .part_index = part_index,
            .delta = owned_delta,
            .snapshot = snapshot,
        } });
    }

    pub fn notePartEndedText(self: *Self, inference_id: []const u8, part_index: u32, part_kind: types.PartKind, text: []const u8) !void {
        return self.notePartEndedTextWithCarry(inference_id, part_index, part_kind, text, null);
    }

    pub fn notePartEndedTextWithCarry(
        self: *Self,
        inference_id: []const u8,
        part_index: u32,
        part_kind: types.PartKind,
        text: []const u8,
        carry: ?[]const u8,
    ) !void {
        const inference = self.findInference(inference_id) orelse return error.UnknownInference;
        const open = inference.open_part orelse return error.NoOpenPart;
        if (open != part_index) return error.PartIndexMismatch;
        if (part_kind == .tool_call) return error.ToolCallNeedsCompleteCall;
        if (carry != null and part_kind == .text) return error.CarryRefusedOnText;

        inference.text.clearRetainingCapacity();
        try inference.text.appendSlice(self.allocator, text);

        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);
        const owned_carry = if (carry) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (owned_carry) |value| self.allocator.free(value);
        const snapshot = try self.snapshotIfDue(inference, true);
        errdefer if (snapshot) |messages| {
            for (messages) |*message| message.deinit(self.allocator);
            self.allocator.free(messages);
        };

        const closed_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(closed_text);
        try inference.closed_parts.append(self.allocator, switch (part_kind) {
            .reasoning => .{ .reasoning = closed_text },
            else => .{ .text = closed_text },
        });

        inference.open_part = null;
        try self.pushScoped(inference, .{ .inference_part_ended = .{
            .part_index = part_index,
            .part_kind = part_kind,
            .text = owned_text,
            .carry = owned_carry,
            .snapshot = snapshot,
        } });
    }

    pub fn notePartEndedToolCall(
        self: *Self,
        inference_id: []const u8,
        part_index: u32,
        tool_call_id: []const u8,
        name: []const u8,
        arguments_json: []const u8,
        carry: ?[]const u8,
    ) !void {
        const inference = self.findInference(inference_id) orelse return error.UnknownInference;
        const open = inference.open_part orelse return error.NoOpenPart;
        if (open != part_index) return error.PartIndexMismatch;

        const owned_id = try self.allocator.dupe(u8, tool_call_id);
        errdefer self.allocator.free(owned_id);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_arguments = try self.allocator.dupe(u8, arguments_json);
        errdefer self.allocator.free(owned_arguments);

        const owned_carry = if (carry) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (owned_carry) |value| self.allocator.free(value);

        const closed_id = try self.allocator.dupe(u8, tool_call_id);
        errdefer self.allocator.free(closed_id);
        const closed_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(closed_name);
        const closed_arguments = try self.allocator.dupe(u8, arguments_json);
        errdefer self.allocator.free(closed_arguments);
        try inference.closed_parts.append(self.allocator, .{ .tool_call = .{
            .tool_call_id = closed_id,
            .name = closed_name,
            .arguments_json = closed_arguments,
        } });

        inference.text.clearRetainingCapacity();
        const snapshot = try self.snapshotIfDue(inference, true);
        errdefer if (snapshot) |messages| {
            for (messages) |*message| message.deinit(self.allocator);
            self.allocator.free(messages);
        };

        inference.open_part = null;
        try self.pushScoped(inference, .{ .inference_part_ended = .{
            .part_index = part_index,
            .part_kind = .tool_call,
            .carry = owned_carry,
            .tool_call = .{
                .tool_call_id = owned_id,
                .name = owned_name,
                .arguments_json = owned_arguments,
            },
            .snapshot = snapshot,
        } });
    }

    pub fn settleCompleted(
        self: *Self,
        inference_id: []const u8,
        stop_reason: types.StopReason,
        usage: ?oap_types.Usage,
    ) !void {
        const inference = self.findInference(inference_id) orelse return error.UnknownInference;
        if (inference.terminal_emitted) return error.TerminalAlreadyEmitted;
        if (inference.open_part != null) return error.PartStillOpen;

        var parts = std.ArrayList(oap_types.ContentPart).empty;
        errdefer {
            for (parts.items) |*part| part.deinit(self.allocator);
            parts.deinit(self.allocator);
        }
        for (inference.closed_parts.items) |part| {
            try parts.append(self.allocator, try clonePart(self.allocator, part));
        }
        const owned_parts = try parts.toOwnedSlice(self.allocator);
        errdefer {
            for (owned_parts) |*part| part.deinit(self.allocator);
            self.allocator.free(owned_parts);
        }
        const content = try contentFromParts(self.allocator, owned_parts);

        inference.terminal_emitted = true;
        try self.pushScoped(inference, .{ .inference_completed = .{
            .message = .{ .role = .assistant, .content = content },
            .stop_reason = stop_reason,
            .usage = usage,
        } });
    }

    pub fn settleCompletedFromResult(
        self: *Self,
        inference_id: []const u8,
        stop_reason: types.StopReason,
        usage: ?oap_types.Usage,
        content: []const ai_content.AssistantContent,
    ) !void {
        const inference = self.findInference(inference_id) orelse return error.UnknownInference;
        if (inference.terminal_emitted) return error.TerminalAlreadyEmitted;
        if (inference.open_part != null) return error.PartStillOpen;

        var parts = std.ArrayList(oap_types.ContentPart).empty;
        errdefer {
            for (parts.items) |*part| part.deinit(self.allocator);
            parts.deinit(self.allocator);
        }

        for (content) |item| {
            switch (item) {
                .text => |text| {
                    const owned = try self.allocator.dupe(u8, text.text);
                    errdefer self.allocator.free(owned);
                    try parts.append(self.allocator, .{ .text = owned });
                },
                .thinking => |thinking| {
                    const owned = try self.allocator.dupe(u8, thinking.thinking);
                    errdefer self.allocator.free(owned);
                    try parts.append(self.allocator, .{ .reasoning = owned });
                },
                .tool_call => |call| {
                    const id = try self.allocator.dupe(u8, call.id);
                    errdefer self.allocator.free(id);
                    const name = try self.allocator.dupe(u8, call.name);
                    errdefer self.allocator.free(name);
                    const arguments = try self.allocator.dupe(u8, call.arguments_json);
                    errdefer self.allocator.free(arguments);
                    try parts.append(self.allocator, .{ .tool_call = .{
                        .tool_call_id = id,
                        .name = name,
                        .arguments_json = arguments,
                    } });
                },
                .image => {},
            }
        }

        const owned_parts = try parts.toOwnedSlice(self.allocator);
        errdefer {
            for (owned_parts) |*part| part.deinit(self.allocator);
            self.allocator.free(owned_parts);
        }
        const result_content = try contentFromParts(self.allocator, owned_parts);

        inference.terminal_emitted = true;
        try self.pushScoped(inference, .{ .inference_completed = .{
            .message = .{ .role = .assistant, .content = result_content },
            .stop_reason = stop_reason,
            .usage = usage,
        } });
    }

    pub fn abandonOpenPart(self: *Self, inference_id: []const u8) void {
        const inference = self.findInference(inference_id) orelse return;
        inference.open_part = null;
        inference.text.clearRetainingCapacity();
        if (inference.open_tool_call_id) |value| self.allocator.free(value);
        if (inference.open_tool_name) |value| self.allocator.free(value);
        inference.open_tool_call_id = null;
        inference.open_tool_name = null;
    }

    pub fn settleFailed(
        self: *Self,
        inference_id: []const u8,
        code: types.ErrorCode,
        message: []const u8,
        usage: ?oap_types.Usage,
    ) !void {
        const inference = self.findInference(inference_id) orelse return error.UnknownInference;
        if (inference.terminal_emitted) return error.TerminalAlreadyEmitted;
        inference.open_part = null;

        const owned_message = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(owned_message);

        inference.terminal_emitted = true;
        try self.pushScoped(inference, .{ .inference_failed = .{
            .err = .{ .code = code, .message = owned_message },
            .usage = usage,
        } });
    }

    pub fn releaseInference(self: *Self, inference_id: []const u8) void {
        for (self.active.items, 0..) |*inference, index| {
            if (!std.mem.eql(u8, inference.id, inference_id)) continue;
            var removed = self.active.orderedRemove(index);
            removed.deinit(self.allocator);
            return;
        }
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

    fn handleCancel(self: *Self, env: types.Envelope) !void {
        const scope = env.inference_id orelse {
            try self.emitError(.invalid_request, "a cancel must name the inference it targets", env.id);
            return;
        };

        const accepted = if (self.findInference(scope)) |inference| blk: {
            inference.cancel_requested = true;
            break :blk !inference.terminal_emitted;
        } else false;

        const id = try self.nextId();
        errdefer self.allocator.free(id);
        const reply = try self.allocator.dupe(u8, env.id);
        errdefer self.allocator.free(reply);
        const owned_scope = try self.allocator.dupe(u8, scope);
        errdefer self.allocator.free(owned_scope);

        var response = types.Envelope{
            .id = id,
            .in_reply_to = reply,
            .inference_id = owned_scope,
            .payload = .{ .inference_cancel_response = .{ .accepted = accepted } },
        };
        defer response.deinit(self.allocator);
        try self.push(response);
    }

    fn handleSyncUnsupported(self: *Self, env: types.Envelope) !void {
        const id = try self.nextId();
        errdefer self.allocator.free(id);
        const reply = try self.allocator.dupe(u8, env.id);
        errdefer self.allocator.free(reply);

        var snapshot: ?[]oap_types.Message = null;
        errdefer if (snapshot) |messages| {
            for (messages) |*message| message.deinit(self.allocator);
            self.allocator.free(messages);
        };
        if (env.inference_id) |scope| {
            if (self.findInference(scope)) |inference| {
                if (!inference.terminal_emitted) {
                    snapshot = try self.buildSnapshot(inference);
                }
            }
        }

        var response = types.Envelope{
            .id = id,
            .in_reply_to = reply,
            .inference_id = if (env.inference_id) |value| try self.allocator.dupe(u8, value) else null,
            .payload = .{ .inference_sync_response = .{ .snapshot = snapshot } },
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
    const wire_id = if (descriptor.wire_id) |value| try allocator.dupe(u8, value) else null;
    errdefer if (wire_id) |value| allocator.free(value);
    const endpoint = try allocator.dupe(u8, descriptor.endpoint);
    errdefer allocator.free(endpoint);
    const headers = try cloneHeaders(allocator, descriptor.headers);
    errdefer types.freeHeaders(allocator, headers);
    const policies = try allocator.dupe(types.SnapshotPolicy, descriptor.snapshot_policies);
    errdefer allocator.free(policies);

    return types.ProviderDescriptor{
        .id = id,
        .display_name = display_name,
        .wire = descriptor.wire,
        .wire_id = wire_id,
        .framing = descriptor.framing,
        .endpoint = endpoint,
        .headers = headers,
        .compatibility = descriptor.compatibility,
        .snapshot_policies = policies,
        .answers_sync = descriptor.answers_sync,
        .credential_grant = descriptor.credential_grant,
        .grant_kinds = try allocator.dupe(types.GrantKind, descriptor.grant_kinds),
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

fn messageCarriesNonText(message: oap_types.Message) bool {
    if (message.role == .tool) return true;
    return switch (message.content) {
        .text => false,
        .parts => |parts| blk: {
            for (parts) |part| {
                switch (part) {
                    .text => {},
                    else => break :blk true,
                }
            }
            break :blk false;
        },
    };
}

fn contentFromParts(
    allocator: std.mem.Allocator,
    parts: []oap_types.ContentPart,
) !oap_types.Content {
    if (parts.len > 0) return .{ .parts = parts };
    allocator.free(parts);
    return .{ .text = try allocator.dupe(u8, "") };
}

pub fn cloneMessages(
    allocator: std.mem.Allocator,
    messages: []const oap_types.Message,
) ![]oap_types.Message {
    const out = try allocator.alloc(oap_types.Message, messages.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*message| message.deinit(allocator);
        allocator.free(out);
    }
    for (messages, 0..) |message, index| {
        const id = if (message.id) |value| try allocator.dupe(u8, value) else null;
        errdefer if (id) |value| allocator.free(value);
        const content: oap_types.Content = switch (message.content) {
            .text => |value| .{ .text = try allocator.dupe(u8, value) },
            .parts => |parts| blk: {
                const cloned = try allocator.alloc(oap_types.ContentPart, parts.len);
                var parts_built: usize = 0;
                errdefer {
                    for (cloned[0..parts_built]) |*part| part.deinit(allocator);
                    allocator.free(cloned);
                }
                for (parts, 0..) |part, part_index| {
                    cloned[part_index] = try clonePart(allocator, part);
                    parts_built += 1;
                }
                break :blk .{ .parts = cloned };
            },
        };
        out[index] = .{ .id = id, .role = message.role, .content = content };
        built += 1;
    }
    return out;
}

fn clonePart(allocator: std.mem.Allocator, part: oap_types.ContentPart) !oap_types.ContentPart {
    return switch (part) {
        .text => |value| .{ .text = try allocator.dupe(u8, value) },
        .reasoning => |value| .{ .reasoning = try allocator.dupe(u8, value) },
        .tool_call => |call| blk: {
            const id = try allocator.dupe(u8, call.tool_call_id);
            errdefer allocator.free(id);
            const name = try allocator.dupe(u8, call.name);
            errdefer allocator.free(name);
            const arguments = try allocator.dupe(u8, call.arguments_json);
            break :blk .{ .tool_call = .{ .tool_call_id = id, .name = name, .arguments_json = arguments } };
        },
        .tool_result => |result| blk: {
            const id = try allocator.dupe(u8, result.tool_call_id);
            errdefer allocator.free(id);
            const json = try allocator.dupe(u8, result.result_json);
            break :blk .{ .tool_result = .{
                .tool_call_id = id,
                .result_json = json,
                .is_error = result.is_error,
            } };
        },
    };
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
        .snapshot_policies = policies,
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

    try std.testing.expect(server.popOutbound() == null);
    try std.testing.expectEqual(@as(usize, 1), server.pending_grants.items.len);
    try std.testing.expectEqual(@as(usize, 0), server.grants.items.len);
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

test "acceptance is discriminated by the scope field, never by a payload copy" {
    const allocator = std.testing.allocator;

    const refusal_with_scope =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++
        "\",\"type\":\"inference.create.response\",\"id\":\"m1\",\"inference_id\":\"inf1\",\"payload\":{\"accepted\":false}}";
    try std.testing.expectError(
        envelope.DecodeError.AcceptanceScopeMismatch,
        envelope.deserializeEnvelope(refusal_with_scope, allocator),
    );

    const acceptance_without_scope =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++
        "\",\"type\":\"inference.create.response\",\"id\":\"m1\",\"payload\":{\"accepted\":true}}";
    try std.testing.expectError(
        envelope.DecodeError.AcceptanceScopeMismatch,
        envelope.deserializeEnvelope(acceptance_without_scope, allocator),
    );

    const scope_repeated_in_payload =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++
        "\",\"type\":\"inference.create.response\",\"id\":\"m1\",\"inference_id\":\"inf1\"," ++
        "\"payload\":{\"accepted\":true,\"inference_id\":\"inf1\"}}";
    try std.testing.expectError(
        envelope.DecodeError.ScopeRepeatedInPayload,
        envelope.deserializeEnvelope(scope_repeated_in_payload, allocator),
    );
}

fn acceptOne(allocator: std.mem.Allocator, server: *Server, snapshot: []const u8) ![]const u8 {
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[],\"include_snapshot\":\"{s}\"}}",
        .{snapshot},
    );
    defer allocator.free(payload);
    const line = try makeRequest(allocator, "inference.create.request", payload, "q1");
    defer allocator.free(line);
    try server.handleLine(line);

    var response = try decodeOnly(allocator, server);
    defer response.deinit(allocator);
    try std.testing.expect(response.payload.inference_create_response.accepted);
    return allocator.dupe(u8, response.inference_id.?);
}

test "a streamed inference emits one contiguous sequence and exactly one terminal" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    const inference_id = try acceptOne(allocator, &server, "never");
    defer allocator.free(inference_id);

    try server.noteStarted(inference_id);
    try server.notePartStarted(inference_id, 0, .text, null, null);
    try server.notePartDelta(inference_id, 0, "hel");
    try server.notePartDelta(inference_id, 0, "lo");
    try server.notePartEndedText(inference_id, 0, .text, "hello");
    try server.settleCompleted(inference_id, .stop, .{ .input_tokens = 3, .output_tokens = 2 });

    var expected_sequence: u64 = 1;
    var terminals: usize = 0;
    while (server.popOutbound()) |line| {
        defer allocator.free(line);
        var env = try envelope.deserializeEnvelope(line, allocator);
        defer env.deinit(allocator);

        try std.testing.expectEqualStrings(inference_id, env.inference_id.?);
        try std.testing.expectEqual(expected_sequence, env.sequence.?);
        expected_sequence += 1;

        switch (env.payload) {
            .inference_completed => |completed| {
                terminals += 1;
                try std.testing.expectEqualStrings("hello", completed.message.content.parts[0].text);
                try std.testing.expectEqual(types.StopReason.stop, completed.stop_reason);
            },
            .inference_failed => terminals += 1,
            else => {},
        }
    }

    try std.testing.expectEqual(@as(u64, 7), expected_sequence);
    try std.testing.expectEqual(@as(usize, 1), terminals);
    try std.testing.expectError(error.TerminalAlreadyEmitted, server.settleCompleted(inference_id, .stop, null));
}

test "a snapshot arrives only where the honoured policy says it should" {
    const allocator = std.testing.allocator;

    var never = try testServer(allocator, .{ .accepts_inference = true });
    defer never.deinit();
    const quiet = try acceptOne(allocator, &never, "never");
    defer allocator.free(quiet);
    try never.notePartStarted(quiet, 0, .text, null, null);
    try never.notePartDelta(quiet, 0, "a");
    try never.notePartEndedText(quiet, 0, .text, "a");
    try std.testing.expectEqual(@as(usize, 0), try countSnapshots(allocator, &never));

    var on_end = try testServer(allocator, .{ .accepts_inference = true });
    defer on_end.deinit();
    const ending = try acceptOne(allocator, &on_end, "on_part_end");
    defer allocator.free(ending);
    try on_end.notePartStarted(ending, 0, .text, null, null);
    try on_end.notePartDelta(ending, 0, "a");
    try on_end.notePartDelta(ending, 0, "b");
    try on_end.notePartEndedText(ending, 0, .text, "ab");
    try std.testing.expectEqual(@as(usize, 1), try countSnapshots(allocator, &on_end));
}

fn countSnapshots(allocator: std.mem.Allocator, server: *Server) !usize {
    var count: usize = 0;
    while (server.popOutbound()) |line| {
        defer allocator.free(line);
        var env = try envelope.deserializeEnvelope(line, allocator);
        defer env.deinit(allocator);
        switch (env.payload) {
            .inference_part_delta => |delta| {
                if (delta.snapshot != null) count += 1;
            },
            .inference_part_ended => |ended| {
                if (ended.snapshot != null) count += 1;
            },
            else => {},
        }
    }
    return count;
}

test "an unsupported policy is degraded to never and the response says so" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    const line = try makeRequest(
        allocator,
        "inference.create.request",
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[]," ++
            "\"include_snapshot\":\"every_delta\",\"allow_degraded_features\":[\"include_snapshot\"]}",
        "q1",
    );
    defer allocator.free(line);
    try server.handleLine(line);

    var response = try decodeOnly(allocator, &server);
    defer response.deinit(allocator);
    try std.testing.expect(response.payload.inference_create_response.accepted);
    try std.testing.expectEqual(
        types.SnapshotPolicy.never,
        response.payload.inference_create_response.honoured.?,
    );
}

test "the emission surface refuses a part shape the wire would refuse" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    const inference_id = try acceptOne(allocator, &server, "never");
    defer allocator.free(inference_id);

    try std.testing.expectError(
        error.ToolCallIdentityRequired,
        server.notePartStarted(inference_id, 0, .tool_call, null, null),
    );
    try std.testing.expectError(
        error.ToolCallIdentityRefused,
        server.notePartStarted(inference_id, 0, .text, "call_1", "search"),
    );
    try std.testing.expectError(error.NoOpenPart, server.notePartDelta(inference_id, 0, "x"));

    try server.notePartStarted(inference_id, 0, .text, null, null);
    try std.testing.expectError(error.PartAlreadyOpen, server.notePartStarted(inference_id, 1, .text, null, null));
    try std.testing.expectError(error.PartIndexMismatch, server.notePartDelta(inference_id, 1, "x"));
    try std.testing.expectError(error.PartStillOpen, server.settleCompleted(inference_id, .stop, null));
}

test "sync answers with the running snapshot and with nothing once it has settled" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    const inference_id = try acceptOne(allocator, &server, "never");
    defer allocator.free(inference_id);

    try server.notePartStarted(inference_id, 0, .text, null, null);
    try server.notePartDelta(inference_id, 0, "partial");
    while (server.popOutbound()) |line| allocator.free(line);

    const sync_line = try std.fmt.allocPrint(
        allocator,
        "{{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"{s}\",\"type\":\"inference.sync.request\",\"id\":\"s1\",\"inference_id\":\"{s}\",\"payload\":{{}}}}",
        .{ types.PROFILE, inference_id },
    );
    defer allocator.free(sync_line);
    try server.handleLine(sync_line);

    var live = try decodeOnly(allocator, &server);
    defer live.deinit(allocator);
    const live_parts = live.payload.inference_sync_response.snapshot.?[0].content.parts;
    try std.testing.expectEqualStrings("partial", live_parts[0].text);

    try server.notePartEndedText(inference_id, 0, .text, "partial");
    try server.settleCompleted(inference_id, .stop, null);
    while (server.popOutbound()) |line| allocator.free(line);

    try server.handleLine(sync_line);
    var settled = try decodeOnly(allocator, &server);
    defer settled.deinit(allocator);
    try std.testing.expect(settled.payload.inference_sync_response.snapshot == null);
}

test "cancellation is intent and the terminal is the settlement" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    const inference_id = try acceptOne(allocator, &server, "never");
    defer allocator.free(inference_id);
    while (server.popOutbound()) |line| allocator.free(line);

    const cancel_line = try std.fmt.allocPrint(
        allocator,
        "{{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"{s}\",\"type\":\"inference.cancel.request\",\"id\":\"c1\",\"inference_id\":\"{s}\",\"payload\":{{}}}}",
        .{ types.PROFILE, inference_id },
    );
    defer allocator.free(cancel_line);
    try server.handleLine(cancel_line);

    var accepted = try decodeOnly(allocator, &server);
    defer accepted.deinit(allocator);
    try std.testing.expect(accepted.payload.inference_cancel_response.accepted);
    try std.testing.expect(server.findInference(inference_id).?.cancel_requested);

    try server.settleCompleted(inference_id, .aborted, null);
    var terminal = try decodeOnly(allocator, &server);
    defer terminal.deinit(allocator);
    try std.testing.expectEqual(types.StopReason.aborted, terminal.payload.inference_completed.stop_reason);
}

test "the terminal is built from the provider result, not from accumulated deltas" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    const inference_id = try acceptOne(allocator, &server, "never");
    defer allocator.free(inference_id);

    try server.notePartStarted(inference_id, 0, .text, null, null);
    try server.notePartDelta(inference_id, 0, "streamed");
    try server.notePartEndedText(inference_id, 0, .text, "streamed");
    while (server.popOutbound()) |line| allocator.free(line);

    const content = [_]ai_content.AssistantContent{
        .{ .text = .{ .text = "final text" } },
        .{ .tool_call = .{ .id = "call_1", .name = "search", .arguments_json = "{}" } },
    };

    try server.settleCompletedFromResult(
        inference_id,
        .tool_use,
        .{ .input_tokens = 11, .output_tokens = 5, .total_tokens = 16 },
        &content,
    );

    var terminal = try decodeOnly(allocator, &server);
    defer terminal.deinit(allocator);

    const completed = terminal.payload.inference_completed;
    try std.testing.expectEqual(types.StopReason.tool_use, completed.stop_reason);
    try std.testing.expectEqual(@as(u64, 16), completed.usage.?.total_tokens.?);

    const parts = completed.message.content.parts;
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqualStrings("final text", parts[0].text);
    try std.testing.expectEqualStrings("call_1", parts[1].tool_call.tool_call_id);
}

test "a request member the endpoint cannot forward is refused rather than dropped" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    const cases = [_][]const u8{
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[],\"tools\":[{\"name\":\"search\"}]}",
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[],\"tool_choice\":\"auto\"}",
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[],\"output_schema\":{\"type\":\"object\"}}",
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[],\"reasoning\":{\"enabled\":true}}",
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[],\"top_p\":0.9}",
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[],\"stream\":false}",
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[],\"headers\":{\"X-Tenant\":\"acme\"}}",
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_call\",\"tool_call_id\":\"c1\",\"name\":\"search\",\"arguments_json\":\"{}\"}]}]}",
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[{\"role\":\"tool\",\"content\":\"result\"}]}",
    };

    for (cases) |payload| {
        const line = try makeRequest(allocator, "inference.create.request", payload, "q1");
        defer allocator.free(line);
        try server.handleLine(line);

        var response = try decodeOnly(allocator, &server);
        defer response.deinit(allocator);
        try std.testing.expect(!response.payload.inference_create_response.accepted);
        try std.testing.expectEqual(
            types.ErrorCode.unsupported_feature,
            response.payload.inference_create_response.err.?.code,
        );
    }

    try std.testing.expectEqual(@as(usize, 0), server.active.items.len);
}

test "sampling controls the endpoint does forward are carried onto the inference" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    const line = try makeRequest(
        allocator,
        "inference.create.request",
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[],\"max_output_tokens\":256,\"temperature\":0.25}",
        "q1",
    );
    defer allocator.free(line);
    try server.handleLine(line);

    var response = try decodeOnly(allocator, &server);
    defer response.deinit(allocator);
    const inference_id = response.inference_id.?;

    const inference = server.findInference(inference_id).?;
    try std.testing.expectEqual(@as(u32, 256), inference.max_output_tokens.?);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), inference.temperature.?, 0.0001);
}

test "a snapshot taken mid tool call carries the fragment and never valid arguments" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    const inference_id = try acceptOne(allocator, &server, "on_part_end");
    defer allocator.free(inference_id);

    try server.notePartStarted(inference_id, 0, .text, null, null);
    try server.notePartEndedText(inference_id, 0, .text, "before");
    try server.notePartStarted(inference_id, 1, .tool_call, "call_1", "search");
    try server.notePartDelta(inference_id, 1, "{\"q\":");
    while (server.popOutbound()) |line| allocator.free(line);

    const sync_line = try std.fmt.allocPrint(
        allocator,
        "{{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"{s}\",\"type\":\"inference.sync.request\",\"id\":\"s1\",\"inference_id\":\"{s}\",\"payload\":{{}}}}",
        .{ types.PROFILE, inference_id },
    );
    defer allocator.free(sync_line);
    try server.handleLine(sync_line);

    var live = try decodeOnly(allocator, &server);
    defer live.deinit(allocator);

    const parts = live.payload.inference_sync_response.snapshot.?[0].content.parts;
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqualStrings("before", parts[0].text);

    const call = parts[1].tool_call;
    try std.testing.expectEqualStrings("call_1", call.tool_call_id);
    try std.testing.expectEqualStrings("search", call.name);
    try std.testing.expectEqualStrings("{\"q\":", call.arguments_partial.?);
    try std.testing.expectEqualStrings("", call.arguments_json);
}

test "a completed tool call appears in the snapshot with complete arguments" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    const inference_id = try acceptOne(allocator, &server, "on_part_end");
    defer allocator.free(inference_id);

    try server.notePartStarted(inference_id, 0, .tool_call, "call_1", "search");
    try server.notePartDelta(inference_id, 0, "{\"q\":\"zig\"}");
    try server.notePartEndedToolCall(inference_id, 0, "call_1", "search", "{\"q\":\"zig\"}", null);

    var found = false;
    while (server.popOutbound()) |line| {
        defer allocator.free(line);
        var env = try envelope.deserializeEnvelope(line, allocator);
        defer env.deinit(allocator);
        const ended = switch (env.payload) {
            .inference_part_ended => |value| value,
            else => continue,
        };
        const snapshot = ended.snapshot orelse continue;
        const call = snapshot[0].content.parts[0].tool_call;
        try std.testing.expectEqualStrings("{\"q\":\"zig\"}", call.arguments_json);
        try std.testing.expect(call.arguments_partial == null);
        found = true;
    }
    try std.testing.expect(found);
}

test "a terminal carrying a partial argument fragment is refused on decode" {
    const allocator = std.testing.allocator;

    const line =
        "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++
        "\",\"type\":\"inference.completed\",\"id\":\"m1\",\"inference_id\":\"i1\",\"sequence\":9," ++
        "\"payload\":{\"stop_reason\":\"stop\",\"message\":{\"role\":\"assistant\",\"content\":[" ++
        "{\"type\":\"tool_call\",\"tool_call_id\":\"c1\",\"name\":\"search\",\"arguments_partial\":\"{\\\"q\\\":\"}]}}}";

    try std.testing.expectError(
        envelope.DecodeError.PartialArgumentsInTerminal,
        envelope.deserializeEnvelope(line, allocator),
    );
}



test "an out of band grant answers with a channel before it answers the grant" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .grant_channel = .out_of_band });
    defer server.deinit();

    const line = try makeRequest(
        allocator,
        "provider.credential.grant.request",
        "{\"provider_id\":\"ollama-local\",\"nonce\":\"n1\"}",
        "q1",
    );
    defer allocator.free(line);
    try server.handleLine(line);

    try std.testing.expect(server.popOutbound() == null);
    const pending = server.nextUnannouncedGrant() orelse return error.TestExpectedPendingGrant;
    try std.testing.expectEqualStrings("n1", pending.nonce);

    try server.announceChannel("n1", "/tmp/grant-n1.sock");
    var channel = try decodeOnly(allocator, &server);
    defer channel.deinit(allocator);
    try std.testing.expectEqualStrings("q1", channel.in_reply_to.?);
    try std.testing.expectEqualStrings("n1", channel.payload.provider_credential_grant_channel.nonce);
    try std.testing.expectEqualStrings("/tmp/grant-n1.sock", channel.payload.provider_credential_grant_channel.channel);
    try std.testing.expectEqual(@as(usize, 0), server.grants.items.len);

    const reference = try server.completeGrant("n1");
    defer allocator.free(reference);

    var response = try decodeOnly(allocator, &server);
    defer response.deinit(allocator);
    try std.testing.expectEqualStrings("q1", response.in_reply_to.?);
    try std.testing.expectEqualStrings(reference, response.payload.provider_credential_grant_response.credential_ref.?);
    try std.testing.expectEqual(@as(usize, 1), server.grants.items.len);
    try std.testing.expect(server.grants.items[0].non_persistable);
}

test "a nonce is burned when its grant settles and cannot be claimed twice" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .grant_channel = .out_of_band });
    defer server.deinit();

    const line = try makeRequest(
        allocator,
        "provider.credential.grant.request",
        "{\"provider_id\":\"ollama-local\",\"nonce\":\"n1\"}",
        "q1",
    );
    defer allocator.free(line);
    try server.handleLine(line);
    try server.announceChannel("n1", "/tmp/grant-n1.sock");

    const reference = try server.completeGrant("n1");
    defer allocator.free(reference);
    try std.testing.expect(server.findPendingGrant("n1") == null);
    try std.testing.expectError(error.UnknownNonce, server.completeGrant("n1"));
}

test "a grant that outlives the arrival deadline is refused and its nonce burned" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .grant_channel = .out_of_band });
    defer server.deinit();

    const line = try makeRequest(
        allocator,
        "provider.credential.grant.request",
        "{\"provider_id\":\"ollama-local\",\"nonce\":\"n1\"}",
        "q1",
    );
    defer allocator.free(line);
    try server.handleLine(line);
    try server.announceChannel("n1", "/tmp/grant-n1.sock");
    while (server.popOutbound()) |outbound| allocator.free(outbound);

    const announced = server.findPendingGrant("n1").?.announced_at_ms.?;
    try std.testing.expect(server.expiredGrantNonce(announced + 1) == null);

    const expired = server.expiredGrantNonce(announced + GRANT_ARRIVAL_DEADLINE_MS) orelse
        return error.TestExpectedExpiry;
    try std.testing.expectEqualStrings("n1", expired);

    try server.refuseGrant("n1", "the credential did not arrive before the deadline");
    var refusal = try decodeOnly(allocator, &server);
    defer refusal.deinit(allocator);
    try std.testing.expectEqual(
        types.ErrorCode.credential_rejected,
        refusal.payload.provider_credential_grant_response.err.?.code,
    );
    try std.testing.expect(server.findPendingGrant("n1") == null);
    try std.testing.expectEqual(@as(usize, 0), server.grants.items.len);
}

test "a nonce already in flight is refused rather than opening a second channel" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .grant_channel = .out_of_band });
    defer server.deinit();

    const first = try makeRequest(allocator, "provider.credential.grant.request", "{\"provider_id\":\"ollama-local\",\"nonce\":\"n1\"}", "q1");
    defer allocator.free(first);
    try server.handleLine(first);

    const second = try makeRequest(allocator, "provider.credential.grant.request", "{\"provider_id\":\"ollama-local\",\"nonce\":\"n1\"}", "q2");
    defer allocator.free(second);
    try server.handleLine(second);

    var refusal = try decodeOnly(allocator, &server);
    defer refusal.deinit(allocator);
    try std.testing.expectEqual(
        types.ErrorCode.invalid_request,
        refusal.payload.provider_credential_grant_response.err.?.code,
    );
    try std.testing.expectEqual(@as(usize, 1), server.pending_grants.items.len);
}
