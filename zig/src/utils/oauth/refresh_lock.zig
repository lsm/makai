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
//! all waiters receive `error.AuthRefreshFailed`. Later callers can start a
//! fresh lock generation; stale owner completions are ignored.

const std = @import("std");

pub const RefreshLock = struct {
    pub const DEFAULT_TIMEOUT_MS: u64 = 30_000;

    const Entry = struct {
        key_owned: []const u8,
        acquired_at: std.time.Instant,
        cond: std.Thread.Condition,
        /// null  = refresh succeeded
        /// error = refresh failed with this error
        result: ?anyerror,
        completed: bool,
        /// True when completion was caused by refresh-lock timeout rather
        /// than owner-provided completion.
        timed_out: bool,
        /// Monotonic ownership token for this lock generation. Owner
        /// completion must present the same generation so stale owners from
        /// timed-out generations cannot complete a newer refresh.
        generation: u64,
        /// Reference count: 1 for the owner + N waiters.
        /// Whoever decrements to 0 removes and frees the entry.
        ref_count: usize,
        /// When true, the original owner is no longer counted in
        /// ref_count because a waiter expired the entry.  A later owner
        /// complete() becomes a no-op instead of decrementing below zero.
        owner_released: bool,
    };

    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    entries: std.StringHashMap(*Entry),
    timeout_ms: u64,
    next_generation: u64,
    /// When true, `acquire()` returns immediately with
    /// `error.AuthRefreshFailed`. Set by `deinit()` before broadcasting
    /// waiters; deinit waits for waiter refs to drain before freeing entries.
    shutdown: bool = false,

    pub const AcquireResult = union(enum) {
        /// Lock acquired — caller owns the refresh and **must** call `complete()`.
        acquired: u64,
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
            .next_generation = 1,
        };
    }

    pub fn deinit(self: *RefreshLock) void {
        // Hold the mutex while setting shutdown and marking entries
        // completed so any threads inside acquire() see a consistent
        // state. Setting shutdown first ensures waiters wake into the
        // shutdown path instead of interpreting the result as a normal
        // refresh completion.
        self.mutex.lock();
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
            entry.cond.broadcast();
        }

        // Wait for any woken waiters to release their refs before freeing.
        // Entries stay allocated while waiters unwind, so the shutdown branch
        // can safely decrement ref_count after reacquiring the mutex.
        while (self.entries.count() > 0) {
            var first_iter = self.entries.iterator();
            const entry = first_iter.next().?.value_ptr.*;
            while (entry.ref_count > 0) {
                entry.cond.wait(&self.mutex);
            }
            self.freeEntry(entry);
        }

        self.mutex.unlock();
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
        entry.cond.broadcast();
        return true;
    }

    fn releaseWaiterRef(self: *RefreshLock, entry: *Entry) void {
        entry.ref_count -= 1;
        if (self.shutdown) {
            entry.cond.broadcast();
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

    /// Check whether a stored lock key matches the given provider_id
    /// and optional user_id.  Used by `complete()` to avoid allocating
    /// a temporary lookup key.
    fn keyMatches(key: []const u8, provider_id: []const u8, user_id: ?[]const u8) bool {
        if (user_id) |uid| {
            // Multi-tenant key: "provider_id\x00user_id"
            const null_pos = std.mem.indexOfScalar(u8, key, 0) orelse return false;
            return std.mem.eql(u8, key[0..null_pos], provider_id) and
                std.mem.eql(u8, key[null_pos + 1 ..], uid);
        } else {
            // Single-tenant: key must be exactly provider_id with no null byte.
            if (std.mem.indexOfScalar(u8, key, 0) != null) return false;
            return std.mem.eql(u8, key, provider_id);
        }
    }

    fn nowInstant() !std.time.Instant {
        return std.time.Instant.now();
    }

    fn elapsedMs(entry: *const Entry, now: std.time.Instant) u64 {
        return @intCast(now.since(entry.acquired_at) / std.time.ns_per_ms);
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

        // Fast exit if the lock has been shut down.
        if (self.shutdown) {
            self.allocator.free(key);
            self.mutex.unlock();
            return error.AuthRefreshFailed;
        }

        if (self.entries.getPtr(key)) |entry_ptr| {
            // Entry already exists.
            const entry = entry_ptr.*;

            if (entry.completed) {
                // Timed-out entries are terminal only for the current
                // waiters. Later callers should recover by starting a
                // fresh refresh rather than failing forever.
                if (entry.timed_out) {
                    self.tryRecoverTimedOutEntry(entry);
                    if (self.entries.getPtr(key) != null) {
                        // Current waiters still hold refs; don't start a
                        // second overlapping refresh for the same scope.
                        self.allocator.free(key);
                        self.mutex.unlock();
                        return .timed_out;
                    }
                    // Fall through below and create a fresh entry for
                    // this caller. Keep `key` as the new owned map key.
                } else {
                    const result = entry.result;
                    self.allocator.free(key);
                    self.mutex.unlock();
                    return if (result) |err|
                        .{ .completed_err = err }
                    else
                        .completed_ok;
                }
            } else {
                // Check timeout.
                const now = nowInstant() catch |err| {
                    self.allocator.free(key);
                    self.mutex.unlock();
                    return err;
                };
                if (elapsedMs(entry, now) > self.timeout_ms) {
                    // Timed out — mark completed so all current waiters see
                    // the failure immediately, and release the owner's ref so
                    // future acquires can recover with a fresh refresh instead
                    // of being poisoned by a stuck owner forever.
                    _ = self.timeoutEntry(entry);
                    self.allocator.free(key);
                    self.mutex.unlock();
                    return .timed_out;
                }

                // Wait for the in-flight refresh. Use timed waits so a
                // waiter can enforce the refresh timeout even if no later
                // caller arrives to observe expiry.
                entry.ref_count += 1;
                while (!self.shutdown and !entry.completed) {
                    const instant = nowInstant() catch |err| {
                        self.releaseWaiterRef(entry);
                        self.allocator.free(key);
                        self.mutex.unlock();
                        return err;
                    };
                    const elapsed_ms = elapsedMs(entry, instant);
                    if (elapsed_ms >= self.timeout_ms) {
                        _ = self.timeoutEntry(entry);
                        self.releaseWaiterRef(entry);
                        self.allocator.free(key);
                        self.mutex.unlock();
                        return .timed_out;
                    }
                    const remaining_ms = self.timeout_ms - elapsed_ms;
                    const timeout_ns = remaining_ms * std.time.ns_per_ms;
                    entry.cond.timedWait(&self.mutex, timeout_ns) catch |err| switch (err) {
                        error.Timeout => {
                            if (!entry.completed) {
                                _ = self.timeoutEntry(entry);
                                self.releaseWaiterRef(entry);
                                self.allocator.free(key);
                                self.mutex.unlock();
                                return .timed_out;
                            }
                            break;
                        },
                    };
                }

                // If the lock was shut down while we were waiting, release
                // our waiter ref and wake deinit() if this was the last waiter.
                // deinit() waits for refs to drain before freeing entries, so
                // this cannot race with entry destruction.
                if (self.shutdown) {
                    self.releaseWaiterRef(entry);
                    self.allocator.free(key);
                    self.mutex.unlock();
                    return error.AuthRefreshFailed;
                }

                // Woken — read shared result.
                const result = entry.result;
                const timed_out = entry.timed_out;
                self.releaseWaiterRef(entry);
                self.allocator.free(key);
                self.mutex.unlock();
                if (timed_out) return .timed_out;
                return if (result) |err|
                    .{ .completed_err = err }
                else
                    .completed_ok;
            }
        }

        // No entry — create one.  Caller owns the refresh.
        const entry = self.allocator.create(Entry) catch |err| {
            self.allocator.free(key);
            self.mutex.unlock();
            return err;
        };
        const acquired_at = nowInstant() catch |err| {
            self.allocator.free(key);
            self.allocator.destroy(entry);
            self.mutex.unlock();
            return err;
        };

        const generation = self.next_generation;
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;

        entry.* = .{
            .key_owned = key,
            .acquired_at = acquired_at,
            .cond = .{},
            .result = null,
            .completed = false,
            .timed_out = false,
            .generation = generation,
            .ref_count = 1,
            .owner_released = false,
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
        return .{ .acquired = generation };
    }

    /// Complete a refresh and wake all waiters.
    ///
    /// `err` is `null` for success, or the error that caused the failure.
    /// This method does not allocate — it finds the entry by linear scan
    /// so that OOM cannot prevent completion.
    pub fn complete(self: *RefreshLock, provider_id: []const u8, user_id: ?[]const u8, generation: u64, err: ?anyerror) void {
        self.mutex.lock();

        // Find matching entry by linear scan.  This avoids allocating a
        // temporary lookup key (which can fail under memory pressure and
        // would leave the entry permanently locked).  The entry count is
        // typically in the single digits.
        var match: ?*Entry = null;
        var iter = self.entries.iterator();
        while (iter.next()) |hashmap_entry| {
            if (keyMatches(hashmap_entry.key_ptr.*, provider_id, user_id)) {
                match = hashmap_entry.value_ptr.*;
                break;
            }
        }

        const entry = match orelse {
            self.mutex.unlock();
            return;
        };

        if (entry.generation != generation or entry.timed_out) {
            self.mutex.unlock();
            return;
        }

        entry.result = err;
        entry.completed = true;
        entry.timed_out = false;
        entry.cond.broadcast();
        if (!entry.owner_released) {
            entry.owner_released = true;
            entry.ref_count -= 1;
        }

        if (entry.ref_count == 0) {
            self.freeEntry(entry);
        }
        self.mutex.unlock();
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
        const now = nowInstant() catch return;

        self.mutex.lock();
        // Collect entries to expire so we don't invalidate the iterator.
        var to_expire = std.ArrayList(*Entry).initCapacity(self.allocator, self.entries.count()) catch {
            self.mutex.unlock();
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
                entry.cond.broadcast();
            }
            // timeoutEntry releases the owner's ref. Waiters clean up
            // when ref_count hits 0, or timeoutEntry frees immediately
            // if no waiters remain.
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

    fn refCountForTesting(self: *RefreshLock, provider_id: []const u8, user_id: ?[]const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = self.entries.iterator();
        while (iter.next()) |hashmap_entry| {
            if (keyMatches(hashmap_entry.key_ptr.*, provider_id, user_id)) {
                return hashmap_entry.value_ptr.*.ref_count;
            }
        }
        return 0;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn expectAcquired(result: RefreshLock.AcquireResult) !u64 {
    return switch (result) {
        .acquired => |generation| generation,
        else => error.TestUnexpectedResult,
    };
}

// -- Basic lifecycle --------------------------------------------------------

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

    // Simulate: first acquire owns and completes successfully.
    const gen1 = try expectAcquired(try lock.acquire("prov", null));
    lock.complete("prov", null, gen1, null);

    // Once the owner completes with no waiters, the entry is removed.
    // A later acquire starts a new refresh.
    const gen2 = try expectAcquired(try lock.acquire("prov", null));
    lock.complete("prov", null, gen2, null);
}

test "RefreshLock acquire returns completed_err after failed refresh" {
    var lock = RefreshLock.init(testing.allocator);
    defer lock.deinit();

    const gen1 = try expectAcquired(try lock.acquire("prov", null));
    lock.complete("prov", null, gen1, error.AuthRefreshFailed);

    // Once the owner completes with no waiters, the entry is removed.
    // A later acquire starts a new refresh.
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

    // Completed entries with no waiters are removed, so a later acquire
    // starts a fresh scoped refresh.
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
        _ = ctx.err_count.fetchAdd(1, .monotonic);
        return;
    };
    _ = ctx.acquire_count.fetchAdd(1, .monotonic);
    switch (result) {
        .acquired => |generation| {
            _ = ctx.refresh_count.fetchAdd(1, .monotonic);
            // Simulate a short refresh delay
            std.Thread.sleep(5 * std.time.ns_per_ms);
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

    // Pre-acquire the lock so all worker threads block on the
    // in-flight entry rather than racing to create new ones.
    const first_gen = try expectAcquired(try lock.acquire("test-provider", null));

    const num_waiters = 4;
    var threads: [num_waiters]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, concurrentWorker, .{&ctx});
    }

    while (lock.refCountForTesting("test-provider", null) < num_waiters + 1) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    lock.complete("test-provider", null, first_gen, null);

    for (&threads) |t| {
        t.join();
    }

    // Workers were waiters only; the initial acquire owned the refresh.
    try testing.expectEqual(@as(usize, 0), ctx.refresh_count.load(.seq_cst));
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
    const first_gen = try expectAcquired(try lock.acquire("prov-ok", null));

    const num_waiters = 5;
    var threads: [num_waiters]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, concurrentWorker, .{&ctx});
    }

    while (lock.refCountForTesting("prov-ok", null) < num_waiters + 1) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    lock.complete("prov-ok", null, first_gen, null);

    for (&threads) |t| {
        t.join();
    }

    try testing.expectEqual(@as(usize, 0), ctx.refresh_count.load(.seq_cst));
    try testing.expectEqual(@as(usize, num_waiters), ctx.ok_count.load(.seq_cst));
    try testing.expectEqual(@as(usize, 0), ctx.err_count.load(.seq_cst));
}

// -- Timeout tests ----------------------------------------------------------

test "lock held beyond timeout returns timed_out" {
    // 50 ms timeout for fast test
    var lock = RefreshLock.initWithTimeout(testing.allocator, 50);
    defer lock.deinit();

    // Acquire and hold — do NOT complete.
    const first_gen = try expectAcquired(try lock.acquire("slow-provider", null));

    // Wait for the timeout to elapse.
    std.Thread.sleep(80 * std.time.ns_per_ms);

    // A second acquire should observe the timeout.
    const second = try lock.acquire("slow-provider", null);
    try testing.expect(second == .timed_out);

    // Clean up: complete the stale entry so deinit doesn't deadlock.
    lock.complete("slow-provider", null, first_gen, null);
}

test "expireTimedOut marks stale entries as completed" {
    var lock = RefreshLock.initWithTimeout(testing.allocator, 50);
    defer lock.deinit();

    _ = try expectAcquired(try lock.acquire("expired-provider", null));

    std.Thread.sleep(80 * std.time.ns_per_ms);
    lock.expireTimedOut();

    // No waiters were holding refs, so expireTimedOut removes the stale
    // entry and a later acquire can recover with a fresh refresh.
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

    // The stale owner completion uses the old generation and must not corrupt
    // the recovered in-flight refresh.
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

    // A late owner completion for the same generation must not clear
    // timed_out=false or replace the timeout with a success result.
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

    std.Thread.sleep(5 * std.time.ns_per_ms);
    var deinit_ctx = DeinitCtx{ .lock = &lock };
    const deinit_thread = try std.Thread.spawn(.{}, deinitWorker, .{&deinit_ctx});

    waiter.join();
    deinit_thread.join();
}

// -- Diagnostics ------------------------------------------------------------

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
