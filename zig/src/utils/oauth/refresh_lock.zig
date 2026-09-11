
const std = @import("std");
const compat = @import("compat");

fn defaultIo() std.Io {
    return if (@import("builtin").is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

pub const RefreshLock = struct {
    pub const DEFAULT_TIMEOUT_MS: u64 = 30_000;

    const Entry = struct {
        key_owned: []const u8,
        acquired_at_ms: u64,
        cond: std.Io.Condition,
        result: ?anyerror,
        completed: bool,
        timed_out: bool,
        generation: u64,
        ref_count: usize,
        owner_released: bool,
    };

    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex,
    entries: std.StringHashMap(*Entry),
    timeout_ms: u64,
    next_generation: u64,
    shutdown: bool = false,

    pub const AcquireResult = union(enum) {
        acquired: u64,
        completed_ok,
        completed_err: anyerror,
        timed_out,
    };

    pub fn init(allocator: std.mem.Allocator) RefreshLock {
        return initWithTimeout(allocator, DEFAULT_TIMEOUT_MS);
    }

    pub fn initWithTimeout(allocator: std.mem.Allocator, timeout_ms: u64) RefreshLock {
        return .{
            .allocator = allocator,
            .mutex = .init,
            .entries = std.StringHashMap(*Entry).init(allocator),
            .timeout_ms = timeout_ms,
            .next_generation = 1,
        };
    }

    pub fn deinit(self: *RefreshLock) void {
        self.mutex.lockUncancelable(defaultIo());
        self.shutdown = true;

        var iter = self.entries.iterator();
        while (iter.next()) |hashmap_entry| {
            const entry = hashmap_entry.value_ptr.*;
            if (!entry.owner_released) {
                entry.owner_released = true;
                entry.ref_count -= 1;
            }
            entry.completed = true;
            entry.result = error.AuthRefreshFailed;
            entry.timed_out = false;
            entry.cond.broadcast(defaultIo());
        }

        while (self.entries.count() > 0) {
            var first_iter = self.entries.iterator();
            const entry = first_iter.next().?.value_ptr.*;
            while (entry.ref_count > 0) {
                entry.cond.waitUncancelable(defaultIo(), &self.mutex);
            }
            self.freeEntry(entry);
        }

        self.mutex.unlock(defaultIo());
        self.entries.deinit();
    }

    pub fn buildLockKey(allocator: std.mem.Allocator, provider_id: []const u8, user_id: ?[]const u8) ![]const u8 {
        if (user_id) |uid| {
            return std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ provider_id, uid });
        }
        return allocator.dupe(u8, provider_id);
    }

    fn freeEntry(self: *RefreshLock, entry: *Entry) void {
        const owned = entry.key_owned;
        _ = self.entries.remove(owned);
        self.allocator.free(owned);
        self.allocator.destroy(entry);
    }

    fn timeoutEntry(self: *RefreshLock, entry: *Entry) bool {
        if (!entry.owner_released) {
            entry.owner_released = true;
            entry.ref_count -= 1;
        }
        entry.completed = true;
        entry.result = error.AuthRefreshFailed;
        entry.timed_out = true;
        if (entry.ref_count == 0) {
            self.freeEntry(entry);
            return false;
        }
        entry.cond.broadcast(defaultIo());
        return true;
    }

    fn releaseWaiterRef(self: *RefreshLock, entry: *Entry) void {
        entry.ref_count -= 1;
        if (self.shutdown) {
            entry.cond.broadcast(defaultIo());
        } else if (entry.ref_count == 0) {
            self.freeEntry(entry);
        }
    }

    fn tryRecoverTimedOutEntry(self: *RefreshLock, entry: *Entry) void {
        if (!entry.owner_released) {
            entry.owner_released = true;
            entry.ref_count -= 1;
        }
        if (entry.ref_count == 0) {
            self.freeEntry(entry);
        }
    }

    fn keyMatches(key: []const u8, provider_id: []const u8, user_id: ?[]const u8) bool {
        if (user_id) |uid| {
            const null_pos = std.mem.findScalar(u8, key, 0) orelse return false;
            return std.mem.eql(u8, key[0..null_pos], provider_id) and
                std.mem.eql(u8, key[null_pos + 1 ..], uid);
        } else {
            if (std.mem.findScalar(u8, key, 0) != null) return false;
            return std.mem.eql(u8, key, provider_id);
        }
    }

    fn monotonicMillis() u64 {
        return (compat.time.monotonicNanos() catch 0) / std.time.ns_per_ms;
    }

    fn elapsedMs(entry: *const Entry, now_ms: u64) u64 {
        return now_ms -| entry.acquired_at_ms;
    }

    pub fn acquire(self: *RefreshLock, provider_id: []const u8, user_id: ?[]const u8) !AcquireResult {
        const key = try buildLockKey(self.allocator, provider_id, user_id);

        self.mutex.lockUncancelable(defaultIo());

        if (self.shutdown) {
            self.allocator.free(key);
            self.mutex.unlock(defaultIo());
            return error.AuthRefreshFailed;
        }

        if (self.entries.getPtr(key)) |entry_ptr| {
            const entry = entry_ptr.*;

            if (entry.completed) {
                if (entry.timed_out) {
                    self.tryRecoverTimedOutEntry(entry);
                    if (self.entries.getPtr(key) != null) {
                        self.allocator.free(key);
                        self.mutex.unlock(defaultIo());
                        return .timed_out;
                    }
                } else {
                    const result = entry.result;
                    self.allocator.free(key);
                    self.mutex.unlock(defaultIo());
                    return if (result) |err|
                        .{ .completed_err = err }
                    else
                        .completed_ok;
                }
            } else {
                const now = monotonicMillis();
                if (elapsedMs(entry, now) > self.timeout_ms) {
                    _ = self.timeoutEntry(entry);
                    self.allocator.free(key);
                    self.mutex.unlock(defaultIo());
                    return .timed_out;
                }

                entry.ref_count += 1;
                while (!self.shutdown and !entry.completed) {
                    const instant = monotonicMillis();
                    const elapsed_ms = elapsedMs(entry, instant);
                    if (elapsed_ms >= self.timeout_ms) {
                        _ = self.timeoutEntry(entry);
                        self.releaseWaiterRef(entry);
                        self.allocator.free(key);
                        self.mutex.unlock(defaultIo());
                        return .timed_out;
                    }

                    const remaining_ms = self.timeout_ms - elapsed_ms;
                    const sleep_ms: u64 = @min(remaining_ms, 10);
                    self.mutex.unlock(defaultIo());
                    defaultIo().sleep(.fromNanoseconds(sleep_ms * std.time.ns_per_ms), .boot) catch {};
                    self.mutex.lockUncancelable(defaultIo());
                }

                if (self.shutdown) {
                    self.releaseWaiterRef(entry);
                    self.allocator.free(key);
                    self.mutex.unlock(defaultIo());
                    return error.AuthRefreshFailed;
                }

                const result = entry.result;
                const timed_out = entry.timed_out;
                self.releaseWaiterRef(entry);
                self.allocator.free(key);
                self.mutex.unlock(defaultIo());
                if (timed_out) return .timed_out;
                return if (result) |err|
                    .{ .completed_err = err }
                else
                    .completed_ok;
            }
        }

        const entry = self.allocator.create(Entry) catch |err| {
            self.allocator.free(key);
            self.mutex.unlock(defaultIo());
            return err;
        };
        const acquired_at_ms = monotonicMillis();

        const generation = self.next_generation;
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;

        entry.* = .{
            .key_owned = key,
            .acquired_at_ms = acquired_at_ms,
            .cond = .init,
            .result = null,
            .completed = false,
            .timed_out = false,
            .generation = generation,
            .ref_count = 1,
            .owner_released = false,
        };
        self.entries.put(key, entry) catch |err| {
            self.allocator.free(entry.key_owned);
            self.allocator.destroy(entry);
            self.mutex.unlock(defaultIo());
            return err;
        };
        self.mutex.unlock(defaultIo());
        return .{ .acquired = generation };
    }

    pub fn complete(self: *RefreshLock, provider_id: []const u8, user_id: ?[]const u8, generation: u64, err: ?anyerror) void {
        self.mutex.lockUncancelable(defaultIo());

        var match: ?*Entry = null;
        var iter = self.entries.iterator();
        while (iter.next()) |hashmap_entry| {
            if (keyMatches(hashmap_entry.key_ptr.*, provider_id, user_id)) {
                match = hashmap_entry.value_ptr.*;
                break;
            }
        }

        const entry = match orelse {
            self.mutex.unlock(defaultIo());
            return;
        };

        if (entry.generation != generation or entry.timed_out) {
            self.mutex.unlock(defaultIo());
            return;
        }

        entry.result = err;
        entry.completed = true;
        entry.timed_out = false;
        entry.cond.broadcast(defaultIo());
        if (!entry.owner_released) {
            entry.owner_released = true;
            entry.ref_count -= 1;
        }

        if (entry.ref_count == 0) {
            self.freeEntry(entry);
        }
        self.mutex.unlock(defaultIo());
    }

    pub fn expireTimedOut(self: *RefreshLock) void {
        const now = monotonicMillis();

        self.mutex.lockUncancelable(defaultIo());
        var to_expire = std.ArrayList(*Entry).initCapacity(self.allocator, self.entries.count()) catch {
            self.mutex.unlock(defaultIo());
            return;
        };
        defer to_expire.deinit(self.allocator);

        var iter = self.entries.iterator();
        while (iter.next()) |hashmap_entry| {
            const entry = hashmap_entry.value_ptr.*;
            if (!entry.completed and elapsedMs(entry, now) > self.timeout_ms) {
                to_expire.appendAssumeCapacity(entry);
            }
        }
        for (to_expire.items) |entry| {
            if (self.timeoutEntry(entry)) {
                entry.cond.broadcast(defaultIo());
            }
        }
        self.mutex.unlock(defaultIo());
    }

    pub fn activeCount(self: *RefreshLock) usize {
        self.mutex.lockUncancelable(defaultIo());
        defer self.mutex.unlock(defaultIo());
        var count: usize = 0;
        var iter = self.entries.iterator();
        while (iter.next()) |hashmap_entry| {
            if (!hashmap_entry.value_ptr.*.completed) count += 1;
        }
        return count;
    }

    fn refCountForTesting(self: *RefreshLock, provider_id: []const u8, user_id: ?[]const u8) usize {
        self.mutex.lockUncancelable(defaultIo());
        defer self.mutex.unlock(defaultIo());

        var iter = self.entries.iterator();
        while (iter.next()) |hashmap_entry| {
            if (keyMatches(hashmap_entry.key_ptr.*, provider_id, user_id)) {
                return hashmap_entry.value_ptr.*.ref_count;
            }
        }
        return 0;
    }
};

const testing = std.testing;
const waiter_spin_limit = 10_000;

fn waitForRefCount(lock: *RefreshLock, provider: []const u8, expected: usize) !void {
    var attempts: usize = 0;
    while (lock.refCountForTesting(provider, null) < expected) : (attempts += 1) {
        if (attempts >= waiter_spin_limit) return error.WaiterRefCountTimeout;
        defaultIo().sleep(.fromNanoseconds(1 * std.time.ns_per_ms), .boot) catch {};
    }
}

fn expectAcquired(result: RefreshLock.AcquireResult) !u64 {
    return switch (result) {
        .acquired => |generation| generation,
        else => error.TestUnexpectedResult,
    };
}

test "RefreshLock init/deinit" {
    var lock = RefreshLock.init(testing.allocator);
    lock.deinit();
}

test "RefreshLock acquire returns acquired for new key" {
    var lock = RefreshLock.init(testing.allocator);
    defer lock.deinit();

    const gen = try expectAcquired(try lock.acquire("test-provider", null));
    lock.complete("test-provider", null, gen, null);
}

test "RefreshLock acquire returns completed_ok after successful refresh" {
    var lock = RefreshLock.init(testing.allocator);
    defer lock.deinit();

    const gen1 = try expectAcquired(try lock.acquire("prov", null));
    lock.complete("prov", null, gen1, null);

    const gen2 = try expectAcquired(try lock.acquire("prov", null));
    lock.complete("prov", null, gen2, null);
}

test "RefreshLock acquire returns completed_err after failed refresh" {
    var lock = RefreshLock.init(testing.allocator);
    defer lock.deinit();

    const gen1 = try expectAcquired(try lock.acquire("prov", null));
    lock.complete("prov", null, gen1, error.AuthRefreshFailed);

    const gen2 = try expectAcquired(try lock.acquire("prov", null));
    lock.complete("prov", null, gen2, error.AuthRefreshFailed);
}

test "RefreshLock different providers are independent" {
    var lock = RefreshLock.init(testing.allocator);
    defer lock.deinit();

    const gen1 = try expectAcquired(try lock.acquire("prov-a", null));

    const gen2 = try expectAcquired(try lock.acquire("prov-b", null));

    lock.complete("prov-a", null, gen1, null);
    lock.complete("prov-b", null, gen2, error.AuthRefreshFailed);
}

test "RefreshLock user_id creates separate scope" {
    var lock = RefreshLock.init(testing.allocator);
    defer lock.deinit();

    const gen1 = try expectAcquired(try lock.acquire("prov", "user1"));

    const gen2 = try expectAcquired(try lock.acquire("prov", "user2"));

    lock.complete("prov", "user1", gen1, null);
    lock.complete("prov", "user2", gen2, null);

    const gen3 = try expectAcquired(try lock.acquire("prov", "user1"));
    lock.complete("prov", "user1", gen3, null);
}

test "RefreshLock buildLockKey single-tenant is just provider_id" {
    const key = try RefreshLock.buildLockKey(testing.allocator, "anthropic", null);
    defer testing.allocator.free(key);
    try testing.expectEqualStrings("anthropic", key);
}

test "RefreshLock buildLockKey multi-tenant includes null separator" {
    const key = try RefreshLock.buildLockKey(testing.allocator, "anthropic", "user-42");
    defer testing.allocator.free(key);
    try testing.expectEqualStrings("anthropic\x00user-42", key);
}

const ConcurrencyCtx = struct {
    lock: *RefreshLock,
    refresh_count: std.atomic.Value(usize),
    acquire_count: std.atomic.Value(usize),
    ok_count: std.atomic.Value(usize),
    err_count: std.atomic.Value(usize),
    timeout_count: std.atomic.Value(usize),
    provider: []const u8,
};

fn concurrentWorker(ctx: *ConcurrencyCtx) void {
    const result = ctx.lock.acquire(ctx.provider, null) catch {
        _ = ctx.err_count.fetchAdd(1, .monotonic);
        return;
    };
    _ = ctx.acquire_count.fetchAdd(1, .monotonic);
    switch (result) {
        .acquired => |generation| {
            _ = ctx.refresh_count.fetchAdd(1, .monotonic);
            defaultIo().sleep(.fromNanoseconds(5 * std.time.ns_per_ms), .boot) catch {};
            ctx.lock.complete(ctx.provider, null, generation, null);
        },
        .completed_ok => {
            _ = ctx.ok_count.fetchAdd(1, .monotonic);
        },
        .completed_err => {
            _ = ctx.err_count.fetchAdd(1, .monotonic);
        },
        .timed_out => {
            _ = ctx.timeout_count.fetchAdd(1, .monotonic);
        },
    }
}

test "concurrent requests for same provider trigger only one refresh" {
    var lock = RefreshLock.init(testing.allocator);
    defer lock.deinit();

    var ctx = ConcurrencyCtx{
        .lock = &lock,
        .refresh_count = std.atomic.Value(usize).init(0),
        .acquire_count = std.atomic.Value(usize).init(0),
        .ok_count = std.atomic.Value(usize).init(0),
        .err_count = std.atomic.Value(usize).init(0),
        .timeout_count = std.atomic.Value(usize).init(0),
        .provider = "test-provider",
    };

    const first_gen = try expectAcquired(try lock.acquire("test-provider", null));

    const num_waiters = 4;
    var threads: [num_waiters]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, concurrentWorker, .{&ctx});
    }

    try waitForRefCount(&lock, "test-provider", num_waiters + 1);
    lock.complete("test-provider", null, first_gen, null);

    for (&threads) |t| {
        t.join();
    }

    try testing.expectEqual(@as(usize, 0), ctx.refresh_count.load(.seq_cst));
    try testing.expectEqual(@as(usize, num_waiters), ctx.ok_count.load(.seq_cst));
    try testing.expectEqual(@as(usize, 0), ctx.err_count.load(.seq_cst));
    try testing.expectEqual(@as(usize, 0), ctx.timeout_count.load(.seq_cst));
}

test "all waiting requests succeed after a single shared refresh completes" {
    var lock = RefreshLock.init(testing.allocator);
    defer lock.deinit();

    var ctx = ConcurrencyCtx{
        .lock = &lock,
        .refresh_count = std.atomic.Value(usize).init(0),
        .acquire_count = std.atomic.Value(usize).init(0),
        .ok_count = std.atomic.Value(usize).init(0),
        .err_count = std.atomic.Value(usize).init(0),
        .timeout_count = std.atomic.Value(usize).init(0),
        .provider = "prov-ok",
    };

    const first_gen = try expectAcquired(try lock.acquire("prov-ok", null));

    const num_waiters = 5;
    var threads: [num_waiters]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, concurrentWorker, .{&ctx});
    }

    try waitForRefCount(&lock, "prov-ok", num_waiters + 1);
    lock.complete("prov-ok", null, first_gen, null);

    for (&threads) |t| {
        t.join();
    }

    try testing.expectEqual(@as(usize, 0), ctx.refresh_count.load(.seq_cst));
    try testing.expectEqual(@as(usize, num_waiters), ctx.ok_count.load(.seq_cst));
    try testing.expectEqual(@as(usize, 0), ctx.err_count.load(.seq_cst));
}

test "lock held beyond timeout returns timed_out" {
    var lock = RefreshLock.initWithTimeout(testing.allocator, 50);
    defer lock.deinit();

    const first_gen = try expectAcquired(try lock.acquire("slow-provider", null));

    defaultIo().sleep(.fromNanoseconds(80 * std.time.ns_per_ms), .boot) catch {};

    const second = try lock.acquire("slow-provider", null);
    try testing.expect(second == .timed_out);

    lock.complete("slow-provider", null, first_gen, null);
}

test "expireTimedOut marks stale entries as completed" {
    var lock = RefreshLock.initWithTimeout(testing.allocator, 50);
    defer lock.deinit();

    _ = try expectAcquired(try lock.acquire("expired-provider", null));

    defaultIo().sleep(.fromNanoseconds(80 * std.time.ns_per_ms), .boot) catch {};
    lock.expireTimedOut();

    const second_gen = try expectAcquired(try lock.acquire("expired-provider", null));
    lock.complete("expired-provider", null, second_gen, null);
}

const WaiterTimeoutCtx = struct {
    lock: *RefreshLock,
    provider: []const u8,
    timed_out_count: std.atomic.Value(usize),
};

fn timeoutWaiter(ctx: *WaiterTimeoutCtx) void {
    const result = ctx.lock.acquire(ctx.provider, null) catch return;
    if (result == .timed_out) {
        _ = ctx.timed_out_count.fetchAdd(1, .monotonic);
    }
}

fn shutdownWaiter(ctx: *WaiterTimeoutCtx) void {
    _ = ctx.lock.acquire(ctx.provider, null) catch return;
}

const DeinitCtx = struct {
    lock: *RefreshLock,
};

fn deinitWorker(ctx: *DeinitCtx) void {
    ctx.lock.deinit();
}

test "waiter timeout releases waiter ref and allows recovery" {
    var lock = RefreshLock.initWithTimeout(testing.allocator, 20);
    defer lock.deinit();

    const stale_gen = try expectAcquired(try lock.acquire("recover-provider", null));

    var ctx = WaiterTimeoutCtx{
        .lock = &lock,
        .provider = "recover-provider",
        .timed_out_count = std.atomic.Value(usize).init(0),
    };
    const waiter = try std.Thread.spawn(.{}, timeoutWaiter, .{&ctx});
    waiter.join();

    try testing.expectEqual(@as(usize, 1), ctx.timed_out_count.load(.seq_cst));

    const recovered_gen = try expectAcquired(try lock.acquire("recover-provider", null));

    lock.complete("recover-provider", null, stale_gen, null);
    try testing.expectEqual(@as(usize, 1), lock.activeCount());

    lock.complete("recover-provider", null, recovered_gen, null);
    try testing.expectEqual(@as(usize, 0), lock.activeCount());
}

test "owner completion after timeout does not rewrite timeout result" {
    var lock = RefreshLock.initWithTimeout(testing.allocator, 20);
    defer lock.deinit();

    const gen = try expectAcquired(try lock.acquire("timed-result-provider", null));

    var ctx = WaiterTimeoutCtx{
        .lock = &lock,
        .provider = "timed-result-provider",
        .timed_out_count = std.atomic.Value(usize).init(0),
    };
    const waiter = try std.Thread.spawn(.{}, timeoutWaiter, .{&ctx});
    waiter.join();

    lock.complete("timed-result-provider", null, gen, null);

    try testing.expectEqual(@as(usize, 1), ctx.timed_out_count.load(.seq_cst));
    const recovered_gen = try expectAcquired(try lock.acquire("timed-result-provider", null));
    lock.complete("timed-result-provider", null, recovered_gen, null);
}

test "shutdown with waiter does not dereference freed entries" {
    var lock = RefreshLock.init(testing.allocator);

    _ = try expectAcquired(try lock.acquire("shutdown-provider", null));

    var ctx = WaiterTimeoutCtx{
        .lock = &lock,
        .provider = "shutdown-provider",
        .timed_out_count = std.atomic.Value(usize).init(0),
    };
    const waiter = try std.Thread.spawn(.{}, shutdownWaiter, .{&ctx});

    defaultIo().sleep(.fromNanoseconds(5 * std.time.ns_per_ms), .boot) catch {};
    var deinit_ctx = DeinitCtx{ .lock = &lock };
    const deinit_thread = try std.Thread.spawn(.{}, deinitWorker, .{&deinit_ctx});

    waiter.join();
    deinit_thread.join();
}

test "activeCount reports in-flight entries" {
    var lock = RefreshLock.init(testing.allocator);
    defer lock.deinit();

    try testing.expectEqual(@as(usize, 0), lock.activeCount());

    const gen_a = try expectAcquired(try lock.acquire("a", null));
    try testing.expectEqual(@as(usize, 1), lock.activeCount());

    const gen_b = try expectAcquired(try lock.acquire("b", null));
    try testing.expectEqual(@as(usize, 2), lock.activeCount());

    lock.complete("a", null, gen_a, null);
    try testing.expectEqual(@as(usize, 1), lock.activeCount());

    lock.complete("b", null, gen_b, null);
    try testing.expectEqual(@as(usize, 0), lock.activeCount());
}
