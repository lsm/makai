const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat");
const ai_types = @import("ai_types");
const oauth_storage = @import("oauth/storage");
const codex_oauth = @import("oauth/openai_codex");

const openai_codex_provider_id = "openai-codex";
const openai_codex_api_id = "openai-codex-responses";
const openai_codex_base_url = "https://chatgpt.com/backend-api/codex";
const kimi_provider_id = "kimi";
const kimi_api_id = "openai-completions";
const kimi_model_id = "kimi-k2.7-code";
const kimi_base_url = "https://api.kimi.com/coding/";
const kimi_global_base_url = "https://api.moonshot.ai/";
const codex_models_cache_name = "models_cache.json";
const makai_catalog_dir_name = "model_catalog";
const makai_codex_catalog_name = "openai-codex.json";
const max_catalog_bytes = 2 * 1024 * 1024;
const default_codex_client_version = "0.0.0";
const default_max_output_tokens: u32 = 16_384;

const CodexParseOptions = struct {
    account_id: ?[]const u8 = null,
    client_version: ?[]const u8 = null,
};

const CatalogLoadMode = enum {
    allow_cache,
    force_fetch,
};

fn secureFree(allocator: std.mem.Allocator, data: []const u8) void {
    if (data.len > 0) {
        const writable: []u8 = @constCast(data);
        std.crypto.secureZero(u8, writable);
    }
    allocator.free(data);
}

fn emptyModels(allocator: std.mem.Allocator) ![]ai_types.Model {
    return allocator.alloc(ai_types.Model, 0);
}

pub fn deinitModels(allocator: std.mem.Allocator, models: []ai_types.Model) void {
    for (models) |*model| model.deinit(allocator);
    allocator.free(models);
}

pub fn loadProductionModels(allocator: std.mem.Allocator) ![]ai_types.Model {
    var codex_models = try loadOpenAICodexModels(allocator, .allow_cache);
    errdefer deinitModels(allocator, codex_models);

    const kimi_models = try loadKimiModels(allocator);
    defer allocator.free(kimi_models);
    errdefer for (kimi_models) |*model| model.deinit(allocator);

    if (kimi_models.len == 0) return codex_models;

    var models = try allocator.alloc(ai_types.Model, codex_models.len + kimi_models.len);
    @memcpy(models[0..codex_models.len], codex_models);
    @memcpy(models[codex_models.len..], kimi_models);
    allocator.free(codex_models);
    codex_models = &.{};
    return models;
}

pub fn refreshProductionModels(allocator: std.mem.Allocator) ![]ai_types.Model {
    var codex_models = try loadOpenAICodexModels(allocator, .force_fetch);
    errdefer deinitModels(allocator, codex_models);

    const kimi_models = try loadKimiModels(allocator);
    defer allocator.free(kimi_models);
    errdefer for (kimi_models) |*model| model.deinit(allocator);

    if (kimi_models.len == 0) return codex_models;

    var models = try allocator.alloc(ai_types.Model, codex_models.len + kimi_models.len);
    @memcpy(models[0..codex_models.len], codex_models);
    @memcpy(models[codex_models.len..], kimi_models);
    allocator.free(codex_models);
    codex_models = &.{};
    return models;
}

/// Public entry point that loads ONLY Kimi models (no network fetch). Used by
/// the non-interactive `-p` print mode to avoid the OpenAI Codex catalog fetch
/// (which can block on the network and masks Kimi-specific streaming bugs).
pub fn loadKimiModelsPublic(allocator: std.mem.Allocator) ![]ai_types.Model {
    return loadKimiModels(allocator);
}

fn loadKimiModels(allocator: std.mem.Allocator) ![]ai_types.Model {
    var region: []const u8 = "china"; // Default to China region
    if (!builtin.is_test) {
        var storage = oauth_storage.AuthStorage.loadDefaultStoredOnly(allocator) catch return emptyModels(allocator);
        defer storage.deinit();
        if (!storage.providers.contains(kimi_provider_id)) return emptyModels(allocator);

        // Extract region from stored credentials
        if (storage.providers.get(kimi_provider_id)) |auth| {
            if (auth == .oauth) {
                if (auth.oauth.provider_data) |provider_data| {
                    if (std.mem.startsWith(u8, provider_data, "region:")) {
                        region = provider_data[7..]; // Skip "region:" prefix
                    }
                }
            }
        }

        if (kimiRegionFromEnv(allocator)) |env_region| {
            region = env_region;
        }
    }

    const models = try allocator.alloc(ai_types.Model, 1);
    errdefer allocator.free(models);
    models[0] = try kimiModel(allocator, region);
    return models;
}

var test_force_kimi_model: bool = false;

fn normalizeKimiRegion(value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "global") or std.ascii.eqlIgnoreCase(trimmed, "moonshot")) return "global";
    if (std.ascii.eqlIgnoreCase(trimmed, "china") or
        std.ascii.eqlIgnoreCase(trimmed, "cn") or
        std.ascii.eqlIgnoreCase(trimmed, "coding"))
    {
        return "china";
    }
    return null;
}

fn kimiRegionFromEnv(allocator: std.mem.Allocator) ?[]const u8 {
    const env_region = compat.getEnvVarOwned(allocator, "KIMI_REGION") catch return null;
    defer allocator.free(env_region);
    return normalizeKimiRegion(env_region);
}

fn kimiModel(allocator: std.mem.Allocator, region: []const u8) !ai_types.Model {
    const id = try allocator.dupe(u8, kimi_model_id);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, "Kimi K2.7 Code");
    errdefer allocator.free(name);
    const use_global = std.mem.eql(u8, region, "global");
    const api = try allocator.dupe(u8, kimi_api_id);
    errdefer allocator.free(api);
    const provider = try allocator.dupe(u8, kimi_provider_id);
    errdefer allocator.free(provider);

    // Select base_url based on region (OpenAI-compatible endpoints)
    // openai-completions appends /v1/chat/completions
    const base_url_str = if (use_global)
        kimi_global_base_url
    else
        "https://api.kimi.com/coding/";
    const base_url = try allocator.dupe(u8, base_url_str);
    errdefer allocator.free(base_url);

    const input = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(input);
    input[0] = try allocator.dupe(u8, "text");
    errdefer allocator.free(input[0]);

    return .{
        .id = id,
        .name = name,
        .api = api,
        .provider = provider,
        .base_url = base_url,
        .reasoning = false,
        .input = input,
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 262_144,
        .max_tokens = 16_384,
        .is_owned = true,
    };
}

fn refreshOpenAICodexCredentials(credentials: oauth_storage.Credentials, allocator: std.mem.Allocator) !oauth_storage.Credentials {
    const refreshed = try codex_oauth.refreshToken(.{
        .refresh = credentials.refresh,
        .access = credentials.access,
        .expires = credentials.expires,
        .provider_data = credentials.provider_data,
    }, allocator);
    errdefer {
        secureFree(allocator, refreshed.refresh);
        secureFree(allocator, refreshed.access);
    }

    const provider_data = refreshed.provider_data;
    errdefer if (provider_data) |data| secureFree(allocator, data);

    return .{
        .refresh = refreshed.refresh,
        .access = refreshed.access,
        .expires = refreshed.expires,
        .provider_data = provider_data,
    };
}

fn getOpenAICodexApiKey(credentials: oauth_storage.Credentials, allocator: std.mem.Allocator) ![]const u8 {
    return try codex_oauth.getApiKey(.{
        .refresh = credentials.refresh,
        .access = credentials.access,
        .expires = credentials.expires,
    }, allocator);
}

fn codexOAuthProvider() oauth_storage.OAuthProvider {
    return .{
        .id = openai_codex_provider_id,
        .name = "OpenAI Codex",
        .refresh_fn = refreshOpenAICodexCredentials,
        .get_api_key_fn = getOpenAICodexApiKey,
    };
}

fn loadOpenAICodexModels(allocator: std.mem.Allocator, mode: CatalogLoadMode) ![]ai_types.Model {
    if (builtin.is_test) return emptyModels(allocator);

    var storage = oauth_storage.AuthStorage.loadDefault(allocator) catch return emptyModels(allocator);
    defer storage.deinit();

    if (!storage.providers.contains(openai_codex_provider_id)) return emptyModels(allocator);

    const account_id = try codexAccountIdFromStorage(allocator, &storage);
    defer if (account_id) |id| allocator.free(id);

    if (mode == .allow_cache) {
        if (try loadCachedCodexModels(allocator, account_id)) |models| {
            if (models.len > 0) return models;
            allocator.free(models);
        }
    }

    const token = storage.getApiKey(openai_codex_provider_id, codexOAuthProvider()) catch null;
    if (token) |access_token| {
        defer secureFree(allocator, access_token);
        const client_version = try codexClientVersion(allocator);
        defer allocator.free(client_version);

        if (fetchCodexModelsCatalog(allocator, access_token, account_id, client_version)) |body| {
            defer allocator.free(body);
            saveMakaiCodexCatalog(allocator, body) catch {};
            return try parseCodexModelsCacheWithOptions(allocator, body, .{
                .account_id = account_id,
                .client_version = client_version,
            });
        } else |err| {
            if (mode == .force_fetch) {
                if (try loadCachedCodexModels(allocator, account_id)) |models| {
                    if (models.len > 0) return models;
                    allocator.free(models);
                }
                return err;
            }
        }
    }

    return emptyModels(allocator);
}

fn loadCachedCodexModels(allocator: std.mem.Allocator, account_id: ?[]const u8) !?[]ai_types.Model {
    const paths = [_]?[]u8{
        makaiCodexCatalogPath(allocator) catch null,
        codexModelsCachePath(allocator) catch null,
    };
    defer {
        for (paths) |maybe_path| {
            if (maybe_path) |path| allocator.free(path);
        }
    }

    for (paths) |maybe_path| {
        const path = maybe_path orelse continue;
        const data = compat.fs.readFileAlloc(allocator, compat.fs.getCwd(), path, max_catalog_bytes) catch continue;
        defer allocator.free(data);

        const models = parseCodexModelsCacheWithOptions(allocator, data, .{ .account_id = account_id }) catch continue;
        if (models.len > 0) return models;
        allocator.free(models);
    }

    return null;
}

fn codexHomePath(allocator: std.mem.Allocator) ![]u8 {
    if (compat.getEnvVarOwned(allocator, "CODEX_HOME")) |codex_home| {
        return codex_home;
    } else |_| {}

    const home = try compat.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".codex" });
}

fn codexModelsCachePath(allocator: std.mem.Allocator) ![]u8 {
    const codex_home = try codexHomePath(allocator);
    defer allocator.free(codex_home);
    return try std.fs.path.join(allocator, &.{ codex_home, codex_models_cache_name });
}

fn makaiCodexCatalogPath(allocator: std.mem.Allocator) ![]u8 {
    const home = try compat.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".makai", makai_catalog_dir_name, makai_codex_catalog_name });
}

fn makaiCatalogDirPath(allocator: std.mem.Allocator) ![]u8 {
    const home = try compat.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".makai", makai_catalog_dir_name });
}

fn saveMakaiCodexCatalog(allocator: std.mem.Allocator, data: []const u8) !void {
    const dir_path = try makaiCatalogDirPath(allocator);
    defer allocator.free(dir_path);
    try compat.fs.createDir(compat.fs.getCwd(), dir_path);

    const path = try makaiCodexCatalogPath(allocator);
    defer allocator.free(path);

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}.{x}", .{ path, compat.time.nowMillis(), compat.random.int(u64) });
    defer allocator.free(tmp_path);

    try compat.fs.atomicReplace(compat.fs.getCwd(), path, tmp_path, data);
}

fn codexClientVersion(allocator: std.mem.Allocator) ![]u8 {
    if (try codexClientVersionFromModelsCache(allocator)) |version| return version;
    if (try codexClientVersionFromVersionFile(allocator)) |version| return version;
    return try allocator.dupe(u8, default_codex_client_version);
}

fn codexClientVersionFromModelsCache(allocator: std.mem.Allocator) !?[]u8 {
    const path = codexModelsCachePath(allocator) catch return null;
    defer allocator.free(path);
    const data = compat.fs.readFileAlloc(allocator, compat.fs.getCwd(), path, max_catalog_bytes) catch return null;
    defer allocator.free(data);
    return try parseRootStringField(allocator, data, "client_version");
}

fn codexClientVersionFromVersionFile(allocator: std.mem.Allocator) !?[]u8 {
    const codex_home = codexHomePath(allocator) catch return null;
    defer allocator.free(codex_home);
    const path = try std.fs.path.join(allocator, &.{ codex_home, "version.json" });
    defer allocator.free(path);
    const data = compat.fs.readFileAlloc(allocator, compat.fs.getCwd(), path, 16 * 1024) catch return null;
    defer allocator.free(data);
    return try parseRootStringField(allocator, data, "latest_version");
}

fn parseRootStringField(allocator: std.mem.Allocator, data: []const u8, key: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get(key) orelse return null;
    if (value != .string) return null;
    return try allocator.dupe(u8, value.string);
}

fn fetchCodexModelsCatalog(
    allocator: std.mem.Allocator,
    access_token: []const u8,
    account_id: ?[]const u8,
    client_version: []const u8,
) ![]u8 {
    const url = try std.fmt.allocPrint(
        allocator,
        "{s}/models?client_version={s}",
        .{ openai_codex_base_url, client_version },
    );
    defer allocator.free(url);

    const uri = try std.Uri.parse(url);

    var client = compat.http.HttpClient.init(allocator);
    defer client.deinit();

    var environ_map = compat.createEnvMap(allocator) catch null;
    defer if (environ_map) |*map| map.deinit();
    if (environ_map) |*map| {
        client.initDefaultProxies(allocator, map) catch {};
    }

    const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
    defer secureFree(allocator, auth);

    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "accept", .value = "application/json" });
    try headers.append(allocator, .{ .name = "authorization", .value = auth });
    try headers.append(allocator, .{ .name = "version", .value = client_version });
    if (account_id) |id| {
        try headers.append(allocator, .{ .name = "ChatGPT-Account-ID", .value = id });
    }

    var req = try client.openRequest(.GET, uri, .{
        .extra_headers = headers.items,
        .accept_encoding = "identity",
    });
    defer req.deinit();
    req.headers.accept_encoding = .omit;

    try compat.http.sendBodilessRequest(&req);

    var head_buf: [4096]u8 = undefined;
    var response = try compat.http.receiveResponse(&req, &head_buf);

    var transfer_buf: [4096]u8 = undefined;
    const reader = compat.http.responseReader(&response, &transfer_buf);
    const body = try compat.http.allocRemainingResponse(allocator, reader, max_catalog_bytes);
    errdefer allocator.free(body);

    if (response.head.status != .ok) return error.ModelCatalogFetchFailed;
    return body;
}

fn codexAccountIdFromStorage(allocator: std.mem.Allocator, storage: *const oauth_storage.AuthStorage) !?[]u8 {
    const auth = storage.providers.get(openai_codex_provider_id) orelse return null;
    return switch (auth) {
        .api_key => null,
        .oauth => |credentials| blk: {
            const provider_data = credentials.provider_data orelse break :blk null;
            break :blk try parseProviderDataAccountId(allocator, provider_data);
        },
    };
}

fn parseProviderDataAccountId(allocator: std.mem.Allocator, provider_data: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, provider_data, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const account_id = parsed.value.object.get("account_id") orelse return null;
    if (account_id != .string or account_id.string.len == 0) return null;
    return try allocator.dupe(u8, account_id.string);
}

pub fn parseCodexModelsCache(allocator: std.mem.Allocator, data: []const u8) ![]ai_types.Model {
    return parseCodexModelsCacheWithOptions(allocator, data, .{});
}

fn parseCodexModelsCacheWithOptions(
    allocator: std.mem.Allocator,
    data: []const u8,
    options: CodexParseOptions,
) ![]ai_types.Model {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidModelCatalog;
    const root = &parsed.value.object;

    const root_client_version = if (options.client_version) |version|
        version
    else if (objectString(root, "client_version")) |version|
        version
    else
        null;

    const models_value = root.get("models") orelse return error.InvalidModelCatalog;
    if (models_value != .array) return error.InvalidModelCatalog;

    var models = std.ArrayList(ai_types.Model).empty;
    errdefer {
        for (models.items) |*model| model.deinit(allocator);
        models.deinit(allocator);
    }

    for (models_value.array.items) |item| {
        if (item != .object) continue;
        const obj = &item.object;
        if (!isVisibleSupportedCodexModel(obj)) continue;

        const slug = objectString(obj, "slug") orelse continue;
        if (slug.len == 0) continue;

        const context_window = objectU32(obj, "context_window") orelse
            objectU32(obj, "max_context_window") orelse
            continue;
        const max_tokens = objectU32(obj, "max_output_tokens") orelse
            objectU32(obj, "max_tokens") orelse
            @min(context_window, default_max_output_tokens);

        const model = try codexModelFromObject(allocator, obj, slug, context_window, max_tokens, .{
            .account_id = options.account_id,
            .client_version = root_client_version,
        });
        try models.append(allocator, model);
    }

    return try models.toOwnedSlice(allocator);
}

fn isVisibleSupportedCodexModel(obj: *const std.json.ObjectMap) bool {
    if (objectString(obj, "visibility")) |visibility| {
        if (!std.mem.eql(u8, visibility, "list")) return false;
    }
    if (objectBool(obj, "supported_in_api")) |supported| {
        if (!supported) return false;
    }
    return true;
}

fn codexModelFromObject(
    allocator: std.mem.Allocator,
    obj: *const std.json.ObjectMap,
    slug: []const u8,
    context_window: u32,
    max_tokens: u32,
    options: CodexParseOptions,
) !ai_types.Model {
    const id = try allocator.dupe(u8, slug);
    errdefer allocator.free(id);
    const display = objectString(obj, "display_name") orelse slug;
    const name = try allocator.dupe(u8, display);
    errdefer allocator.free(name);
    const api = try allocator.dupe(u8, openai_codex_api_id);
    errdefer allocator.free(api);
    const provider = try allocator.dupe(u8, openai_codex_provider_id);
    errdefer allocator.free(provider);
    const base_url = try allocator.dupe(u8, openai_codex_base_url);
    errdefer allocator.free(base_url);

    const input = try parseInputModalities(allocator, obj);
    errdefer freeInput(allocator, input);

    const headers = try codexModelHeaders(allocator, options);
    errdefer if (headers) |pairs| freeHeaders(allocator, pairs);

    return .{
        .id = id,
        .name = name,
        .api = api,
        .provider = provider,
        .base_url = base_url,
        .reasoning = modelSupportsReasoning(obj),
        .input = input,
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = context_window,
        .max_tokens = max_tokens,
        .headers = headers,
        .is_owned = true,
    };
}

fn parseInputModalities(allocator: std.mem.Allocator, obj: *const std.json.ObjectMap) ![]const []const u8 {
    if (obj.get("input_modalities")) |value| {
        if (value == .array and value.array.items.len > 0) {
            var modalities = std.ArrayList([]const u8).empty;
            errdefer {
                for (modalities.items) |item| allocator.free(item);
                modalities.deinit(allocator);
            }

            for (value.array.items) |item| {
                if (item != .string or item.string.len == 0) continue;
                const modality = try allocator.dupe(u8, item.string);
                errdefer allocator.free(modality);
                try modalities.append(allocator, modality);
            }

            if (modalities.items.len > 0) return try modalities.toOwnedSlice(allocator);
            modalities.deinit(allocator);
        }
    }

    const fallback = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(fallback);
    fallback[0] = try allocator.dupe(u8, "text");
    return fallback;
}

fn codexModelHeaders(allocator: std.mem.Allocator, options: CodexParseOptions) !?[]const ai_types.HeaderPair {
    const count: usize = (if (options.client_version) |_| @as(usize, 1) else 0) +
        (if (options.account_id) |_| @as(usize, 1) else 0);
    if (count == 0) return null;

    var headers = try allocator.alloc(ai_types.HeaderPair, count);
    errdefer allocator.free(headers);

    var idx: usize = 0;
    if (options.client_version) |version| {
        const name = try allocator.dupe(u8, "version");
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, version);
        errdefer allocator.free(value);
        headers[idx] = .{ .name = name, .value = value };
        idx += 1;
    }
    errdefer for (headers[0..idx]) |*header| header.deinit(allocator);

    if (options.account_id) |account_id| {
        const name = try allocator.dupe(u8, "ChatGPT-Account-ID");
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, account_id);
        errdefer allocator.free(value);
        headers[idx] = .{ .name = name, .value = value };
        idx += 1;
    }

    return headers;
}

fn modelSupportsReasoning(obj: *const std.json.ObjectMap) bool {
    if (obj.get("supported_reasoning_levels")) |value| {
        return value == .array and value.array.items.len > 0;
    }
    if (objectString(obj, "default_reasoning_level")) |level| {
        return level.len > 0 and !std.mem.eql(u8, level, "off");
    }
    return false;
}

fn freeInput(allocator: std.mem.Allocator, input: []const []const u8) void {
    for (input) |item| allocator.free(item);
    allocator.free(input);
}

fn freeHeaders(allocator: std.mem.Allocator, headers: []const ai_types.HeaderPair) void {
    for (headers) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
    allocator.free(headers);
}

fn objectString(obj: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn objectBool(obj: *const std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    if (value != .bool) return null;
    return value.bool;
}

fn objectU32(obj: *const std.json.ObjectMap, key: []const u8) ?u32 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |v| {
            if (v < 0 or v > std.math.maxInt(u32)) return null;
            return @intCast(v);
        },
        .float => |v| {
            if (!std.math.isFinite(v)) return null;
            if (v < 0 or v > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return null;
            return @intFromFloat(v);
        },
        else => return null,
    };
}

test "parseCodexModelsCache maps visible supported Codex models" {
    const data =
        \\{
        \\  "client_version": "0.135.0",
        \\  "models": [
        \\    {
        \\      "slug": "gpt-test-codex",
        \\      "display_name": "GPT Test Codex",
        \\      "visibility": "list",
        \\      "supported_in_api": true,
        \\      "context_window": 272000,
        \\      "input_modalities": ["text", "image"],
        \\      "supported_reasoning_levels": [{"effort": "low"}]
        \\    },
        \\    {
        \\      "slug": "hidden-model",
        \\      "visibility": "hidden",
        \\      "supported_in_api": true,
        \\      "context_window": 128000
        \\    },
        \\    {
        \\      "slug": "unsupported-model",
        \\      "visibility": "list",
        \\      "supported_in_api": false,
        \\      "context_window": 128000
        \\    }
        \\  ]
        \\}
    ;

    const models = try parseCodexModelsCache(std.testing.allocator, data);
    defer deinitModels(std.testing.allocator, models);

    try std.testing.expectEqual(@as(usize, 1), models.len);
    try std.testing.expectEqualStrings("gpt-test-codex", models[0].id);
    try std.testing.expectEqualStrings("GPT Test Codex", models[0].name);
    try std.testing.expectEqualStrings(openai_codex_provider_id, models[0].provider);
    try std.testing.expectEqualStrings(openai_codex_api_id, models[0].api);
    try std.testing.expectEqualStrings(openai_codex_base_url, models[0].base_url);
    try std.testing.expect(models[0].reasoning);
    try std.testing.expectEqual(@as(u32, 272000), models[0].context_window);
    try std.testing.expectEqual(@as(u32, default_max_output_tokens), models[0].max_tokens);
    try std.testing.expectEqual(@as(usize, 2), models[0].input.len);
    try std.testing.expectEqualStrings("text", models[0].input[0]);
    try std.testing.expectEqualStrings("image", models[0].input[1]);
    try std.testing.expect(models[0].headers != null);
    try std.testing.expectEqualStrings("version", models[0].headers.?[0].name);
    try std.testing.expectEqualStrings("0.135.0", models[0].headers.?[0].value);
}

test "loadProductionModels includes Kimi model when enabled" {
    test_force_kimi_model = true;
    defer test_force_kimi_model = false;

    const models = try loadProductionModels(std.testing.allocator);
    defer deinitModels(std.testing.allocator, models);

    try std.testing.expectEqual(@as(usize, 1), models.len);
    try std.testing.expectEqualStrings(kimi_model_id, models[0].id);
    try std.testing.expectEqualStrings("Kimi K2.7 Code", models[0].name);
    try std.testing.expectEqualStrings(kimi_provider_id, models[0].provider);
    try std.testing.expectEqualStrings(kimi_api_id, models[0].api);
    try std.testing.expectEqualStrings(kimi_base_url, models[0].base_url);
    try std.testing.expectEqual(@as(u32, 262_144), models[0].context_window);
    try std.testing.expectEqual(@as(u32, 16_384), models[0].max_tokens);
}

test "parseCodexModelsCache accepts models response body" {
    const data =
        \\{"models":[{"slug":"gpt-api","visibility":"list","supported_in_api":true,"max_context_window":128000}]}
    ;

    const models = try parseCodexModelsCache(std.testing.allocator, data);
    defer deinitModels(std.testing.allocator, models);

    try std.testing.expectEqual(@as(usize, 1), models.len);
    try std.testing.expectEqualStrings("gpt-api", models[0].id);
    try std.testing.expectEqual(@as(u32, 128000), models[0].context_window);
    try std.testing.expectEqual(@as(u32, default_max_output_tokens), models[0].max_tokens);
    try std.testing.expect(models[0].headers == null);
}

test "parseCodexModelsCache rejects oversized floating catalog sizes" {
    const oversized_context =
        \\{"models":[{"slug":"bad-context","visibility":"list","supported_in_api":true,"context_window":1e40}]}
    ;

    const no_models = try parseCodexModelsCache(std.testing.allocator, oversized_context);
    defer deinitModels(std.testing.allocator, no_models);
    try std.testing.expectEqual(@as(usize, 0), no_models.len);

    const oversized_max_tokens =
        \\{"models":[{"slug":"valid-context","visibility":"list","supported_in_api":true,"context_window":128000,"max_tokens":1e40}]}
    ;

    const models = try parseCodexModelsCache(std.testing.allocator, oversized_max_tokens);
    defer deinitModels(std.testing.allocator, models);
    try std.testing.expectEqual(@as(usize, 1), models.len);
    try std.testing.expectEqual(@as(u32, default_max_output_tokens), models[0].max_tokens);
}
