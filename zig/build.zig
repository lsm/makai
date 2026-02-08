const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ZIO dependency
    const zio_dep = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });
    const zio_mod = zio_dep.module("zio");

    // libxev dependency
    const xev_dep = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });
    const xev_mod = xev_dep.module("xev");

    // Modules
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

    const mock_provider_mod = b.createModule(.{
        .root_source_file = b.path("src/mock_provider.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "provider", .module = provider_mod },
            .{ .name = "zio", .module = zio_mod },
        },
    });

    const fiber_mock_provider_mod = b.createModule(.{
        .root_source_file = b.path("src/fiber_mock_provider.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "provider", .module = provider_mod },
            .{ .name = "zio", .module = zio_mod },
        },
    });

    // Provider modules
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

    // Provider modules (will be used by main_mod once we add provider demo)
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

    // Main module
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "provider", .module = provider_mod },
            .{ .name = "mock_provider", .module = mock_provider_mod },
            .{ .name = "fiber_mock_provider", .module = fiber_mock_provider_mod },
        },
    });

    // Main executable
    const exe = b.addExecutable(.{
        .name = "pi-ai-demo",
        .root_module = main_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the demo");
    run_step.dependOn(&run_cmd.step);

    // Benchmark module
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
            .{ .name = "provider", .module = provider_mod },
            .{ .name = "mock_provider", .module = mock_provider_mod },
            .{ .name = "fiber_mock_provider", .module = fiber_mock_provider_mod },
            .{ .name = "zio", .module = zio_mod },
        },
    });

    // Benchmark executable
    const bench_exe = b.addExecutable(.{
        .name = "pi-ai-bench",
        .root_module = bench_mod,
    });
    b.installArtifact(bench_exe);

    const bench_run_cmd = b.addRunArtifact(bench_exe);
    bench_run_cmd.step.dependOn(b.getInstallStep());

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_run_cmd.step);

    // Fiber benchmark module
    const fiber_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/fiber_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "zio", .module = zio_mod },
        },
    });

    // Fiber benchmark executable
    const fiber_bench_exe = b.addExecutable(.{
        .name = "fiber-bench",
        .root_module = fiber_bench_mod,
    });
    b.installArtifact(fiber_bench_exe);

    const fiber_bench_run_cmd = b.addRunArtifact(fiber_bench_exe);
    fiber_bench_run_cmd.step.dependOn(b.getInstallStep());

    const fiber_bench_step = b.step("fiber-bench", "Run fiber vs thread benchmarks");
    fiber_bench_step.dependOn(&fiber_bench_run_cmd.step);

    // Shared runtime benchmark module
    const shared_runtime_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/shared_runtime_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "zio", .module = zio_mod },
        },
    });

    // Shared runtime benchmark executable
    const shared_runtime_bench_exe = b.addExecutable(.{
        .name = "shared-runtime-bench",
        .root_module = shared_runtime_bench_mod,
    });
    b.installArtifact(shared_runtime_bench_exe);

    const shared_runtime_bench_run_cmd = b.addRunArtifact(shared_runtime_bench_exe);
    shared_runtime_bench_run_cmd.step.dependOn(b.getInstallStep());

    const shared_runtime_bench_step = b.step("shared-bench", "Run shared ZIO runtime benchmark");
    shared_runtime_bench_step.dependOn(&shared_runtime_bench_run_cmd.step);

    // libxev benchmark module
    const xev_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/libxev_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "xev", .module = xev_mod },
            .{ .name = "zio", .module = zio_mod },
        },
    });

    // libxev benchmark executable
    const xev_bench_exe = b.addExecutable(.{
        .name = "xev-bench",
        .root_module = xev_bench_mod,
    });
    b.installArtifact(xev_bench_exe);

    const xev_bench_run_cmd = b.addRunArtifact(xev_bench_exe);
    xev_bench_run_cmd.step.dependOn(b.getInstallStep());

    const xev_bench_step = b.step("xev-bench", "Run libxev vs ZIO vs threads benchmark");
    xev_bench_step.dependOn(&xev_bench_run_cmd.step);

    // Multi-threaded libxev benchmark module
    const mt_xev_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/mt_xev_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "xev", .module = xev_mod },
        },
    });

    // Multi-threaded libxev benchmark executable
    const mt_xev_bench_exe = b.addExecutable(.{
        .name = "mt-xev-bench",
        .root_module = mt_xev_bench_mod,
    });
    b.installArtifact(mt_xev_bench_exe);

    const mt_xev_bench_run_cmd = b.addRunArtifact(mt_xev_bench_exe);
    mt_xev_bench_run_cmd.step.dependOn(b.getInstallStep());

    const mt_xev_bench_step = b.step("mt-xev-bench", "Run multi-threaded libxev benchmark");
    mt_xev_bench_step.dependOn(&mt_xev_bench_run_cmd.step);

    // Test modules
    const types_test_mod = b.createModule(.{
        .root_source_file = b.path("src/types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const event_stream_test_mod = b.createModule(.{
        .root_source_file = b.path("src/event_stream.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
        },
    });

    const provider_test_mod = b.createModule(.{
        .root_source_file = b.path("src/provider.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "event_stream", .module = event_stream_mod },
        },
    });

    const json_writer_test_mod = b.createModule(.{
        .root_source_file = b.path("src/json/writer.zig"),
        .target = target,
        .optimize = optimize,
    });

    const config_test_mod = b.createModule(.{
        .root_source_file = b.path("src/providers/config.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
        },
    });

    const sse_parser_test_mod = b.createModule(.{
        .root_source_file = b.path("src/providers/sse_parser.zig"),
        .target = target,
        .optimize = optimize,
    });

    const http_test_mod = b.createModule(.{
        .root_source_file = b.path("src/providers/http.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "xev", .module = xev_mod },
        },
    });

    const anthropic_test_mod = b.createModule(.{
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

    const openai_test_mod = b.createModule(.{
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

    const ollama_test_mod = b.createModule(.{
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

    // Test step
    const lib_unit_tests = b.addTest(.{
        .root_module = types_test_mod,
    });

    const event_stream_tests = b.addTest(.{
        .root_module = event_stream_test_mod,
    });

    const provider_tests = b.addTest(.{
        .root_module = provider_test_mod,
    });

    const json_writer_tests = b.addTest(.{
        .root_module = json_writer_test_mod,
    });

    const config_tests = b.addTest(.{
        .root_module = config_test_mod,
    });

    const sse_parser_tests = b.addTest(.{
        .root_module = sse_parser_test_mod,
    });

    const http_tests = b.addTest(.{
        .root_module = http_test_mod,
    });

    const anthropic_tests = b.addTest(.{
        .root_module = anthropic_test_mod,
    });

    const openai_tests = b.addTest(.{
        .root_module = openai_test_mod,
    });

    const ollama_tests = b.addTest(.{
        .root_module = ollama_test_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const run_event_stream_tests = b.addRunArtifact(event_stream_tests);
    const run_provider_tests = b.addRunArtifact(provider_tests);
    const run_json_writer_tests = b.addRunArtifact(json_writer_tests);
    const run_config_tests = b.addRunArtifact(config_tests);
    const run_sse_parser_tests = b.addRunArtifact(sse_parser_tests);
    const run_http_tests = b.addRunArtifact(http_tests);
    const run_anthropic_tests = b.addRunArtifact(anthropic_tests);
    const run_openai_tests = b.addRunArtifact(openai_tests);
    const run_ollama_tests = b.addRunArtifact(ollama_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_event_stream_tests.step);
    test_step.dependOn(&run_provider_tests.step);
    test_step.dependOn(&run_json_writer_tests.step);
    test_step.dependOn(&run_config_tests.step);
    test_step.dependOn(&run_sse_parser_tests.step);
    test_step.dependOn(&run_http_tests.step);
    test_step.dependOn(&run_anthropic_tests.step);
    test_step.dependOn(&run_openai_tests.step);
    test_step.dependOn(&run_ollama_tests.step);
}
