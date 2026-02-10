const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // libxev dependency (used by http.zig)
    const xev_dep = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });
    const xev_mod = xev_dep.module("xev");

    // Core modules
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

    const provider_mod = b.createModule(.{
        .root_source_file = b.path("src/provider.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
        },
    });

    const json_writer_mod = b.createModule(.{
        .root_source_file = b.path("src/json/writer.zig"),
        .target = target,
        .optimize = optimize,
    });

    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/providers/config.zig"),
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

    _ = b.createModule(.{
        .root_source_file = b.path("src/providers/http.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "xev", .module = xev_mod },
        },
    });

    _ = b.createModule(.{
        .root_source_file = b.path("src/providers/anthropic.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "provider", .module = provider_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "sse_parser", .module = sse_parser_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
        },
    });

    _ = b.createModule(.{
        .root_source_file = b.path("src/providers/openai.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "provider", .module = provider_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "sse_parser", .module = sse_parser_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
        },
    });

    _ = b.createModule(.{
        .root_source_file = b.path("src/providers/ollama.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "provider", .module = provider_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
        },
    });

    // Test modules
    const types_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/types.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const event_stream_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/event_stream.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
            },
        }),
    });

    const provider_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/provider.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "event_stream", .module = event_stream_mod },
            },
        }),
    });

    const json_writer_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/json/writer.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const config_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/providers/config.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
            },
        }),
    });

    const sse_parser_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/providers/sse_parser.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const http_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/providers/http.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "xev", .module = xev_mod },
            },
        }),
    });

    const anthropic_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/providers/anthropic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "event_stream", .module = event_stream_mod },
                .{ .name = "provider", .module = provider_mod },
                .{ .name = "config", .module = config_mod },
                .{ .name = "sse_parser", .module = sse_parser_mod },
                .{ .name = "json_writer", .module = json_writer_mod },
            },
        }),
    });

    const openai_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/providers/openai.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "event_stream", .module = event_stream_mod },
                .{ .name = "provider", .module = provider_mod },
                .{ .name = "config", .module = config_mod },
                .{ .name = "sse_parser", .module = sse_parser_mod },
                .{ .name = "json_writer", .module = json_writer_mod },
            },
        }),
    });

    const ollama_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/providers/ollama.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "event_stream", .module = event_stream_mod },
                .{ .name = "provider", .module = provider_mod },
                .{ .name = "config", .module = config_mod },
                .{ .name = "json_writer", .module = json_writer_mod },
            },
        }),
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(types_test).step);
    test_step.dependOn(&b.addRunArtifact(event_stream_test).step);
    test_step.dependOn(&b.addRunArtifact(provider_test).step);
    test_step.dependOn(&b.addRunArtifact(json_writer_test).step);
    test_step.dependOn(&b.addRunArtifact(config_test).step);
    test_step.dependOn(&b.addRunArtifact(sse_parser_test).step);
    test_step.dependOn(&b.addRunArtifact(http_test).step);
    test_step.dependOn(&b.addRunArtifact(anthropic_test).step);
    test_step.dependOn(&b.addRunArtifact(openai_test).step);
    test_step.dependOn(&b.addRunArtifact(ollama_test).step);
}
