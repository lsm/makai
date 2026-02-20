const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Skip tests that do not match filter");

    const ai_types_mod = b.createModule(.{
        .root_source_file = b.path("src/ai_types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const event_stream_mod = b.createModule(.{
        .root_source_file = b.path("src/event_stream.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
        },
    });

    // Update ai_types_mod to import event_stream (circular dependency)
    ai_types_mod.addImport("event_stream", event_stream_mod);

    const sse_parser_mod = b.createModule(.{
        .root_source_file = b.path("src/providers/sse_parser.zig"),
        .target = target,
        .optimize = optimize,
    });

    const json_writer_mod = b.createModule(.{
        .root_source_file = b.path("src/json/writer.zig"),
        .target = target,
        .optimize = optimize,
    });

    const streaming_json_mod = b.createModule(.{
        .root_source_file = b.path("src/streaming_json.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tool_call_tracker_mod = b.createModule(.{
        .root_source_file = b.path("src/tool_call_tracker.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "streaming_json", .module = streaming_json_mod },
            .{ .name = "ai_types", .module = ai_types_mod },
        },
    });

    const api_registry_mod = b.createModule(.{
        .root_source_file = b.path("src/api_registry.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
        },
    });

    const github_copilot_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/oauth/github_copilot.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
        },
    });

    const oauth_anthropic_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/oauth/anthropic.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
        },
    });

    const provider_caps_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/provider_caps.zig"),
        .target = target,
        .optimize = optimize,
    });

    const overflow_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/overflow.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
        },
    });

    const retry_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/retry.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sanitize_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/sanitize.zig"),
        .target = target,
        .optimize = optimize,
    });

    const pre_transform_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/pre_transform.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
        },
    });

    const test_helpers_mod = b.createModule(.{
        .root_source_file = b.path("test/e2e/test_helpers.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "retry", .module = retry_mod },
            .{ .name = "oauth/github_copilot", .module = github_copilot_mod },
            .{ .name = "oauth/anthropic", .module = oauth_anthropic_mod },
        },
    });

    const oauth_pkce_mod = b.createModule(.{
        .root_source_file = b.path("src/oauth/pkce.zig"),
        .target = target,
        .optimize = optimize,
    });

    const openai_completions_api_mod = b.createModule(.{
        .root_source_file = b.path("src/providers/openai_completions_api.zig"),
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
        },
    });

    const anthropic_messages_api_mod = b.createModule(.{
        .root_source_file = b.path("src/providers/anthropic_messages_api.zig"),
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
        },
    });

    const openai_responses_api_mod = b.createModule(.{
        .root_source_file = b.path("src/providers/openai_responses_api.zig"),
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
        },
    });

    const azure_openai_responses_api_mod = b.createModule(.{
        .root_source_file = b.path("src/providers/azure_openai_responses_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "api_registry", .module = api_registry_mod },
            .{ .name = "sse_parser", .module = sse_parser_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
        },
    });

    const google_generative_api_mod = b.createModule(.{
        .root_source_file = b.path("src/providers/google_generative_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "api_registry", .module = api_registry_mod },
            .{ .name = "sse_parser", .module = sse_parser_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "sanitize", .module = sanitize_mod },
            .{ .name = "retry", .module = retry_mod },
            .{ .name = "pre_transform", .module = pre_transform_mod },
        },
    });

    const google_vertex_api_mod = b.createModule(.{
        .root_source_file = b.path("src/providers/google_vertex_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "api_registry", .module = api_registry_mod },
            .{ .name = "sse_parser", .module = sse_parser_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "retry", .module = retry_mod },
            .{ .name = "pre_transform", .module = pre_transform_mod },
        },
    });

    const ollama_api_mod = b.createModule(.{
        .root_source_file = b.path("src/providers/ollama_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "api_registry", .module = api_registry_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "sanitize", .module = sanitize_mod },
            .{ .name = "retry", .module = retry_mod },
            .{ .name = "pre_transform", .module = pre_transform_mod },
        },
    });

    const register_builtins_mod = b.createModule(.{
        .root_source_file = b.path("src/register_builtins.zig"),
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
        .root_source_file = b.path("src/stream.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "api_registry", .module = api_registry_mod },
        },
    });

    const transport_mod = b.createModule(.{
        .root_source_file = b.path("src/transport.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
        },
    });

    const stdio_transport_mod = b.createModule(.{
        .root_source_file = b.path("src/transports/stdio.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "transport", .module = transport_mod },
        },
    });

    const sse_transport_mod = b.createModule(.{
        .root_source_file = b.path("src/transports/sse.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "transport", .module = transport_mod },
            .{ .name = "sse_parser", .module = sse_parser_mod },
            .{ .name = "ai_types", .module = ai_types_mod },
        },
    });

    const websocket_transport_mod = b.createModule(.{
        .root_source_file = b.path("src/transports/websocket.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "transport", .module = transport_mod },
            .{ .name = "ai_types", .module = ai_types_mod },
        },
    });

    const in_process_transport_mod = b.createModule(.{
        .root_source_file = b.path("src/transports/in_process.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "transport", .module = transport_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "ai_types", .module = ai_types_mod },
        },
    });

    const content_partial_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol/content_partial.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
        },
    });

    const partial_serializer_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol/partial_serializer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "content_partial", .module = content_partial_mod },
        },
    });

    const protocol_types_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol/types.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
        },
    });

    const protocol_envelope_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol/envelope.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "transport", .module = transport_mod },
            .{ .name = "protocol_types", .module = protocol_types_mod },
        },
    });

    const partial_reconstructor_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol/partial_reconstructor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "streaming_json", .module = streaming_json_mod },
            .{ .name = "content_partial", .module = content_partial_mod },
        },
    });

    const protocol_server_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol/server.zig"),
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
        },
    });

    const protocol_client_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol/client.zig"),
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
        },
    });

    // Tests
    const event_stream_test = b.addTest(.{ .root_module = event_stream_mod });

    const streaming_json_test = b.addTest(.{ .root_module = streaming_json_mod });

    const ai_types_test = b.addTest(.{ .root_module = ai_types_mod });

    const tool_call_tracker_test = b.addTest(.{ .root_module = tool_call_tracker_mod });

    const api_registry_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/api_registry.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ai_types", .module = ai_types_mod },
                .{ .name = "event_stream", .module = event_stream_mod },
            },
        }),
    });

    const stream_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stream.zig"),
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

    const sanitize_test = b.addTest(.{ .root_module = sanitize_mod });

    const pre_transform_test = b.addTest(.{ .root_module = pre_transform_mod });

    const openai_completions_api_test = b.addTest(.{ .root_module = openai_completions_api_mod });
    const anthropic_messages_api_test = b.addTest(.{ .root_module = anthropic_messages_api_mod });
    const openai_responses_api_test = b.addTest(.{ .root_module = openai_responses_api_mod });
    const azure_openai_responses_api_test = b.addTest(.{ .root_module = azure_openai_responses_api_mod });
    const google_generative_api_test = b.addTest(.{ .root_module = google_generative_api_mod });
    const google_vertex_api_test = b.addTest(.{ .root_module = google_vertex_api_mod });
    const ollama_api_test = b.addTest(.{ .root_module = ollama_api_mod });

    const oauth_pkce_test = b.addTest(.{ .root_module = oauth_pkce_mod });

    const oauth_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/oauth/mod.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pkce", .module = oauth_pkce_mod },
            },
        }),
    });

    const e2e_anthropic_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e/anthropic_api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
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
            .root_source_file = b.path("test/e2e/openai_api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
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
            .root_source_file = b.path("test/e2e/azure_api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
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
            .root_source_file = b.path("test/e2e/google_api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
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
            .root_source_file = b.path("test/e2e/ollama_api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ai_types", .module = ai_types_mod },
                .{ .name = "api_registry", .module = api_registry_mod },
                .{ .name = "register_builtins", .module = register_builtins_mod },
                .{ .name = "stream", .module = stream_mod },
                .{ .name = "test_helpers", .module = test_helpers_mod },
            },
        }),
    });

    const e2e_protocol_fullstack_test_filters: []const []const u8 = if (test_filter) |filter| &[_][]const u8{filter} else &[_][]const u8{};

    const e2e_protocol_fullstack_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e/protocol_fullstack.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ai_types", .module = ai_types_mod },
                .{ .name = "api_registry", .module = api_registry_mod },
                .{ .name = "register_builtins", .module = register_builtins_mod },
                .{ .name = "stream", .module = stream_mod },
                .{ .name = "test_helpers", .module = test_helpers_mod },
                .{ .name = "protocol_server", .module = protocol_server_mod },
                .{ .name = "protocol_client", .module = protocol_client_mod },
                .{ .name = "envelope", .module = protocol_envelope_mod },
                .{ .name = "transport", .module = transport_mod },
                .{ .name = "transports/in_process", .module = in_process_transport_mod },
            },
        }),
        .filters = e2e_protocol_fullstack_test_filters,
    });

    // Protocol E2E tests (mock-based, no real providers needed)
    // Uses protocol_types as the root module to avoid conflict with server's local types.zig import
    const e2e_protocol_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e/protocol.zig"),
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

    const transport_test = b.addTest(.{ .root_module = transport_mod });

    const stdio_transport_test = b.addTest(.{ .root_module = stdio_transport_mod });

    const sse_transport_test = b.addTest(.{ .root_module = sse_transport_mod });

    const websocket_transport_test = b.addTest(.{ .root_module = websocket_transport_mod });

    const in_process_transport_test = b.addTest(.{ .root_module = in_process_transport_mod });

    const content_partial_test = b.addTest(.{ .root_module = content_partial_mod });

    const partial_serializer_test = b.addTest(.{ .root_module = partial_serializer_mod });

    const protocol_types_test = b.addTest(.{ .root_module = protocol_types_mod });

    const protocol_envelope_test = b.addTest(.{ .root_module = protocol_envelope_mod });

    const partial_reconstructor_test = b.addTest(.{ .root_module = partial_reconstructor_mod });

    const protocol_server_test = b.addTest(.{ .root_module = protocol_server_mod });

    const protocol_client_test = b.addTest(.{ .root_module = protocol_client_mod });

    const test_step = b.step("test", "Run tests");
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
    test_step.dependOn(&b.addRunArtifact(content_partial_test).step);
    test_step.dependOn(&b.addRunArtifact(partial_serializer_test).step);
    test_step.dependOn(&b.addRunArtifact(protocol_types_test).step);
    test_step.dependOn(&b.addRunArtifact(protocol_envelope_test).step);
    test_step.dependOn(&b.addRunArtifact(partial_reconstructor_test).step);
    test_step.dependOn(&b.addRunArtifact(protocol_server_test).step);
    test_step.dependOn(&b.addRunArtifact(protocol_client_test).step);
    test_step.dependOn(&b.addRunArtifact(register_builtins_test).step);
    test_step.dependOn(&b.addRunArtifact(github_copilot_test).step);
    test_step.dependOn(&b.addRunArtifact(overflow_test).step);
    test_step.dependOn(&b.addRunArtifact(retry_test).step);
    test_step.dependOn(&b.addRunArtifact(sanitize_test).step);
    test_step.dependOn(&b.addRunArtifact(pre_transform_test).step);
    test_step.dependOn(&b.addRunArtifact(openai_completions_api_test).step);
    test_step.dependOn(&b.addRunArtifact(anthropic_messages_api_test).step);
    test_step.dependOn(&b.addRunArtifact(openai_responses_api_test).step);
    test_step.dependOn(&b.addRunArtifact(azure_openai_responses_api_test).step);
    test_step.dependOn(&b.addRunArtifact(google_generative_api_test).step);
    test_step.dependOn(&b.addRunArtifact(google_vertex_api_test).step);
    test_step.dependOn(&b.addRunArtifact(ollama_api_test).step);
    test_step.dependOn(&b.addRunArtifact(oauth_pkce_test).step);
    test_step.dependOn(&b.addRunArtifact(oauth_test).step);

    // Grouped unit test steps for parallel CI
    const test_unit_core_step = b.step("test-unit-core", "Run core types unit tests");
    test_unit_core_step.dependOn(&b.addRunArtifact(event_stream_test).step);
    test_unit_core_step.dependOn(&b.addRunArtifact(streaming_json_test).step);
    test_unit_core_step.dependOn(&b.addRunArtifact(ai_types_test).step);
    test_unit_core_step.dependOn(&b.addRunArtifact(tool_call_tracker_test).step);

    const test_unit_transport_step = b.step("test-unit-transport", "Run transport layer unit tests");
    test_unit_transport_step.dependOn(&b.addRunArtifact(transport_test).step);
    test_unit_transport_step.dependOn(&b.addRunArtifact(stdio_transport_test).step);
    test_unit_transport_step.dependOn(&b.addRunArtifact(sse_transport_test).step);
    test_unit_transport_step.dependOn(&b.addRunArtifact(websocket_transport_test).step);
    test_unit_transport_step.dependOn(&b.addRunArtifact(in_process_transport_test).step);

    const test_unit_protocol_step = b.step("test-unit-protocol", "Run protocol layer unit tests");
    test_unit_protocol_step.dependOn(&b.addRunArtifact(content_partial_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(partial_serializer_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(protocol_types_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(protocol_envelope_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(partial_reconstructor_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(protocol_server_test).step);
    test_unit_protocol_step.dependOn(&b.addRunArtifact(protocol_client_test).step);

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

    const test_unit_utils_step = b.step("test-unit-utils", "Run utils/oauth unit tests");
    test_unit_utils_step.dependOn(&b.addRunArtifact(github_copilot_test).step);
    test_unit_utils_step.dependOn(&b.addRunArtifact(oauth_pkce_test).step);
    test_unit_utils_step.dependOn(&b.addRunArtifact(oauth_test).step);
    test_unit_utils_step.dependOn(&b.addRunArtifact(overflow_test).step);
    test_unit_utils_step.dependOn(&b.addRunArtifact(retry_test).step);
    test_unit_utils_step.dependOn(&b.addRunArtifact(sanitize_test).step);
    test_unit_utils_step.dependOn(&b.addRunArtifact(pre_transform_test).step);

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

    const test_e2e_protocol_fullstack_step = b.step("test-e2e-protocol-fullstack", "Run Protocol Fullstack E2E tests");
    test_e2e_protocol_fullstack_step.dependOn(&b.addRunArtifact(e2e_protocol_fullstack_test).step);

    const test_e2e_protocol_step = b.step("test-e2e-protocol", "Run Protocol E2E tests (mock-based)");
    test_e2e_protocol_step.dependOn(&b.addRunArtifact(e2e_protocol_test).step);

    const test_e2e_step = b.step("test-e2e", "Run E2E tests");
    test_e2e_step.dependOn(test_e2e_anthropic_step);
    test_e2e_step.dependOn(test_e2e_openai_step);
    test_e2e_step.dependOn(test_e2e_azure_step);
    test_e2e_step.dependOn(test_e2e_google_step);
    test_e2e_step.dependOn(test_e2e_ollama_step);
    test_e2e_step.dependOn(test_e2e_protocol_fullstack_step);
    test_e2e_step.dependOn(test_e2e_protocol_step);

    const test_protocol_types_step = b.step("test-protocol-types", "Run protocol types tests");
    test_protocol_types_step.dependOn(&b.addRunArtifact(protocol_types_test).step);
}
