const std = @import("std");
const compat = @import("compat");
const ai_types = @import("ai_types");
const runtime_mod = @import("tui_runtime");

const websocket_mock_server_py =
    \\import base64, hashlib, json, socket, struct, sys
    \\
    \\port_file, auth_file = sys.argv[1], sys.argv[2]
    \\def mark(v):
    \\    with open(auth_file + ".phase", "w") as f:
    \\        f.write(v)
    \\sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    \\sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    \\sock.bind(("127.0.0.1", 0))
    \\sock.listen(1)
    \\with open(port_file, "w") as f:
    \\    f.write(str(sock.getsockname()[1]))
    \\
    \\def recv_all(conn, n):
    \\    data = b""
    \\    while len(data) < n:
    \\        chunk = conn.recv(n - len(data))
    \\        if not chunk:
    \\            raise SystemExit(1)
    \\        data += chunk
    \\    return data
    \\
    \\conn, _ = sock.accept()
    \\mark("accepted")
    \\conn.settimeout(30)
    \\data = b""
    \\while b"\r\n\r\n" not in data:
    \\    chunk = conn.recv(1024)
    \\    if not chunk:
    \\        raise SystemExit(1)
    \\    data += chunk
    \\headers = data.decode("iso-8859-1").split("\r\n")
    \\key = None
    \\auth_ok = False
    \\proto_ok = False
    \\for line in headers:
    \\    lower = line.lower()
    \\    if lower.startswith("sec-websocket-key:"):
    \\        key = line.split(":", 1)[1].strip()
    \\    if lower == "authorization: bearer test-token":
    \\        auth_ok = True
    \\    if lower == "sec-websocket-protocol: makai.v1":
    \\        proto_ok = True
    \\with open(auth_file, "w") as f:
    \\    f.write("ok" if auth_ok and proto_ok else "missing")
    \\accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
    \\response = ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Protocol: makai.v1\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n").encode()
    \\sid = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    \\reply = json.dumps({"version":1,"session_id":sid,"message_id":"01BRZ3NDEKTSV4RRFFQ69G5FAV","sequence":1,"timestamp":0,"payload":{"agent_started":{"session_id":sid}}}).encode()
    \\frame = bytearray([0x81])
    \\if len(reply) < 126:
    \\    frame.append(len(reply))
    \\else:
    \\    frame.append(126); frame.extend(struct.pack(">H", len(reply)))
    \\frame.extend(reply)
    \\conn.sendall(response + bytes(frame))
    \\conn.close()
;

fn writeFile(path: []const u8, data: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, data);
}

fn readSmallFile(path: []const u8, buf: []u8) ![]const u8 {
    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    var reader = file.reader(std.testing.io, &.{});
    const n = try reader.interface.readSliceShort(buf);
    return buf[0..n];
}

fn deleteIgnore(path: []const u8) void {
    std.Io.Dir.deleteFile(.cwd(), std.testing.io, path) catch {};
}

fn waitForPort(path: []const u8) !u16 {
    const start = compat.time.nowMillis();
    var buf: [32]u8 = undefined;
    while (@as(u64, @intCast(compat.time.nowMillis() - start)) < 5_000) {
        const data = readSmallFile(path, &buf) catch {
            compat.time.sleepMs(10);
            continue;
        };
        return std.fmt.parseUnsigned(u16, std.mem.trim(u8, data, " \n\r\t"), 10) catch {
            compat.time.sleepMs(10);
            continue;
        };
    }
    return error.MockServerTimeout;
}

test "TUI remote WebSocket connects, sends auth/subprotocol, and exchanges envelopes" {
    const allocator = std.testing.allocator;
    const unique = compat.time.nowMillis();
    const script_path = try std.fmt.allocPrint(allocator, "/tmp/makai-ws-{d}.py", .{unique});
    defer allocator.free(script_path);
    const port_path = try std.fmt.allocPrint(allocator, "/tmp/makai-ws-{d}.port", .{unique});
    defer allocator.free(port_path);
    const auth_path = try std.fmt.allocPrint(allocator, "/tmp/makai-ws-{d}.auth", .{unique});
    defer allocator.free(auth_path);
    defer deleteIgnore(script_path);
    defer deleteIgnore(port_path);
    defer deleteIgnore(auth_path);

    try writeFile(script_path, websocket_mock_server_py);
    var child = std.process.spawn(std.testing.io, .{ .argv = &.{ "python3", script_path, port_path, auth_path }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => |e| return e,
    };
    defer {
        if (child.id != null) _ = child.kill(std.testing.io);
        if (child.id != null) _ = child.wait(std.testing.io) catch {};
    }

    const port = try waitForPort(port_path);
    const endpoint = try std.fmt.allocPrint(allocator, "ws://127.0.0.1:{d}/agent", .{port});
    defer allocator.free(endpoint);

    var runtime = try runtime_mod.TuiRuntime.init(allocator, .{
        .remote_config = .{ .mode = .remote, .transport = .websocket, .endpoint = endpoint, .auth_headers = &.{.{ .name = "Authorization", .value = "Bearer test-token" }}, .subprotocol = "makai.v1" },
        .models = &[_]ai_types.Model{.{ .id = "test-model", .name = "Test Model", .api = "test", .provider = "test", .base_url = "", .reasoning = false, .input = &.{}, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 }, .context_window = 4096, .max_tokens = 1024 }},
    });
    defer runtime.deinit();

    try std.testing.expect(runtime.websocket_client != null);
    try std.testing.expect(runtime.websocket_handle != null);
    try std.testing.expect(runtime.remote_sender != null);
    try std.testing.expect(runtime.remote_receiver != null);

    const start = compat.time.nowMillis();
    while (true) {
        if (@as(u64, @intCast(compat.time.nowMillis() - start)) >= 5_000) return error.NoWebSocketReply;
        const inbound = try runtime.remote_receiver.?.read(allocator);
        switch (inbound) {
            .line => |line| {
                defer allocator.free(line);
                try std.testing.expect(line.len > 0);
                break;
            },
            .pending => compat.time.sleepMs(10),
            .disconnected => return error.NoWebSocketReply,
        }
    }

    var auth_buf: [16]u8 = undefined;
    const auth = try readSmallFile(auth_path, &auth_buf);
    try std.testing.expectEqualStrings("ok", std.mem.trim(u8, auth, " \n\r\t"));
}
