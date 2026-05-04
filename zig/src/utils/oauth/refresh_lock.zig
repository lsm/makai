//! Thread-safe refresh lock that ensures only one refresh runs at a time
//! per lock scope (provider_id [, user_id]). Other concurrent requests wait
//! on the same refresh result via condition variables.
//!
//! Lock key scoping:
//!   - Single-tenant (user_id = null): key = provider_id
//!   - Multi-tenant  (user_id set):   key = "provider_id\x00user_id"
//!
//! Timeout: if a refresh lock is held for more than `timeout_ms` (default
//! 30 000 ms), any waiter that observes the expiry releases the lock and
//! all waiters receive `error.AuthRefreshFailed`.

const std = @import("std");

pub const RefreshLock = struct {
    pub const DEFAULT_TIMEOUT_MS: u64 = 30_000;

    const Entry = struct {
        key_owned: []const u8,
        acquired_at: i64,
        cond: std.Thread.Condition,
        /// null  = refresh succeeded
        /// error = refresh failed with this error
        result: ?anyerror,
        completed: bool,
        /// Reference count: 1 for the owner + N waiters.
        /// Whoever decrements to 0 removes and frees the entry.
        ref_count: usize,
    };

    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    entries: std.StringHashMap(*Entry),
    timeout_ms: u64,

    pub const AcquireResult = union(enum) {
        /// Lock acquired — caller owns the refresh and **must** call `complete()`.
        acquired,
        /// Another refresh completed successfully — proceed.
        completed_ok,
        /// Another refresh completed with an error — propagate.
        completed_err: anyerror,
        /// The in-flight refresh exceeded the timeout.
        timed_out,
    };

    // ------------------------------------------------------------------
    // Lifetime
    // ------------------------------------------------------------------

    pub fn init(allocator: std.mem.Allocator) RefreshLock {
        return initWithTimeout(allocator, DEFAULT_TIMEOUT_MS);
    }

    pub fn initWithTimeout(allocator: std.mem.Allocator, timeout_ms: u64) RefreshLock {
        return .{
            .allocator = allocator,
            .mutex = .{},
            .entries = std.StringHashMap(*Entry).init(allocator),
            .timeout_ms = timeout_ms,
        };
    }

    pub fn deinit(self: *RefreshLock) void {
        // Hold the mutex while marking entries completed so any threads
        // inside acquire() see a consistent state.  Marking completed
        // before broadcast ensures waiters wake to a terminal result
        // rather than accessing freed memory.
        self.mutex.lock();

        // Collect entries so we can free them after releasing the mutex.
        var to_free = std.ArrayList(*Entry).initCapacity(self.allocator, self.entries.count()) catch {
            // OOM during deinit — still mark completed and broadcast so
            // waiters don't deadlock, even if we can't collect for free.
            var fallback_iter = self.entries.iterator();
            while (fallback_iter.next()) |he| {
                const e = he.value_ptr.*;
                e.completed = true;
                e.result = error.AuthRefreshFailed;
                e.cond.broadcast();
            }
            self.mutex.unlock();
            self.entries.deinit();
            return;
        };
        defer to_free.deinit(self.allocator);

        var iter = self.entries.iterator();
        while (iter.next()) |hashmap_entry| {
            const entry = hashmap_entry.value_ptr.*;
            entry.completed = true;
            entry.result = error.AuthRefreshFailed;
            entry.cond.broadcast();
            to_free.appendAssumeCapacity(entry);
        }
        self.mutex.unlock();

        // Now safe to free — no thread can be inside acquire() with a
        // reference to these entries (they all see completed=true).
        for (to_free.items) |entry| {
            self.allocator.free(entry.key_owned);
            self.allocator.destroy(entry);
        }
        self.entries.deinit();
    }

    // ------------------------------------------------------------------
    // Key builder
    // ------------------------------------------------------------------

    /// Build a lock key from provider_id and optional user_id.
    /// For single-tenant (user_id = null) the key is just provider_id.
    /// For multi-tenant the key is "provider_id\x00user_id" so the
    /// separator cannot appear in either string.
    pub fn buildLockKey(allocator: std.mem.Allocator, provider_id: []const u8, user_id: ?[]const u8) ![]const u8 {
        if (user_id) |uid| {
            return std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ provider_id, uid });
        }
        return allocator.dupe(u8, provider_id);
    }

    // ------------------------------------------------------------------
    // Acquire / Complete
    // ------------------------------------------------------------------

    /// Acquire the refresh lock for `(provider_id, user_id)`.
    ///
    /// Thread-safe. May block the calling thread while another refresh
    /// is in progress; once that refresh completes the caller is woken
    /// and receives the shared result.
    pub fn acquire(self: *RefreshLock, provider_id: []const u8, user_id: ?[]const u8) !AcquireResult {
        const key = try buildLockKey(self.allocator, provider_id, user_id);

        self.mutex.lock();

        if (self.entries.getPtr(key)) |entry_ptr| {
            // Entry already exists.
            const entry = entry_ptr.*;
            // key no longer needed — lookup was by content.
            self.allocator.free(key);

            if (entry.completed) {
                const result = entry.result;
                self.mutex.unlock();
                return if (result) |err|
                    .{ .completed_err = err }
                else
                    .completed_ok;
            }

            // Check timeout.
            const now = std.time.milliTimestamp();
            if (now - entry.acquired_at > @as(i64, @intCast(self.timeout_ms))) {
                // Timed out — mark completed so all current and future
                // waiters see the failure immediately.
                entry.completed = true;
                entry.result = error.AuthRefreshFailed;
                entry.cond.broadcast();
                // This waiter never incremented ref_count, so just return.
                self.mutex.unlock();
                return .timed_out;
            }

            // Wait for the in-flight refresh.
            entry.ref_count += 1;
            while (!entry.completed) {
                entry.cond.wait(&self.mutex);
            }

            // Woken — read shared result.
            const result = entry.result;
            entry.ref_count -= 1;
            if (entry.ref_count == 0) {
                const owned = entry.key_owned;
                _ = self.entries.remove(owned);
                self.mutex.unlock();
                self.allocator.free(owned);
                self.allocator.destroy(entry);
            } else {
                self.mutex.unlock();
            }
            return if (result) |err|
                .{ .completed_err = err }
            else
                .completed_ok;
        }

        // No entry — create one.  Caller owns the refresh.
        const entry = self.allocator.create(Entry) catch |err| {
            self.allocator.free(key);
            self.mutex.unlock();
            return err;
        };
        entry.* = .{
            .key_owned = key,
            .acquired_at = std.time.milliTimestamp(),
            .cond = .{},
            .result = null,
            .completed = false,
            .ref_count = 1,
        };
        self.entries.put(key, entry) catch |err| {
            // Entry was created but not added to the map.
            // Free key via entry.key_owned then destroy the entry.
            self.allocator.free(entry.key_owned);
            self.allocator.destroy(entry);
            self.mutex.unlock();
            return err;
        };
        self.mutex.unlock();
        return .acquired;
    }

    /// Complete a refresh and wake all waiters.
    ///
    /// `err` is `null` for success, or the error that caused the failure.
    pub fn complete(self: *RefreshLock, provider_id: []const u8, user_id: ?[]const u8, err: ?anyerror) void {
        const key = buildLockKey(self.allocator, provider_id, user_id) catch return;
        defer self.allocator.free(key);

        self.mutex.lock();

        const entry_ptr = self.entries.getPtr(key) orelse {
            self.mutex.unlock();
            return;
        };

        const entry = entry_ptr.*;
        entry.result = err;
        entry.completed = true;
        entry.cond.broadcast();
        entry.ref_count -= 1;

        if (entry.ref_count == 0) {
            const owned = entry.key_owned;
            _ = self.entries.remove(owned);
            self.mutex.unlock();
            self.allocator.free(owned);
            self.allocator.destroy(entry);
        } else {
            self.mutex.unlock();
        }
    }

    // ------------------------------------------------------------------
    // Periodic maintenance
    // ------------------------------------------------------------------

    /// Expire any in-flight refresh whose lock has been held longer than
    /// `timeout_ms`.  Call this periodically from the event loop.
    ///
    /// Timed-out entries are marked completed with `error.AuthRefreshFailed`
    /// and all waiters are woken.  The holder's `complete()` call will be a
    /// no-op (entry already removed or marked completed).
    pub fn expireTimedOut(self: *RefreshLock) void {
        const now = std.time.milliTimestamp();

        self.mutex.lock();
        // Collect entries to expire so we don't invalidate the iterator.
        var to_expire = std.ArrayList(*Entry).initCapacity(self.allocator, 4) catch {
            self.mutex.unlock();
            return;
        };
        defer to_expire.deinit(self.allocator);

        var iter = self.entries.iterator();
        while (iter.next()) |hashmap_entry| {
            const entry = hashmap_entry.value_ptr.*;
            if (!entry.completed and now - entry.acquired_at > @as(i64, @intCast(self.timeout_ms))) {
                to_expire.appendAssumeCapacity(entry);
            }
        }
        for (to_expire.items) |entry| {
            entry.completed = true;
            entry.result = error.AuthRefreshFailed;
            entry.cond.broadcast();
            // Don't remove here — waiters (or the holder's complete call)
            // will clean up when ref_count hits 0.
        }
        self.mutex.unlock();
    }

    /// Number of in-flight (not completed) refresh locks.  For diagnostics.
    pub fn activeCount(self: *RefreshLock) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var count: usize = 0;
        var iter = self.entries.iterator();
        while (iter.next()) |hashmap_entry| {
            if (!hashmap_entry.value_ptr.*.completed) count += 1;
        }
        return count;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

// -- Basic lifecycle --------------------------------------------------------

test "RefreshLock init/deinit" {
    var lock = RefreshLock.init(testing.allocator);
    lock.deinit();
}

test "RefreshLock acquire returns acquired for new key" {
    var lock = RefreshLock.init(testing.allocator);
    defer lock.deinit();

    const result = try lock.acquire("test-provider", null);
    try testing.expect(result == .acquired);
    lock.complete("test-provider", null, null);
}

test "RefreshLock acquire returns completed_ok after successful refresh" {
    var lock = RefreshLock.init(testing.allocator);
    defer lock.deinit();

    // Simulate: first acquire completes successfully
    const r1 = try lock.acquire("prov", null);
    try testing.expect(r1 == .acquired);
    lock.complete("prov", null, null);

    // Second acquire should see completed result
    const r2 = try lock.acquire("prov", null);
    try testing.expect(r2 == .completed_ok);
}

test "RefreshLock acquire returns completed_err after failed refresh" {
    var lock = RefreshLock.init(testing.allocator);
    defer lock.deinit();

    const r1 = try lock.acquire("prov", null);
    try testing.expect(r1 == .acquired);
    lock.complete("prov", null, error.AuthRefreshFailed);

    const r2 = try lock.acquire("prov", null);
    try testing.expect(r2 == .completed_err);
    try testing.expect(r2.completed_err == error.AuthRefreshFailed);
}

test "RefreshLock different providers are independent" {
    var lock = RefreshLock.init(testing.allocator);
    defer lock.deinit();

    const r1 = try lock.acquire("prov-a", null);
    try testing.expect(r1 == .acquired);

    const r2 = try lock.acquire("prov-b", null);
    try testing.expect(r2 == .acquired);

    lock.complete("prov-a", null, null);
    lock.complete("prov-b", null, error.AuthRefreshFailed);
}

test "RefreshLock user_id creates separate scope" {
    var lock = RefreshLock.init(testing.allocator);
    defer lock.deinit();

    const r1 = try lock.acquire("prov", "user1");
    try testing.expect(r1 == .acquired);

    const r2 = try lock.acquire("prov", "user2");
    try testing.expect(r2 == .acquired);

    // Same provider, same user → should see completed
    // (But we haven't completed user1 yet, so user1 acquire would block)
    lock.complete("prov", "user1", null);
    lock.complete("prov", "user2", null);

    const r3 = try lock.acquire("prov", "user1");
    try testing.expect(r3 == .completed_ok);
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

// -- Concurrency tests ------------------------------------------------------

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
        ctx.err_count.fetchAdd(1, .monotonic);
        return;
    };
    ctx.acquire_count.fetchAdd(1, .monotonic);
    switch (result) {
        .acquired => {
            _ = ctx.refresh_count.fetchAdd(1, .monotonic);
            // Simulate a short refresh delay
            std.time.sleep(5 * std.time.ns_per_ms);
            ctx.lock.complete(ctx.provider, null, null);
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

    // Pre-acquire the lock so all worker threads block on the
    // in-flight entry rather than racing to create new ones.
    const first_result = try lock.acquire("test-provider", null);
    try testing.expect(first_result == .acquired);

    const num_waiters = 4;
    var threads: [num_waiters]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, concurrentWorker, .{&ctx});
    }

    // Hold the lock a moment so waiters actually block.
    std.time.sleep(10 * std.time.ns_per_ms);
    lock.complete("test-provider", null, null);

    for (&threads) |t| {
        t.join();
    }

    // Exactly one refresh (the initial acquire).
    try testing.expectEqual(@as(usize, 1), ctx.refresh_count.load(.seq_cst));
    // All waiters got completed_ok.
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

    // Pre-acquire so all workers block.
    const first = try lock.acquire("prov-ok", null);
    try testing.expect(first == .acquired);

    const num_waiters = 5;
    var threads: [num_waiters]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, concurrentWorker, .{&ctx});
    }

    // Complete with success.
    std.time.sleep(5 * std.time.ns_per_ms);
    lock.complete("prov-ok", null, null);

    for (&threads) |t| {
        t.join();
    }

    try testing.expectEqual(@as(usize, 1), ctx.refresh_count.load(.seq_cst));
    try testing.expectEqual(@as(usize, num_waiters), ctx.ok_count.load(.seq_cst));
    try testing.expectEqual(@as(usize, 0), ctx.err_count.load(.seq_cst));
}

// -- Timeout tests ----------------------------------------------------------

test "lock held beyond timeout returns timed_out" {
    // 50 ms timeout for fast test
    var lock = RefreshLock.initWithTimeout(testing.allocator, 50);
    defer lock.deinit();

    // Acquire and hold — do NOT complete.
    const first = try lock.acquire("slow-provider", null);
    try testing.expect(first == .acquired);

    // Wait for the timeout to elapse.
    std.time.sleep(80 * std.time.ns_per_ms);

    // A second acquire should observe the timeout.
    const second = try lock.acquire("slow-provider", null);
    try testing.expect(second == .timed_out);

    // Clean up: complete the stale entry so deinit doesn't deadlock.
    lock.complete("slow-provider", null, null);
}

test "expireTimedOut marks stale entries as completed" {
    var lock = RefreshLock.initWithTimeout(testing.allocator, 50);
    defer lock.deinit();

    const first = try lock.acquire("expired-provider", null);
    try testing.expect(first == .acquired);

    std.time.sleep(80 * std.time.ns_per_ms);
    lock.expireTimedOut();

    // New acquire should see the expired entry.
    const second = try lock.acquire("expired-provider", null);
    try testing.expect(second == .timed_out);
}

// -- Diagnostics ------------------------------------------------------------

test "activeCount reports in-flight entries" {
    var lock = RefreshLock.init(testing.allocator);
    defer lock.deinit();

    try testing.expectEqual(@as(usize, 0), lock.activeCount());

    _ = try lock.acquire("a", null);
    try testing.expectEqual(@as(usize, 1), lock.activeCount());

    _ = try lock.acquire("b", null);
    try testing.expectEqual(@as(usize, 2), lock.activeCount());

    lock.complete("a", null, null);
    try testing.expectEqual(@as(usize, 1), lock.activeCount());

    lock.complete("b", null, null);
    try testing.expectEqual(@as(usize, 0), lock.activeCount());
}
