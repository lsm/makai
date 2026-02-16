const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const std = @import("std");

/// Native Bedrock API provider placeholder.
/// Legacy bridge removed; full AWS event-stream implementation pending in this interface layer.
pub fn streamBedrockConverseStream(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !*ai_types.AssistantMessageEventStream {
    _ = model;
    _ = context;
    _ = options;
    _ = allocator;
    return error.NotImplemented;
}

pub fn streamSimpleBedrockConverseStream(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) !*ai_types.AssistantMessageEventStream {
    _ = model;
    _ = context;
    _ = options;
    _ = allocator;
    return error.NotImplemented;
}

pub fn registerBedrockConverseStreamApiProvider(registry: *api_registry.ApiRegistry) !void {
    try registry.registerApiProvider(.{
        .api = "bedrock-converse-stream",
        .stream = streamBedrockConverseStream,
        .stream_simple = streamSimpleBedrockConverseStream,
    }, null);
}
