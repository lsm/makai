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

    const model_mod = b.createModule(.{
        .root_source_file = b.path("src/model.zig"),
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
        .root_source_file = b.path("src/utils/retry.zig"),
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

    const aws_sigv4_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/aws_sigv4.zig"),
        .target = target,
        .optimize = optimize,
    });

    // OAuth modules
    const oauth_pkce_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/oauth/pkce.zig"),
        .target = target,
        .optimize = optimize,
    });

    const oauth_callback_server_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/oauth/callback_server.zig"),
        .target = target,
        .optimize = optimize,
    });

    const oauth_anthropic_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/oauth/anthropic.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pkce", .module = oauth_pkce_mod },
        },
    });

    const oauth_github_copilot_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/oauth/github_copilot.zig"),
        .target = target,
        .optimize = optimize,
    });

    const oauth_google_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/oauth/google.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pkce", .module = oauth_pkce_mod },
            .{ .name = "callback_server", .module = oauth_callback_server_mod },
        },
    });

    const oauth_storage_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/oauth/storage.zig"),
        .target = target,
        .optimize = optimize,
    });

    _ = b.createModule(.{
        .root_source_file = b.path("src/utils/oauth.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "oauth/pkce", .module = oauth_pkce_mod },
            .{ .name = "oauth/callback_server", .module = oauth_callback_server_mod },
            .{ .name = "oauth/anthropic", .module = oauth_anthropic_mod },
            .{ .name = "oauth/github_copilot", .module = oauth_github_copilot_mod },
            .{ .name = "oauth/google", .module = oauth_google_mod },
            .{ .name = "oauth/storage", .module = oauth_storage_mod },
        },
    });

    const anthropic_mod = b.createModule(.{
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

    const openai_mod = b.createModule(.{
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

    const ollama_mod = b.createModule(.{
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

    const azure_mod = b.createModule(.{
        .root_source_file = b.path("src/providers/azure.zig"),
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

    const google_shared_mod = b.createModule(.{
        .root_source_file = b.path("src/providers/google_shared.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
        },
    });

    const google_mod = b.createModule(.{
        .root_source_file = b.path("src/providers/google.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "provider", .module = provider_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "sse_parser", .module = sse_parser_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "google_shared", .module = google_shared_mod },
        },
    });

    const google_vertex_mod = b.createModule(.{
        .root_source_file = b.path("src/providers/google_vertex.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "provider", .module = provider_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "sse_parser", .module = sse_parser_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "google_shared", .module = google_shared_mod },
            .{ .name = "google", .module = google_mod },
        },
    });

    const bedrock_mod = b.createModule(.{
        .root_source_file = b.path("src/providers/bedrock.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "provider", .module = provider_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
            .{ .name = "aws_sigv4", .module = aws_sigv4_mod },
        },
    });

    _ = b.createModule(.{
        .root_source_file = b.path("src/simple_stream.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "model", .module = model_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "provider", .module = provider_mod },
            .{ .name = "anthropic", .module = anthropic_mod },
            .{ .name = "openai", .module = openai_mod },
            .{ .name = "ollama", .module = ollama_mod },
            .{ .name = "azure", .module = azure_mod },
            .{ .name = "google", .module = google_mod },
            .{ .name = "google_vertex", .module = google_vertex_mod },
        },
    });

    // Transport modules
    const transport_mod = b.createModule(.{
        .root_source_file = b.path("src/transport.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "json_writer", .module = json_writer_mod },
        },
    });

    _ = b.createModule(.{
        .root_source_file = b.path("src/transports/stdio.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "transport", .module = transport_mod },
        },
    });

    _ = b.createModule(.{
        .root_source_file = b.path("src/transports/sse.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "transport", .module = transport_mod },
            .{ .name = "sse_parser", .module = sse_parser_mod },
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

    const model_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/model.zig"),
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

    const retry_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/utils/retry.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const aws_sigv4_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/utils/aws_sigv4.zig"),
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

    const azure_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/providers/azure.zig"),
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

    const google_shared_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/providers/google_shared.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "json_writer", .module = json_writer_mod },
            },
        }),
    });

    const google_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/providers/google.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "event_stream", .module = event_stream_mod },
                .{ .name = "provider", .module = provider_mod },
                .{ .name = "config", .module = config_mod },
                .{ .name = "sse_parser", .module = sse_parser_mod },
                .{ .name = "json_writer", .module = json_writer_mod },
                .{ .name = "google_shared", .module = google_shared_mod },
            },
        }),
    });

    const google_vertex_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/providers/google_vertex.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "event_stream", .module = event_stream_mod },
                .{ .name = "provider", .module = provider_mod },
                .{ .name = "config", .module = config_mod },
                .{ .name = "sse_parser", .module = sse_parser_mod },
                .{ .name = "json_writer", .module = json_writer_mod },
                .{ .name = "google_shared", .module = google_shared_mod },
                .{ .name = "google", .module = google_mod },
            },
        }),
    });

    const bedrock_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/providers/bedrock.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "event_stream", .module = event_stream_mod },
                .{ .name = "provider", .module = provider_mod },
                .{ .name = "config", .module = config_mod },
                .{ .name = "json_writer", .module = json_writer_mod },
                .{ .name = "aws_sigv4", .module = aws_sigv4_mod },
            },
        }),
    });

    const transport_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/transport.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "event_stream", .module = event_stream_mod },
                .{ .name = "json_writer", .module = json_writer_mod },
            },
        }),
    });

    const stdio_transport_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/transports/stdio.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "transport", .module = transport_mod },
            },
        }),
    });

    const sse_transport_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/transports/sse.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "transport", .module = transport_mod },
                .{ .name = "sse_parser", .module = sse_parser_mod },
            },
        }),
    });

    const simple_stream_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/simple_stream.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "config", .module = config_mod },
                .{ .name = "model", .module = model_mod },
                .{ .name = "event_stream", .module = event_stream_mod },
                .{ .name = "provider", .module = provider_mod },
                .{ .name = "anthropic", .module = anthropic_mod },
                .{ .name = "openai", .module = openai_mod },
                .{ .name = "ollama", .module = ollama_mod },
                .{ .name = "azure", .module = azure_mod },
            },
        }),
    });

    // OAuth tests
    const oauth_pkce_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/utils/oauth/pkce.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const oauth_callback_server_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/utils/oauth/callback_server.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const oauth_anthropic_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/utils/oauth/anthropic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pkce", .module = oauth_pkce_mod },
            },
        }),
    });

    const oauth_github_copilot_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/utils/oauth/github_copilot.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const oauth_google_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/utils/oauth/google.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pkce", .module = oauth_pkce_mod },
                .{ .name = "callback_server", .module = oauth_callback_server_mod },
            },
        }),
    });

    const oauth_storage_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/utils/oauth/storage.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const oauth_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/utils/oauth.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "oauth/pkce", .module = oauth_pkce_mod },
                .{ .name = "oauth/callback_server", .module = oauth_callback_server_mod },
                .{ .name = "oauth/anthropic", .module = oauth_anthropic_mod },
                .{ .name = "oauth/github_copilot", .module = oauth_github_copilot_mod },
                .{ .name = "oauth/google", .module = oauth_google_mod },
                .{ .name = "oauth/storage", .module = oauth_storage_mod },
            },
        }),
    });

    // E2E tests
    const test_helpers_mod = b.createModule(.{
        .root_source_file = b.path("test/e2e/test_helpers.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
        },
    });

    const e2e_anthropic_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e/anthropic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "config", .module = config_mod },
                .{ .name = "anthropic", .module = anthropic_mod },
                .{ .name = "test_helpers", .module = test_helpers_mod },
            },
        }),
    });
    e2e_anthropic_test.root_module.addOptions("build_options", b.addOptions());

    const e2e_openai_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e/openai.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "config", .module = config_mod },
                .{ .name = "openai", .module = openai_mod },
                .{ .name = "test_helpers", .module = test_helpers_mod },
            },
        }),
    });

    const e2e_ollama_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e/ollama.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "config", .module = config_mod },
                .{ .name = "ollama", .module = ollama_mod },
                .{ .name = "test_helpers", .module = test_helpers_mod },
            },
        }),
    });

    const e2e_azure_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e/azure.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "config", .module = config_mod },
                .{ .name = "azure", .module = azure_mod },
                .{ .name = "test_helpers", .module = test_helpers_mod },
            },
        }),
    });

    const e2e_google_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e/google.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "config", .module = config_mod },
                .{ .name = "google", .module = google_mod },
                .{ .name = "test_helpers", .module = test_helpers_mod },
            },
        }),
    });

    const e2e_google_vertex_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e/google_vertex.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "config", .module = config_mod },
                .{ .name = "google", .module = google_mod },
                .{ .name = "google_vertex", .module = google_vertex_mod },
                .{ .name = "test_helpers", .module = test_helpers_mod },
            },
        }),
    });

    const e2e_bedrock_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e/bedrock.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "config", .module = config_mod },
                .{ .name = "bedrock", .module = bedrock_mod },
                .{ .name = "test_helpers", .module = test_helpers_mod },
            },
        }),
    });

    const e2e_abort_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e/abort.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "config", .module = config_mod },
                .{ .name = "anthropic", .module = anthropic_mod },
                .{ .name = "openai", .module = openai_mod },
                .{ .name = "test_helpers", .module = test_helpers_mod },
            },
        }),
    });

    const e2e_empty_messages_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e/empty_messages.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "config", .module = config_mod },
                .{ .name = "anthropic", .module = anthropic_mod },
                .{ .name = "openai", .module = openai_mod },
                .{ .name = "test_helpers", .module = test_helpers_mod },
            },
        }),
    });

    const e2e_unicode_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e/unicode.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types_mod },
                .{ .name = "config", .module = config_mod },
                .{ .name = "anthropic", .module = anthropic_mod },
                .{ .name = "openai", .module = openai_mod },
                .{ .name = "test_helpers", .module = test_helpers_mod },
            },
        }),
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(types_test).step);
    test_step.dependOn(&b.addRunArtifact(event_stream_test).step);
    test_step.dependOn(&b.addRunArtifact(provider_test).step);
    test_step.dependOn(&b.addRunArtifact(json_writer_test).step);
    test_step.dependOn(&b.addRunArtifact(config_test).step);
    test_step.dependOn(&b.addRunArtifact(model_test).step);
    test_step.dependOn(&b.addRunArtifact(sse_parser_test).step);
    test_step.dependOn(&b.addRunArtifact(retry_test).step);
    test_step.dependOn(&b.addRunArtifact(aws_sigv4_test).step);
    test_step.dependOn(&b.addRunArtifact(http_test).step);
    test_step.dependOn(&b.addRunArtifact(anthropic_test).step);
    test_step.dependOn(&b.addRunArtifact(openai_test).step);
    test_step.dependOn(&b.addRunArtifact(ollama_test).step);
    test_step.dependOn(&b.addRunArtifact(azure_test).step);
    test_step.dependOn(&b.addRunArtifact(google_shared_test).step);
    test_step.dependOn(&b.addRunArtifact(google_test).step);
    test_step.dependOn(&b.addRunArtifact(google_vertex_test).step);
    test_step.dependOn(&b.addRunArtifact(bedrock_test).step);
    test_step.dependOn(&b.addRunArtifact(transport_test).step);
    test_step.dependOn(&b.addRunArtifact(stdio_transport_test).step);
    test_step.dependOn(&b.addRunArtifact(sse_transport_test).step);
    test_step.dependOn(&b.addRunArtifact(simple_stream_test).step);
    test_step.dependOn(&b.addRunArtifact(oauth_pkce_test).step);
    test_step.dependOn(&b.addRunArtifact(oauth_callback_server_test).step);
    test_step.dependOn(&b.addRunArtifact(oauth_anthropic_test).step);
    test_step.dependOn(&b.addRunArtifact(oauth_github_copilot_test).step);
    test_step.dependOn(&b.addRunArtifact(oauth_google_test).step);
    test_step.dependOn(&b.addRunArtifact(oauth_storage_test).step);
    test_step.dependOn(&b.addRunArtifact(oauth_test).step);

    // E2E test step
    const e2e_test_step = b.step("test-e2e", "Run end-to-end integration tests (requires API credentials)");

    // Set timeout for E2E tests (60 seconds)
    const e2e_anthropic_run = b.addRunArtifact(e2e_anthropic_test);
    e2e_anthropic_run.step.max_rss = 0;
    e2e_test_step.dependOn(&e2e_anthropic_run.step);

    const e2e_openai_run = b.addRunArtifact(e2e_openai_test);
    e2e_openai_run.step.max_rss = 0;
    e2e_test_step.dependOn(&e2e_openai_run.step);

    const e2e_ollama_run = b.addRunArtifact(e2e_ollama_test);
    e2e_ollama_run.step.max_rss = 0;
    e2e_test_step.dependOn(&e2e_ollama_run.step);

    const e2e_azure_run = b.addRunArtifact(e2e_azure_test);
    e2e_azure_run.step.max_rss = 0;
    e2e_test_step.dependOn(&e2e_azure_run.step);

    const e2e_google_run = b.addRunArtifact(e2e_google_test);
    e2e_google_run.step.max_rss = 0;
    e2e_test_step.dependOn(&e2e_google_run.step);

    const e2e_google_vertex_run = b.addRunArtifact(e2e_google_vertex_test);
    e2e_google_vertex_run.step.max_rss = 0;
    e2e_test_step.dependOn(&e2e_google_vertex_run.step);

    const e2e_bedrock_run = b.addRunArtifact(e2e_bedrock_test);
    e2e_bedrock_run.step.max_rss = 0;
    e2e_test_step.dependOn(&e2e_bedrock_run.step);

    const e2e_abort_run = b.addRunArtifact(e2e_abort_test);
    e2e_abort_run.step.max_rss = 0;
    e2e_test_step.dependOn(&e2e_abort_run.step);

    const e2e_empty_messages_run = b.addRunArtifact(e2e_empty_messages_test);
    e2e_empty_messages_run.step.max_rss = 0;
    e2e_test_step.dependOn(&e2e_empty_messages_run.step);

    const e2e_unicode_run = b.addRunArtifact(e2e_unicode_test);
    e2e_unicode_run.step.max_rss = 0;
    e2e_test_step.dependOn(&e2e_unicode_run.step);
}
