const std = @import("std");
const types = @import("types");

pub const ApiType = enum { anthropic, openai, ollama, azure, google, bedrock };
pub const InputModality = enum { text, image };

pub const CostPerMillion = struct {
    input: f64 = 0,
    output: f64 = 0,
    cache_read: f64 = 0,
    cache_write: f64 = 0,
};

pub const Model = struct {
    id: []const u8,
    name: []const u8,
    api_type: ApiType,
    provider: []const u8,
    base_url: ?[]const u8 = null,
    reasoning: bool = false,
    input_modalities: []const InputModality = &[_]InputModality{.text},
    cost: CostPerMillion = .{},
    context_window: u32 = 128_000,
    max_tokens: u32 = 4096,

    pub fn supportsXhigh(self: Model) bool {
        // Only certain Anthropic Opus models support xhigh thinking
        return self.reasoning and self.api_type == .anthropic and
            (std.mem.indexOf(u8, self.id, "opus") != null);
    }

    pub fn supportsImages(self: Model) bool {
        for (self.input_modalities) |m| {
            if (m == .image) return true;
        }
        return false;
    }
};

pub const CostInfo = struct {
    input_cost: f64 = 0,
    output_cost: f64 = 0,
    cache_read_cost: f64 = 0,
    cache_write_cost: f64 = 0,

    pub fn total(self: CostInfo) f64 {
        return self.input_cost + self.output_cost + self.cache_read_cost + self.cache_write_cost;
    }
};

pub fn calculateCost(usage: types.Usage, mdl: Model) CostInfo {
    return .{
        .input_cost = @as(f64, @floatFromInt(usage.input_tokens)) * mdl.cost.input / 1_000_000.0,
        .output_cost = @as(f64, @floatFromInt(usage.output_tokens)) * mdl.cost.output / 1_000_000.0,
        .cache_read_cost = @as(f64, @floatFromInt(usage.cache_read_tokens)) * mdl.cost.cache_read / 1_000_000.0,
        .cache_write_cost = @as(f64, @floatFromInt(usage.cache_write_tokens)) * mdl.cost.cache_write / 1_000_000.0,
    };
}

// Comptime input modality arrays
const text_only = [_]InputModality{.text};
const text_and_image = [_]InputModality{ .text, .image };

// Comptime model database
const known_models = [_]Model{
    // Anthropic models
    .{
        .id = "claude-sonnet-4-20250514",
        .name = "Claude Sonnet 4",
        .api_type = .anthropic,
        .provider = "anthropic",
        .reasoning = true,
        .input_modalities = &text_and_image,
        .cost = .{ .input = 3.0, .output = 15.0, .cache_read = 0.30, .cache_write = 3.75 },
        .context_window = 200_000,
        .max_tokens = 16_384,
    },
    .{
        .id = "claude-opus-4-20250514",
        .name = "Claude Opus 4",
        .api_type = .anthropic,
        .provider = "anthropic",
        .reasoning = true,
        .input_modalities = &text_and_image,
        .cost = .{ .input = 15.0, .output = 75.0, .cache_read = 1.50, .cache_write = 18.75 },
        .context_window = 200_000,
        .max_tokens = 32_000,
    },
    .{
        .id = "claude-haiku-3-5-20241022",
        .name = "Claude Haiku 3.5",
        .api_type = .anthropic,
        .provider = "anthropic",
        .reasoning = false,
        .input_modalities = &text_and_image,
        .cost = .{ .input = 0.80, .output = 4.0, .cache_read = 0.08, .cache_write = 1.0 },
        .context_window = 200_000,
        .max_tokens = 8192,
    },
    // OpenAI models
    .{
        .id = "gpt-4o",
        .name = "GPT-4o",
        .api_type = .openai,
        .provider = "openai",
        .reasoning = false,
        .input_modalities = &text_and_image,
        .cost = .{ .input = 2.50, .output = 10.0, .cache_read = 1.25, .cache_write = 2.50 },
        .context_window = 128_000,
        .max_tokens = 16_384,
    },
    .{
        .id = "gpt-4o-mini",
        .name = "GPT-4o Mini",
        .api_type = .openai,
        .provider = "openai",
        .reasoning = false,
        .input_modalities = &text_and_image,
        .cost = .{ .input = 0.15, .output = 0.60, .cache_read = 0.075, .cache_write = 0.15 },
        .context_window = 128_000,
        .max_tokens = 16_384,
    },
    .{
        .id = "o3",
        .name = "O3",
        .api_type = .openai,
        .provider = "openai",
        .reasoning = true,
        .input_modalities = &text_and_image,
        .cost = .{ .input = 10.0, .output = 40.0, .cache_read = 2.50, .cache_write = 10.0 },
        .context_window = 200_000,
        .max_tokens = 100_000,
    },
    .{
        .id = "o3-mini",
        .name = "O3 Mini",
        .api_type = .openai,
        .provider = "openai",
        .reasoning = true,
        .input_modalities = &text_only,
        .cost = .{ .input = 1.10, .output = 4.40, .cache_read = 0.55, .cache_write = 1.10 },
        .context_window = 200_000,
        .max_tokens = 100_000,
    },
    .{
        .id = "o4-mini",
        .name = "O4 Mini",
        .api_type = .openai,
        .provider = "openai",
        .reasoning = true,
        .input_modalities = &text_and_image,
        .cost = .{ .input = 1.10, .output = 4.40, .cache_read = 0.55, .cache_write = 1.10 },
        .context_window = 200_000,
        .max_tokens = 100_000,
    },
    // Azure OpenAI models (same pricing as OpenAI)
    .{
        .id = "azure-gpt-4o",
        .name = "Azure GPT-4o",
        .api_type = .azure,
        .provider = "azure",
        .reasoning = false,
        .input_modalities = &text_and_image,
        .cost = .{ .input = 2.50, .output = 10.0, .cache_read = 1.25, .cache_write = 2.50 },
        .context_window = 128_000,
        .max_tokens = 16_384,
    },
    .{
        .id = "azure-gpt-4o-mini",
        .name = "Azure GPT-4o Mini",
        .api_type = .azure,
        .provider = "azure",
        .reasoning = false,
        .input_modalities = &text_and_image,
        .cost = .{ .input = 0.15, .output = 0.60, .cache_read = 0.075, .cache_write = 0.15 },
        .context_window = 128_000,
        .max_tokens = 16_384,
    },
    .{
        .id = "azure-o3-mini",
        .name = "Azure O3 Mini",
        .api_type = .azure,
        .provider = "azure",
        .reasoning = true,
        .input_modalities = &text_only,
        .cost = .{ .input = 1.10, .output = 4.40, .cache_read = 0.55, .cache_write = 1.10 },
        .context_window = 200_000,
        .max_tokens = 100_000,
    },
    // Google models
    .{
        .id = "gemini-2.5-pro",
        .name = "Gemini 2.5 Pro",
        .api_type = .google,
        .provider = "google",
        .reasoning = true,
        .input_modalities = &text_and_image,
        .cost = .{ .input = 1.25, .output = 5.0, .cache_read = 0.3125, .cache_write = 1.5625 },
        .context_window = 1_000_000,
        .max_tokens = 8192,
    },
    .{
        .id = "gemini-2.5-flash",
        .name = "Gemini 2.5 Flash",
        .api_type = .google,
        .provider = "google",
        .reasoning = true,
        .input_modalities = &text_and_image,
        .cost = .{ .input = 0.075, .output = 0.30, .cache_read = 0.01875, .cache_write = 0.09375 },
        .context_window = 1_000_000,
        .max_tokens = 8192,
    },
    .{
        .id = "gemini-3-pro",
        .name = "Gemini 3 Pro",
        .api_type = .google,
        .provider = "google",
        .reasoning = true,
        .input_modalities = &text_and_image,
        .cost = .{ .input = 2.50, .output = 10.0, .cache_read = 0.625, .cache_write = 3.125 },
        .context_window = 2_000_000,
        .max_tokens = 16_384,
    },
    // Ollama models (local, zero cost)
    .{
        .id = "llama3.1",
        .name = "Llama 3.1",
        .api_type = .ollama,
        .provider = "ollama",
        .reasoning = false,
        .input_modalities = &text_only,
        .cost = .{},
        .context_window = 128_000,
        .max_tokens = 4096,
    },
    .{
        .id = "codellama",
        .name = "Code Llama",
        .api_type = .ollama,
        .provider = "ollama",
        .reasoning = false,
        .input_modalities = &text_only,
        .cost = .{},
        .context_window = 16_384,
        .max_tokens = 4096,
    },
    .{
        .id = "mistral",
        .name = "Mistral",
        .api_type = .ollama,
        .provider = "ollama",
        .reasoning = false,
        .input_modalities = &text_only,
        .cost = .{},
        .context_window = 32_768,
        .max_tokens = 4096,
    },
    // AWS Bedrock models
    .{
        .id = "anthropic.claude-3-5-sonnet-20240620-v1:0",
        .name = "Claude 3.5 Sonnet (Bedrock)",
        .api_type = .bedrock,
        .provider = "bedrock",
        .reasoning = true,
        .input_modalities = &text_and_image,
        .cost = .{ .input = 3.0, .output = 15.0, .cache_read = 0.30, .cache_write = 3.75 },
        .context_window = 200_000,
        .max_tokens = 8192,
    },
    .{
        .id = "anthropic.claude-opus-4-20250514-v1:0",
        .name = "Claude Opus 4 (Bedrock)",
        .api_type = .bedrock,
        .provider = "bedrock",
        .reasoning = true,
        .input_modalities = &text_and_image,
        .cost = .{ .input = 15.0, .output = 75.0, .cache_read = 1.50, .cache_write = 18.75 },
        .context_window = 200_000,
        .max_tokens = 32_000,
    },
};

pub fn getModel(id: []const u8) ?Model {
    for (known_models) |model| {
        if (std.mem.eql(u8, model.id, id)) {
            return model;
        }
    }
    return null;
}

pub fn getModels() []const Model {
    return &known_models;
}

pub const ModelRegistry = struct {
    models: std.StringHashMap(Model),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ModelRegistry {
        return .{
            .models = std.StringHashMap(Model).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ModelRegistry) void {
        var it = self.models.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.models.deinit();
    }

    pub fn get(self: *const ModelRegistry, id: []const u8) ?Model {
        // Check custom models first, then fall through to known_models
        if (self.models.get(id)) |m| return m;
        return getModel(id);
    }

    pub fn register(self: *ModelRegistry, mdl: Model) !void {
        const key = try self.allocator.dupe(u8, mdl.id);
        errdefer self.allocator.free(key);
        try self.models.put(key, mdl);
    }
};

// Tests

test "getModel returns known model" {
    const model = getModel("gpt-4o");
    try std.testing.expect(model != null);
    const m = model.?;
    try std.testing.expectEqualStrings("gpt-4o", m.id);
    try std.testing.expectEqualStrings("GPT-4o", m.name);
    try std.testing.expectEqual(ApiType.openai, m.api_type);
    try std.testing.expectEqualStrings("openai", m.provider);
    try std.testing.expectEqual(false, m.reasoning);
    try std.testing.expectEqual(@as(u32, 128_000), m.context_window);
    try std.testing.expectEqual(@as(u32, 16_384), m.max_tokens);
    try std.testing.expectEqual(@as(f64, 2.50), m.cost.input);
    try std.testing.expectEqual(@as(f64, 10.0), m.cost.output);
}

test "getModel returns null for unknown" {
    const model = getModel("nonexistent");
    try std.testing.expectEqual(@as(?Model, null), model);
}

test "getModels returns all known models" {
    const models = getModels();
    try std.testing.expectEqual(@as(usize, 19), models.len);
}

test "calculateCost basic" {
    const usage = types.Usage{
        .input_tokens = 1000,
        .output_tokens = 0,
        .cache_read_tokens = 0,
        .cache_write_tokens = 0,
    };
    const model = getModel("gpt-4o").?;
    const cost = calculateCost(usage, model);

    // 1000 tokens * 2.50 / 1_000_000 = 0.0025
    try std.testing.expectApproxEqAbs(@as(f64, 0.0025), cost.input_cost, 0.000001);
    try std.testing.expectEqual(@as(f64, 0), cost.output_cost);
    try std.testing.expectEqual(@as(f64, 0), cost.cache_read_cost);
    try std.testing.expectEqual(@as(f64, 0), cost.cache_write_cost);
}

test "calculateCost with cache tokens" {
    const usage = types.Usage{
        .input_tokens = 1000,
        .output_tokens = 500,
        .cache_read_tokens = 2000,
        .cache_write_tokens = 1500,
    };
    const model = getModel("gpt-4o").?;
    const cost = calculateCost(usage, model);

    // input: 1000 * 2.50 / 1_000_000 = 0.0025
    try std.testing.expectApproxEqAbs(@as(f64, 0.0025), cost.input_cost, 0.000001);
    // output: 500 * 10.0 / 1_000_000 = 0.005
    try std.testing.expectApproxEqAbs(@as(f64, 0.005), cost.output_cost, 0.000001);
    // cache_read: 2000 * 1.25 / 1_000_000 = 0.0025
    try std.testing.expectApproxEqAbs(@as(f64, 0.0025), cost.cache_read_cost, 0.000001);
    // cache_write: 1500 * 2.50 / 1_000_000 = 0.00375
    try std.testing.expectApproxEqAbs(@as(f64, 0.00375), cost.cache_write_cost, 0.000001);
}

test "CostInfo total" {
    const cost = CostInfo{
        .input_cost = 0.0025,
        .output_cost = 0.005,
        .cache_read_cost = 0.0025,
        .cache_write_cost = 0.00375,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 0.01375), cost.total(), 0.000001);
}

test "supportsXhigh" {
    const opus = getModel("claude-opus-4-20250514").?;
    try std.testing.expect(opus.supportsXhigh());

    const sonnet = getModel("claude-sonnet-4-20250514").?;
    try std.testing.expect(!sonnet.supportsXhigh());

    const gpt4o = getModel("gpt-4o").?;
    try std.testing.expect(!gpt4o.supportsXhigh());

    const o3 = getModel("o3").?;
    try std.testing.expect(!o3.supportsXhigh());
}

test "supportsImages" {
    const gpt4o = getModel("gpt-4o").?;
    try std.testing.expect(gpt4o.supportsImages());

    const llama = getModel("llama3.1").?;
    try std.testing.expect(!llama.supportsImages());

    const o3mini = getModel("o3-mini").?;
    try std.testing.expect(!o3mini.supportsImages());

    const o4mini = getModel("o4-mini").?;
    try std.testing.expect(o4mini.supportsImages());
}

test "ModelRegistry custom model" {
    var registry = ModelRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const custom = Model{
        .id = "custom-model",
        .name = "Custom Model",
        .api_type = .openai,
        .provider = "custom",
        .reasoning = true,
        .cost = .{ .input = 5.0, .output = 20.0, .cache_read = 0, .cache_write = 0 },
        .context_window = 50_000,
        .max_tokens = 8000,
    };

    try registry.register(custom);

    const retrieved = registry.get("custom-model");
    try std.testing.expect(retrieved != null);
    const m = retrieved.?;
    try std.testing.expectEqualStrings("custom-model", m.id);
    try std.testing.expectEqualStrings("Custom Model", m.name);
    try std.testing.expectEqual(ApiType.openai, m.api_type);
    try std.testing.expectEqual(true, m.reasoning);
    try std.testing.expectEqual(@as(f64, 5.0), m.cost.input);
}

test "ModelRegistry fallthrough to known" {
    var registry = ModelRegistry.init(std.testing.allocator);
    defer registry.deinit();

    // Empty registry should still find known models
    const model = registry.get("gpt-4o");
    try std.testing.expect(model != null);
    try std.testing.expectEqualStrings("gpt-4o", model.?.id);
}

test "Model default values" {
    const minimal = Model{
        .id = "test",
        .name = "Test",
        .api_type = .ollama,
        .provider = "test",
    };

    try std.testing.expectEqual(false, minimal.reasoning);
    try std.testing.expectEqual(@as(usize, 1), minimal.input_modalities.len);
    try std.testing.expectEqual(InputModality.text, minimal.input_modalities[0]);
    try std.testing.expectEqual(@as(f64, 0), minimal.cost.input);
    try std.testing.expectEqual(@as(f64, 0), minimal.cost.output);
    try std.testing.expectEqual(@as(f64, 0), minimal.cost.cache_read);
    try std.testing.expectEqual(@as(f64, 0), minimal.cost.cache_write);
    try std.testing.expectEqual(@as(u32, 128_000), minimal.context_window);
    try std.testing.expectEqual(@as(u32, 4096), minimal.max_tokens);
    try std.testing.expectEqual(@as(?[]const u8, null), minimal.base_url);
}
