const std = @import("std");

pub const ProviderDefinition = struct {
    id: []const u8,
    name: []const u8,
};

pub const AUTH_PROVIDER_DEFINITIONS = [_]ProviderDefinition{
    .{ .id = "anthropic", .name = "Anthropic" },
    .{ .id = "github-copilot", .name = "GitHub Copilot" },
    .{ .id = "test-fixture", .name = "Test Fixture (CI)" },
};

pub fn findProvider(provider_id: []const u8) ?ProviderDefinition {
    for (AUTH_PROVIDER_DEFINITIONS) |provider| {
        if (std.mem.eql(u8, provider.id, provider_id)) {
            return provider;
        }
    }
    return null;
}

test "findProvider returns configured provider by id" {
    const provider = findProvider("anthropic") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("Anthropic", provider.name);
}
