const std = @import("std");
const oap_types = @import("oap_types");
const types = @import("oap_provider_types");
const envelope = @import("oap_provider_envelope");
const json_writer = @import("json_writer");
const compat = @import("compat");
const ai_content = @import("ai_types");

pub const GrantChannel = enum {
    out_of_band,
    on_envelope,
    unsupported,
};

pub const IMPLEMENTED_SNAPSHOT_POLICIES: []const types.SnapshotPolicy = &.{ .never, .on_part_end, .every_delta };

pub const IMPLEMENTS_SYNC = true;

pub const Options = struct {
    capability_revision: []const u8 = "r1",
    profile_revision: ?[]const u8 = null,
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
    credential_ref: ?[]const u8 = null,
    tools: []const types.ToolDefinition = &.{},
    tool_choice: ?types.ToolChoice = null,
    reasoning: ?types.ReasoningOptions = null,
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
        if (self.credential_ref) |value| allocator.free(value);
        for (self.tools) |*tool| {
            var owned = tool.*;
            owned.deinit(allocator);
        }
        allocator.free(self.tools);
        if (self.tool_choice) |*choice| choice.deinit(allocator);
        if (self.reasoning) |*options| options.deinit(allocator);
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
    specimen_sequence: u64 = 1,
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

        const env = types.Envelope{
            .id = id,
            .in_reply_to = reply,
            .payload = .{ .provider_credential_grant_channel = .{
                .nonce = owned_nonce,
                .channel = owned_channel,
            } },
        };
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

        const response = types.Envelope{
            .id = id,
            .in_reply_to = reply,
            .payload = .{ .provider_credential_grant_response = .{
                .accepted = true,
                .credential_ref = echoed,
                .expires_at_ms = expires_at,
            } },
        };
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

        const response = types.Envelope{
            .id = id,
            .in_reply_to = reply,
            .payload = .{ .provider_credential_grant_response = .{
                .accepted = false,
                .err = .{ .code = .credential_rejected, .message = owned_message },
            } },
        };
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

    pub fn modelDeclares(self: *Self, model_ref: []const u8, capability: types.ModelCapability) bool {
        for (self.models.items) |entry| {
            if (!std.mem.eql(u8, entry.model_ref, model_ref)) continue;
            for (entry.capabilities) |declared| {
                if (declared == capability) return true;
            }
            return false;
        }
        return false;
    }

    pub const GrantLookup = enum { live, expired, unknown };

    pub fn burnExpiredGrants(self: *Self, now_ms: i64) void {
        var index: usize = 0;
        while (index < self.grants.items.len) {
            const expiry = self.grants.items[index].expires_at_ms orelse {
                index += 1;
                continue;
            };
            if (now_ms < expiry) {
                index += 1;
                continue;
            }
            var removed = self.grants.orderedRemove(index);
            removed.deinit(self.allocator);
        }
    }

    pub fn lookupGrant(self: *Self, reference: []const u8) GrantLookup {
        const now = compat.time.nowMillis();
        for (self.grants.items) |*grant| {
            if (!std.mem.eql(u8, grant.reference, reference)) continue;
            const expiry = grant.expires_at_ms orelse return .live;
            if (now < expiry) return .live;
            self.burnExpiredGrants(now);
            return .expired;
        }
        return .unknown;
    }

    pub fn holdsGrant(self: *Self, reference: []const u8) bool {
        for (self.grants.items) |*grant| {
            if (std.mem.eql(u8, grant.reference, reference)) return true;
        }
        return false;
    }

    pub fn findGrant(self: *Self, reference: []const u8) ?*GrantedCredential {
        if (self.lookupGrant(reference) != .live) return null;
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
        var owned = env;
        owned.deinit(self.allocator);
    }

    pub const SPECIMEN_INFERENCE_ID = "specimen-inference";

    pub const SPECIMEN_TYPES = [_][]const u8{
        "provider.describe.response",
        "provider.models.list.response",
        "inference.create.response",
        "inference.started",
        "inference.part.started",
        "inference.part.delta",
        "inference.part.ended",
        "inference.completed",
        "inference.failed",
        "inference.cancel.response",
        "inference.sync.response",
        "error",
    };

    pub const SPECIMEN_EXCLUDED = [_][]const u8{
        "provider.credential.grant.channel",
        "provider.credential.grant.response",
    };

    fn pushRawLine(self: *Self, line: []const u8) !void {
        errdefer self.allocator.free(line);
        try self.outbound.append(self.allocator, line);
    }

    fn specimenControlLine(
        self: *Self,
        control: []const u8,
        request_id: []const u8,
        include_lists: bool,
    ) ![]const u8 {
        var buffer = std.ArrayList(u8).empty;
        errdefer buffer.deinit(self.allocator);
        var w = json_writer.JsonWriter.init(&buffer, self.allocator);

        try w.beginObject();
        try w.writeStringField("control", control);
        try w.writeStringField("in_reply_to", request_id);
        if (include_lists) {
            try w.writeKey("types");
            try w.beginArray();
            for (SPECIMEN_TYPES) |name| try w.writeString(name);
            try w.endArray();
            try w.writeKey("excluded");
            try w.beginArray();
            for (SPECIMEN_EXCLUDED) |name| try w.writeString(name);
            try w.endArray();
        }
        try w.endObject();
        return buffer.toOwnedSlice(self.allocator);
    }

    pub fn emitSpecimenError(self: *Self, request_id: []const u8, reason: []const u8) !void {
        var buffer = std.ArrayList(u8).empty;
        errdefer buffer.deinit(self.allocator);
        var w = json_writer.JsonWriter.init(&buffer, self.allocator);
        try w.beginObject();
        try w.writeStringField("control", "specimen.error");
        try w.writeStringField("in_reply_to", request_id);
        try w.writeStringField("reason", reason);
        try w.endObject();
        const line = try buffer.toOwnedSlice(self.allocator);
        try self.pushRawLine(line);
    }

    pub fn emitSpecimens(self: *Self, request_id: []const u8) !void {
        if (self.active.items.len > 0) {
            try self.emitSpecimenError(request_id, "specimens are answered only on a connection with no active inference");
            return;
        }

        self.specimen_sequence = 1;
        const accepted = try self.specimenControlLine("specimen.accepted", request_id, true);
        try self.pushRawLine(accepted);

        for (SPECIMEN_TYPES) |name| try self.pushSpecimenFor(name);

        const complete = try self.specimenControlLine("specimen.complete", request_id, false);
        try self.pushRawLine(complete);
    }

    fn pushSpecimen(self: *Self, payload: types.Payload, scoped: bool) !void {
        var env = try self.specimenEnvelope(payload, scoped);
        errdefer env.deinit(self.allocator);
        try self.push(env);
    }

    fn specimenEnvelope(self: *Self, payload: types.Payload, scoped: bool) !types.Envelope {
        var owned_payload = payload;
        errdefer owned_payload.deinit(self.allocator);
        const id = try self.nextId();
        errdefer self.allocator.free(id);
        const scope = if (scoped) try self.allocator.dupe(u8, SPECIMEN_INFERENCE_ID) else null;
        var sequence: ?u64 = null;
        if (owned_payload.isScopedEvent()) {
            sequence = self.specimen_sequence;
            self.specimen_sequence += 1;
        }
        return types.Envelope{
            .id = id,
            .inference_id = scope,
            .sequence = sequence,
            .payload = owned_payload,
        };
    }

    fn specimenError(self: *Self) !types.ProtocolError {
        const message = try self.allocator.dupe(u8, "a specimen instance of this envelope, not a real failure");
        return types.ProtocolError{ .code = .provider_unavailable, .message = message };
    }

    fn specimenMessage(self: *Self) !oap_types.Message {
        const text = try self.allocator.dupe(u8, "specimen");
        errdefer self.allocator.free(text);
        const parts = try self.allocator.alloc(oap_types.ContentPart, 1);
        parts[0] = .{ .text = text };
        return oap_types.Message{ .role = .assistant, .content = .{ .parts = parts } };
    }

    fn pushSpecimenFor(self: *Self, type_name: []const u8) !void {
        const eql = std.mem.eql;
        if (eql(u8, type_name, "provider.describe.response")) {
            var transferred = false;
            const versions = try self.allocator.alloc([]const u8, 1);
            errdefer if (!transferred) self.allocator.free(versions);
            versions[0] = try self.allocator.dupe(u8, types.VERSION);
            errdefer if (!transferred) self.allocator.free(versions[0]);
            const providers = try self.allocator.alloc(types.ProviderDescriptor, 0);
            errdefer if (!transferred) self.allocator.free(providers);
            const payload = types.Payload{ .provider_describe_response = .{
                .providers = providers,
                .protocol_versions = versions,
            } };
            transferred = true;
            return self.pushSpecimen(payload, false);
        }
        if (eql(u8, type_name, "provider.models.list.response")) {
            const models = try self.allocator.alloc(types.ModelEntry, 0);
            return self.pushSpecimen(.{ .provider_models_list_response = .{ .models = models } }, false);
        }
        if (eql(u8, type_name, "inference.create.response")) {
            return self.pushSpecimen(.{ .inference_create_response = .{
                .accepted = true,
                .honoured = .never,
            } }, true);
        }
        if (eql(u8, type_name, "inference.started")) {
            const model_ref = try self.allocator.dupe(u8, "specimen/anthropic-messages@specimen-model");
            return self.pushSpecimen(.{ .inference_started = .{
                .model_ref = model_ref,
                .started_at_ms = compat.time.nowMillis(),
            } }, true);
        }
        if (eql(u8, type_name, "inference.part.started")) {
            return self.pushSpecimen(.{ .inference_part_started = .{
                .part_index = 0,
                .part_kind = .text,
            } }, true);
        }
        if (eql(u8, type_name, "inference.part.delta")) {
            const delta = try self.allocator.dupe(u8, "spec");
            return self.pushSpecimen(.{ .inference_part_delta = .{
                .part_index = 0,
                .delta = delta,
            } }, true);
        }
        if (eql(u8, type_name, "inference.part.ended")) {
            const text = try self.allocator.dupe(u8, "specimen");
            return self.pushSpecimen(.{ .inference_part_ended = .{
                .part_index = 0,
                .part_kind = .text,
                .text = text,
            } }, true);
        }
        if (eql(u8, type_name, "inference.completed")) {
            return self.pushSpecimen(.{ .inference_completed = .{
                .message = try self.specimenMessage(),
                .stop_reason = .stop,
            } }, true);
        }
        if (eql(u8, type_name, "inference.failed")) {
            return self.pushSpecimen(.{ .inference_failed = .{
                .err = try self.specimenError(),
            } }, true);
        }
        if (eql(u8, type_name, "inference.cancel.response")) {
            return self.pushSpecimen(.{ .inference_cancel_response = .{ .accepted = true } }, true);
        }
        if (eql(u8, type_name, "inference.sync.response")) {
            return self.pushSpecimen(.{ .inference_sync_response = .{} }, true);
        }
        if (eql(u8, type_name, "error")) {
            return self.pushSpecimen(.{ .protocol_error = .{
                .err = try self.specimenError(),
            } }, false);
        }
        return error.UnknownSpecimenType;
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

        const version_string = try self.allocator.dupe(u8, types.VERSION);
        errdefer self.allocator.free(version_string);
        const versions = try self.allocator.alloc([]const u8, 1);
        errdefer self.allocator.free(versions);
        versions[0] = version_string;

        const env = types.Envelope{
            .id = id,
            .in_reply_to = reply,
            .payload = .{ .protocol_error = .{
                .err = .{ .code = code, .message = owned_message },
                .protocol_versions = versions,
            } },
        };
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
            error.OutOfMemory => .resource_exhausted,
            envelope.DecodeError.VersionMismatch => .unsupported_version,
            envelope.DecodeError.CredentialInHeaders => .invalid_request,
            envelope.DecodeError.UnknownEnvelopeType => .invalid_request,
            envelope.DecodeError.ProfileMismatch, envelope.DecodeError.ProtocolMismatch => .protocol_violation,
            envelope.DecodeError.MissingField, envelope.DecodeError.InvalidField => .invalid_request,
            envelope.DecodeError.UnknownField => .invalid_request,
            envelope.DecodeError.CarryInReasoningOptions => .invalid_request,
            else => .protocol_violation,
        };
        const message = switch (err) {
            error.OutOfMemory => "the endpoint could not allocate to decode this envelope",
            envelope.DecodeError.CredentialInHeaders => "a credential must not travel in request headers; use provider.credential.grant.request",
            envelope.DecodeError.ProfileMismatch => "this endpoint serves open-agent-protocol 0.1 model-provider-core only",
            envelope.DecodeError.VersionMismatch => "unsupported protocol version",
            envelope.DecodeError.UnknownEnvelopeType => "unrecognized envelope type for this profile",
            envelope.DecodeError.UnknownField => "this payload carries a member the profile does not define",
            envelope.DecodeError.CarryInReasoningOptions => "a carry no longer rides reasoning options; put it on the reasoning or tool_call content part it belongs to",
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
            .inference_sync_request => try self.handleSync(env),
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

        const version_string = try self.allocator.dupe(u8, types.VERSION);
        errdefer self.allocator.free(version_string);
        const versions = try self.allocator.alloc([]const u8, 1);
        errdefer self.allocator.free(versions);
        versions[0] = version_string;

        const profile_revision = if (self.options.profile_revision) |value|
            try self.allocator.dupe(u8, value)
        else
            null;
        errdefer if (profile_revision) |value| self.allocator.free(value);

        const response = types.Envelope{
            .id = id,
            .in_reply_to = reply,
            .capability_revision = revision,
            .payload = .{ .provider_describe_response = .{
                .providers = descriptors,
                .protocol_versions = versions,
                .profile_revision = profile_revision,
            } },
        };
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

        const response = types.Envelope{
            .id = id,
            .in_reply_to = reply,
            .capability_revision = revision,
            .payload = .{ .provider_models_list_response = .{
                .models = entries,
            } },
        };
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

        if (self.options.grant_channel == .on_envelope) {
            try self.emitGrantRefusal(
                env,
                .unsupported_feature,
                "this implementation cannot yet honour a credential carried on the grant envelope",
            );
            return;
        }
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

        const response = types.Envelope{
            .id = id,
            .in_reply_to = reply,
            .payload = .{ .provider_credential_grant_response = .{
                .accepted = false,
                .err = .{ .code = code, .message = owned_message },
            } },
        };
        try self.push(response);
    }

    pub const ParsedModelRef = types.ParsedModelRef;

    pub fn parseModelRef(model_ref: []const u8) ?ParsedModelRef {
        return types.parseModelRef(model_ref);
    }

    fn messagesCarryPartialArguments(messages: []const oap_types.Message) bool {
        for (messages) |message| {
            const parts = switch (message.content) {
                .parts => |value| value,
                else => continue,
            };
            for (parts) |part| {
                if (part != .tool_call) continue;
                if (part.tool_call.arguments_partial != null) return true;
            }
        }
        return false;
    }

    fn requestAsksForReasoning(reasoning: ?types.ReasoningOptions) bool {
        const options = reasoning orelse return false;
        return options.enabled orelse false;
    }

    fn messagesReplayACarry(messages: []const oap_types.Message) bool {
        for (messages) |message| {
            const parts = switch (message.content) {
                .parts => |value| value,
                else => continue,
            };
            for (parts) |part| switch (part) {
                .reasoning => |value| if (value.carry != null) return true,
                .tool_call => |value| if (value.carry != null) return true,
                else => {},
            };
        }
        return false;
    }

    fn handleCreate(self: *Self, env: types.Envelope, create_request: types.CreateRequest) !void {
        const parsed = parseModelRef(create_request.model_ref) orelse {
            try self.emitCreateRefusal(env, .invalid_request, "model_ref must be provider_id/wire@model_id");
            return;
        };

        const descriptor = self.findProvider(parsed.provider_id) orelse {
            try self.emitCreateRefusal(env, .model_not_found, "no such provider");
            return;
        };

        if (descriptor.wire != parsed.wire) {
            try self.emitCreateRefusal(env, .invalid_request, "model_ref names a wire this provider does not speak");
            return;
        }

        const descriptor_wire_id = descriptor.wire_id;
        const refs_disagree = blk: {
            if (descriptor_wire_id == null and parsed.wire_id == null) break :blk false;
            if (descriptor_wire_id == null or parsed.wire_id == null) break :blk true;
            break :blk !std.mem.eql(u8, descriptor_wire_id.?, parsed.wire_id.?);
        };
        if (refs_disagree) {
            try self.emitCreateRefusal(env, .invalid_request, "model_ref names a wire this provider does not speak");
            return;
        }

        if (create_request.credential_ref) |reference| {
            switch (self.lookupGrant(reference)) {
                .live => {},
                .expired => {
                    try self.emitCreateRefusal(
                        env,
                        .credential_expired,
                        "the credential this reference names has passed the expiry it was granted with",
                    );
                    return;
                },
                .unknown => if (!descriptor.allows_anonymous) {
                    try self.emitCreateRefusal(env, .credential_missing, "credential_ref names no credential this implementation holds");
                    return;
                },
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

        if (create_request.tools.len > 0 and !self.modelDeclares(create_request.model_ref, .tools)) {
            try self.emitCreateRefusal(
                env,
                .unsupported_feature,
                "this model does not declare the tools capability",
            );
            return;
        }

        for (create_request.messages) |message| {
            if (messageCarriesUnforwardablePart(message)) {
                try self.emitCreateRefusal(
                    env,
                    .unsupported_feature,
                    "a reasoning or tool_call part belongs to an assistant message, a tool_result to a user or tool message, and a tool-role message must carry one",
                );
                return;
            }
        }

        if (create_request.output_schema_json != null) {
            try self.emitCreateRefusal(env, .unsupported_feature, "this endpoint does not forward a structured output schema");
            return;
        }

        if (create_request.reasoning != null) {
            if (!self.modelDeclares(create_request.model_ref, .reasoning)) {
                try self.emitCreateRefusal(
                    env,
                    .unsupported_feature,
                    "this model does not declare the reasoning capability",
                );
                return;
            }
        }

        if (messagesCarryPartialArguments(create_request.messages)) {
            try self.emitCreateRefusal(
                env,
                .invalid_request,
                "a replayed tool call must carry complete arguments_json; arguments_partial names a call still in flight",
            );
            return;
        }

        if (!descriptor.round_trips_carry and messagesReplayACarry(create_request.messages)) {
            try self.emitCreateRefusal(
                env,
                .unsupported_feature,
                "this provider does not round-trip a carry; see round_trips_carry on its descriptor",
            );
            return;
        }

        if (messagesReplayACarry(create_request.messages) and !requestAsksForReasoning(create_request.reasoning)) {
            try self.emitCreateRefusal(
                env,
                .invalid_request,
                "a replayed carry needs reasoning enabled on this request; the provider rejects signed history without it",
            );
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

        const credential_ref = if (create_request.credential_ref) |value|
            try self.allocator.dupe(u8, value)
        else
            null;
        errdefer if (credential_ref) |value| self.allocator.free(value);

        const tools = try cloneToolDefinitions(self.allocator, create_request.tools);
        errdefer {
            for (tools) |*tool| {
                var owned = tool.*;
                owned.deinit(self.allocator);
            }
            self.allocator.free(tools);
        }
        const tool_choice = try cloneToolChoice(self.allocator, create_request.tool_choice);
        errdefer if (tool_choice) |*value| {
            var owned = value.*;
            owned.deinit(self.allocator);
        };
        const reasoning = try cloneReasoning(self.allocator, create_request.reasoning);
        errdefer if (reasoning) |*value| {
            var owned = value.*;
            owned.deinit(self.allocator);
        };

        const queued = try self.allocator.dupe(u8, inference_id);
        errdefer self.allocator.free(queued);

        const line = blk: {
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
            break :blk try envelope.serializeEnvelope(response, self.allocator);
        };
        errdefer self.allocator.free(line);

        try self.active.ensureUnusedCapacity(self.allocator, 1);
        try self.pending_starts.ensureUnusedCapacity(self.allocator, 1);
        try self.outbound.ensureUnusedCapacity(self.allocator, 1);

        self.active.appendAssumeCapacity(.{
            .id = inference_id,
            .model_ref = model_ref,
            .messages = messages,
            .max_output_tokens = create_request.max_output_tokens,
            .temperature = create_request.temperature,
            .include_snapshot = honoured,
            .credential_ref = credential_ref,
            .tools = tools,
            .tool_choice = tool_choice,
            .reasoning = reasoning,
            .closed_parts = std.ArrayList(oap_types.ContentPart).empty,
            .text = std.ArrayList(u8).empty,
        });
        self.pending_starts.appendAssumeCapacity(queued);
        self.outbound.appendAssumeCapacity(line);
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

        const env = types.Envelope{
            .id = id,
            .inference_id = scope,
            .sequence = inference.next_sequence,
            .timestamp_ms = compat.time.nowMillis(),
            .payload = payload,
        };
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

        return try self.buildSnapshot(inference, !at_part_end);
    }

    fn buildSnapshot(
        self: *Self,
        inference: *ActiveInference,
        include_open_part: bool,
    ) !?[]oap_types.Message {
        var parts = std.ArrayList(oap_types.ContentPart).empty;
        errdefer {
            for (parts.items) |*part| part.deinit(self.allocator);
            parts.deinit(self.allocator);
        }

        for (inference.closed_parts.items) |part| {
            try parts.append(self.allocator, try clonePart(self.allocator, part));
        }

        if (include_open_part and inference.open_part != null) {
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
                    try parts.append(self.allocator, .{ .reasoning = .{ .text = owned } });
                },
                .tool_call => {
                    const id = try self.allocator.dupe(u8, inference.open_tool_call_id orelse "");
                    errdefer self.allocator.free(id);
                    const name = try self.allocator.dupe(u8, inference.open_tool_name orelse "");
                    errdefer self.allocator.free(name);
                    const empty = try self.allocator.dupe(u8, "");
                    errdefer self.allocator.free(empty);
                    const partial = try self.allocator.dupe(u8, accumulated);
                    errdefer self.allocator.free(partial);
                    try parts.append(self.allocator, .{ .tool_call = .{
                        .tool_call_id = id,
                        .name = name,
                        .arguments_json = empty,
                        .arguments_partial = partial,
                    } });
                },
            }
        }

        var content_transferred = false;
        const owned_parts = try parts.toOwnedSlice(self.allocator);
        errdefer if (!content_transferred) {
            for (owned_parts) |*part| part.deinit(self.allocator);
            self.allocator.free(owned_parts);
        };

        const empty_text = try self.allocator.dupe(u8, "");
        errdefer if (!content_transferred) self.allocator.free(empty_text);
        const messages = try self.allocator.alloc(oap_types.Message, 1);
        const content = contentFromParts(self.allocator, owned_parts, empty_text);
        content_transferred = true;
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

        const next_tool_call_id = if (tool_call_id) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (next_tool_call_id) |value| self.allocator.free(value);
        const next_tool_name = if (name) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (next_tool_name) |value| self.allocator.free(value);

        inference.open_part = part_index;
        inference.open_part_kind = part_kind;
        inference.text.clearRetainingCapacity();
        if (inference.open_tool_call_id) |value| self.allocator.free(value);
        if (inference.open_tool_name) |value| self.allocator.free(value);
        inference.open_tool_call_id = next_tool_call_id;
        inference.open_tool_name = next_tool_name;
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
        var closed_transferred = false;
        const closed_text = try self.allocator.dupe(u8, text);
        errdefer if (!closed_transferred) self.allocator.free(closed_text);
        const closed_carry = if (carry) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (!closed_transferred) {
            if (closed_carry) |value| self.allocator.free(value);
        };
        try inference.closed_parts.ensureUnusedCapacity(self.allocator, 1);
        inference.closed_parts.appendAssumeCapacity(switch (part_kind) {
            .reasoning => .{ .reasoning = .{ .text = closed_text, .carry = closed_carry } },
            else => .{ .text = closed_text },
        });
        closed_transferred = true;

        const snapshot = try self.snapshotIfDue(inference, true);
        errdefer if (snapshot) |messages| {
            for (messages) |*message| message.deinit(self.allocator);
            self.allocator.free(messages);
        };

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

        var closed_transferred = false;
        const closed_id = try self.allocator.dupe(u8, tool_call_id);
        errdefer if (!closed_transferred) self.allocator.free(closed_id);
        const closed_name = try self.allocator.dupe(u8, name);
        errdefer if (!closed_transferred) self.allocator.free(closed_name);
        const closed_arguments = try self.allocator.dupe(u8, arguments_json);
        errdefer if (!closed_transferred) self.allocator.free(closed_arguments);
        const closed_carry = if (carry) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (!closed_transferred) {
            if (closed_carry) |value| self.allocator.free(value);
        };
        try inference.closed_parts.ensureUnusedCapacity(self.allocator, 1);
        inference.closed_parts.appendAssumeCapacity(.{ .tool_call = .{
            .tool_call_id = closed_id,
            .name = closed_name,
            .arguments_json = closed_arguments,
            .carry = closed_carry,
        } });
        closed_transferred = true;

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
        var content_transferred = false;
        const empty_text = try self.allocator.dupe(u8, "");
        errdefer if (!content_transferred) self.allocator.free(empty_text);
        const owned_parts = try parts.toOwnedSlice(self.allocator);
        errdefer if (!content_transferred) {
            for (owned_parts) |*part| part.deinit(self.allocator);
            self.allocator.free(owned_parts);
        };
        const content = contentFromParts(self.allocator, owned_parts, empty_text);
        content_transferred = true;
        var content_settled = false;
        errdefer if (!content_settled) {
            var owned_content = content;
            owned_content.deinit(self.allocator);
        };

        inference.terminal_emitted = true;
        try self.pushScoped(inference, .{ .inference_completed = .{
            .message = .{ .role = .assistant, .content = content },
            .stop_reason = stop_reason,
            .usage = usage,
        } });
        content_settled = true;
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
                    const carry = if (thinking.thinking_signature) |value|
                        try self.allocator.dupe(u8, value)
                    else
                        null;
                    errdefer if (carry) |value| self.allocator.free(value);
                    try parts.append(self.allocator, .{ .reasoning = .{ .text = owned, .carry = carry } });
                },
                .tool_call => |call| {
                    const id = try self.allocator.dupe(u8, call.id);
                    errdefer self.allocator.free(id);
                    const name = try self.allocator.dupe(u8, call.name);
                    errdefer self.allocator.free(name);
                    const arguments = try self.allocator.dupe(u8, call.arguments_json);
                    errdefer self.allocator.free(arguments);
                    const carry = if (call.thought_signature) |value|
                        try self.allocator.dupe(u8, value)
                    else
                        null;
                    errdefer if (carry) |value| self.allocator.free(value);
                    try parts.append(self.allocator, .{ .tool_call = .{
                        .tool_call_id = id,
                        .name = name,
                        .arguments_json = arguments,
                        .carry = carry,
                    } });
                },
                .image => {},
            }
        }

        var content_transferred = false;
        const empty_text = try self.allocator.dupe(u8, "");
        errdefer if (!content_transferred) self.allocator.free(empty_text);
        const owned_parts = try parts.toOwnedSlice(self.allocator);
        errdefer if (!content_transferred) {
            for (owned_parts) |*part| part.deinit(self.allocator);
            self.allocator.free(owned_parts);
        };
        const result_content = contentFromParts(self.allocator, owned_parts, empty_text);
        content_transferred = true;
        var content_settled = false;
        errdefer if (!content_settled) {
            var owned_content = result_content;
            owned_content.deinit(self.allocator);
        };

        inference.terminal_emitted = true;
        try self.pushScoped(inference, .{ .inference_completed = .{
            .message = .{ .role = .assistant, .content = result_content },
            .stop_reason = stop_reason,
            .usage = usage,
        } });
        content_settled = true;
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

        const response = types.Envelope{
            .id = id,
            .in_reply_to = reply,
            .payload = .{ .inference_create_response = .{
                .accepted = false,
                .err = .{ .code = code, .message = owned_message },
            } },
        };
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

        const response = types.Envelope{
            .id = id,
            .in_reply_to = reply,
            .inference_id = owned_scope,
            .payload = .{ .inference_cancel_response = .{ .accepted = accepted } },
        };
        try self.push(response);
    }

    fn handleSync(self: *Self, env: types.Envelope) !void {
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
                    snapshot = try self.buildSnapshot(inference, true);
                }
            }
        }

        const scope_copy = if (env.inference_id) |value|
            try self.allocator.dupe(u8, value)
        else
            null;
        errdefer if (scope_copy) |value| self.allocator.free(value);

        const response = types.Envelope{
            .id = id,
            .in_reply_to = reply,
            .inference_id = scope_copy,
            .payload = .{ .inference_sync_response = .{ .snapshot = snapshot } },
        };
        try self.push(response);
    }
};

fn cloneToolDefinitions(
    allocator: std.mem.Allocator,
    source: []const types.ToolDefinition,
) ![]const types.ToolDefinition {
    const out = try allocator.alloc(types.ToolDefinition, source.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*tool| tool.deinit(allocator);
        allocator.free(out);
    }
    for (source, 0..) |tool, index| {
        const name = try allocator.dupe(u8, tool.name);
        errdefer allocator.free(name);
        const description = if (tool.description) |value| try allocator.dupe(u8, value) else null;
        errdefer if (description) |value| allocator.free(value);
        const schema = if (tool.input_schema_json) |value| try allocator.dupe(u8, value) else null;
        out[index] = .{ .name = name, .description = description, .input_schema_json = schema };
        built += 1;
    }
    return out;
}

fn cloneToolChoice(allocator: std.mem.Allocator, source: ?types.ToolChoice) !?types.ToolChoice {
    const choice = source orelse return null;
    return switch (choice) {
        .function => |name| types.ToolChoice{ .function = try allocator.dupe(u8, name) },
        .auto => types.ToolChoice.auto,
        .none => types.ToolChoice.none,
        .required => types.ToolChoice.required,
    };
}

fn cloneReasoning(allocator: std.mem.Allocator, source: ?types.ReasoningOptions) !?types.ReasoningOptions {
    const options = source orelse return null;
    const effort = if (options.effort) |value| try allocator.dupe(u8, value) else null;
    errdefer if (effort) |value| allocator.free(value);
    return .{
        .enabled = options.enabled,
        .budget_tokens = options.budget_tokens,
        .effort = effort,
    };
}

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
        .round_trips_carry = descriptor.round_trips_carry,
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

fn messageCarriesUnforwardablePart(message: oap_types.Message) bool {
    return switch (message.content) {
        .text => message.role == .tool,
        .parts => |parts| blk: {
            var carries_result = false;
            for (parts) |part| {
                switch (part) {
                    .text => {},
                    .reasoning, .tool_call => if (message.role != .assistant) break :blk true,
                    .tool_result => {
                        if (message.role != .user and message.role != .tool) break :blk true;
                        carries_result = true;
                    },
                }
            }
            break :blk message.role == .tool and !carries_result;
        },
    };
}

fn contentFromParts(
    allocator: std.mem.Allocator,
    parts: []oap_types.ContentPart,
    empty_text: []const u8,
) oap_types.Content {
    if (parts.len > 0) {
        allocator.free(empty_text);
        return .{ .parts = parts };
    }
    allocator.free(parts);
    return .{ .text = empty_text };
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
        .reasoning => |value| blk: {
            const text = try allocator.dupe(u8, value.text);
            errdefer allocator.free(text);
            const carry = if (value.carry) |raw| try allocator.dupe(u8, raw) else null;
            break :blk .{ .reasoning = .{ .text = text, .carry = carry } };
        },
        .tool_call => |call| blk: {
            const id = try allocator.dupe(u8, call.tool_call_id);
            errdefer allocator.free(id);
            const name = try allocator.dupe(u8, call.name);
            errdefer allocator.free(name);
            const arguments = try allocator.dupe(u8, call.arguments_json);
            errdefer allocator.free(arguments);
            const carry = if (call.carry) |raw| try allocator.dupe(u8, raw) else null;
            break :blk .{ .tool_call = .{
                .tool_call_id = id,
                .name = name,
                .arguments_json = arguments,
                .carry = carry,
            } };
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

    var provider_transferred = false;
    const provider_id = try allocator.dupe(u8, "ollama-local");
    errdefer if (!provider_transferred) allocator.free(provider_id);
    const endpoint = try allocator.dupe(u8, "http://127.0.0.1:11434");
    errdefer if (!provider_transferred) allocator.free(endpoint);
    const policies = try allocator.dupe(types.SnapshotPolicy, &.{ .never, .on_part_end });
    errdefer if (!provider_transferred) allocator.free(policies);

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
    provider_transferred = true;

    var model_transferred = false;
    const model_ref = try allocator.dupe(u8, "ollama-local/openai-chat-completions@gemma");
    errdefer if (!model_transferred) allocator.free(model_ref);
    const model_id = try allocator.dupe(u8, "gemma");
    errdefer if (!model_transferred) allocator.free(model_id);
    const model_provider_id = try allocator.dupe(u8, "ollama-local");
    errdefer if (!model_transferred) allocator.free(model_provider_id);
    const capabilities = try allocator.dupe(types.ModelCapability, &.{ .chat, .streaming });
    errdefer if (!model_transferred) allocator.free(capabilities);

    try server.addModel(.{
        .model_ref = model_ref,
        .model_id = model_id,
        .provider_id = model_provider_id,
        .wire = .@"openai-chat-completions",
        .capabilities = capabilities,
        .source = .discovered,
        .auth_status = .authenticated,
    });
    model_transferred = true;

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
    while (server.popOutbound()) |outbound| allocator.free(outbound);

    try std.testing.expectEqual(@as(usize, 1), server.grants.items.len);
    try std.testing.expect(server.grants.items[0].non_persistable);
    try std.testing.expect(server.grants.items[0].expires_at_ms != null);
    try std.testing.expect(server.findGrant(reference) != null);

    server.releaseGrants();
    try std.testing.expectEqual(@as(usize, 0), server.grants.items.len);
    try std.testing.expect(server.findGrant(reference) == null);
}
test "the envelope-carrying tier is refused rather than accepting a secret it cannot honour" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .grant_channel = .on_envelope });
    defer server.deinit();

    const with_value = try makeRequest(
        allocator,
        "provider.credential.grant.request",
        "{\"provider_id\":\"ollama-local\",\"nonce\":\"n1\",\"value\":\"sk-secret\"}",
        "q1",
    );
    defer allocator.free(with_value);
    try server.handleLine(with_value);

    var response = try decodeOnly(allocator, &server);
    defer response.deinit(allocator);
    try std.testing.expect(!response.payload.provider_credential_grant_response.accepted);
    try std.testing.expectEqual(
        types.ErrorCode.unsupported_feature,
        response.payload.provider_credential_grant_response.err.?.code,
    );
    try std.testing.expectEqual(@as(usize, 0), server.grants.items.len);
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

test "a grant past its stated expiry is refused with the actionable code and burned" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .grant_channel = .out_of_band, .default_grant_ttl_ms = 0 });
    defer server.deinit();

    try server.addProvider(.{
        .id = try allocator.dupe(u8, "acme"),
        .wire = .@"anthropic-messages",
        .framing = .sse,
        .endpoint = try allocator.dupe(u8, "https://acme.test"),
        .allows_anonymous = false,
    });

    const grant_line = try makeRequest(
        allocator,
        "provider.credential.grant.request",
        "{\"provider_id\":\"acme\",\"nonce\":\"n1\"}",
        "q1",
    );
    defer allocator.free(grant_line);
    try server.handleLine(grant_line);
    try server.announceChannel("n1", "/tmp/grant-expiry.sock");

    const reference = try server.completeGrant("n1");
    defer allocator.free(reference);
    while (server.popOutbound()) |outbound| allocator.free(outbound);
    try std.testing.expectEqual(@as(usize, 1), server.grants.items.len);

    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"model_ref\":\"acme/anthropic-messages@m\",\"messages\":[],\"credential_ref\":\"{s}\"}}",
        .{reference},
    );
    defer allocator.free(payload);
    const create_line = try makeRequest(allocator, "inference.create.request", payload, "q2");
    defer allocator.free(create_line);
    try server.handleLine(create_line);

    var refusal = try decodeOnly(allocator, &server);
    defer refusal.deinit(allocator);
    try std.testing.expectEqual(
        types.ErrorCode.credential_expired,
        refusal.payload.inference_create_response.err.?.code,
    );
    try std.testing.expectEqual(
        types.ErrorAction.refresh,
        refusal.payload.inference_create_response.err.?.code.action(),
    );
    try std.testing.expect(!refusal.payload.inference_create_response.accepted);
    try std.testing.expect(refusal.inference_id == null);

    try std.testing.expectEqual(@as(usize, 0), server.grants.items.len);
    try std.testing.expect(server.findGrant(reference) == null);
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
        "\",\"type\":\"inference.create.response\",\"id\":\"m1\",\"inference_id\":\"inf1\"," ++
        "\"payload\":{\"accepted\":false,\"error\":{\"code\":\"invalid_request\",\"message\":\"no\"}}}";
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

test "a part-end snapshot holds the closed reasoning part once, with its carry" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    const inference_id = try acceptOne(allocator, &server, "on_part_end");
    defer allocator.free(inference_id);
    while (server.popOutbound()) |line| allocator.free(line);

    try server.notePartStarted(inference_id, 0, .reasoning, null, null);
    try server.notePartDelta(inference_id, 0, "weighing");
    while (server.popOutbound()) |line| allocator.free(line);
    try server.notePartEndedTextWithCarry(inference_id, 0, .reasoning, "weighing", "REASON-SIG");

    var ended = try decodeOnly(allocator, &server);
    defer ended.deinit(allocator);
    const snapshot = ended.payload.inference_part_ended.snapshot orelse return error.TestExpectedSnapshot;
    const parts = snapshot[0].content.parts;
    try std.testing.expectEqual(@as(usize, 1), parts.len);
    try std.testing.expectEqualStrings("weighing", parts[0].reasoning.text);
    try std.testing.expectEqualStrings("REASON-SIG", parts[0].reasoning.carry orelse "");
}

test "a tool call keeps its carry through the snapshot and the terminal" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    const inference_id = try acceptOne(allocator, &server, "on_part_end");
    defer allocator.free(inference_id);
    while (server.popOutbound()) |line| allocator.free(line);

    try server.notePartStarted(inference_id, 0, .tool_call, "c1", "search");
    while (server.popOutbound()) |line| allocator.free(line);
    try server.notePartEndedToolCall(inference_id, 0, "c1", "search", "{}", "TOOL-SIG");

    var ended = try decodeOnly(allocator, &server);
    defer ended.deinit(allocator);
    const part_ended = ended.payload.inference_part_ended;
    try std.testing.expectEqualStrings("TOOL-SIG", part_ended.carry orelse "");

    const snapshot = part_ended.snapshot orelse return error.TestExpectedSnapshot;
    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    const snapshot_parts = snapshot[0].content.parts;
    try std.testing.expectEqual(@as(usize, 1), snapshot_parts.len);
    try std.testing.expectEqualStrings("TOOL-SIG", snapshot_parts[0].tool_call.carry orelse "");
    try std.testing.expect(snapshot_parts[0].tool_call.arguments_partial == null);
}

test "a replayed tool call with partial arguments is refused rather than forwarded empty" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    const payload =
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_call\",\"tool_call_id\":\"c1\",\"name\":\"search\",\"arguments_partial\":\"{\\\"q\\\":\"}]}]}";
    const line = try makeRequest(allocator, "inference.create.request", payload, "q1");
    defer allocator.free(line);
    try server.handleLine(line);

    var refusal = try decodeOnly(allocator, &server);
    defer refusal.deinit(allocator);
    try std.testing.expectEqual(
        types.ErrorCode.invalid_request,
        refusal.payload.inference_create_response.err.?.code,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        refusal.payload.inference_create_response.err.?.message,
        "arguments_partial",
    ) != null);
}

test "a tool-role message that carries no tool result is refused rather than rewritten as a user turn" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    const cases = [_][]const u8{
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[{\"role\":\"tool\",\"content\":\"bare text\"}]}",
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[{\"role\":\"tool\",\"content\":[{\"type\":\"text\",\"text\":\"bare text\"}]}]}",
    };

    for (cases) |payload| {
        const line = try makeRequest(allocator, "inference.create.request", payload, "q1");
        defer allocator.free(line);
        try server.handleLine(line);

        var refusal = try decodeOnly(allocator, &server);
        defer refusal.deinit(allocator);
        try std.testing.expectEqual(
            types.ErrorCode.unsupported_feature,
            refusal.payload.inference_create_response.err.?.code,
        );
        try std.testing.expect(!refusal.payload.inference_create_response.accepted);
    }
}

test "a carry-bearing part on a non-assistant message is refused rather than dropped" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    const payload =
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"reasoning\",\"reasoning\":\"prior\",\"carry\":\"REASON-SIG\"}]}]}";
    const line = try makeRequest(allocator, "inference.create.request", payload, "q1");
    defer allocator.free(line);
    try server.handleLine(line);

    var refusal = try decodeOnly(allocator, &server);
    defer refusal.deinit(allocator);
    try std.testing.expectEqual(
        types.ErrorCode.unsupported_feature,
        refusal.payload.inference_create_response.err.?.code,
    );
    try std.testing.expect(!refusal.payload.inference_create_response.accepted);
    try std.testing.expect(std.mem.indexOf(
        u8,
        refusal.payload.inference_create_response.err.?.message,
        "belongs to an assistant message",
    ) != null);
}

test "a tool result on a system or developer message is refused rather than demoting the instruction to a user turn" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    const roles = [_][]const u8{ "system", "developer" };
    for (roles) |role| {
        const payload = try std.fmt.allocPrint(
            allocator,
            "{{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[{{\"role\":\"{s}\"," ++
                "\"content\":[{{\"type\":\"text\",\"text\":\"always answer in french\"}}," ++
                "{{\"type\":\"tool_result\",\"tool_call_id\":\"c1\",\"result\":{{}}}}]}}]}}",
            .{role},
        );
        defer allocator.free(payload);

        const line = try makeRequest(allocator, "inference.create.request", payload, "q1");
        defer allocator.free(line);
        try server.handleLine(line);

        var refusal = try decodeOnly(allocator, &server);
        defer refusal.deinit(allocator);
        try std.testing.expect(!refusal.payload.inference_create_response.accepted);
        try std.testing.expectEqual(
            types.ErrorCode.unsupported_feature,
            refusal.payload.inference_create_response.err.?.code,
        );
        try std.testing.expect(std.mem.indexOf(
            u8,
            refusal.payload.inference_create_response.err.?.message,
            "a tool_result to a user or tool message",
        ) != null);
    }

    const user_carried =
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[{\"role\":\"user\"," ++
        "\"content\":[{\"type\":\"text\",\"text\":\"and here is what it said\"}," ++
        "{\"type\":\"tool_result\",\"tool_call_id\":\"c1\",\"result\":{}}]}]}";
    const accepted_line = try makeRequest(allocator, "inference.create.request", user_carried, "q2");
    defer allocator.free(accepted_line);
    try server.handleLine(accepted_line);

    var accepted = try decodeOnly(allocator, &server);
    defer accepted.deinit(allocator);
    try std.testing.expect(accepted.payload.inference_create_response.accepted);
}

test "the terminal assembly repeats the carry each part ended with" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    const inference_id = try acceptOne(allocator, &server, "never");
    defer allocator.free(inference_id);
    while (server.popOutbound()) |line| allocator.free(line);

    const content = [_]ai_content.AssistantContent{
        .{ .thinking = .{ .thinking = "weighing", .thinking_signature = "sig-reasoning" } },
        .{ .tool_call = .{
            .id = "call_1",
            .name = "search",
            .arguments_json = "{}",
            .thought_signature = "sig-toolcall",
        } },
        .{ .text = .{ .text = "answer" } },
    };

    try server.settleCompletedFromResult(inference_id, .tool_use, null, &content);

    var terminal = try decodeOnly(allocator, &server);
    defer terminal.deinit(allocator);

    const parts = terminal.payload.inference_completed.message.content.parts;
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("sig-reasoning", parts[0].reasoning.carry orelse "");
    try std.testing.expectEqualStrings("sig-toolcall", parts[1].tool_call.carry orelse "");
    try std.testing.expect(parts[2] == .text);
}

test "a carry sent as a reasoning option is refused and told where the carry moved" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    const payload =
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[]," ++
        "\"reasoning\":{\"enabled\":true,\"encrypted_carry\":\"prior\"}}";
    const line = try makeRequest(allocator, "inference.create.request", payload, "q1");
    defer allocator.free(line);
    try server.handleLine(line);

    var refusal = try decodeOnly(allocator, &server);
    defer refusal.deinit(allocator);
    try std.testing.expect(refusal.payload == .protocol_error);
    try std.testing.expectEqual(
        types.ErrorCode.invalid_request,
        refusal.payload.protocol_error.err.code,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        refusal.payload.protocol_error.err.message,
        "reasoning or tool_call content part",
    ) != null);

    const without_carry =
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[]," ++
        "\"reasoning\":{\"enabled\":true,\"budget_tokens\":2048,\"effort\":\"high\"}}";
    const accepted_line = try makeRequest(allocator, "inference.create.request", without_carry, "q2");
    defer allocator.free(accepted_line);
    try server.handleLine(accepted_line);

    var answer = try decodeOnly(allocator, &server);
    defer answer.deinit(allocator);
    try std.testing.expect(answer.payload == .inference_create_response);
}

test "a replayed carry is refused by a provider whose descriptor does not claim the round trip" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    for (server.providers.items) |descriptor| {
        try std.testing.expect(!descriptor.round_trips_carry);
    }

    const cases = [_][]const u8{
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[{\"role\":\"assistant\",\"content\":[{\"type\":\"reasoning\",\"reasoning\":\"prior\",\"carry\":\"sig\"}]}]}",
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_call\",\"tool_call_id\":\"c1\",\"name\":\"search\",\"arguments_json\":\"{}\",\"carry\":\"sig\"}]}]}",
    };

    for (cases) |payload| {
        const line = try makeRequest(allocator, "inference.create.request", payload, "q1");
        defer allocator.free(line);
        try server.handleLine(line);

        var refusal = try decodeOnly(allocator, &server);
        defer refusal.deinit(allocator);
        try std.testing.expectEqual(
            types.ErrorCode.unsupported_feature,
            refusal.payload.inference_create_response.err.?.code,
        );
        try std.testing.expect(!refusal.payload.inference_create_response.accepted);
        try std.testing.expect(refusal.inference_id == null);
    }
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

test "an inference that fails mid-stream numbers its frames the same way a completed one does" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    const inference_id = try acceptOne(allocator, &server, "never");
    defer allocator.free(inference_id);

    try server.noteStarted(inference_id);
    try server.notePartStarted(inference_id, 0, .text, null, null);
    try server.notePartDelta(inference_id, 0, "partial");
    server.abandonOpenPart(inference_id);
    try server.settleFailed(inference_id, .provider_unavailable, "upstream went away", null);

    var expected_sequence: u64 = 1;
    var terminals: usize = 0;
    while (server.popOutbound()) |line| {
        defer allocator.free(line);
        var env = try envelope.deserializeEnvelope(line, allocator);
        defer env.deinit(allocator);

        try std.testing.expectEqualStrings(inference_id, env.inference_id.?);
        try std.testing.expectEqual(expected_sequence, env.sequence.?);
        expected_sequence += 1;
        if (env.payload == .inference_failed) terminals += 1;
    }

    try std.testing.expectEqual(@as(u64, 5), expected_sequence);
    try std.testing.expectEqual(@as(usize, 1), terminals);
}

test "a refused create consumes no inference sequence because it opens no inference" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    const bad = try makeRequest(
        allocator,
        "inference.create.request",
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[],\"top_p\":0.9}",
        "q1",
    );
    defer allocator.free(bad);
    try server.handleLine(bad);

    var refusal = try decodeOnly(allocator, &server);
    defer refusal.deinit(allocator);
    try std.testing.expect(!refusal.payload.inference_create_response.accepted);
    try std.testing.expect(refusal.inference_id == null);
    try std.testing.expect(refusal.sequence == null);

    const inference_id = try acceptOne(allocator, &server, "never");
    defer allocator.free(inference_id);
    try server.noteStarted(inference_id);

    var started = try decodeOnly(allocator, &server);
    defer started.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 1), started.sequence.?);
}

fn emitSpecimensUnderFailure(allocator: std.mem.Allocator) !void {
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();
    try server.emitSpecimens("s1");
}

test "a specimen run frees nothing twice and leaks nothing under allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        emitSpecimensUnderFailure,
        .{},
    );
}

test "a specimen run emits every type it announced, bracketed, and nothing it excluded" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    try server.emitSpecimens("s1");

    var lines = std.ArrayList([]const u8).empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }
    while (server.popOutbound()) |line| try lines.append(allocator, line);

    try std.testing.expectEqual(Server.SPECIMEN_TYPES.len + 2, lines.items.len);

    var first = try std.json.parseFromSlice(std.json.Value, allocator, lines.items[0], .{});
    defer first.deinit();
    try std.testing.expectEqualStrings("specimen.accepted", first.value.object.get("control").?.string);
    try std.testing.expectEqualStrings("s1", first.value.object.get("in_reply_to").?.string);
    const announced = first.value.object.get("types").?.array;
    try std.testing.expectEqual(Server.SPECIMEN_TYPES.len, announced.items.len);
    try std.testing.expectEqual(Server.SPECIMEN_EXCLUDED.len, first.value.object.get("excluded").?.array.items.len);

    var last = try std.json.parseFromSlice(std.json.Value, allocator, lines.items[lines.items.len - 1], .{});
    defer last.deinit();
    try std.testing.expectEqualStrings("specimen.complete", last.value.object.get("control").?.string);

    for (lines.items[1 .. lines.items.len - 1], 0..) |line, index| {
        var env = try envelope.deserializeEnvelope(line, allocator);
        defer env.deinit(allocator);
        try std.testing.expectEqualStrings(announced.items[index].string, env.payload.typeName());
        try std.testing.expectEqualStrings(Server.SPECIMEN_TYPES[index], env.payload.typeName());
        if (env.inference_id) |scope| {
            try std.testing.expectEqualStrings(Server.SPECIMEN_INFERENCE_ID, scope);
        }
        for (Server.SPECIMEN_EXCLUDED) |withheld| {
            try std.testing.expect(!std.mem.eql(u8, withheld, env.payload.typeName()));
        }
    }
}

test "a specimen inference id cannot be produced by the real id generator" {
    for (Server.SPECIMEN_INFERENCE_ID) |byte| {
        const is_hex = (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f');
        if (!is_hex) return;
    }
    return error.SpecimenIdIsHexAndCouldCollide;
}

test "specimens are refused while an inference is running rather than interleaved" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    const inference_id = try acceptOne(allocator, &server, "never");
    defer allocator.free(inference_id);
    while (server.popOutbound()) |line| allocator.free(line);

    try server.emitSpecimens("s1");

    const line = server.popOutbound() orelse return error.TestExpectedOutbound;
    defer allocator.free(line);
    try std.testing.expect(server.popOutbound() == null);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("specimen.error", parsed.value.object.get("control").?.string);
    try std.testing.expectEqualStrings("s1", parsed.value.object.get("in_reply_to").?.string);
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
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[],\"output_schema\":{\"type\":\"object\"}}",
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[],\"top_p\":0.9}",
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[],\"stream\":false}",
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[],\"headers\":{\"X-Tenant\":\"acme\"}}",
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[{\"role\":\"tool\",\"content\":\"bare result with no call id\"}]}",
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

test "describe advertises the carry round trip a provider is configured with" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{});
    defer server.deinit();

    const id = try allocator.dupe(u8, "carrier");
    errdefer allocator.free(id);
    const endpoint = try allocator.dupe(u8, "https://carrier.test");
    errdefer allocator.free(endpoint);
    try server.addProvider(.{
        .id = id,
        .wire = .@"anthropic-messages",
        .framing = .sse,
        .endpoint = endpoint,
        .round_trips_carry = true,
    });

    const line = try makeRequest(allocator, "provider.describe.request", "{}", "q1");
    defer allocator.free(line);
    try server.handleLine(line);

    var response = try decodeOnly(allocator, &server);
    defer response.deinit(allocator);

    const providers = response.payload.provider_describe_response.providers;
    var found = false;
    for (providers) |descriptor| {
        if (!std.mem.eql(u8, descriptor.id, "carrier")) continue;
        found = true;
        try std.testing.expect(descriptor.round_trips_carry);
    }
    try std.testing.expect(found);
}

test "an emission path frees each allocation exactly once when one fails" {
    const head = "{\"protocol\":\"open-agent-protocol\",\"version\":\"0.1\",\"profile\":\"" ++ types.PROFILE ++ "\",";
    const lines = [_][]const u8{
        head ++ "\"type\":\"provider.describe.request\",\"id\":\"q1\",\"payload\":{}}",
        head ++ "\"type\":\"provider.models.list.request\",\"id\":\"q2\",\"payload\":{}}",
        head ++ "\"type\":\"inference.sync.request\",\"id\":\"q3\",\"inference_id\":\"none\",\"payload\":{}}",
        head ++ "\"type\":\"inference.cancel.request\",\"id\":\"q4\",\"inference_id\":\"none\",\"payload\":{}}",
        head ++ "\"type\":\"provider.credential.grant.request\",\"id\":\"q5\",\"payload\":{\"provider_id\":\"p1\",\"nonce\":\"n1\"}}",
        head ++ "\"type\":\"inference.create.request\",\"id\":\"q6\",\"payload\":{\"model_ref\":\"nope\",\"messages\":[]}}",
        head ++ "\"type\":\"nonsense\",\"id\":\"q7\",\"payload\":{}}",
    };

    var index: usize = 0;
    while (index < 300) : (index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = index });
        const allocator = failing.allocator();

        var server = Server.init(allocator, .{});
        defer server.deinit();

        const id = allocator.dupe(u8, "p1") catch continue;
        const endpoint = allocator.dupe(u8, "https://p.test") catch {
            allocator.free(id);
            continue;
        };
        server.addProvider(.{
            .id = id,
            .wire = .@"anthropic-messages",
            .framing = .sse,
            .endpoint = endpoint,
        }) catch {
            allocator.free(id);
            allocator.free(endpoint);
            continue;
        };

        for (lines) |line| server.handleLine(line) catch {};
        while (server.popOutbound()) |out| allocator.free(out);
    }
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

test "a model ref is validated whole at create, not one segment of it" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    const malformed = [_][]const u8{
        "ollama-local/openai-chat-completions",
        "ollama-local/@gemma",
        "ollama-local/openai-chat-completions@",
        "/openai-chat-completions@gemma",
        "ollama-local/not-a-wire@gemma",
        "ollama-local/openai-chat-completions:bolted-on@gemma",
    };

    for (malformed) |model_ref| {
        const payload = try std.fmt.allocPrint(
            allocator,
            "{{\"model_ref\":\"{s}\",\"messages\":[]}}",
            .{model_ref},
        );
        defer allocator.free(payload);
        const line = try makeRequest(allocator, "inference.create.request", payload, "q1");
        defer allocator.free(line);
        try server.handleLine(line);

        var response = try decodeOnly(allocator, &server);
        defer response.deinit(allocator);
        try std.testing.expect(!response.payload.inference_create_response.accepted);
        try std.testing.expectEqual(
            types.ErrorCode.invalid_request,
            response.payload.inference_create_response.err.?.code,
        );
    }

    try std.testing.expectEqual(@as(usize, 0), server.active.items.len);
}

test "a ref naming a wire the provider does not speak is refused before anything is spent" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    const wrong_wire = try makeRequest(
        allocator,
        "inference.create.request",
        "{\"model_ref\":\"ollama-local/openai-responses@gemma\",\"messages\":[]}",
        "q1",
    );
    defer allocator.free(wrong_wire);
    try server.handleLine(wrong_wire);

    var refusal = try decodeOnly(allocator, &server);
    defer refusal.deinit(allocator);
    try std.testing.expect(!refusal.payload.inference_create_response.accepted);
    try std.testing.expectEqual(@as(usize, 0), server.active.items.len);

    const right_wire = try makeRequest(
        allocator,
        "inference.create.request",
        "{\"model_ref\":\"ollama-local/openai-chat-completions@gemma\",\"messages\":[]}",
        "q2",
    );
    defer allocator.free(right_wire);
    try server.handleLine(right_wire);

    var accepted = try decodeOnly(allocator, &server);
    defer accepted.deinit(allocator);
    try std.testing.expect(accepted.payload.inference_create_response.accepted);
}

test "an unnamed wire must carry the discriminator the descriptor published" {
    const allocator = std.testing.allocator;
    var server = try testServer(allocator, .{ .accepts_inference = true });
    defer server.deinit();

    const provider_id = try allocator.dupe(u8, "vendor");
    errdefer allocator.free(provider_id);
    const wire_id = try allocator.dupe(u8, "vendor-chat");
    errdefer allocator.free(wire_id);
    const endpoint = try allocator.dupe(u8, "https://vendor.test");
    errdefer allocator.free(endpoint);

    try server.addProvider(.{
        .id = provider_id,
        .wire = .other,
        .wire_id = wire_id,
        .framing = .ndjson,
        .endpoint = endpoint,
        .allows_anonymous = true,
    });

    const cases = [_]struct { ref: []const u8, accepted: bool }{
        .{ .ref = "vendor/other:vendor-chat@m", .accepted = true },
        .{ .ref = "vendor/other:something-else@m", .accepted = false },
        .{ .ref = "vendor/other@m", .accepted = false },
    };

    for (cases) |case| {
        const payload = try std.fmt.allocPrint(allocator, "{{\"model_ref\":\"{s}\",\"messages\":[]}}", .{case.ref});
        defer allocator.free(payload);
        const line = try makeRequest(allocator, "inference.create.request", payload, "q1");
        defer allocator.free(line);
        try server.handleLine(line);

        var response = try decodeOnly(allocator, &server);
        defer response.deinit(allocator);
        try std.testing.expectEqual(case.accepted, response.payload.inference_create_response.accepted);
    }
}
