
const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");

pub fn defaultBaseUrlForRef(allocator: std.mem.Allocator, provider_id: []const u8, api: []const u8) ![]const u8 {
    return defaultBaseUrlForRefWithRegion(allocator, provider_id, api, null);
}

pub fn defaultBaseUrlForRefWithRegion(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    api: []const u8,
    stored_kimi_region: ?[]const u8,
) ![]const u8 {
    const global = try envOwnedOrNull(allocator, "MAKAI_BASE_URL");
    defer if (global) |g| allocator.free(g);
    const anthropic = try envOwnedOrNull(allocator, "ANTHROPIC_BASE_URL");
    defer if (anthropic) |v| allocator.free(v);
    const openai = try envOwnedOrNull(allocator, "OPENAI_BASE_URL");
    defer if (openai) |v| allocator.free(v);
    const deepseek = try envOwnedOrNull(allocator, "DEEPSEEK_BASE_URL");
    defer if (deepseek) |v| allocator.free(v);

    const kimi_region: []const u8 = blk: {
        if (try envOwnedOrNull(allocator, "KIMI_REGION")) |env_region| {
            defer allocator.free(env_region);
            if (normalizeKimiRegion(env_region)) |region| break :blk region;
        }
        if (stored_kimi_region) |stored| {
            if (normalizeKimiRegion(stored)) |region| break :blk region;
        }
        break :blk "china";
    };

    return baseUrlWithOverrides(allocator, provider_id, api, .{
        .global = global orelse "",
        .anthropic = anthropic orelse "",
        .openai = openai orelse "",
        .deepseek = deepseek orelse "",
        .kimi_region = kimi_region,
    });
}

pub const BaseUrlOverrides = struct {
    global: []const u8 = "",
    anthropic: []const u8 = "",
    openai: []const u8 = "",
    deepseek: []const u8 = "",
    kimi_region: []const u8 = "china",
};

const OPENAI_CODEX_BASE_URL = "https://chatgpt.com/backend-api/codex";
const KIMI_CHINA_BASE_URL = "https://api.kimi.com/coding";
const KIMI_GLOBAL_BASE_URL = "https://api.moonshot.ai";

pub fn normalizeKimiRegion(value: []const u8) ?[]const u8 {
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

pub fn normalizeVersionedBaseUrl(url: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, url, "/");
    if (std.mem.endsWith(u8, trimmed, "/v1")) return trimmed[0 .. trimmed.len - 3];
    return trimmed;
}

pub fn usesVersionedRoute(provider_id: []const u8, api: []const u8) bool {
    if (std.mem.eql(u8, provider_id, "github-copilot")) return false;
    return std.mem.eql(u8, api, "anthropic-messages") or
        std.mem.eql(u8, api, "openai-completions") or
        std.mem.eql(u8, api, "openai-responses");
}

pub fn baseUrlWithOverrides(allocator: std.mem.Allocator, provider_id: []const u8, api: []const u8, ov: BaseUrlOverrides) ![]const u8 {
    if (ov.global.len > 0) {
        const global = if (usesVersionedRoute(provider_id, api)) normalizeVersionedBaseUrl(ov.global) else std.mem.trimEnd(u8, ov.global, "/");
        return try allocator.dupe(u8, global);
    }

    const by_provider: ?[]const u8 = if (std.mem.eql(u8, provider_id, "anthropic") and std.mem.eql(u8, api, "anthropic-messages"))
        if (ov.anthropic.len > 0) normalizeVersionedBaseUrl(ov.anthropic) else "https://api.anthropic.com"
    else if (std.mem.eql(u8, provider_id, "openai") and (std.mem.eql(u8, api, "openai-completions") or std.mem.eql(u8, api, "openai-responses")))
        if (ov.openai.len > 0) normalizeVersionedBaseUrl(ov.openai) else "https://api.openai.com"
    else if (std.mem.eql(u8, provider_id, "deepseek") and std.mem.eql(u8, api, "openai-completions"))
        if (ov.deepseek.len > 0) normalizeVersionedBaseUrl(ov.deepseek) else "https://api.deepseek.com"
    else if (std.mem.eql(u8, provider_id, "openai-codex") and std.mem.eql(u8, api, "openai-codex-responses"))
        OPENAI_CODEX_BASE_URL
    else if (std.mem.eql(u8, provider_id, "kimi") and std.mem.eql(u8, api, "openai-completions"))
        if (std.mem.eql(u8, ov.kimi_region, "global")) KIMI_GLOBAL_BASE_URL else KIMI_CHINA_BASE_URL
    else
        null;
    if (by_provider) |url| return try allocator.dupe(u8, url);

    return try allocator.dupe(u8, "");
}

pub fn envOwnedOrNull(allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
    const value = compat.getEnvVarOwned(allocator, key) catch return null;
    if (value.len == 0) {
        allocator.free(value);
        return null;
    }
    return value;
}

pub const OAuthOriginSources = struct {
    global: []const u8 = "",
    provider: []const u8 = "",
    credential: []const u8 = "",
    credential_is_api_key: bool = false,
};

const ANTHROPIC_OAUTH_ORIGIN = "https://api.anthropic.com";
const GITHUB_COPILOT_OAUTH_DOMAIN = "githubcopilot.com";

const OAuthOriginPolicy = struct {
    exact: []const []const u8 = &.{},
    domain: ?[]const u8 = null,
    credential_declares_origin: bool = false,
};

const Origin = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
};

fn defaultPortForScheme(scheme: []const u8) u16 {
    if (std.ascii.eqlIgnoreCase(scheme, "https")) return 443;
    if (std.ascii.eqlIgnoreCase(scheme, "http")) return 80;
    return 0;
}

fn parseOrigin(url: []const u8) ?Origin {
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    const scheme_end = std.mem.indexOf(u8, trimmed, "://") orelse return null;
    const scheme = trimmed[0..scheme_end];
    if (scheme.len == 0) return null;

    var authority = trimmed[scheme_end + 3 ..];
    if (std.mem.indexOfAny(u8, authority, "/?#")) |idx| authority = authority[0..idx];
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |idx| authority = authority[idx + 1 ..];
    if (authority.len == 0) return null;

    var host = authority;
    var port = defaultPortForScheme(scheme);
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
        host = authority[0 .. close + 1];
        const tail = authority[close + 1 ..];
        if (tail.len > 0) {
            if (tail[0] != ':') return null;
            port = std.fmt.parseInt(u16, tail[1..], 10) catch return null;
        }
    } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |idx| {
        host = authority[0..idx];
        port = std.fmt.parseInt(u16, authority[idx + 1 ..], 10) catch return null;
    }
    if (host.len == 0) return null;
    return .{ .scheme = scheme, .host = host, .port = port };
}

fn originsMatch(requested: Origin, candidate_url: []const u8) bool {
    const candidate = parseOrigin(candidate_url) orelse return false;
    return std.ascii.eqlIgnoreCase(requested.scheme, candidate.scheme) and
        std.ascii.eqlIgnoreCase(requested.host, candidate.host) and
        requested.port == candidate.port;
}

fn hostUnderDomain(host: []const u8, domain: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, domain)) return true;
    if (host.len <= domain.len + 1) return false;
    const suffix_start = host.len - domain.len;
    if (host[suffix_start - 1] != '.') return false;
    return std.ascii.eqlIgnoreCase(host[suffix_start..], domain);
}

fn oauthOriginPolicyFor(provider_id: []const u8) ?OAuthOriginPolicy {
    if (std.mem.eql(u8, provider_id, "anthropic")) {
        return .{ .exact = &.{ANTHROPIC_OAUTH_ORIGIN} };
    }
    if (std.mem.eql(u8, provider_id, "openai-codex")) {
        return .{ .exact = &.{OPENAI_CODEX_BASE_URL} };
    }
    if (std.mem.eql(u8, provider_id, "github-copilot")) {
        return .{ .domain = GITHUB_COPILOT_OAUTH_DOMAIN, .credential_declares_origin = true };
    }
    return null;
}

pub fn oauthOriginAllowedWithSources(
    provider_id: []const u8,
    base_url: []const u8,
    sources: OAuthOriginSources,
) bool {
    const trimmed = std.mem.trim(u8, base_url, " \t\r\n");
    if (trimmed.len == 0) return true;

    const policy_for_provider = oauthOriginPolicyFor(provider_id);
    if (sources.credential_is_api_key and policy_for_provider == null) return true;

    const requested = parseOrigin(trimmed) orelse return false;
    if (sources.global.len > 0 and originsMatch(requested, sources.global)) return true;
    if (sources.provider.len > 0 and originsMatch(requested, sources.provider)) return true;

    const policy = policy_for_provider orelse return false;
    if (policy.credential_declares_origin and
        sources.credential.len > 0 and
        originsMatch(requested, sources.credential))
    {
        return true;
    }
    for (policy.exact) |allowed| {
        if (originsMatch(requested, allowed)) return true;
    }
    if (policy.domain) |domain| {
        if (hostUnderDomain(requested.host, domain)) return true;
    }
    return false;
}

fn providerBaseUrlEnvName(provider_id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, provider_id, "anthropic")) return "ANTHROPIC_BASE_URL";
    if (std.mem.eql(u8, provider_id, "openai")) return "OPENAI_BASE_URL";
    if (std.mem.eql(u8, provider_id, "deepseek")) return "DEEPSEEK_BASE_URL";
    return null;
}

pub fn credentialDeclaredBaseUrl(allocator: std.mem.Allocator, provider_data: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, provider_data, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get("baseUrl") orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return allocator.dupe(u8, value.string) catch null;
}

pub fn storedCredentialIsApiKeyShaped(refresh: []const u8) bool {
    return refresh.len == 0;
}

pub fn oauthOriginAllowed(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    base_url: []const u8,
    refresh: []const u8,
    provider_data: ?[]const u8,
) bool {
    const trimmed = std.mem.trim(u8, base_url, " \t\r\n");
    if (trimmed.len == 0) return true;
    if (storedCredentialIsApiKeyShaped(refresh) and oauthOriginPolicyFor(provider_id) == null) return true;

    const global = envOwnedOrNull(allocator, "MAKAI_BASE_URL") catch null;
    defer if (global) |value| allocator.free(value);

    const provider_override: ?[]const u8 = blk: {
        const name = providerBaseUrlEnvName(provider_id) orelse break :blk null;
        break :blk envOwnedOrNull(allocator, name) catch null;
    };
    defer if (provider_override) |value| allocator.free(value);

    const credential: ?[]u8 = blk: {
        const data = provider_data orelse break :blk null;
        break :blk credentialDeclaredBaseUrl(allocator, data);
    };
    defer if (credential) |value| allocator.free(value);

    return oauthOriginAllowedWithSources(provider_id, trimmed, .{
        .global = global orelse "",
        .provider = provider_override orelse "",
        .credential = credential orelse "",
        .credential_is_api_key = storedCredentialIsApiKeyShaped(refresh),
    });
}

pub const ProxyCompatFlags = struct {
    global_base_set: bool = false,
    global_proxy: bool = false,
    openai_proxy: bool = false,
    deepseek_proxy: bool = false,
    anthropic_proxy: bool = false,
};

pub fn proxyCompatFlagsFromEnv(allocator: std.mem.Allocator) !ProxyCompatFlags {
    const global_base = try envOwnedOrNull(allocator, "MAKAI_BASE_URL");
    defer if (global_base) |value| allocator.free(value);

    return .{
        .global_base_set = global_base != null,
        .global_proxy = try envFlag(allocator, "MAKAI_BASE_URL_IS_PROXY"),
        .openai_proxy = try envFlag(allocator, "OPENAI_BASE_URL_IS_PROXY"),
        .deepseek_proxy = try envFlag(allocator, "DEEPSEEK_BASE_URL_IS_PROXY"),
        .anthropic_proxy = try envFlag(allocator, "ANTHROPIC_BASE_URL_IS_PROXY"),
    };
}

pub fn transparentProxyCompat(allocator: std.mem.Allocator, provider_id: []const u8) !?ai_types.OpenAICompatOptions {
    return transparentProxyCompatForFlags(provider_id, try proxyCompatFlagsFromEnv(allocator));
}

pub fn transparentProxyCompatForFlags(provider_id: []const u8, flags: ProxyCompatFlags) ?ai_types.OpenAICompatOptions {
    if (std.mem.eql(u8, provider_id, "openai") and (if (flags.global_base_set) flags.global_proxy else flags.openai_proxy)) {
        return .{
            .supports_store = true,
            .supports_developer_role = true,
            .supports_reasoning_effort = true,
            .max_tokens_field = .max_completion_tokens,
        };
    }
    if (std.mem.eql(u8, provider_id, "deepseek") and (if (flags.global_base_set) flags.global_proxy else flags.deepseek_proxy)) {
        return .{
            .requires_thinking_as_text = true,
            .max_tokens_field = .max_tokens,
            .supports_strict_mode = false,
        };
    }
    if (std.mem.eql(u8, provider_id, "anthropic") and (if (flags.global_base_set) flags.global_proxy else flags.anthropic_proxy)) {
        return .{ .supports_anthropic_cache_ttl = true };
    }
    return null;
}

fn envFlag(allocator: std.mem.Allocator, key: []const u8) !bool {
    const value = try envOwnedOrNull(allocator, key) orelse return false;
    defer allocator.free(value);
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true");
}

pub fn isReasoningModelRef(provider_id: []const u8, model_id: []const u8) bool {    if (std.mem.eql(u8, provider_id, "openai") or std.mem.eql(u8, provider_id, "openai-codex")) {
        return std.mem.startsWith(u8, model_id, "o1") or
            std.mem.startsWith(u8, model_id, "o3") or
            std.mem.startsWith(u8, model_id, "o4") or
            (std.mem.startsWith(u8, model_id, "gpt-5") and std.mem.indexOf(u8, model_id, "-chat") == null);
    }
    if (std.mem.eql(u8, provider_id, "deepseek")) {
        return std.mem.startsWith(u8, model_id, "deepseek-reasoner");
    }
    if (std.mem.eql(u8, provider_id, "anthropic")) {
        if (!std.mem.startsWith(u8, model_id, "claude-")) return false;
        if (std.mem.startsWith(u8, model_id, "claude-1")) return false;
        if (std.mem.startsWith(u8, model_id, "claude-2")) return false;
        if (std.mem.startsWith(u8, model_id, "claude-v")) return false;
        if (std.mem.startsWith(u8, model_id, "claude-instant")) return false;
        if (std.mem.startsWith(u8, model_id, "claude-3-7")) return true;
        return !std.mem.startsWith(u8, model_id, "claude-3");
    }
    return false;
}

pub fn defaultMaxTokensForRef(provider_id: []const u8, api: []const u8) u32 {
    if (std.mem.eql(u8, provider_id, "kimi") and std.mem.eql(u8, api, "openai-completions")) {
        return 16_384;
    }
    return 4_096;
}

test "baseUrlWithOverrides resolves canonical provider defaults" {
    const allocator = std.testing.allocator;

    const anthropic = try baseUrlWithOverrides(allocator, "anthropic", "anthropic-messages", .{});
    defer allocator.free(anthropic);
    try std.testing.expectEqualStrings("https://api.anthropic.com", anthropic);

    const openai = try baseUrlWithOverrides(allocator, "openai", "openai-completions", .{});
    defer allocator.free(openai);
    try std.testing.expectEqualStrings("https://api.openai.com", openai);

    const deepseek = try baseUrlWithOverrides(allocator, "deepseek", "openai-completions", .{});
    defer allocator.free(deepseek);
    try std.testing.expectEqualStrings("https://api.deepseek.com", deepseek);
}

test "baseUrlWithOverrides prefers env overrides and global override" {
    const allocator = std.testing.allocator;

    const proxied = try baseUrlWithOverrides(allocator, "anthropic", "anthropic-messages", .{
        .anthropic = "https://proxy.example.com",
    });
    defer allocator.free(proxied);
    try std.testing.expectEqualStrings("https://proxy.example.com", proxied);

    const versioned_anthropic = try baseUrlWithOverrides(allocator, "anthropic", "anthropic-messages", .{
        .anthropic = "https://proxy.example.com/anthropic/v1/",
    });
    defer allocator.free(versioned_anthropic);
    try std.testing.expectEqualStrings("https://proxy.example.com/anthropic", versioned_anthropic);

    const versioned_openai = try baseUrlWithOverrides(allocator, "openai", "openai-completions", .{
        .openai = "https://proxy.example.com/openai/v1/",
    });
    defer allocator.free(versioned_openai);
    try std.testing.expectEqualStrings("https://proxy.example.com/openai", versioned_openai);

    const global = try baseUrlWithOverrides(allocator, "kimi", "openai-completions", .{
        .global = "https://everywhere.example.com",
    });
    defer allocator.free(global);
    try std.testing.expectEqualStrings("https://everywhere.example.com", global);

    const versioned_global = try baseUrlWithOverrides(allocator, "openai", "openai-completions", .{
        .global = "https://proxy.example.com/v1",
    });
    defer allocator.free(versioned_global);
    try std.testing.expectEqualStrings("https://proxy.example.com", versioned_global);

    const copilot_global = try baseUrlWithOverrides(allocator, "github-copilot", "openai-completions", .{
        .global = "https://proxy.example.com/v1",
    });
    defer allocator.free(copilot_global);
    try std.testing.expectEqualStrings("https://proxy.example.com/v1", copilot_global);

    const versioned_deepseek = try baseUrlWithOverrides(allocator, "deepseek", "openai-completions", .{
        .deepseek = "https://proxy.example.com/v1/",
    });
    defer allocator.free(versioned_deepseek);
    try std.testing.expectEqualStrings("https://proxy.example.com", versioned_deepseek);
}

test "baseUrlWithOverrides requires explicit endpoint for unknown providers" {
    const allocator = std.testing.allocator;

    const unknown = try baseUrlWithOverrides(allocator, "openrouter", "openai-completions", .{});
    defer allocator.free(unknown);
    try std.testing.expectEqualStrings("", unknown);

    const explicit = try baseUrlWithOverrides(allocator, "openrouter", "openai-completions", .{
        .global = "https://openrouter.example.com/api",
    });
    defer allocator.free(explicit);
    try std.testing.expectEqualStrings("https://openrouter.example.com/api", explicit);
}

test "baseUrlWithOverrides rejects provider/API mismatches" {
    const allocator = std.testing.allocator;

    const anthropic_openai = try baseUrlWithOverrides(allocator, "anthropic", "openai-completions", .{});
    defer allocator.free(anthropic_openai);
    try std.testing.expectEqualStrings("", anthropic_openai);

    const openai_anthropic = try baseUrlWithOverrides(allocator, "openai", "anthropic-messages", .{});
    defer allocator.free(openai_anthropic);
    try std.testing.expectEqualStrings("", openai_anthropic);

    const openai_codex_responses = try baseUrlWithOverrides(allocator, "openai", "openai-codex-responses", .{});
    defer allocator.free(openai_codex_responses);
    try std.testing.expectEqualStrings("", openai_codex_responses);

    const deepseek_responses = try baseUrlWithOverrides(allocator, "deepseek", "openai-responses", .{});
    defer allocator.free(deepseek_responses);
    try std.testing.expectEqualStrings("", deepseek_responses);
}

test "transparent proxy compat preserves vendor token-limit fields" {
    const deepseek = transparentProxyCompatForFlags("deepseek", .{ .deepseek_proxy = true });
    try std.testing.expect(deepseek != null);
    try std.testing.expectEqual(@as(?bool, true), deepseek.?.requires_thinking_as_text);
    try std.testing.expect(deepseek.?.max_tokens_field.? == .max_tokens);
    try std.testing.expectEqual(@as(?bool, false), deepseek.?.supports_strict_mode);

    const deepseek_global = transparentProxyCompatForFlags("deepseek", .{
        .global_base_set = true,
        .global_proxy = true,
        .deepseek_proxy = false,
    });
    try std.testing.expect(deepseek_global != null);
    try std.testing.expect(deepseek_global.?.max_tokens_field.? == .max_tokens);

    try std.testing.expect(transparentProxyCompatForFlags("deepseek", .{}) == null);

    const openai = transparentProxyCompatForFlags("openai", .{ .openai_proxy = true });
    try std.testing.expect(openai != null);
    try std.testing.expect(openai.?.max_tokens_field.? == .max_completion_tokens);
}

test "baseUrlWithOverrides resolves production catalog pairs" {
    const allocator = std.testing.allocator;

    const codex = try baseUrlWithOverrides(allocator, "openai-codex", "openai-codex-responses", .{});
    defer allocator.free(codex);
    try std.testing.expectEqualStrings(OPENAI_CODEX_BASE_URL, codex);

    const kimi_china = try baseUrlWithOverrides(allocator, "kimi", "openai-completions", .{});
    defer allocator.free(kimi_china);
    try std.testing.expectEqualStrings(KIMI_CHINA_BASE_URL, kimi_china);

    const kimi_global = try baseUrlWithOverrides(allocator, "kimi", "openai-completions", .{
        .kimi_region = "global",
    });
    defer allocator.free(kimi_global);
    try std.testing.expectEqualStrings(KIMI_GLOBAL_BASE_URL, kimi_global);

    const kimi_overridden = try baseUrlWithOverrides(allocator, "kimi", "openai-completions", .{
        .global = "https://everywhere.example.com",
    });
    defer allocator.free(kimi_overridden);
    try std.testing.expectEqualStrings("https://everywhere.example.com", kimi_overridden);

    const kimi_wrong_api = try baseUrlWithOverrides(allocator, "kimi", "openai-responses", .{});
    defer allocator.free(kimi_wrong_api);
    try std.testing.expectEqualStrings("", kimi_wrong_api);

    const codex_wrong_provider = try baseUrlWithOverrides(allocator, "openai", "openai-codex-responses", .{});
    defer allocator.free(codex_wrong_provider);
    try std.testing.expectEqualStrings("", codex_wrong_provider);
}

test "oauthOriginAllowedWithSources binds vendor tokens to vendor origins" {
    try std.testing.expect(oauthOriginAllowedWithSources("anthropic", "https://api.anthropic.com", .{}));
    try std.testing.expect(oauthOriginAllowedWithSources("anthropic", "https://api.anthropic.com/v1/", .{}));
    try std.testing.expect(!oauthOriginAllowedWithSources("anthropic", "https://attacker.test", .{}));
    try std.testing.expect(!oauthOriginAllowedWithSources("anthropic", "https://api.anthropic.com.attacker.test", .{}));
    try std.testing.expect(!oauthOriginAllowedWithSources("anthropic", "http://api.anthropic.com", .{}));
    try std.testing.expect(!oauthOriginAllowedWithSources("anthropic", "https://api.anthropic.com:8443", .{}));

    try std.testing.expect(oauthOriginAllowedWithSources("openai-codex", "https://chatgpt.com/backend-api/codex", .{}));
    try std.testing.expect(!oauthOriginAllowedWithSources("openai-codex", "https://chatgpt.attacker.test/backend-api/codex", .{}));
}

test "oauthOriginAllowedWithSources allows an absent base_url" {
    try std.testing.expect(oauthOriginAllowedWithSources("anthropic", "", .{}));
    try std.testing.expect(oauthOriginAllowedWithSources("anthropic", "   ", .{}));
    try std.testing.expect(oauthOriginAllowedWithSources("test-fixture", "", .{}));
}

test "oauthOriginAllowedWithSources fails closed for an unpoliced provider id" {
    try std.testing.expect(!oauthOriginAllowedWithSources("test-fixture", "https://anywhere.test", .{}));
    try std.testing.expect(!oauthOriginAllowedWithSources("gateway", "https://gateway.test", .{}));
    try std.testing.expect(oauthOriginAllowedWithSources("gateway", "https://gateway.test", .{
        .global = "https://gateway.test",
    }));
}

test "oauthOriginAllowedWithSources exempts an api-key-shaped entry under an unpoliced id" {
    try std.testing.expect(oauthOriginAllowedWithSources("kimi", "https://api.kimi.com/coding", .{
        .credential_is_api_key = true,
    }));
    try std.testing.expect(oauthOriginAllowedWithSources("kimi", "https://api.moonshot.ai", .{
        .credential_is_api_key = true,
    }));
    try std.testing.expect(oauthOriginAllowedWithSources("gateway", "https://gateway.test", .{
        .credential_is_api_key = true,
    }));
    try std.testing.expect(!oauthOriginAllowedWithSources("kimi", "https://api.kimi.com/coding", .{}));

    try std.testing.expect(!oauthOriginAllowedWithSources("anthropic", "https://attacker.test", .{
        .credential_is_api_key = true,
    }));
    try std.testing.expect(!oauthOriginAllowedWithSources("github-copilot", "https://attacker.test", .{
        .credential_is_api_key = true,
    }));
    try std.testing.expect(!oauthOriginAllowedWithSources("openai-codex", "https://attacker.test", .{
        .credential_is_api_key = true,
    }));
}

test "storedCredentialIsApiKeyShaped keys on the absent refresh token" {
    try std.testing.expect(storedCredentialIsApiKeyShaped(""));
    try std.testing.expect(!storedCredentialIsApiKeyShaped("refresh-token"));
}

test "oauthOriginAllowedWithSources honours operator-configured overrides" {
    try std.testing.expect(oauthOriginAllowedWithSources("anthropic", "https://proxy.corp.test/anthropic", .{
        .provider = "https://proxy.corp.test",
    }));
    try std.testing.expect(oauthOriginAllowedWithSources("anthropic", "https://proxy.corp.test/anthropic", .{
        .global = "https://proxy.corp.test/v1",
    }));
    try std.testing.expect(!oauthOriginAllowedWithSources("anthropic", "https://other.corp.test", .{
        .provider = "https://proxy.corp.test",
    }));
}

test "oauthOriginAllowedWithSources accepts the GitHub Copilot domain and the stored origin" {
    try std.testing.expect(oauthOriginAllowedWithSources("github-copilot", "https://api.individual.githubcopilot.com", .{}));
    try std.testing.expect(oauthOriginAllowedWithSources("github-copilot", "https://api.acme.githubcopilot.com", .{}));
    try std.testing.expect(oauthOriginAllowedWithSources("github-copilot", "https://githubcopilot.com", .{}));
    try std.testing.expect(!oauthOriginAllowedWithSources("github-copilot", "https://notgithubcopilot.com", .{}));
    try std.testing.expect(!oauthOriginAllowedWithSources("github-copilot", "https://githubcopilot.com.attacker.test", .{}));

    try std.testing.expect(oauthOriginAllowedWithSources("github-copilot", "https://copilot.acme.test", .{
        .credential = "https://copilot.acme.test",
    }));
    try std.testing.expect(!oauthOriginAllowedWithSources("github-copilot", "https://copilot.acme.test", .{}));
    try std.testing.expect(!oauthOriginAllowedWithSources("anthropic", "https://copilot.acme.test", .{
        .credential = "https://copilot.acme.test",
    }));
}

test "oauthOriginAllowedWithSources reads the host rather than the userinfo" {
    try std.testing.expect(!oauthOriginAllowedWithSources("anthropic", "https://api.anthropic.com@attacker.test", .{}));
    try std.testing.expect(!oauthOriginAllowedWithSources("github-copilot", "https://api.githubcopilot.com@attacker.test", .{}));
}

test "oauthOriginAllowedWithSources rejects unparseable base urls" {
    try std.testing.expect(!oauthOriginAllowedWithSources("anthropic", "api.anthropic.com", .{}));
    try std.testing.expect(!oauthOriginAllowedWithSources("anthropic", "https://", .{}));
    try std.testing.expect(!oauthOriginAllowedWithSources("anthropic", "https://api.anthropic.com:notaport", .{}));
}

test "credentialDeclaredBaseUrl reads the login-recorded endpoint" {
    const allocator = std.testing.allocator;

    const found = credentialDeclaredBaseUrl(allocator, "{\"baseUrl\":\"https://api.acme.githubcopilot.com\"}").?;
    defer allocator.free(found);
    try std.testing.expectEqualStrings("https://api.acme.githubcopilot.com", found);

    try std.testing.expect(credentialDeclaredBaseUrl(allocator, "{\"enterpriseUrl\":\"https://gh.acme.test\"}") == null);
    try std.testing.expect(credentialDeclaredBaseUrl(allocator, "{\"baseUrl\":\"\"}") == null);
    try std.testing.expect(credentialDeclaredBaseUrl(allocator, "not json") == null);
    try std.testing.expect(credentialDeclaredBaseUrl(allocator, "[]") == null);
}

test "oauthOriginAllowed reads the credential-declared endpoint" {
    const allocator = std.testing.allocator;
    try std.testing.expect(oauthOriginAllowed(
        allocator,
        "github-copilot",
        "https://copilot.acme.test",
        "gho-refresh",
        "{\"baseUrl\":\"https://copilot.acme.test\"}",
    ));
    try std.testing.expect(!oauthOriginAllowed(
        allocator,
        "github-copilot",
        "https://attacker.test",
        "gho-refresh",
        "{\"baseUrl\":\"https://copilot.acme.test\"}",
    ));
    try std.testing.expect(oauthOriginAllowed(allocator, "anthropic", "", "refresh", null));
}

test "oauthOriginAllowed lets a kimi login keep streaming" {
    const allocator = std.testing.allocator;
    try std.testing.expect(oauthOriginAllowed(allocator, "kimi", "https://api.kimi.com/coding", "", "region:china"));
    try std.testing.expect(oauthOriginAllowed(allocator, "kimi", "https://api.moonshot.ai", "", "region:global"));
    try std.testing.expect(!oauthOriginAllowed(allocator, "anthropic", "https://attacker.test", "", null));
}

test "normalizeKimiRegion accepts catalog region aliases" {
    try std.testing.expectEqualStrings("global", normalizeKimiRegion("global").?);
    try std.testing.expectEqualStrings("global", normalizeKimiRegion(" moonshot ").?);
    try std.testing.expectEqualStrings("china", normalizeKimiRegion("CN").?);
    try std.testing.expectEqualStrings("china", normalizeKimiRegion("coding").?);
    try std.testing.expectEqualStrings("china", normalizeKimiRegion("china").?);
    try std.testing.expect(normalizeKimiRegion("mars") == null);
    try std.testing.expect(normalizeKimiRegion("") == null);
}

test "defaultMaxTokensForRef uses catalog limits for catalog pairs" {
    try std.testing.expectEqual(@as(u32, 16_384), defaultMaxTokensForRef("kimi", "openai-completions"));
    try std.testing.expectEqual(@as(u32, 4_096), defaultMaxTokensForRef("anthropic", "anthropic-messages"));
    try std.testing.expectEqual(@as(u32, 4_096), defaultMaxTokensForRef("openai", "openai-completions"));
    try std.testing.expectEqual(@as(u32, 4_096), defaultMaxTokensForRef("kimi", "openai-responses"));
}
