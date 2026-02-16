const std = @import("std");
const ai_types = @import("ai_types");
const api_registry = @import("api_registry");
const google_generative_api = @import("google_generative_api");

/// Temporary native implementation: routes through Gemini-compatible streaming path.
/// This removes legacy bridge usage while we stabilize Vertex-specific auth/routing.
pub fn streamGoogleVertex(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.StreamOptions,
    allocator: std.mem.Allocator,
) !*ai_types.AssistantMessageEventStream {
    return google_generative_api.streamGoogleGenerativeAI(model, context, options, allocator);
}

pub fn streamSimpleGoogleVertex(
    model: ai_types.Model,
    context: ai_types.Context,
    options: ?ai_types.SimpleStreamOptions,
    allocator: std.mem.Allocator,
) !*ai_types.AssistantMessageEventStream {
    return google_generative_api.streamSimpleGoogleGenerativeAI(model, context, options, allocator);
}

pub fn registerGoogleVertexApiProvider(registry: *api_registry.ApiRegistry) !void {
    try registry.registerApiProvider(.{
        .api = "google-vertex",
        .stream = streamGoogleVertex,
        .stream_simple = streamSimpleGoogleVertex,
    }, null);
}
