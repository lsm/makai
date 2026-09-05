//! Canonical provider base URL resolution shared by the CLI and the protocol
//! server.
//!
//! The protocol server defaults empty client-supplied base URLs here (#183)
//! so every client (TS SDK, CLI, wire peers) reaches the vendor endpoint,
//! while the CLI print path resolves non-catalog model refs with the same
//! table. Env overrides follow the common `<PROVIDER>_BASE_URL` conventions
//! so proxies and custom endpoints work; `MAKAI_BASE_URL` overrides
//! everything.

const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");

/// Base URL for canonical refs outside the production catalog (the catalog
/// only covers Codex OAuth + Kimi). Env overrides follow the common
/// <PROVIDER>_BASE_URL conventions so proxies and custom endpoints work;
/// MAKAI_BASE_URL overrides everything.
pub fn defaultBaseUrlForRef(allocator: std.mem.Allocator, provider_id: []const u8, api: []const u8) ![]const u8 {
    return defaultBaseUrlForRefWithRegion(allocator, provider_id, api, null);
}

/// `defaultBaseUrlForRef` with the region stored on a provider's OAuth
/// credentials (Kimi only). `KIMI_REGION` still wins over `stored_kimi_region`,
/// matching the production catalog's precedence (tui/model_catalog.zig).
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

    // KIMI_REGION env beats the stored region; both fall back to china,
    // the catalog default. normalizeKimiRegion returns static literals, so
    // the result outlives the borrowed stored slice.
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

/// Explicit URL overrides for baseUrlForRef (empty = use canonical default).
pub const BaseUrlOverrides = struct {
    global: []const u8 = "",
    anthropic: []const u8 = "",
    openai: []const u8 = "",
    deepseek: []const u8 = "",
    /// Kimi OAuth region ("china" or "global"); selects the region endpoint
    /// exactly like the production catalog does.
    kimi_region: []const u8 = "china",
};

/// Canonical endpoints for the production catalog's provider pairs
/// (tui/model_catalog.zig). The TS SDK rebuilds model descriptors from
/// catalog-issued refs with `base_url: ""`, so these must be defaulted the
/// same way the catalog itself would (#183).
const OPENAI_CODEX_BASE_URL = "https://chatgpt.com/backend-api/codex";
const KIMI_CHINA_BASE_URL = "https://api.kimi.com/coding";
const KIMI_GLOBAL_BASE_URL = "https://api.moonshot.ai";

/// Kimi region alias normalization; mirrors tui/model_catalog.zig (kept in
/// sync rather than importing the whole TUI catalog + OAuth stack here).
/// Returns the static literal "global"/"china", or null for unknown values.
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

/// Provider routes append `/v1/...`; accept the common versioned override
/// form without producing a duplicate `/v1/v1/...` path.
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

/// Pure base-URL resolution: known providers map to their vendor endpoints
/// (overridable); unknown providers get "" — an empty base means "no
/// endpoint" and the request fails before the network, rather than deriving
/// an endpoint from the wire-protocol API type and sending the caller's
/// credentials to an unrelated vendor. Always returns owned memory.
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

/// Owned env value, null when unset or empty (the allocation is freed when
/// the value is empty — callers only own the returned slice).
pub fn envOwnedOrNull(allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
    const value = compat.getEnvVarOwned(allocator, key) catch return null;
    if (value.len == 0) {
        allocator.free(value);
        return null;
    }
    return value;
}

/// Explicit proxy flags for transparentProxyCompat (pure form, testable
/// without mutating the process environment). When `global_base_set` is
/// true the global flag decides; otherwise the provider-specific flag does.
pub const ProxyCompatFlags = struct {
    global_base_set: bool = false,
    global_proxy: bool = false,
    openai_proxy: bool = false,
    deepseek_proxy: bool = false,
    anthropic_proxy: bool = false,
};

/// A custom base URL is OpenAI-compatible by default. Set
/// `<PROVIDER>_BASE_URL_IS_PROXY=true` (or `MAKAI_BASE_URL_IS_PROXY=true`)
/// only when it transparently preserves the canonical vendor API.
pub fn transparentProxyCompat(allocator: std.mem.Allocator, provider_id: []const u8) !?ai_types.OpenAICompatOptions {
    const global_base = try envOwnedOrNull(allocator, "MAKAI_BASE_URL");
    defer if (global_base) |value| allocator.free(value);

    return transparentProxyCompatForFlags(provider_id, .{
        .global_base_set = global_base != null,
        .global_proxy = try envFlag(allocator, "MAKAI_BASE_URL_IS_PROXY"),
        .openai_proxy = try envFlag(allocator, "OPENAI_BASE_URL_IS_PROXY"),
        .deepseek_proxy = try envFlag(allocator, "DEEPSEEK_BASE_URL_IS_PROXY"),
        .anthropic_proxy = try envFlag(allocator, "ANTHROPIC_BASE_URL_IS_PROXY"),
    });
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
        // A transparent DeepSeek proxy preserves the canonical DeepSeek API:
        // token limits via max_tokens (not OpenAI's max_completion_tokens
        // default inherited by a partial compat value) and no tool strict
        // mode, matching the detected-capability path for api.deepseek.com.
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

/// Whether a model family supports reasoning/thinking output, inferred from
/// the provider and model id the way the CLI does for non-catalog refs.
/// Protocol clients (TS SDK) send no capability metadata, so the server
/// rehydrates the same flag before dispatch.
pub fn isReasoningModelRef(provider_id: []const u8, model_id: []const u8) bool {
    if (std.mem.eql(u8, provider_id, "openai") or std.mem.eql(u8, provider_id, "openai-codex")) {
        // The Codex OAuth provider serves the same model families; its
        // catalog entries are all reasoning-capable (o-series / gpt-5*).
        return std.mem.startsWith(u8, model_id, "o1") or
            std.mem.startsWith(u8, model_id, "o3") or
            std.mem.startsWith(u8, model_id, "o4") or
            (std.mem.startsWith(u8, model_id, "gpt-5") and std.mem.indexOf(u8, model_id, "-chat") == null);
    }
    if (std.mem.eql(u8, provider_id, "deepseek")) {
        return std.mem.startsWith(u8, model_id, "deepseek-reasoner");
    }
    if (std.mem.eql(u8, provider_id, "anthropic")) {
        // Thinking arrived with Claude 3.7 Sonnet; every 4.x+ model has it.
        // Pre-3.7 3.x models (claude-3, claude-3-5-*) and the legacy 1/2/v1/
        // instant families do not; unknown future identifiers default to
        // capable so a selected thinking level is never silently dropped.
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

test "baseUrlWithOverrides resolves canonical provider defaults" {
    const allocator = std.testing.allocator;

    const anthropic = try baseUrlWithOverrides(allocator, "anthropic", "anthropic-messages", .{});
    defer allocator.free(anthropic);
    try std.testing.expectEqualStrings("https://api.anthropic.com", anthropic);

    const openai = try baseUrlWithOverrides(allocator, "openai", "openai-completions", .{});
    defer allocator.free(openai);
    // Providers append /v1/chat/completions themselves — the base must NOT
    // include /v1 or requests would target /v1/v1/...
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

    // No endpoint derived from the API type: an unknown provider without an
    // override must fail before the network rather than send credentials to
    // the API vendor's endpoint.
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
    // A declared transparent DeepSeek proxy keeps the canonical DeepSeek
    // max_tokens field; the partial compat value must not inherit OpenAI's
    // max_completion_tokens default.
    const deepseek = transparentProxyCompatForFlags("deepseek", .{ .deepseek_proxy = true });
    try std.testing.expect(deepseek != null);
    try std.testing.expectEqual(@as(?bool, true), deepseek.?.requires_thinking_as_text);
    try std.testing.expectEqual(@as(@TypeOf(deepseek.?.max_tokens_field), .max_tokens), deepseek.?.max_tokens_field);
    try std.testing.expectEqual(@as(?bool, false), deepseek.?.supports_strict_mode);

    // The global proxy flag governs when MAKAI_BASE_URL supplies the endpoint.
    const deepseek_global = transparentProxyCompatForFlags("deepseek", .{
        .global_base_set = true,
        .global_proxy = true,
        .deepseek_proxy = false,
    });
    try std.testing.expect(deepseek_global != null);
    try std.testing.expectEqual(@as(@TypeOf(deepseek_global.?.max_tokens_field), .max_tokens), deepseek_global.?.max_tokens_field);

    // Without any proxy declaration there is no compat override.
    try std.testing.expect(transparentProxyCompatForFlags("deepseek", .{}) == null);

    // OpenAI transparent proxies keep the native field name.
    const openai = transparentProxyCompatForFlags("openai", .{ .openai_proxy = true });
    try std.testing.expect(openai != null);
    try std.testing.expectEqual(@as(@TypeOf(openai.?.max_tokens_field), .max_completion_tokens), openai.?.max_tokens_field);
}

test "baseUrlWithOverrides resolves production catalog pairs" {
    const allocator = std.testing.allocator;

    // Codex OAuth models always use the ChatGPT backend, no override form.
    const codex = try baseUrlWithOverrides(allocator, "openai-codex", "openai-codex-responses", .{});
    defer allocator.free(codex);
    try std.testing.expectEqualStrings(OPENAI_CODEX_BASE_URL, codex);

    // Kimi defaults to the China coding endpoint and switches on region.
    const kimi_china = try baseUrlWithOverrides(allocator, "kimi", "openai-completions", .{});
    defer allocator.free(kimi_china);
    try std.testing.expectEqualStrings(KIMI_CHINA_BASE_URL, kimi_china);

    const kimi_global = try baseUrlWithOverrides(allocator, "kimi", "openai-completions", .{
        .kimi_region = "global",
    });
    defer allocator.free(kimi_global);
    try std.testing.expectEqualStrings(KIMI_GLOBAL_BASE_URL, kimi_global);

    // The global override still wins over every catalog endpoint.
    const kimi_overridden = try baseUrlWithOverrides(allocator, "kimi", "openai-completions", .{
        .global = "https://everywhere.example.com",
    });
    defer allocator.free(kimi_overridden);
    try std.testing.expectEqualStrings("https://everywhere.example.com", kimi_overridden);

    // Catalog pairs stay provider-specific: kimi is not openai, and the
    // codex API name alone must not default the plain openai provider.
    const kimi_wrong_api = try baseUrlWithOverrides(allocator, "kimi", "openai-responses", .{});
    defer allocator.free(kimi_wrong_api);
    try std.testing.expectEqualStrings("", kimi_wrong_api);

    const codex_wrong_provider = try baseUrlWithOverrides(allocator, "openai", "openai-codex-responses", .{});
    defer allocator.free(codex_wrong_provider);
    try std.testing.expectEqualStrings("", codex_wrong_provider);
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
