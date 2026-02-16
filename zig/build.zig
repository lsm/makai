const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core legacy support modules still required by event_stream generic internals.
    const types_mod = b.createModule(.{
        .root_source_file = b.path("src/types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const event_stream_mod = b.createModule(.{
        .root_source_file = b.path("src/event_stream.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
        },
    });

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

    const ai_types_mod = b.createModule(.{
        .root_source_file = b.path("src/ai_types.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "event_stream", .module = event_stream_mod },
        },
    });

    const api_registry_mod = b.createModule(.{
        .root_source_file = b.path("src/api_registry.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
        },
    });

    const openai_completions_api_mod = b.createModule(.{
        .root_source_file = b.path("src/providers/openai_completions_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "api_registry", .module = api_registry_mod },
            .{ .name = "sse_parser", .module = sse_parser_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
        },
    });

    const anthropic_messages_api_mod = b.createModule(.{
        .root_source_file = b.path("src/providers/anthropic_messages_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "api_registry", .module = api_registry_mod },
            .{ .name = "sse_parser", .module = sse_parser_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
        },
    });

    const openai_responses_api_mod = b.createModule(.{
        .root_source_file = b.path("src/providers/openai_responses_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "api_registry", .module = api_registry_mod },
            .{ .name = "sse_parser", .module = sse_parser_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
        },
    });

    const azure_openai_responses_api_mod = b.createModule(.{
        .root_source_file = b.path("src/providers/azure_openai_responses_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
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
            .{ .name = "api_registry", .module = api_registry_mod },
            .{ .name = "sse_parser", .module = sse_parser_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
        },
    });

    const ollama_api_mod = b.createModule(.{
        .root_source_file = b.path("src/providers/ollama_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ai_types", .module = ai_types_mod },
            .{ .name = "api_registry", .module = api_registry_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
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
            .{ .name = "api_registry", .module = api_registry_mod },
        },
    });

    // Tests
    const types_test = b.addTest(.{ .root_module = types_mod });

    const event_stream_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/event_stream.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "types", .module = types_mod }},
        }),
    });

    const ai_types_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ai_types.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "event_stream", .module = event_stream_mod }},
        }),
    });

    const api_registry_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/api_registry.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ai_types", .module = ai_types_mod }},
        }),
    });

    const stream_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stream.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ai_types", .module = ai_types_mod },
                .{ .name = "api_registry", .module = api_registry_mod },
            },
        }),
    });

    const register_builtins_test = b.addTest(.{ .root_module = register_builtins_mod });

    const openai_completions_api_test = b.addTest(.{ .root_module = openai_completions_api_mod });
    const anthropic_messages_api_test = b.addTest(.{ .root_module = anthropic_messages_api_mod });
    const openai_responses_api_test = b.addTest(.{ .root_module = openai_responses_api_mod });
    const azure_openai_responses_api_test = b.addTest(.{ .root_module = azure_openai_responses_api_mod });
    const google_generative_api_test = b.addTest(.{ .root_module = google_generative_api_mod });
    const ollama_api_test = b.addTest(.{ .root_module = ollama_api_mod });

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
            },
        }),
    });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(types_test).step);
    test_step.dependOn(&b.addRunArtifact(event_stream_test).step);
    test_step.dependOn(&b.addRunArtifact(ai_types_test).step);
    test_step.dependOn(&b.addRunArtifact(api_registry_test).step);
    test_step.dependOn(&b.addRunArtifact(stream_test).step);
    test_step.dependOn(&b.addRunArtifact(register_builtins_test).step);
    test_step.dependOn(&b.addRunArtifact(openai_completions_api_test).step);
    test_step.dependOn(&b.addRunArtifact(anthropic_messages_api_test).step);
    test_step.dependOn(&b.addRunArtifact(openai_responses_api_test).step);
    test_step.dependOn(&b.addRunArtifact(azure_openai_responses_api_test).step);
    test_step.dependOn(&b.addRunArtifact(google_generative_api_test).step);
    test_step.dependOn(&b.addRunArtifact(ollama_api_test).step);

    const test_e2e_ollama_step = b.step("test-e2e-ollama", "Run Ollama E2E test");
    test_e2e_ollama_step.dependOn(&b.addRunArtifact(e2e_ollama_test).step);

    const test_e2e_step = b.step("test-e2e", "Run E2E tests");
    test_e2e_step.dependOn(test_e2e_ollama_step);
}
