const std = @import("std");
const oauth = @import("oauth/github_copilot");

// Global state for callbacks (needed for stdin reading)
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var allocator: std.mem.Allocator = undefined;
var input_buffer: [1024]u8 = undefined;
var reader_buf: [4096]u8 = undefined;

fn onAuth(info: oauth.AuthInfo) void {
    const stdout_file = std.fs.File.stdout();
    stdout_file.writeAll("\n") catch return;
    stdout_file.writeAll(info.url) catch return;
    stdout_file.writeAll("\n") catch return;
    if (info.instructions) |instructions| {
        stdout_file.writeAll(instructions) catch return;
        stdout_file.writeAll("\n\n") catch return;
    }
    stdout_file.writeAll("Waiting for authorization...\n") catch return;
}

fn onPrompt(prompt: oauth.Prompt) []const u8 {
    const stdout_file = std.fs.File.stdout();
    const stdin_file = std.fs.File.stdin();

    stdout_file.writeAll(prompt.message) catch return "";
    stdout_file.writeAll(" ") catch return "";

    // Read line from stdin using new Zig 0.15 API
    var reader = stdin_file.reader(&reader_buf);
    const line = reader.interface.takeDelimiter('\n') catch return "";
    
    if (line) |l| {
        // Trim trailing whitespace
        const trimmed = std.mem.trim(u8, l, " \t\r\n");

        // Return empty string directly if allowed and input is empty
        if (prompt.allow_empty and trimmed.len == 0) {
            return "";
        }

        // Allocate and return a copy
        return allocator.dupe(u8, trimmed) catch return "";
    }
    
    return "";
}

pub fn main() !void {
    allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.print("Memory leak detected!\n", .{});
        }
    }

    const stdout_file = std.fs.File.stdout();

    try stdout_file.writeAll("GitHub Copilot Login\n");
    try stdout_file.writeAll("====================\n\n");

    const callbacks = oauth.Callbacks{
        .onAuth = onAuth,
        .onPrompt = onPrompt,
    };

    const credentials = oauth.login(callbacks, allocator) catch |err| {
        try stdout_file.writeAll("\nLogin failed: ");
        var err_buf: [64]u8 = undefined;
        const err_str = std.fmt.bufPrint(&err_buf, "{}", .{err}) catch "unknown error";
        try stdout_file.writeAll(err_str);
        try stdout_file.writeAll("\n");
        std.process.exit(1);
    };

    // Free credentials on exit
    defer {
        allocator.free(credentials.refresh);
        allocator.free(credentials.access);
        if (credentials.provider_data) |data| allocator.free(data);
        if (credentials.enabled_models) |models| {
            for (models) |m| allocator.free(m);
            allocator.free(models);
        }
        if (credentials.base_url) |url| allocator.free(url);
    }

    try stdout_file.writeAll("\nLogin successful!\n\n");
    try stdout_file.writeAll("Credentials (JSON):\n");

    // Output credentials as JSON
    try stdout_file.writeAll("{\n");
    
    try stdout_file.writeAll("  \"refresh\": \"");
    try stdout_file.writeAll(credentials.refresh);
    try stdout_file.writeAll("\",\n");
    
    try stdout_file.writeAll("  \"access\": \"");
    try stdout_file.writeAll(credentials.access);
    try stdout_file.writeAll("\",\n");
    
    var num_buf: [32]u8 = undefined;
    const expires_str = std.fmt.bufPrint(&num_buf, "{d}", .{credentials.expires}) catch "0";
    try stdout_file.writeAll("  \"expires\": ");
    try stdout_file.writeAll(expires_str);
    try stdout_file.writeAll(",\n");
    
    if (credentials.provider_data) |data| {
        try stdout_file.writeAll("  \"provider_data\": ");
        try stdout_file.writeAll(data);
        try stdout_file.writeAll(",\n");
    }
    if (credentials.base_url) |url| {
        try stdout_file.writeAll("  \"base_url\": \"");
        try stdout_file.writeAll(url);
        try stdout_file.writeAll("\",\n");
    }
    if (credentials.enabled_models) |models| {
        try stdout_file.writeAll("  \"enabled_models\": [");
        for (models, 0..) |model, i| {
            if (i > 0) try stdout_file.writeAll(", ");
            try stdout_file.writeAll("\"");
            try stdout_file.writeAll(model);
            try stdout_file.writeAll("\"");
        }
        try stdout_file.writeAll("]\n");
    }
    try stdout_file.writeAll("}\n");
}
