const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zigzag_dep = b.dependency("zigzag", .{
        .target = target,
        .optimize = optimize,
    });
    const zigzag_mod = zigzag_dep.module("zigzag");

    const ai_types_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/ai_types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const event_stream_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/event_stream.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
        },
    });

    // Update ai_types_mod to import event_stream (circular dependency)
    ai_types_mod.addImport("event_stream", event_stream_mod);

    const sse_parser_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/providers/sse_parser.zig"),
        .target = target,
        .optimize = optimize,
    });

    const json_writer_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/json/writer.zig"),
        .target = target,
        .optimize = optimize,
    });

    const owned_slice_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/owned_slice.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ai_types depends on OwnedSlice for selective ownership wrappers
    ai_types_mod.addImport("owned_slice", owned_slice_mod);

    const string_builder_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/string_builder.zig"),
        .target = target,
        .optimize = optimize,
    });

    const hive_array_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/hive_array.zig"),
        .target = target,
        .optimize = optimize,
    });

    const compat_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/compat/mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sse_parser", .module = sse_parser_mod },
        },
    });

    // Canonical provider base URL resolution shared by the CLI and the
    // provider protocol server (empty client base URLs, env overrides).
    const provider_base_url_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/provider_base_url.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const streaming_json_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/streaming_json.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tool_call_tracker_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/tool_call_tracker.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "streaming_json", .module = streaming_json_mod },
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
        },
    });

    const artifact_store_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/artifact/store.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
        },
    });

    const oauth_storage_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/utils/oauth/storage.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
        },
    });
    if (target.result.os.tag == .macos) {
        oauth_storage_mod.linkFramework("Security", .{});
        oauth_storage_mod.linkFramework("CoreFoundation", .{});
    }

    const refresh_lock_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/utils/oauth/refresh_lock.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const api_registry_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/api_registry.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "oauth/storage", .module = oauth_storage_mod },
        },
    });

    const github_copilot_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/utils/oauth/github_copilot.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const oauth_utils_pkce_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/utils/oauth/pkce.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const oauth_anthropic_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/utils/oauth/anthropic.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "oauth/pkce", .module = oauth_utils_pkce_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const oauth_openai_codex_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/utils/oauth/openai_codex.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "oauth/pkce", .module = oauth_utils_pkce_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const auth_resolver_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/utils/auth_resolver.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "oauth/storage", .module = oauth_storage_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const auth_provider_defs_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/auth/providers.zig"),
        .target = target,
        .optimize = optimize,
    });

    const provider_caps_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/utils/provider_caps.zig"),
        .target = target,
        .optimize = optimize,
    });

    const overflow_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/utils/overflow.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
        },
    });

    const retry_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/utils/retry.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const oom_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/utils/oom.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sanitize_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/utils/sanitize.zig"),
        .target = target,
        .optimize = optimize,
    });

    const pre_transform_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/utils/pre_transform.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "string_builder", .module = string_builder_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const test_helpers_mod = b.createModule(.{
        .root_source_file = b.path("zig/test/e2e/test_helpers.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "retry", .module = retry_mod },
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "oauth/github_copilot", .module = github_copilot_mod },
            .{ .name = "oauth/anthropic", .module = oauth_anthropic_mod },
        },
    });

    const oauth_pkce_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/oauth/pkce.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const openai_completions_api_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/providers/openai_completions_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "api_registry", .module = api_registry_mod },
            .{ .name = "sse_parser", .module = sse_parser_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "github_copilot", .module = github_copilot_mod },
            .{ .name = "tool_call_tracker", .module = tool_call_tracker_mod },
            .{ .name = "provider_caps", .module = provider_caps_mod },
            .{ .name = "sanitize", .module = sanitize_mod },
            .{ .name = "retry", .module = retry_mod },
            .{ .name = "pre_transform", .module = pre_transform_mod },
            .{ .name = "string_builder", .module = string_builder_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const anthropic_messages_api_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/providers/anthropic_messages_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "api_registry", .module = api_registry_mod },
            .{ .name = "sse_parser", .module = sse_parser_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "tool_call_tracker", .module = tool_call_tracker_mod },
            .{ .name = "oauth/storage", .module = oauth_storage_mod },
            .{ .name = "oauth/anthropic", .module = oauth_anthropic_mod },
            .{ .name = "sanitize", .module = sanitize_mod },
            .{ .name = "retry", .module = retry_mod },
            .{ .name = "pre_transform", .module = pre_transform_mod },
            .{ .name = "string_builder", .module = string_builder_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const openai_responses_api_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/providers/openai_responses_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "api_registry", .module = api_registry_mod },
            .{ .name = "sse_parser", .module = sse_parser_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "tool_call_tracker", .module = tool_call_tracker_mod },
            .{ .name = "sanitize", .module = sanitize_mod },
            .{ .name = "retry", .module = retry_mod },
            .{ .name = "pre_transform", .module = pre_transform_mod },
            .{ .name = "string_builder", .module = string_builder_mod },
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "oauth/storage", .module = oauth_storage_mod },
            .{ .name = "oauth/openai_codex", .module = oauth_openai_codex_mod },
        },
    });

    const azure_openai_responses_api_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/providers/azure_openai_responses_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "api_registry", .module = api_registry_mod },
            .{ .name = "sse_parser", .module = sse_parser_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const google_generative_api_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/providers/google_generative_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "api_registry", .module = api_registry_mod },
            .{ .name = "sse_parser", .module = sse_parser_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "sanitize", .module = sanitize_mod },
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "retry", .module = retry_mod },
            .{ .name = "pre_transform", .module = pre_transform_mod },
            .{ .name = "string_builder", .module = string_builder_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const google_vertex_api_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/providers/google_vertex_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "api_registry", .module = api_registry_mod },
            .{ .name = "sse_parser", .module = sse_parser_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "retry", .module = retry_mod },
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "pre_transform", .module = pre_transform_mod },
            .{ .name = "string_builder", .module = string_builder_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const ollama_api_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/providers/ollama_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "api_registry", .module = api_registry_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "sanitize", .module = sanitize_mod },
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "retry", .module = retry_mod },
            .{ .name = "pre_transform", .module = pre_transform_mod },
            .{ .name = "string_builder", .module = string_builder_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const register_builtins_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/register_builtins.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "api_registry", .module = api_registry_mod },
            .{ .name = "anthropic_messages_api", .module = anthropic_messages_api_mod },
            .{ .name = "openai_completions_api", .module = openai_completions_api_mod },
            .{ .name = "openai_responses_api", .module = openai_responses_api_mod },
            .{ .name = "azure_openai_responses_api", .module = azure_openai_responses_api_mod },
            .{ .name = "google_generative_api", .module = google_generative_api_mod },
            .{ .name = "ollama_api", .module = ollama_api_mod },
        },
    });

    const stream_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/stream.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "api_registry", .module = api_registry_mod },
        },
    });

    const transport_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/transport.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
        },
    });

    const stdio_transport_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/transports/stdio.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "transport", .module = transport_mod },
        },
    });

    const sse_transport_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/transports/sse.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "transport", .module = transport_mod },
            .{ .name = "sse_parser", .module = sse_parser_mod },
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const websocket_transport_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/transports/websocket.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "transport", .module = transport_mod },
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const in_process_transport_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/transports/in_process.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "transport", .module = transport_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "oom", .module = oom_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const transport_retry_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/transports/transport_retry.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "transport", .module = transport_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "ai_types", .module = ai_types_mod },
        },
    });

    // Standalone protocol helper modules (no runtime wiring in M-003 scope).
    const protocol_model_ref_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/protocol/model_ref.zig"),
        .target = target,
        .optimize = optimize,
    });
    const protocol_model_catalog_types_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/protocol/model_catalog_types.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "owned_slice", .module = owned_slice_mod },
        },
    });

    // =========================================================================
    // Protocol Provider Modules (protocol/provider/)
    // =========================================================================
    const content_partial_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/protocol/provider/content_partial.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
        },
    });

    const partial_serializer_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/protocol/provider/partial_serializer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "content_partial", .module = content_partial_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const protocol_types_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/protocol/provider/types.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
            .{ .name = "model_catalog_types", .module = protocol_model_catalog_types_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const protocol_envelope_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/protocol/provider/envelope.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "transport", .module = transport_mod },
            .{ .name = "protocol_types", .module = protocol_types_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const partial_reconstructor_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/protocol/provider/partial_reconstructor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "streaming_json", .module = streaming_json_mod },
            .{ .name = "content_partial", .module = content_partial_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
        },
    });

    const protocol_server_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/protocol/provider/server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "api_registry", .module = api_registry_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "content_partial", .module = content_partial_mod },
            .{ .name = "transport", .module = transport_mod },
            .{ .name = "protocol_types", .module = protocol_types_mod },
            .{ .name = "protocol_envelope", .module = protocol_envelope_mod },
            .{ .name = "model_ref", .module = protocol_model_ref_mod },
            .{ .name = "model_catalog_types", .module = protocol_model_catalog_types_mod },
            .{ .name = "hive_array", .module = hive_array_mod },
            .{ .name = "auth_resolver", .module = auth_resolver_mod },
            .{ .name = "oauth/storage", .module = oauth_storage_mod },
            .{ .name = "oauth/refresh_lock", .module = refresh_lock_mod },
            .{ .name = "oom", .module = oom_mod },
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "provider_base_url", .module = provider_base_url_mod },
        },
    });

    const protocol_client_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/protocol/provider/client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "transport", .module = transport_mod },
            .{ .name = "streaming_json", .module = streaming_json_mod },
            .{ .name = "content_partial", .module = content_partial_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "protocol_types", .module = protocol_types_mod },
            .{ .name = "protocol_envelope", .module = protocol_envelope_mod },
            .{ .name = "oom", .module = oom_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "transport_retry", .module = transport_retry_mod },
        },
    });

    const protocol_runtime_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/protocol/provider/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "protocol_server", .module = protocol_server_mod },
            .{ .name = "protocol_client", .module = protocol_client_mod },
            .{ .name = "protocol_envelope", .module = protocol_envelope_mod },
            .{ .name = "transports/in_process", .module = in_process_transport_mod },
        },
    });

    // =========================================================================
    // Protocol Agent Modules (protocol/agent/)
    // =========================================================================
    const protocol_agent_types_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/protocol/agent/types.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol_types", .module = protocol_types_mod },
            .{ .name = "model_catalog_types", .module = protocol_model_catalog_types_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
        },
    });

    const protocol_agent_envelope_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/protocol/agent/envelope.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "agent_types", .module = protocol_agent_types_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "model_catalog_types", .module = protocol_model_catalog_types_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const protocol_agent_server_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/protocol/agent/server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "agent_types", .module = protocol_agent_types_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const protocol_agent_client_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/protocol/agent/client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "agent_types", .module = protocol_agent_types_mod },
            .{ .name = "agent_envelope", .module = protocol_agent_envelope_mod },
            .{ .name = "transport", .module = transport_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const protocol_agent_runtime_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/protocol/agent/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "agent_server", .module = protocol_agent_server_mod },
            .{ .name = "agent_client", .module = protocol_agent_client_mod },
            .{ .name = "agent_envelope", .module = protocol_agent_envelope_mod },
            .{ .name = "transports/in_process", .module = in_process_transport_mod },
        },
    });

    // =========================================================================
    // Protocol Auth Modules (protocol/auth/)
    // =========================================================================
    const protocol_auth_types_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/protocol/auth/types.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol_types", .module = protocol_types_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
        },
    });

    const protocol_auth_envelope_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/protocol/auth/envelope.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "auth_types", .module = protocol_auth_types_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const protocol_auth_server_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/protocol/auth/server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "auth_types", .module = protocol_auth_types_mod },
            .{ .name = "auth/providers", .module = auth_provider_defs_mod },
            .{ .name = "oauth/anthropic", .module = oauth_anthropic_mod },
            .{ .name = "oauth/github_copilot", .module = github_copilot_mod },
            .{ .name = "oauth/openai_codex", .module = oauth_openai_codex_mod },
            .{ .name = "oauth/storage", .module = oauth_storage_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const protocol_auth_runtime_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/protocol/auth/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "auth_server", .module = protocol_auth_server_mod },
            .{ .name = "auth_envelope", .module = protocol_auth_envelope_mod },
            .{ .name = "transports/in_process", .module = in_process_transport_mod },
        },
    });

    // =========================================================================
    // Protocol Tool Modules (protocol/tool/)
    // =========================================================================
    const protocol_tool_types_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/protocol/tool/types.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol_types", .module = protocol_types_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
        },
    });

    const protocol_tool_envelope_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/protocol/tool/envelope.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tool_types", .module = protocol_tool_types_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const protocol_tool_runtime_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/protocol/tool/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tool_envelope", .module = protocol_tool_envelope_mod },
            .{ .name = "transports/in_process", .module = in_process_transport_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const permission_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/tools/permission.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
        },
    });

    // Agent modules
    const agent_types_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/agent/types.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
            .{ .name = "permission", .module = permission_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const protocol_tool_local_runtime_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/protocol/tool/local_runtime.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "agent_types", .module = agent_types_mod },
            .{ .name = "tool_types", .module = protocol_tool_types_mod },
            .{ .name = "tool_envelope", .module = protocol_tool_envelope_mod },
            .{ .name = "tool_runtime", .module = protocol_tool_runtime_mod },
            .{ .name = "transports/in_process", .module = in_process_transport_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
        },
    });

    const agent_loop_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/agent/agent_loop.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "agent_types", .module = agent_types_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
            .{ .name = "permission", .module = permission_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
        },
    });

    const agent_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/agent/mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "agent_types", .module = agent_types_mod },
            .{ .name = "agent_loop", .module = agent_loop_mod },
            .{ .name = "api_registry", .module = api_registry_mod },
            .{ .name = "protocol_server", .module = protocol_server_mod },
            .{ .name = "protocol_client", .module = protocol_client_mod },
            .{ .name = "protocol_runtime", .module = protocol_runtime_mod },
            .{ .name = "tool_local_runtime", .module = protocol_tool_local_runtime_mod },
            .{ .name = "transports/in_process", .module = in_process_transport_mod },
        },
    });

    const agent_provider_protocol_bridge_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/agent/provider_protocol_bridge.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "api_registry", .module = api_registry_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "agent_types", .module = agent_types_mod },
            .{ .name = "protocol_server", .module = protocol_server_mod },
            .{ .name = "protocol_client", .module = protocol_client_mod },
            .{ .name = "protocol_runtime", .module = protocol_runtime_mod },
            .{ .name = "transports/in_process", .module = in_process_transport_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const tui_session_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/tui/session.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "agent", .module = agent_mod },
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
        },
    });

    const tui_config_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/tui/config.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "json/writer", .module = json_writer_mod },
        },
    });

    const tools_common_mod = b.createModule(.{ .root_source_file = b.path("zig/src/tools/common.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ai_types", .module = ai_types_mod }, .{ .name = "agent", .module = agent_mod }, .{ .name = "artifact/store", .module = artifact_store_mod }, .{ .name = "compat", .module = compat_mod } } });
    const tools_process_runner_mod = b.createModule(.{ .root_source_file = b.path("zig/src/tools/process_runner.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ai_types", .module = ai_types_mod }, .{ .name = "compat", .module = compat_mod }, .{ .name = "tools/common", .module = tools_common_mod } } });
    const tools_artifact_mod = b.createModule(.{ .root_source_file = b.path("zig/src/tools/artifact.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ai_types", .module = ai_types_mod }, .{ .name = "agent", .module = agent_mod }, .{ .name = "tools/common", .module = tools_common_mod } } });
    const tools_shell_mod = b.createModule(.{ .root_source_file = b.path("zig/src/tools/shell.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ai_types", .module = ai_types_mod }, .{ .name = "agent", .module = agent_mod }, .{ .name = "tools/common", .module = tools_common_mod }, .{ .name = "tools/process_runner", .module = tools_process_runner_mod } } });
    const tools_file_mod = b.createModule(.{ .root_source_file = b.path("zig/src/tools/file.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ai_types", .module = ai_types_mod }, .{ .name = "agent", .module = agent_mod }, .{ .name = "tools/common", .module = tools_common_mod } } });
    const tools_edit_mod = b.createModule(.{ .root_source_file = b.path("zig/src/tools/edit.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ai_types", .module = ai_types_mod }, .{ .name = "agent", .module = agent_mod }, .{ .name = "tools/common", .module = tools_common_mod } } });
    const tools_hashline_mod = b.createModule(.{ .root_source_file = b.path("zig/src/tools/hashline.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ai_types", .module = ai_types_mod }, .{ .name = "agent", .module = agent_mod }, .{ .name = "tools/common", .module = tools_common_mod }, .{ .name = "protocol_tool_types", .module = protocol_tool_types_mod } } });
    const tools_search_mod = b.createModule(.{ .root_source_file = b.path("zig/src/tools/search.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ai_types", .module = ai_types_mod }, .{ .name = "agent", .module = agent_mod }, .{ .name = "tools/common", .module = tools_common_mod } } });
    const tools_workspace_mod = b.createModule(.{ .root_source_file = b.path("zig/src/tools/workspace.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "ai_types", .module = ai_types_mod }, .{ .name = "agent", .module = agent_mod }, .{ .name = "tools/common", .module = tools_common_mod }, .{ .name = "tools/process_runner", .module = tools_process_runner_mod } } });
    const tools_mcp_bridge_mod = b.createModule(.{ .root_source_file = b.path("zig/src/tools/mcp_bridge.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "compat", .module = compat_mod }, .{ .name = "ai_types", .module = ai_types_mod }, .{ .name = "agent", .module = agent_mod }, .{ .name = "tools/common", .module = tools_common_mod } } });
    const tools_registry_mod = b.createModule(.{ .root_source_file = b.path("zig/src/tools/registry.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "agent", .module = agent_mod }, .{ .name = "tools/shell", .module = tools_shell_mod }, .{ .name = "tools/file", .module = tools_file_mod }, .{ .name = "tools/edit", .module = tools_edit_mod }, .{ .name = "tools/hashline", .module = tools_hashline_mod }, .{ .name = "tools/search", .module = tools_search_mod }, .{ .name = "tools/workspace", .module = tools_workspace_mod }, .{ .name = "tools/artifact", .module = tools_artifact_mod }, .{ .name = "tools/mcp_bridge", .module = tools_mcp_bridge_mod } } });

    const tui_runtime_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/tui/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "agent", .module = agent_mod },
            .{ .name = "agent_types", .module = agent_types_mod },
            .{ .name = "permission", .module = permission_mod },
            .{ .name = "agent_protocol_client", .module = protocol_agent_client_mod },
            .{ .name = "agent_protocol_server", .module = protocol_agent_server_mod },
            .{ .name = "agent_protocol_runtime", .module = protocol_agent_runtime_mod },
            .{ .name = "agent_envelope", .module = protocol_agent_envelope_mod },
            .{ .name = "agent_protocol_types", .module = protocol_agent_types_mod },
            .{ .name = "transport", .module = transport_mod },
            .{ .name = "transports/in_process", .module = in_process_transport_mod },
            .{ .name = "transports/stdio", .module = stdio_transport_mod },
            .{ .name = "transports/sse", .module = sse_transport_mod },
            .{ .name = "transports/websocket", .module = websocket_transport_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "model_ref", .module = protocol_model_ref_mod },
            .{ .name = "tui_session", .module = tui_session_mod },
            .{ .name = "tools/registry", .module = tools_registry_mod },
            .{ .name = "tool_local_runtime", .module = protocol_tool_local_runtime_mod },
            .{ .name = "json/writer", .module = json_writer_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
            .{ .name = "tui_config", .module = tui_config_mod },
        },
    });

    const tui_session_store_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/tui/session_store.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "tui_session", .module = tui_session_mod },
            .{ .name = "tui_runtime", .module = tui_runtime_mod },
            .{ .name = "agent", .module = agent_mod },
            .{ .name = "json/writer", .module = json_writer_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
        },
    });

    const tui_state_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/tui/state.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "agent", .module = agent_mod },
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "tui_runtime", .module = tui_runtime_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
        },
    });

    const tui_commands_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/tui/commands.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "tui_runtime", .module = tui_runtime_mod },
            .{ .name = "tui_state", .module = tui_state_mod },
            .{ .name = "tui_config", .module = tui_config_mod },
            .{ .name = "transports/sse", .module = sse_transport_mod },
        },
    });

    const tui_theme_mod = b.createModule(.{ .root_source_file = b.path("zig/src/tui/theme.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "zigzag", .module = zigzag_mod }, .{ .name = "tui_state", .module = tui_state_mod } } });
    const tui_text_mod = b.createModule(.{ .root_source_file = b.path("zig/src/tui/text.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "zigzag", .module = zigzag_mod }} });
    const tui_render_mod = b.createModule(.{ .root_source_file = b.path("zig/src/tui/render.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "zigzag", .module = zigzag_mod }} });
    const tui_markdown_mod = b.createModule(.{ .root_source_file = b.path("zig/src/tui/markdown.zig"), .target = target, .optimize = optimize, .imports = &.{} });

    const tui_view_transcript_mod = b.createModule(.{ .root_source_file = b.path("zig/src/tui/views/transcript.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "zigzag", .module = zigzag_mod }, .{ .name = "tui_state", .module = tui_state_mod }, .{ .name = "tui_theme", .module = tui_theme_mod }, .{ .name = "tui_text", .module = tui_text_mod }, .{ .name = "tui_markdown", .module = tui_markdown_mod }, .{ .name = "tui_render", .module = tui_render_mod } } });
    const tui_view_composer_mod = b.createModule(.{ .root_source_file = b.path("zig/src/tui/views/composer.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "zigzag", .module = zigzag_mod }, .{ .name = "tui_state", .module = tui_state_mod }, .{ .name = "tui_theme", .module = tui_theme_mod }, .{ .name = "tui_text", .module = tui_text_mod }, .{ .name = "tui_render", .module = tui_render_mod } } });
    const tui_view_status_bar_mod = b.createModule(.{ .root_source_file = b.path("zig/src/tui/views/status_bar.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "zigzag", .module = zigzag_mod }, .{ .name = "tui_state", .module = tui_state_mod }, .{ .name = "tui_theme", .module = tui_theme_mod }, .{ .name = "tui_text", .module = tui_text_mod }, .{ .name = "tui_render", .module = tui_render_mod } } });
    const tui_view_tool_panel_mod = b.createModule(.{ .root_source_file = b.path("zig/src/tui/views/tool_panel.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "zigzag", .module = zigzag_mod }, .{ .name = "ai_types", .module = ai_types_mod }, .{ .name = "agent", .module = agent_mod }, .{ .name = "tui_state", .module = tui_state_mod }, .{ .name = "tui_theme", .module = tui_theme_mod }, .{ .name = "tui_text", .module = tui_text_mod }, .{ .name = "tui_render", .module = tui_render_mod } } });
    const tui_view_telemetry_mod = b.createModule(.{ .root_source_file = b.path("zig/src/tui/views/telemetry.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "zigzag", .module = zigzag_mod }, .{ .name = "tui_state", .module = tui_state_mod }, .{ .name = "tui_theme", .module = tui_theme_mod }, .{ .name = "tui_text", .module = tui_text_mod }, .{ .name = "tui_render", .module = tui_render_mod } } });
    const tui_view_approval_mod = b.createModule(.{ .root_source_file = b.path("zig/src/tui/views/approval.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "zigzag", .module = zigzag_mod }, .{ .name = "tui_state", .module = tui_state_mod }, .{ .name = "tui_theme", .module = tui_theme_mod }, .{ .name = "tui_text", .module = tui_text_mod }, .{ .name = "tui_render", .module = tui_render_mod } } });
    const tui_view_preview_mod = b.createModule(.{ .root_source_file = b.path("zig/src/tui/views/preview.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "zigzag", .module = zigzag_mod }, .{ .name = "tui_state", .module = tui_state_mod }, .{ .name = "tui_theme", .module = tui_theme_mod }, .{ .name = "tui_text", .module = tui_text_mod }, .{ .name = "tui_render", .module = tui_render_mod } } });
    const tui_view_session_picker_mod = b.createModule(.{ .root_source_file = b.path("zig/src/tui/views/session_picker.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "zigzag", .module = zigzag_mod }, .{ .name = "tui_state", .module = tui_state_mod }, .{ .name = "tui_theme", .module = tui_theme_mod }, .{ .name = "tui_text", .module = tui_text_mod }, .{ .name = "tui_render", .module = tui_render_mod } } });
    const tui_view_menu_picker_mod = b.createModule(.{ .root_source_file = b.path("zig/src/tui/views/menu_picker.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "tui_theme", .module = tui_theme_mod }, .{ .name = "tui_text", .module = tui_text_mod }, .{ .name = "tui_render", .module = tui_render_mod } } });

    const tui_login_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/tui/login.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "oauth/storage", .module = oauth_storage_mod },
            .{ .name = "oauth/anthropic", .module = oauth_anthropic_mod },
            .{ .name = "oauth/github_copilot", .module = github_copilot_mod },
            .{ .name = "oauth/openai_codex", .module = oauth_openai_codex_mod },
        },
    });

    const tui_model_catalog_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/tui/model_catalog.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "oauth/storage", .module = oauth_storage_mod },
            .{ .name = "oauth/openai_codex", .module = oauth_openai_codex_mod },
        },
    });

    const tui_app_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/tui/app.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "zigzag", .module = zigzag_mod },
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "api_registry", .module = api_registry_mod },
            .{ .name = "register_builtins", .module = register_builtins_mod },
            .{ .name = "agent", .module = agent_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "tui_runtime", .module = tui_runtime_mod },
            .{ .name = "tui_state", .module = tui_state_mod },
            .{ .name = "tui_commands", .module = tui_commands_mod },
            .{ .name = "tui_login", .module = tui_login_mod },
            .{ .name = "tui_model_catalog", .module = tui_model_catalog_mod },
            .{ .name = "tui_config", .module = tui_config_mod },
            .{ .name = "tui_theme", .module = tui_theme_mod },
            .{ .name = "tui_text", .module = tui_text_mod },
            .{ .name = "oauth/storage", .module = oauth_storage_mod },
            .{ .name = "tui_render", .module = tui_render_mod },
            .{ .name = "tui_session_store", .module = tui_session_store_mod },
            .{ .name = "tui_view_transcript", .module = tui_view_transcript_mod },
            .{ .name = "tui_view_composer", .module = tui_view_composer_mod },
            .{ .name = "tui_view_status_bar", .module = tui_view_status_bar_mod },
            .{ .name = "tui_view_tool_panel", .module = tui_view_tool_panel_mod },
            .{ .name = "tui_view_telemetry", .module = tui_view_telemetry_mod },
            .{ .name = "tui_view_approval", .module = tui_view_approval_mod },
            .{ .name = "tui_view_preview", .module = tui_view_preview_mod },
            .{ .name = "tui_view_session_picker", .module = tui_view_session_picker_mod },
            .{ .name = "tui_view_menu_picker", .module = tui_view_menu_picker_mod },
            .{ .name = "permission", .module = permission_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
            .{ .name = "tools/common", .module = tools_common_mod },
        },
    });

    const tui_tests_mock_provider_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/tui/tests/mock_provider.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "agent", .module = agent_mod },
        },
    });

    const tui_tests_mock_transport_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/tui/tests/mock_transport.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "transport", .module = transport_mod },
        },
    });

    const tui_tests_fixtures_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/tui/tests/fixtures/mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "agent", .module = agent_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
            .{ .name = "tui_tests_mock_provider", .module = tui_tests_mock_provider_mod },
        },
    });

    const tui_tests_scenarios_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/tui/tests/scenario_tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "tui_runtime", .module = tui_runtime_mod },
            .{ .name = "tui_session", .module = tui_session_mod },
            .{ .name = "tui_session_store", .module = tui_session_store_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
            .{ .name = "tui_tests_mock_provider", .module = tui_tests_mock_provider_mod },
            .{ .name = "tui_tests_mock_transport", .module = tui_tests_mock_transport_mod },
            .{ .name = "tui_tests_fixtures", .module = tui_tests_fixtures_mod },
        },
    });

    const tui_tests_e2e_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/tui/tests/e2e_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "zigzag", .module = zigzag_mod },
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "tui_app", .module = tui_app_mod },
            .{ .name = "tui_runtime", .module = tui_runtime_mod },
            .{ .name = "tui_state", .module = tui_state_mod },
            .{ .name = "tui_session", .module = tui_session_mod },
            .{ .name = "tui_session_store", .module = tui_session_store_mod },
            .{ .name = "tui_config", .module = tui_config_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
            .{ .name = "tui_tests_mock_provider", .module = tui_tests_mock_provider_mod },
            .{ .name = "tui_tests_fixtures", .module = tui_tests_fixtures_mod },
        },
    });

    // Tests
    const owned_slice_test = b.addTest(.{ .root_module = owned_slice_mod });
    const string_builder_test = b.addTest(.{ .root_module = string_builder_mod });
    const hive_array_test = b.addTest(.{ .root_module = hive_array_mod });
    const compat_test = b.addTest(.{ .root_module = compat_mod });
    const artifact_store_test = b.addTest(.{ .root_module = artifact_store_mod });
    const provider_base_url_test = b.addTest(.{ .root_module = provider_base_url_mod });

    const event_stream_test = b.addTest(.{ .root_module = event_stream_mod });

    const streaming_json_test = b.addTest(.{ .root_module = streaming_json_mod });

    const ai_types_test = b.addTest(.{ .root_module = ai_types_mod });

    const tool_call_tracker_test = b.addTest(.{ .root_module = tool_call_tracker_mod });

    const api_registry_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/src/api_registry.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ai_types", .module = ai_types_mod },
                .{ .name = "event_stream", .module = event_stream_mod },
                .{ .name = "oauth/storage", .module = oauth_storage_mod },
            },
        }),
    });

    const stream_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/src/stream.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ai_types", .module = ai_types_mod },
                .{ .name = "event_stream", .module = event_stream_mod },
                .{ .name = "api_registry", .module = api_registry_mod },
            },
        }),
    });

    const register_builtins_test = b.addTest(.{ .root_module = register_builtins_mod });

    const github_copilot_test = b.addTest(.{ .root_module = github_copilot_mod });

    const overflow_test = b.addTest(.{ .root_module = overflow_mod });

    const retry_test = b.addTest(.{ .root_module = retry_mod });

    const oom_test = b.addTest(.{ .root_module = oom_mod });

    const sanitize_test = b.addTest(.{ .root_module = sanitize_mod });

    const pre_transform_test = b.addTest(.{ .root_module = pre_transform_mod });

    const auth_provider_defs_test = b.addTest(.{ .root_module = auth_provider_defs_mod });

    const auth_resolver_test = b.addTest(.{ .root_module = auth_resolver_mod });

    const openai_completions_api_test = b.addTest(.{ .root_module = openai_completions_api_mod });
    const anthropic_messages_api_test = b.addTest(.{ .root_module = anthropic_messages_api_mod });
    const openai_responses_api_test = b.addTest(.{ .root_module = openai_responses_api_mod });
    const azure_openai_responses_api_test = b.addTest(.{ .root_module = azure_openai_responses_api_mod });
    const google_generative_api_test = b.addTest(.{ .root_module = google_generative_api_mod });
    const google_vertex_api_test = b.addTest(.{ .root_module = google_vertex_api_mod });
    const ollama_api_test = b.addTest(.{ .root_module = ollama_api_mod });
    const sse_parser_test = b.addTest(.{ .root_module = sse_parser_mod });

    const oauth_pkce_test = b.addTest(.{ .root_module = oauth_pkce_mod });
    const oauth_utils_pkce_test = b.addTest(.{ .root_module = oauth_utils_pkce_mod });
    const oauth_openai_codex_test = b.addTest(.{ .root_module = oauth_openai_codex_mod });

    const refresh_lock_test = b.addTest(.{ .root_module = refresh_lock_mod });

    const oauth_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/src/oauth/mod.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pkce", .module = oauth_pkce_mod },
                .{ .name = "compat", .module = compat_mod },
            },
        }),
    });

    const e2e_anthropic_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/test/e2e/anthropic_api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "compat", .module = compat_mod },
                .{ .name = "ai_types", .module = ai_types_mod },
                .{ .name = "api_registry", .module = api_registry_mod },
                .{ .name = "register_builtins", .module = register_builtins_mod },
                .{ .name = "stream", .module = stream_mod },
                .{ .name = "test_helpers", .module = test_helpers_mod },
            },
        }),
    });

    const e2e_openai_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/test/e2e/openai_api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "compat", .module = compat_mod },
                .{ .name = "ai_types", .module = ai_types_mod },
                .{ .name = "api_registry", .module = api_registry_mod },
                .{ .name = "register_builtins", .module = register_builtins_mod },
                .{ .name = "stream", .module = stream_mod },
                .{ .name = "test_helpers", .module = test_helpers_mod },
                .{ .name = "event_stream", .module = event_stream_mod },
            },
        }),
    });

    const e2e_azure_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/test/e2e/azure_api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "compat", .module = compat_mod },
                .{ .name = "ai_types", .module = ai_types_mod },
                .{ .name = "api_registry", .module = api_registry_mod },
                .{ .name = "register_builtins", .module = register_builtins_mod },
                .{ .name = "stream", .module = stream_mod },
                .{ .name = "test_helpers", .module = test_helpers_mod },
            },
        }),
    });

    const e2e_google_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/test/e2e/google_api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "compat", .module = compat_mod },
                .{ .name = "ai_types", .module = ai_types_mod },
                .{ .name = "api_registry", .module = api_registry_mod },
                .{ .name = "register_builtins", .module = register_builtins_mod },
                .{ .name = "stream", .module = stream_mod },
                .{ .name = "test_helpers", .module = test_helpers_mod },
            },
        }),
    });

    const e2e_ollama_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/test/e2e/ollama_api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "compat", .module = compat_mod },
                .{ .name = "ai_types", .module = ai_types_mod },
                .{ .name = "api_registry", .module = api_registry_mod },
                .{ .name = "register_builtins", .module = register_builtins_mod },
                .{ .name = "stream", .module = stream_mod },
                .{ .name = "test_helpers", .module = test_helpers_mod },
            },
        }),
    });

    // Provider Protocol Fullstack E2E tests - Ollama
    const e2e_provider_protocol_fullstack_ollama_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/test/e2e/provider_protocol_fullstack_ollama.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "compat", .module = compat_mod },
                .{ .name = "ai_types", .module = ai_types_mod },
                .{ .name = "api_registry", .module = api_registry_mod },
                .{ .name = "register_builtins", .module = register_builtins_mod },
                .{ .name = "test_helpers", .module = test_helpers_mod },
                .{ .name = "protocol_server", .module = protocol_server_mod },
                .{ .name = "protocol_client", .module = protocol_client_mod },
                .{ .name = "envelope", .module = protocol_envelope_mod },
                .{ .name = "transports/in_process", .module = in_process_transport_mod },
                .{ .name = "protocol_runtime", .module = protocol_runtime_mod },
            },
        }),
    });

    // Provider Protocol Fullstack E2E tests - GitHub Copilot
    const e2e_provider_protocol_fullstack_github_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/test/e2e/provider_protocol_fullstack_github.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "compat", .module = compat_mod },
                .{ .name = "ai_types", .module = ai_types_mod },
                .{ .name = "api_registry", .module = api_registry_mod },
                .{ .name = "register_builtins", .module = register_builtins_mod },
                .{ .name = "test_helpers", .module = test_helpers_mod },
                .{ .name = "protocol_server", .module = protocol_server_mod },
                .{ .name = "protocol_client", .module = protocol_client_mod },
                .{ .name = "envelope", .module = protocol_envelope_mod },
                .{ .name = "transports/in_process", .module = in_process_transport_mod },
                .{ .name = "protocol_runtime", .module = protocol_runtime_mod },
            },
        }),
    });

    // Protocol E2E tests (mock-based, no real providers needed)
    // Uses protocol_types as the root module to avoid conflict with server's local types.zig import
    const e2e_protocol_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/test/e2e/protocol.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ai_types", .module = ai_types_mod },
                .{ .name = "api_registry", .module = api_registry_mod },
                .{ .name = "event_stream", .module = event_stream_mod },
                .{ .name = "transport", .module = transport_mod },
                .{ .name = "protocol_envelope", .module = protocol_envelope_mod },
                .{ .name = "stdio", .module = stdio_transport_mod },
            },
        }),
    });

    const e2e_tui_websocket_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/test/e2e/tui_websocket.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "compat", .module = compat_mod },
                .{ .name = "ai_types", .module = ai_types_mod },
                .{ .name = "tui_runtime", .module = tui_runtime_mod },
            },
        }),
    });

    // E2E: default base URL resolution on the stdio protocol path (#183).
    // Mock providers, no API keys. OPENAI_BASE_URL is pinned for this binary
    // so the env-override assertion is deterministic on every machine.
    const e2e_provider_base_url_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/test/e2e/provider_base_url.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "compat", .module = compat_mod },
                .{ .name = "ai_types", .module = ai_types_mod },
                .{ .name = "api_registry", .module = api_registry_mod },
                .{ .name = "event_stream", .module = event_stream_mod },
                .{ .name = "protocol_server", .module = protocol_server_mod },
                .{ .name = "protocol_client", .module = protocol_client_mod },
                .{ .name = "envelope", .module = protocol_envelope_mod },
                .{ .name = "protocol_runtime", .module = protocol_runtime_mod },
                .{ .name = "provider_base_url", .module = provider_base_url_mod },
                .{ .name = "transports/in_process", .module = in_process_transport_mod },
            },
        }),
    });
    const e2e_provider_base_url_test_run = b.addRunArtifact(e2e_provider_base_url_test);
    e2e_provider_base_url_test_run.setEnvironmentVariable("OPENAI_BASE_URL", "https://env-override.makai.test/openai");

    const e2e_distributed_fullstack_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/test/e2e/distributed_fullstack.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "compat", .module = compat_mod },
                .{ .name = "ai_types", .module = ai_types_mod },
                .{ .name = "api_registry", .module = api_registry_mod },
                .{ .name = "event_stream", .module = event_stream_mod },
                .{ .name = "agent_types", .module = agent_types_mod },
                .{ .name = "agent_loop", .module = agent_loop_mod },
                .{ .name = "agent_bridge", .module = agent_provider_protocol_bridge_mod },
                .{ .name = "tool_types", .module = protocol_tool_types_mod },
                .{ .name = "tool_envelope", .module = protocol_tool_envelope_mod },
                .{ .name = "tool_runtime", .module = protocol_tool_runtime_mod },
                .{ .name = "tool_local_runtime", .module = protocol_tool_local_runtime_mod },
                .{ .name = "transports/in_process", .module = in_process_transport_mod },
            },
        }),
    });
    // TODO: Remove once Zig 0.16 self-hosted backend handles this test correctly.
    // The distributed fullstack test uses in-process threading + condition variables
    // and currently matches the bridge test backend issue; LLVM handles it fine.
    e2e_distributed_fullstack_test.use_llvm = true;

    const e2e_distributed_fullstack_github_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/test/e2e/distributed_fullstack_github.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "compat", .module = compat_mod },
                .{ .name = "ai_types", .module = ai_types_mod },
                .{ .name = "api_registry", .module = api_registry_mod },
                .{ .name = "register_builtins", .module = register_builtins_mod },
                .{ .name = "test_helpers", .module = test_helpers_mod },
                .{ .name = "agent_types", .module = agent_types_mod },
                .{ .name = "agent_loop", .module = agent_loop_mod },
                .{ .name = "agent_bridge", .module = agent_provider_protocol_bridge_mod },
                .{ .name = "tool_types", .module = protocol_tool_types_mod },
                .{ .name = "tool_envelope", .module = protocol_tool_envelope_mod },
                .{ .name = "tool_runtime", .module = protocol_tool_runtime_mod },
                .{ .name = "transports/in_process", .module = in_process_transport_mod },
            },
        }),
    });

    const transport_test = b.addTest(.{ .root_module = transport_mod });

    const stdio_transport_test = b.addTest(.{ .root_module = stdio_transport_mod });

    const sse_transport_test = b.addTest(.{ .root_module = sse_transport_mod });

    const websocket_transport_test = b.addTest(.{ .root_module = websocket_transport_mod });

    const in_process_transport_test = b.addTest(.{ .root_module = in_process_transport_mod });

    const transport_retry_test = b.addTest(.{ .root_module = transport_retry_mod });

    const protocol_model_ref_test = b.addTest(.{ .root_module = protocol_model_ref_mod });
    const protocol_model_catalog_types_test = b.addTest(.{ .root_module = protocol_model_catalog_types_mod });

    const content_partial_test = b.addTest(.{ .root_module = content_partial_mod });

    const partial_serializer_test = b.addTest(.{ .root_module = partial_serializer_mod });

    const protocol_types_test = b.addTest(.{ .root_module = protocol_types_mod });

    const protocol_envelope_test = b.addTest(.{ .root_module = protocol_envelope_mod });

    const partial_reconstructor_test = b.addTest(.{ .root_module = partial_reconstructor_mod });

    const protocol_server_test = b.addTest(.{ .root_module = protocol_server_mod });

    const protocol_client_test = b.addTest(.{ .root_module = protocol_client_mod });

    const protocol_runtime_test = b.addTest(.{ .root_module = protocol_runtime_mod });

    // Protocol Agent tests
    const protocol_agent_types_test = b.addTest(.{ .root_module = protocol_agent_types_mod });
    const protocol_agent_envelope_test = b.addTest(.{ .root_module = protocol_agent_envelope_mod });
    const protocol_agent_server_test = b.addTest(.{ .root_module = protocol_agent_server_mod });
    const protocol_agent_client_test = b.addTest(.{ .root_module = protocol_agent_client_mod });
    const protocol_agent_runtime_test = b.addTest(.{ .root_module = protocol_agent_runtime_mod });

    // Protocol Auth tests
    const protocol_auth_types_test = b.addTest(.{ .root_module = protocol_auth_types_mod });
    const protocol_auth_envelope_test = b.addTest(.{ .root_module = protocol_auth_envelope_mod });
    const protocol_auth_server_test = b.addTest(.{ .root_module = protocol_auth_server_mod });
    const protocol_auth_runtime_test = b.addTest(.{ .root_module = protocol_auth_runtime_mod });

    // Protocol Tool tests
    const protocol_tool_types_test = b.addTest(.{ .root_module = protocol_tool_types_mod });
    const protocol_tool_envelope_test = b.addTest(.{ .root_module = protocol_tool_envelope_mod });
    const protocol_tool_runtime_test = b.addTest(.{ .root_module = protocol_tool_runtime_mod });
    const protocol_tool_local_runtime_test = b.addTest(.{ .root_module = protocol_tool_local_runtime_mod });

    // Agent tests
    const permission_test = b.addTest(.{ .root_module = permission_mod });

    const agent_types_test = b.addTest(.{ .root_module = agent_types_mod });
    const agent_loop_test = b.addTest(.{ .root_module = agent_loop_mod });

    const agent_mod_test = b.addTest(.{ .root_module = agent_mod });

    const agent_provider_protocol_bridge_test = b.addTest(.{ .root_module = agent_provider_protocol_bridge_mod });
    const tui_session_test = b.addTest(.{ .root_module = tui_session_mod });
    const tui_config_test = b.addTest(.{ .root_module = tui_config_mod });
    const tui_runtime_test = b.addTest(.{ .root_module = tui_runtime_mod });
    const tui_session_store_test = b.addTest(.{ .root_module = tui_session_store_mod });
    const tui_state_test = b.addTest(.{ .root_module = tui_state_mod });
    const tui_commands_test = b.addTest(.{ .root_module = tui_commands_mod });
    const tui_login_test = b.addTest(.{ .root_module = tui_login_mod });
    const tui_model_catalog_test = b.addTest(.{ .root_module = tui_model_catalog_mod });
    const tui_app_test = b.addTest(.{ .root_module = tui_app_mod });
    const tui_theme_test = b.addTest(.{ .root_module = tui_theme_mod });
    const tui_text_test = b.addTest(.{ .root_module = tui_text_mod });
    const tui_render_test = b.addTest(.{ .root_module = tui_render_mod });
    const tui_markdown_test = b.addTest(.{ .root_module = tui_markdown_mod });
    const tui_view_transcript_test = b.addTest(.{ .root_module = tui_view_transcript_mod });
    const tui_view_composer_test = b.addTest(.{ .root_module = tui_view_composer_mod });
    const tui_view_status_bar_test = b.addTest(.{ .root_module = tui_view_status_bar_mod });
    const tui_view_tool_panel_test = b.addTest(.{ .root_module = tui_view_tool_panel_mod });
    const tui_view_telemetry_test = b.addTest(.{ .root_module = tui_view_telemetry_mod });
    const tui_view_approval_test = b.addTest(.{ .root_module = tui_view_approval_mod });
    const tui_view_preview_test = b.addTest(.{ .root_module = tui_view_preview_mod });
    const tui_view_session_picker_test = b.addTest(.{ .root_module = tui_view_session_picker_mod });
    const tui_view_menu_picker_test = b.addTest(.{ .root_module = tui_view_menu_picker_mod });
    const tui_tests_scenarios_test = b.addTest(.{ .root_module = tui_tests_scenarios_mod });
    const tui_tests_e2e_test = b.addTest(.{ .root_module = tui_tests_e2e_mod });
    const tui_tests_mock_transport_test = b.addTest(.{ .root_module = tui_tests_mock_transport_mod });
    const tools_common_test = b.addTest(.{ .root_module = tools_common_mod });
    const tools_process_runner_test = b.addTest(.{ .root_module = tools_process_runner_mod });
    const tools_artifact_test = b.addTest(.{ .root_module = tools_artifact_mod });
    const tools_shell_test = b.addTest(.{ .root_module = tools_shell_mod });
    const tools_file_test = b.addTest(.{ .root_module = tools_file_mod });
    const tools_edit_test = b.addTest(.{ .root_module = tools_edit_mod });
    const tools_hashline_test = b.addTest(.{ .root_module = tools_hashline_mod });
    const tools_search_test = b.addTest(.{ .root_module = tools_search_mod });
    const tools_workspace_test = b.addTest(.{ .root_module = tools_workspace_mod });
    const tools_mcp_bridge_test = b.addTest(.{ .root_module = tools_mcp_bridge_mod });
    const tools_registry_test = b.addTest(.{ .root_module = tools_registry_mod });
    // TODO: Remove once Zig 0.16 self-hosted backend handles this test correctly.
    // The bridge test uses in-process threading + condition variables that trigger
    // a known backend bug; LLVM handles it fine.
    agent_provider_protocol_bridge_test.use_llvm = true;

    const agent_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/test/unit/agent.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "compat", .module = compat_mod },
                .{ .name = "ai_types", .module = ai_types_mod },
                .{ .name = "event_stream", .module = event_stream_mod },
                .{ .name = "agent_types", .module = agent_types_mod },
                .{ .name = "agent_loop", .module = agent_loop_mod },
            },
        }),
    });

    const agent_protocol_chain_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/test/unit/agent_protocol_chain.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "compat", .module = compat_mod },
                .{ .name = "ai_types", .module = ai_types_mod },
                .{ .name = "api_registry", .module = api_registry_mod },
                .{ .name = "event_stream", .module = event_stream_mod },
                .{ .name = "agent_types", .module = agent_types_mod },
                .{ .name = "agent_loop", .module = agent_loop_mod },
                .{ .name = "agent_bridge", .module = agent_provider_protocol_bridge_mod },
                .{ .name = "protocol_agent_server", .module = protocol_agent_server_mod },
                .{ .name = "protocol_agent_client", .module = protocol_agent_client_mod },
                .{ .name = "protocol_agent_runtime", .module = protocol_agent_runtime_mod },
                .{ .name = "transports/in_process", .module = in_process_transport_mod },
            },
        }),
    });

    // Auth CLI wrapper module — drives the auth protocol runtime in-process so
    // `makai auth providers` and `makai auth login` are thin wrappers over the
    // protocol layer (M-013). Lives separately from the CLI entry point so
    // tests can exercise it with in-memory IO without dragging in the entire
    // `makai.zig` surface.
    const auth_cli_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/tools/auth_cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "auth_server", .module = protocol_auth_server_mod },
            .{ .name = "auth_runtime", .module = protocol_auth_runtime_mod },
            .{ .name = "auth_envelope", .module = protocol_auth_envelope_mod },
            .{ .name = "transports/in_process", .module = in_process_transport_mod },
            .{ .name = "owned_slice", .module = owned_slice_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });

    const makai_cli_module = b.createModule(.{
        .root_source_file = b.path("zig/src/tools/makai.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "api_registry", .module = api_registry_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "agent_loop", .module = agent_loop_mod },
            .{ .name = "agent_bridge", .module = agent_mod },
            .{ .name = "transport", .module = transport_mod },
            .{ .name = "model_ref", .module = protocol_model_ref_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "oauth/anthropic", .module = oauth_anthropic_mod },
            .{ .name = "oauth/github_copilot", .module = github_copilot_mod },
            .{ .name = "oauth/storage", .module = oauth_storage_mod },
            .{ .name = "register_builtins", .module = register_builtins_mod },
            .{ .name = "protocol_server", .module = protocol_server_mod },
            .{ .name = "protocol_runtime", .module = protocol_runtime_mod },
            .{ .name = "protocol_envelope", .module = protocol_envelope_mod },
            .{ .name = "agent_server", .module = protocol_agent_server_mod },
            .{ .name = "agent_runtime", .module = protocol_agent_runtime_mod },
            .{ .name = "agent_envelope", .module = protocol_agent_envelope_mod },
            .{ .name = "auth_server", .module = protocol_auth_server_mod },
            .{ .name = "auth_runtime", .module = protocol_auth_runtime_mod },
            .{ .name = "auth_envelope", .module = protocol_auth_envelope_mod },
            .{ .name = "auth/providers", .module = auth_provider_defs_mod },
            .{ .name = "auth_cli", .module = auth_cli_mod },
            .{ .name = "transports/in_process", .module = in_process_transport_mod },
            .{ .name = "stdio", .module = stdio_transport_mod },
            .{ .name = "tui_app", .module = tui_app_mod },
            .{ .name = "tui_model_catalog", .module = tui_model_catalog_mod },
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "provider_base_url", .module = provider_base_url_mod },
        },
    });

    const makai_cli = b.addExecutable(.{
        .name = "makai",
        .root_module = makai_cli_module,
    });
    const makai_cli_test = b.addTest(.{ .root_module = makai_cli_module });
    const makai_cli_test_run = b.addRunArtifact(makai_cli_test);
    const auth_cli_test = b.addTest(.{ .root_module = auth_cli_mod });
    const auth_cli_test_run = b.addRunArtifact(auth_cli_test);
    b.installArtifact(makai_cli);

    const run_cmd = b.addRunArtifact(makai_cli);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the Makai CLI");
    run_step.dependOn(&run_cmd.step);

    const run_tui_cmd = b.addRunArtifact(makai_cli);
    run_tui_cmd.addArg("--tui");
    const run_tui_step = b.step("run-tui", "Run the Makai TUI");
    run_tui_step.dependOn(&run_tui_cmd.step);

    const counting_allocator_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/bench/counting_allocator.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bench_options = b.addOptions();
    bench_options.addOption([]const u8, "git_revision", b.option([]const u8, "git-revision", "Source revision recorded in benchmark reports") orelse "unknown");
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/bench/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sse_parser", .module = sse_parser_mod },
            .{ .name = "protocol_envelope", .module = protocol_envelope_mod },
            .{ .name = "protocol_types", .module = protocol_types_mod },
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "counting_allocator", .module = counting_allocator_mod },
            .{ .name = "compat", .module = compat_mod },
            .{ .name = "bench_options", .module = bench_options.createModule() },
        },
    });
    const bench_exe = b.addExecutable(.{ .name = "makai-bench", .root_module = bench_mod });
    const bench_run = b.addRunArtifact(bench_exe);
    if (b.args) |args| bench_run.addArgs(args);
    const bench_step = b.step("bench", "Run deterministic performance and allocation baselines");
    bench_step.dependOn(&bench_run.step);

    const bench_compare_mod = b.createModule(.{
        .root_source_file = b.path("zig/src/bench/compare.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "compat", .module = compat_mod }},
    });
    const bench_compare_exe = b.addExecutable(.{ .name = "makai-bench-compare", .root_module = bench_compare_mod });
    const bench_compare_run = b.addRunArtifact(bench_compare_exe);
    if (b.args) |args| bench_compare_run.addArgs(args);
    const bench_compare_step = b.step("bench-compare", "Compare compatible benchmark JSON reports");
    bench_compare_step.dependOn(&bench_compare_run.step);

    const counting_allocator_test = b.addTest(.{ .root_module = counting_allocator_mod });
    const bench_compare_test = b.addTest(.{ .root_module = bench_compare_mod });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(counting_allocator_test).step);
    test_step.dependOn(&b.addRunArtifact(bench_compare_test).step);
    test_step.dependOn(&b.addRunArtifact(owned_slice_test).step);
    test_step.dependOn(&b.addRunArtifact(string_builder_test).step);
    test_step.dependOn(&b.addRunArtifact(hive_array_test).step);
    test_step.dependOn(&b.addRunArtifact(compat_test).step);
    test_step.dependOn(&b.addRunArtifact(artifact_store_test).step);
    test_step.dependOn(&b.addRunArtifact(provider_base_url_test).step);
    test_step.dependOn(&b.addRunArtifact(event_stream_test).step);
    test_step.dependOn(&b.addRunArtifact(streaming_json_test).step);
    test_step.dependOn(&b.addRunArtifact(ai_types_test).step);
    test_step.dependOn(&b.addRunArtifact(tool_call_tracker_test).step);
    test_step.dependOn(&b.addRunArtifact(api_registry_test).step);
    test_step.dependOn(&b.addRunArtifact(stream_test).step);
    test_step.dependOn(&b.addRunArtifact(transport_test).step);
    test_step.dependOn(&b.addRunArtifact(stdio_transport_test).step);
    test_step.dependOn(&b.addRunArtifact(sse_transport_test).step);
    test_step.dependOn(&b.addRunArtifact(websocket_transport_test).step);
    test_step.dependOn(&b.addRunArtifact(in_process_transport_test).step);
    test_step.dependOn(&b.addRunArtifact(protocol_model_ref_test).step);
    test_step.dependOn(&b.addRunArtifact(protocol_model_catalog_types_test).step);
    test_step.dependOn(&b.addRunArtifact(content_partial_test).step);
    test_step.dependOn(&b.addRunArtifact(partial_serializer_test).step);
    test_step.dependOn(&b.addRunArtifact(protocol_types_test).step);
    test_step.dependOn(&b.addRunArtifact(protocol_envelope_test).step);
    test_step.dependOn(&b.addRunArtifact(partial_reconstructor_test).step);
    test_step.dependOn(&b.addRunArtifact(protocol_server_test).step);
    test_step.dependOn(&b.addRunArtifact(protocol_client_test).step);
    test_step.dependOn(&b.addRunArtifact(protocol_runtime_test).step);
    test_step.dependOn(&b.addRunArtifact(register_builtins_test).step);
    test_step.dependOn(&b.addRunArtifact(github_copilot_test).step);
    test_step.dependOn(&b.addRunArtifact(overflow_test).step);
    test_step.dependOn(&b.addRunArtifact(retry_test).step);
    test_step.dependOn(&b.addRunArtifact(oom_test).step);
    test_step.dependOn(&b.addRunArtifact(sanitize_test).step);
    test_step.dependOn(&b.addRunArtifact(pre_transform_test).step);
    test_step.dependOn(&b.addRunArtifact(auth_provider_defs_test).step);
    test_step.dependOn(&b.addRunArtifact(auth_resolver_test).step);
    test_step.dependOn(&b.addRunArtifact(openai_completions_api_test).step);
    test_step.dependOn(&b.addRunArtifact(anthropic_messages_api_test).step);
    test_step.dependOn(&b.addRunArtifact(openai_responses_api_test).step);
    test_step.dependOn(&b.addRunArtifact(azure_openai_responses_api_test).step);
    test_step.dependOn(&b.addRunArtifact(google_generative_api_test).step);
    test_step.dependOn(&b.addRunArtifact(google_vertex_api_test).step);
    test_step.dependOn(&b.addRunArtifact(ollama_api_test).step);
    test_step.dependOn(&b.addRunArtifact(oauth_pkce_test).step);
    test_step.dependOn(&b.addRunArtifact(oauth_utils_pkce_test).step);
    test_step.dependOn(&b.addRunArtifact(oauth_openai_codex_test).step);
    test_step.dependOn(&b.addRunArtifact(refresh_lock_test).step);
    test_step.dependOn(&b.addRunArtifact(oauth_test).step);
    test_step.dependOn(&b.addRunArtifact(permission_test).step);
    test_step.dependOn(&b.addRunArtifact(agent_types_test).step);
    test_step.dependOn(&b.addRunArtifact(tools_common_test).step);
    test_step.dependOn(&b.addRunArtifact(tools_artifact_test).step);
    test_step.dependOn(&b.addRunArtifact(tools_file_test).step);
    test_step.dependOn(&b.addRunArtifact(tools_edit_test).step);
    test_step.dependOn(&b.addRunArtifact(tools_hashline_test).step);
    test_step.dependOn(&b.addRunArtifact(tools_shell_test).step);
    test_step.dependOn(&b.addRunArtifact(tools_search_test).step);
    test_step.dependOn(&b.addRunArtifact(tools_workspace_test).step);
    test_step.dependOn(&b.addRunArtifact(tools_mcp_bridge_test).step);
    test_step.dependOn(&b.addRunArtifact(tools_registry_test).step);
    test_step.dependOn(&b.addRunArtifact(agent_loop_test).step);
    test_step.dependOn(&b.addRunArtifact(agent_mod_test).step);
    test_step.dependOn(&b.addRunArtifact(agent_provider_protocol_bridge_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_session_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_config_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_runtime_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_session_store_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_state_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_commands_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_login_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_model_catalog_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_app_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_theme_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_text_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_render_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_markdown_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_view_transcript_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_view_composer_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_view_status_bar_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_view_tool_panel_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_view_telemetry_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_view_approval_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_view_preview_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_view_session_picker_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_view_menu_picker_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_tests_scenarios_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_tests_e2e_test).step);
    test_step.dependOn(&b.addRunArtifact(tui_tests_mock_transport_test).step);
    test_step.dependOn(&b.addRunArtifact(tools_process_runner_test).step);
    test_step.dependOn(&b.addRunArtifact(agent_test).step);
    test_step.dependOn(&b.addRunArtifact(agent_protocol_chain_test).step);
    test_step.dependOn(&b.addRunArtifact(protocol_agent_types_test).step);
    test_step.dependOn(&b.addRunArtifact(protocol_agent_envelope_test).step);
    test_step.dependOn(&b.addRunArtifact(protocol_agent_server_test).step);
    test_step.dependOn(&b.addRunArtifact(protocol_agent_client_test).step);
    test_step.dependOn(&b.addRunArtifact(protocol_agent_runtime_test).step);
    test_step.dependOn(&b.addRunArtifact(protocol_auth_types_test).step);
    test_step.dependOn(&b.addRunArtifact(protocol_auth_envelope_test).step);
    test_step.dependOn(&b.addRunArtifact(protocol_auth_server_test).step);
    test_step.dependOn(&b.addRunArtifact(protocol_auth_runtime_test).step);
    test_step.dependOn(&b.addRunArtifact(protocol_tool_types_test).step);
    test_step.dependOn(&b.addRunArtifact(protocol_tool_envelope_test).step);
    test_step.dependOn(&b.addRunArtifact(protocol_tool_runtime_test).step);
    test_step.dependOn(&b.addRunArtifact(protocol_tool_local_runtime_test).step);
    test_step.dependOn(&auth_cli_test_run.step);
    test_step.dependOn(&makai_cli_test_run.step);

    // Grouped unit test steps for parallel CI
    const test_unit_core_step = b.step("test-unit-core", "Run core types unit tests");
    test_unit_core_step.dependOn(&b.addRunArtifact(event_stream_test).step);
    test_unit_core_step.dependOn(&b.addRunArtifact(streaming_json_test).step);
    test_unit_core_step.dependOn(&b.addRunArtifact(ai_types_test).step);
    test_unit_core_step.dependOn(&b.addRunArtifact(tool_call_tracker_test).step);
    test_unit_core_step.dependOn(&b.addRunArtifact(owned_slice_test).step);
    test_unit_core_step.dependOn(&b.addRunArtifact(string_builder_test).step);
    test_unit_core_step.dependOn(&b.addRunArtifact(hive_array_test).step);
    test_unit_core_step.dependOn(&b.addRunArtifact(compat_test).step);
    test_unit_core_step.dependOn(&b.addRunArtifact(artifact_store_test).step);
    test_unit_core_step.dependOn(&b.addRunArtifact(counting_allocator_test).step);
    test_unit_core_step.dependOn(&b.addRunArtifact(bench_compare_test).step);

    const test_unit_transport_step = b.step("test-unit-transport", "Run transport layer unit tests");
    test_unit_transport_step.dependOn(&b.addRunArtifact(transport_test).step);
    test_unit_transport_step.dependOn(&b.addRunArtifact(stdio_transport_test).step);
    test_unit_transport_step.dependOn(&b.addRunArtifact(sse_transport_test).step);
    test_unit_transport_step.dependOn(&b.addRunArtifact(websocket_transport_test).step);
    test_unit_transport_step.dependOn(&b.addRunArtifact(in_process_transport_test).step);
    test_unit_transport_step.dependOn(&b.addRunArtifact(transport_retry_test).step);

    const test_unit_protocol_step = b.step("test-unit-protocol", "Run protocol layer unit tests");
    test_unit_protocol_step.dependOn(&b.addRunArtifact(provider_base_url_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(protocol_model_ref_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(protocol_model_catalog_types_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(content_partial_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(partial_serializer_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(protocol_types_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(protocol_envelope_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(partial_reconstructor_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(protocol_server_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(protocol_client_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(protocol_runtime_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(protocol_agent_types_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(protocol_agent_envelope_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(protocol_agent_server_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(protocol_agent_client_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(protocol_agent_runtime_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(protocol_auth_types_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(protocol_auth_envelope_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(protocol_auth_server_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(protocol_auth_runtime_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(protocol_tool_types_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(protocol_tool_envelope_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(protocol_tool_runtime_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(protocol_tool_local_runtime_test).step);

    const test_unit_providers_step = b.step("test-unit-providers", "Run provider unit tests");
    test_unit_providers_step.dependOn(&b.addRunArtifact(api_registry_test).step);
    test_unit_providers_step.dependOn(&b.addRunArtifact(stream_test).step);
    test_unit_providers_step.dependOn(&b.addRunArtifact(register_builtins_test).step);
    test_unit_providers_step.dependOn(&b.addRunArtifact(openai_completions_api_test).step);
    test_unit_providers_step.dependOn(&b.addRunArtifact(anthropic_messages_api_test).step);
    test_unit_providers_step.dependOn(&b.addRunArtifact(openai_responses_api_test).step);
    test_unit_providers_step.dependOn(&b.addRunArtifact(azure_openai_responses_api_test).step);
    test_unit_providers_step.dependOn(&b.addRunArtifact(google_generative_api_test).step);
    test_unit_providers_step.dependOn(&b.addRunArtifact(google_vertex_api_test).step);
    test_unit_providers_step.dependOn(&b.addRunArtifact(ollama_api_test).step);
    test_unit_providers_step.dependOn(&b.addRunArtifact(sse_parser_test).step);
    test_unit_providers_step.dependOn(&b.addRunArtifact(auth_provider_defs_test).step);

    const test_unit_utils_step = b.step("test-unit-utils", "Run utils/oauth unit tests");
    test_unit_utils_step.dependOn(&b.addRunArtifact(github_copilot_test).step);
    test_unit_utils_step.dependOn(&b.addRunArtifact(oauth_pkce_test).step);
    test_unit_utils_step.dependOn(&b.addRunArtifact(oauth_utils_pkce_test).step);
    test_unit_utils_step.dependOn(&b.addRunArtifact(oauth_openai_codex_test).step);
    test_unit_utils_step.dependOn(&b.addRunArtifact(refresh_lock_test).step);
    test_unit_utils_step.dependOn(&b.addRunArtifact(oauth_test).step);
    test_unit_utils_step.dependOn(&b.addRunArtifact(overflow_test).step);
    test_unit_utils_step.dependOn(&b.addRunArtifact(retry_test).step);
    test_unit_utils_step.dependOn(&b.addRunArtifact(oom_test).step);
    test_unit_utils_step.dependOn(&b.addRunArtifact(sanitize_test).step);
    test_unit_utils_step.dependOn(&b.addRunArtifact(pre_transform_test).step);
    test_unit_utils_step.dependOn(&b.addRunArtifact(auth_resolver_test).step);

    const test_unit_makai_cli_step = b.step("test-unit-makai-cli", "Run makai CLI unit tests");
    test_unit_makai_cli_step.dependOn(&auth_cli_test_run.step);
    test_unit_makai_cli_step.dependOn(&makai_cli_test_run.step);

    const test_unit_agent_step = b.step("test-unit-agent", "Run agent unit tests");
    test_unit_agent_step.dependOn(&b.addRunArtifact(permission_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(agent_types_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(tools_common_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(tools_artifact_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(tools_file_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(tools_edit_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(tools_hashline_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(tools_shell_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(tools_search_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(tools_workspace_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(tools_mcp_bridge_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(tools_registry_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(agent_loop_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(agent_mod_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(agent_provider_protocol_bridge_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(tui_session_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(tui_config_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(tui_runtime_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(tui_session_store_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(tools_common_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(tools_process_runner_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(tools_shell_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(tools_file_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(tools_edit_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(tools_hashline_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(tools_search_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(tools_workspace_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(tools_mcp_bridge_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(tools_registry_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(agent_test).step);
    test_unit_agent_step.dependOn(&b.addRunArtifact(agent_protocol_chain_test).step);

    const test_unit_agent_types_step = b.step("test-unit-agent-types", "Run agent types unit tests");
    test_unit_agent_types_step.dependOn(&b.addRunArtifact(permission_test).step);
    test_unit_agent_types_step.dependOn(&b.addRunArtifact(agent_types_test).step);

    const test_unit_agent_loop_step = b.step("test-unit-agent-loop", "Run agent loop unit tests");
    test_unit_agent_loop_step.dependOn(&b.addRunArtifact(agent_loop_test).step);

    const test_unit_agent_mod_step = b.step("test-unit-agent-mod", "Run agent module unit tests");
    test_unit_agent_mod_step.dependOn(&b.addRunArtifact(agent_mod_test).step);

    const test_unit_agent_bridge_step = b.step("test-unit-agent-bridge", "Run agent bridge unit tests");
    test_unit_agent_bridge_step.dependOn(&b.addRunArtifact(agent_provider_protocol_bridge_test).step);

    const test_unit_agent_unit_step = b.step("test-unit-agent-unit", "Run agent unit test file");
    test_unit_agent_unit_step.dependOn(&b.addRunArtifact(agent_test).step);

    const test_unit_agent_chain_step = b.step("test-unit-agent-chain", "Run agent protocol chain unit tests");
    test_unit_agent_chain_step.dependOn(&b.addRunArtifact(agent_protocol_chain_test).step);

    const test_unit_tui_step = b.step("test-unit-tui", "Run TUI runtime unit tests");
    test_unit_tui_step.dependOn(&b.addRunArtifact(tui_session_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tui_config_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tui_runtime_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tui_session_store_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tui_state_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tui_commands_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tui_login_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tui_model_catalog_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tui_app_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tui_theme_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tui_text_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tui_render_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tui_markdown_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tui_view_transcript_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tui_view_composer_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tui_view_status_bar_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tui_view_tool_panel_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tui_view_telemetry_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tui_view_approval_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tui_view_preview_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tui_view_session_picker_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tui_view_menu_picker_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tui_tests_scenarios_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tui_tests_e2e_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tui_tests_mock_transport_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tools_common_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tools_process_runner_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tools_shell_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tools_file_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tools_edit_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tools_hashline_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tools_search_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tools_workspace_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tools_mcp_bridge_test).step);
    test_unit_tui_step.dependOn(&b.addRunArtifact(tools_registry_test).step);

    const test_e2e_anthropic_step = b.step("test-e2e-anthropic", "Run Anthropic E2E tests");
    test_e2e_anthropic_step.dependOn(&b.addRunArtifact(e2e_anthropic_test).step);

    const test_e2e_openai_step = b.step("test-e2e-openai", "Run OpenAI E2E tests");
    test_e2e_openai_step.dependOn(&b.addRunArtifact(e2e_openai_test).step);

    const test_e2e_azure_step = b.step("test-e2e-azure", "Run Azure E2E tests");
    test_e2e_azure_step.dependOn(&b.addRunArtifact(e2e_azure_test).step);

    const test_e2e_google_step = b.step("test-e2e-google", "Run Google E2E tests");
    test_e2e_google_step.dependOn(&b.addRunArtifact(e2e_google_test).step);

    const test_e2e_ollama_step = b.step("test-e2e-ollama", "Run Ollama E2E tests");
    test_e2e_ollama_step.dependOn(&b.addRunArtifact(e2e_ollama_test).step);

    const test_e2e_provider_protocol_fullstack_ollama_step = b.step("test-e2e-provider-protocol-fullstack-ollama", "Run Provider Protocol Fullstack E2E tests - Ollama");
    test_e2e_provider_protocol_fullstack_ollama_step.dependOn(&b.addRunArtifact(e2e_provider_protocol_fullstack_ollama_test).step);

    // GitHub Copilot E2E tests
    const e2e_github_copilot_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/test/e2e/github_copilot_api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "compat", .module = compat_mod },
                .{ .name = "ai_types", .module = ai_types_mod },
                .{ .name = "api_registry", .module = api_registry_mod },
                .{ .name = "register_builtins", .module = register_builtins_mod },
                .{ .name = "stream", .module = stream_mod },
                .{ .name = "test_helpers", .module = test_helpers_mod },
            },
        }),
    });

    const test_e2e_provider_protocol_fullstack_github_step = b.step("test-e2e-provider-protocol-fullstack-github", "Run Provider Protocol Fullstack E2E tests - GitHub Copilot");
    test_e2e_provider_protocol_fullstack_github_step.dependOn(&b.addRunArtifact(e2e_provider_protocol_fullstack_github_test).step);

    const test_e2e_github_copilot_step = b.step("test-e2e-github-copilot", "Run GitHub Copilot E2E tests");
    test_e2e_github_copilot_step.dependOn(&b.addRunArtifact(e2e_github_copilot_test).step);

    const test_e2e_protocol_step = b.step("test-e2e-protocol", "Run Protocol E2E tests (mock-based)");
    test_e2e_protocol_step.dependOn(&b.addRunArtifact(e2e_protocol_test).step);
    test_e2e_protocol_step.dependOn(&e2e_provider_base_url_test_run.step);
    test_e2e_protocol_step.dependOn(&b.addRunArtifact(e2e_distributed_fullstack_test).step);

    const test_e2e_tui_websocket_step = b.step("test-e2e-tui-websocket", "Run TUI WebSocket remote backend E2E test (mock-based)");
    test_e2e_tui_websocket_step.dependOn(&b.addRunArtifact(e2e_tui_websocket_test).step);

    const test_e2e_distributed_fullstack_step = b.step("test-e2e-distributed-fullstack", "Run distributed fullstack E2E tests (mock-based)");
    test_e2e_distributed_fullstack_step.dependOn(&b.addRunArtifact(e2e_distributed_fullstack_test).step);

    const test_e2e_distributed_fullstack_github_step = b.step("test-e2e-distributed-fullstack-github", "Run distributed fullstack E2E tests (GitHub Copilot)");
    test_e2e_distributed_fullstack_github_step.dependOn(&b.addRunArtifact(e2e_distributed_fullstack_github_test).step);

    const test_e2e_step = b.step("test-e2e", "Run E2E tests");
    test_e2e_step.dependOn(test_e2e_anthropic_step);
    test_e2e_step.dependOn(test_e2e_openai_step);
    test_e2e_step.dependOn(test_e2e_azure_step);
    test_e2e_step.dependOn(test_e2e_google_step);
    test_e2e_step.dependOn(test_e2e_ollama_step);
    test_e2e_step.dependOn(test_e2e_github_copilot_step);
    test_e2e_step.dependOn(test_e2e_provider_protocol_fullstack_ollama_step);
    test_e2e_step.dependOn(test_e2e_provider_protocol_fullstack_github_step);
    test_e2e_step.dependOn(test_e2e_protocol_step);
    test_e2e_step.dependOn(test_e2e_tui_websocket_step);

    const test_protocol_types_step = b.step("test-protocol-types", "Run protocol types tests");
    test_protocol_types_step.dependOn(&b.addRunArtifact(protocol_types_test).step);

    // Expose modules for consumers via `b.dependency("makai", .{}).module("...")`
    b.modules.put(b.allocator, b.dupe("ai_types"), ai_types_mod) catch @panic("OOM");
    b.modules.put(b.allocator, b.dupe("event_stream"), event_stream_mod) catch @panic("OOM");
    b.modules.put(b.allocator, b.dupe("stream"), stream_mod) catch @panic("OOM");
    b.modules.put(b.allocator, b.dupe("api_registry"), api_registry_mod) catch @panic("OOM");
    b.modules.put(b.allocator, b.dupe("register_builtins"), register_builtins_mod) catch @panic("OOM");
    b.modules.put(b.allocator, b.dupe("transport"), transport_mod) catch @panic("OOM");
    b.modules.put(b.allocator, b.dupe("protocol_runtime"), protocol_runtime_mod) catch @panic("OOM");
    b.modules.put(b.allocator, b.dupe("agent"), agent_mod) catch @panic("OOM");
}
