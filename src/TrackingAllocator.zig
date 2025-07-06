const std = @import("std");
const log = std.log.scoped(.tracking_allocator);

/// TrackingAllocator - A debugging allocator that tracks all allocations
///
/// This implementation is based on common allocation tracking patterns found in:
/// - Zig's standard library (formerly std.heap.LoggingAllocator, removed in 0.11)
/// - The Zig Allocator interface design: https://ziglang.org/documentation/master/#Allocators
/// - Similar implementations in other allocators like jemalloc's profiling mode
///
/// Key concepts:
/// 1. Allocator Wrapping Pattern - wraps another allocator to intercept all operations
/// 2. Metadata Tracking - uses a HashMap to store allocation metadata
/// 3. Thread Safety - uses mutex for concurrent access
///
/// References for learning:
/// - Zig's Allocator interface: https://ziglang.org/documentation/master/std/#std.mem.Allocator
/// - "Writing a Custom Allocator" by Andrew Kelley: https://www.youtube.com/watch?v=vHWiDx_l4V0
/// - The old LoggingAllocator source: https://github.com/ziglang/zig/blob/0.10.x/lib/std/heap/logging_allocator.zig
/// - Memory debugging techniques: https://valgrind.org/docs/manual/mc-manual.html
const TrackingAllocator = @This();

/// The underlying allocator that performs actual allocations
child_allocator: std.mem.Allocator,
/// Map of allocation addresses to their metadata
allocations: std.AutoHashMap(usize, AllocationInfo),
/// Total bytes currently allocated
total_allocated: usize = 0,
/// Peak bytes allocated
peak_allocated: usize = 0,
/// Total number of allocations made
total_allocations: u64 = 0,
/// Total number of deallocations made
total_deallocations: u64 = 0,
/// Mutex for thread safety
mutex: std.Thread.Mutex = .{},

pub const AllocationInfo = struct {
    size: usize,
    stack_trace: std.builtin.StackTrace,
    timestamp: i64,
};

pub fn init(child_allocator: std.mem.Allocator) !TrackingAllocator {
    return TrackingAllocator{
        .child_allocator = child_allocator,
        .allocations = std.AutoHashMap(usize, AllocationInfo).init(child_allocator),
    };
}

pub fn deinit(self: *TrackingAllocator) void {
    if (self.allocations.count() > 0) {
        log.warn("Memory leaks detected! {} allocations not freed", .{self.allocations.count()});
        var it = self.allocations.iterator();
        while (it.next()) |entry| {
            log.warn("Leaked {} bytes at 0x{x}", .{ entry.value_ptr.size, entry.key_ptr.* });
            dumpStackTrace(entry.value_ptr.stack_trace);
        }
    }
    self.allocations.deinit();
}

/// Returns a std.mem.Allocator interface that wraps this tracking allocator
/// This follows Zig's allocator interface pattern where allocators return
/// a fat pointer (ptr + vtable) that implements the Allocator interface
pub fn allocator(self: *TrackingAllocator) std.mem.Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .free = free,
            .remap = remap,
        },
    };
}

// VTable implementation functions
// These follow the exact signatures required by std.mem.Allocator.VTable
// See: https://github.com/ziglang/zig/blob/master/lib/std/mem/Allocator.zig

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));

    const result = self.child_allocator.rawAlloc(len, alignment, ret_addr) orelse return null;

    self.mutex.lock();
    defer self.mutex.unlock();

    // Record allocation
    const addr = @intFromPtr(result);
    var stack_trace = std.builtin.StackTrace{
        .instruction_addresses = &[_]usize{},
        .index = 0,
    };

    // Capture stack trace if in debug mode
    if (@import("builtin").mode == .Debug) {
        var addresses: [32]usize = undefined;
        var trace = std.builtin.StackTrace{
            .instruction_addresses = &addresses,
            .index = 0,
        };
        std.debug.captureStackTrace(ret_addr, &trace);
        stack_trace = trace;
    }

    self.allocations.put(addr, .{
        .size = len,
        .stack_trace = stack_trace,
        .timestamp = std.time.milliTimestamp(),
    }) catch {
        // If we can't track it, still return the allocation
        log.warn("Failed to track allocation of {} bytes", .{len});
    };

    self.total_allocated += len;
    self.total_allocations += 1;
    if (self.total_allocated > self.peak_allocated) {
        self.peak_allocated = self.total_allocated;
    }

    // Always log allocations
    const stderr = std.io.getStdErr().writer();
    stderr.print("[ALLOC] {} bytes at 0x{x} (total: {}, peak: {})\n", .{
        len,
        addr,
        self.total_allocated,
        self.peak_allocated,
    }) catch {};

    return result;
}

fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));

    if (!self.child_allocator.rawResize(buf, buf_align, new_len, ret_addr)) {
        return false;
    }

    self.mutex.lock();
    defer self.mutex.unlock();

    const addr = @intFromPtr(buf.ptr);
    if (self.allocations.get(addr)) |info| {
        const old_size = info.size;
        var new_info = info;
        new_info.size = new_len;
        self.allocations.put(addr, new_info) catch {};

        if (new_len > old_size) {
            self.total_allocated += new_len - old_size;
        } else {
            self.total_allocated -= old_size - new_len;
        }

        if (self.total_allocated > self.peak_allocated) {
            self.peak_allocated = self.total_allocated;
        }

        // Always log resizes
        const stderr = std.io.getStdErr().writer();
        stderr.print("[RESIZE] {} -> {} bytes at 0x{x} (total: {})\n", .{
            old_size,
            new_len,
            addr,
            self.total_allocated,
        }) catch {};
    }

    return true;
}

fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
    const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));

    self.mutex.lock();
    defer self.mutex.unlock();

    const addr = @intFromPtr(buf.ptr);
    if (self.allocations.fetchRemove(addr)) |entry| {
        self.total_allocated -= entry.value.size;
        self.total_deallocations += 1;

        // Always log frees
        const stderr = std.io.getStdErr().writer();
        stderr.print("[FREE] {} bytes at 0x{x} (total: {})\n", .{
            entry.value.size,
            addr,
            self.total_allocated,
        }) catch {};
    } else {
        log.warn("Freeing untracked allocation at 0x{x}", .{addr});
    }

    self.child_allocator.rawFree(buf, buf_align, ret_addr);
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));

    const result = self.child_allocator.vtable.remap(self.child_allocator.ptr, memory, alignment, new_len, ret_addr) orelse return null;

    self.mutex.lock();
    defer self.mutex.unlock();

    const old_addr = @intFromPtr(memory.ptr);
    const new_addr = @intFromPtr(result);

    if (old_addr != new_addr) {
        // Memory was moved to a new location
        if (self.allocations.fetchRemove(old_addr)) |entry| {
            // Track the new allocation
            self.allocations.put(new_addr, .{
                .size = new_len,
                .stack_trace = entry.value.stack_trace,
                .timestamp = std.time.milliTimestamp(),
            }) catch {};

            // Update total allocated
            if (new_len > entry.value.size) {
                self.total_allocated += new_len - entry.value.size;
            } else {
                self.total_allocated -= entry.value.size - new_len;
            }

            if (self.total_allocated > self.peak_allocated) {
                self.peak_allocated = self.total_allocated;
            }
        }
    } else {
        // Memory was resized in place
        if (self.allocations.getPtr(old_addr)) |info| {
            const old_size = info.size;
            info.size = new_len;

            if (new_len > old_size) {
                self.total_allocated += new_len - old_size;
            } else {
                self.total_allocated -= old_size - new_len;
            }

            if (self.total_allocated > self.peak_allocated) {
                self.peak_allocated = self.total_allocated;
            }
        }
    }

    return result;
}

pub fn printReport(self: *TrackingAllocator, writer: anytype) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    try writer.print("\n=== Memory Allocation Report ===\n", .{});
    try writer.print("Total allocations: {}\n", .{self.total_allocations});
    try writer.print("Total deallocations: {}\n", .{self.total_deallocations});
    try writer.print("Current allocated: {} bytes\n", .{self.total_allocated});
    try writer.print("Peak allocated: {} bytes\n", .{self.peak_allocated});
    try writer.print("Active allocations: {}\n", .{self.allocations.count()});

    if (self.allocations.count() > 0) {
        try writer.print("\nActive allocations:\n", .{});
        var it = self.allocations.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            if (i >= 10) {
                try writer.print("... and {} more\n", .{self.allocations.count() - 10});
                break;
            }
            try writer.print("  {} bytes at 0x{x}\n", .{ entry.value_ptr.size, entry.key_ptr.* });
        }
    }
    try writer.print("================================\n", .{});
}

fn dumpStackTrace(trace: std.builtin.StackTrace) void {
    if (trace.index == 0) return;

    const stderr = std.io.getStdErr().writer();
    // Simple stack trace dumping for now - just print the addresses
    stderr.print("Stack trace:\n", .{}) catch {};
    for (trace.instruction_addresses[0..trace.index]) |addr| {
        stderr.print("  0x{x}\n", .{addr}) catch {};
    }
}

test "TrackingAllocator basic functionality" {
    var tracker = try TrackingAllocator.init(std.testing.allocator);
    defer tracker.deinit();

    const tracking_alloc = tracker.allocator();

    // Test allocation
    const ptr1 = try tracking_alloc.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), tracker.total_allocated);
    try std.testing.expectEqual(@as(u64, 1), tracker.total_allocations);

    // Test another allocation
    const ptr2 = try tracking_alloc.alloc(u8, 200);
    try std.testing.expectEqual(@as(usize, 300), tracker.total_allocated);
    try std.testing.expectEqual(@as(usize, 300), tracker.peak_allocated);

    // Test deallocation
    tracking_alloc.free(ptr1);
    try std.testing.expectEqual(@as(usize, 200), tracker.total_allocated);
    try std.testing.expectEqual(@as(u64, 1), tracker.total_deallocations);

    // Peak should remain unchanged
    try std.testing.expectEqual(@as(usize, 300), tracker.peak_allocated);

    // Clean up
    tracking_alloc.free(ptr2);
    try std.testing.expectEqual(@as(usize, 0), tracker.total_allocated);
}
