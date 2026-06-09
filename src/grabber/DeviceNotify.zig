//! Event-driven keyboard (re-)enumeration notifications via
//! IOServiceAddMatchingNotification.
//!
//! Why: the grabber's seize silently dies when the built-in keyboard
//! re-enumerates across a `DarkWake from Deep Idle` — the old IORegistry
//! entry terminates, a new one appears, but that DarkWake never delivers
//! `kIOMessageSystemHasPoweredOn`, so PowerNotify's re-seize never fires
//! and the seize keeps holding the dead device (keyboard appears dead;
//! verified — old entry id 4294969998 → new 4295340270).
//!
//! This subscribes to the IOKit registry directly (kIOFirstMatch +
//! kIOTerminated on a keyboard matching dict). The kernel fires the
//! callback exactly when a keyboard appears or disappears, so we re-seize
//! precisely when needed — no polling, zero steady-state overhead on a
//! 24/7 daemon. This is the same mechanism Karabiner-Elements'
//! iokit_service_monitor is built on.
//!
//! Lifetime: one DeviceNotify per Daemon. init creates an
//! IONotificationPort on the current run loop and arms the notifications
//! by draining their initial iterators (the pre-existing devices, which
//! startup already seized — so the initial drain does NOT re-seize).
//! deinit removes the source and releases the port + iterators.

const std = @import("std");
const c = @import("c.zig");

const log = std.log.scoped(.device_notify);

/// Invoked (on the run-loop thread, between run-loop sources) whenever a
/// keyboard enumerates or terminates. The handler re-seizes.
pub const ChangeCallback = *const fn (ctx: ?*anyopaque) void;

allocator: std.mem.Allocator,
notify_port: c.IONotificationPortRef = null,
run_loop_source: c.CFRunLoopSourceRef = null,
matched_iter: c.io_iterator_t = c.IO_OBJECT_NULL,
terminated_iter: c.io_iterator_t = c.IO_OBJECT_NULL,
on_change: ChangeCallback,
on_change_ctx: ?*anyopaque,

const Self = @This();

pub fn init(
    allocator: std.mem.Allocator,
    on_change: ChangeCallback,
    on_change_ctx: ?*anyopaque,
) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .on_change = on_change,
        .on_change_ctx = on_change_ctx,
    };

    const port = c.IONotificationPortCreate(c.kIOMainPortDefault);
    if (port == null) {
        log.err("IONotificationPortCreate failed", .{});
        return error.NotificationPortFailed;
    }
    errdefer c.IONotificationPortDestroy(port);
    self.notify_port = port;

    const source = c.IONotificationPortGetRunLoopSource(port);
    if (source == null) {
        log.err("IONotificationPortGetRunLoopSource returned null", .{});
        return error.RunLoopSourceFailed;
    }
    c.CFRunLoopAddSource(c.CFRunLoopGetCurrent(), source, c.kCFRunLoopDefaultMode);
    self.run_loop_source = source;
    errdefer c.CFRunLoopRemoveSource(c.CFRunLoopGetCurrent(), source, c.kCFRunLoopDefaultMode);

    // Keyboard matching dict: { IOProviderClass = IOHIDDevice,
    // PrimaryUsagePage = GenericDesktop, PrimaryUsage = Keyboard }. The
    // built-in keyboard's IOHIDDevice node exposes these (verified via
    // ioreg); mice/trackpads (usage != 6) are excluded so an unrelated
    // device plug doesn't churn the seize.
    const dict = c.IOServiceMatching(c.kIOHIDDeviceKey);
    if (dict == null) {
        log.err("IOServiceMatching(IOHIDDevice) failed", .{});
        return error.MatchingDictFailed;
    }
    defer c.CFRelease(dict);
    setNumberKey(dict, c.kIOHIDPrimaryUsagePageKey, c.kHIDPage_GenericDesktop);
    setNumberKey(dict, c.kIOHIDPrimaryUsageKey, c.kHIDUsage_GD_Keyboard);

    // IOServiceAddMatchingNotification consumes one ref of the dict per
    // call; CFRetain to keep our own (released by `defer` above).
    _ = c.CFRetain(dict);
    const mr = c.IOServiceAddMatchingNotification(port, c.kIOFirstMatchNotification, dict, matchedCallback, self, &self.matched_iter);
    if (mr != c.kIOReturnSuccess) {
        log.err("IOServiceAddMatchingNotification(match) failed: 0x{X:0>8}", .{@as(u32, @bitCast(mr))});
        return error.AddNotificationFailed;
    }
    errdefer _ = c.IOObjectRelease(self.matched_iter);

    _ = c.CFRetain(dict);
    const tr = c.IOServiceAddMatchingNotification(port, c.kIOTerminatedNotification, dict, terminatedCallback, self, &self.terminated_iter);
    if (tr != c.kIOReturnSuccess) {
        log.err("IOServiceAddMatchingNotification(terminate) failed: 0x{X:0>8}", .{@as(u32, @bitCast(tr))});
        return error.AddNotificationFailed;
    }
    errdefer _ = c.IOObjectRelease(self.terminated_iter);

    // Drain the initial iterators to ARM the notifications. These are the
    // keyboards already present at startup, which the normal seize path
    // already grabbed — so drain silently, do NOT call on_change.
    drainSilently(self.matched_iter);
    drainSilently(self.terminated_iter);

    log.info("registered for keyboard enumeration notifications", .{});
    return self;
}

pub fn deinit(self: *Self) void {
    if (self.run_loop_source) |src| {
        c.CFRunLoopRemoveSource(c.CFRunLoopGetCurrent(), src, c.kCFRunLoopDefaultMode);
        self.run_loop_source = null; // owned by the port; don't release
    }
    if (self.matched_iter != c.IO_OBJECT_NULL) {
        _ = c.IOObjectRelease(self.matched_iter);
        self.matched_iter = c.IO_OBJECT_NULL;
    }
    if (self.terminated_iter != c.IO_OBJECT_NULL) {
        _ = c.IOObjectRelease(self.terminated_iter);
        self.terminated_iter = c.IO_OBJECT_NULL;
    }
    if (self.notify_port) |p| {
        c.IONotificationPortDestroy(p);
        self.notify_port = null;
    }
    self.allocator.destroy(self);
}

fn setNumberKey(dict: c.CFMutableDictionaryRef, key_cstr: [*:0]const u8, value: i32) void {
    const key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, key_cstr, c.kCFStringEncodingUTF8);
    if (key == null) return;
    defer c.CFRelease(key);
    var v = value;
    const num = c.CFNumberCreate(c.kCFAllocatorDefault, c.kCFNumberSInt32Type, &v);
    if (num == null) return;
    defer c.CFRelease(num);
    c.CFDictionarySetValue(dict, key, num);
}

/// Drain an iterator without acting on it — used at startup to arm the
/// notification against the already-seized device set.
fn drainSilently(iter: c.io_iterator_t) void {
    while (true) {
        const svc = c.IOIteratorNext(iter);
        if (svc == c.IO_OBJECT_NULL) break;
        _ = c.IOObjectRelease(svc);
    }
}

/// Drain + log every service in the iterator. Draining is mandatory:
/// it both reads the changed services and re-arms the notification for
/// the next event. `kind` labels the forensic log line.
fn drainAndLog(iter: c.io_iterator_t, kind: []const u8) void {
    while (true) {
        const svc = c.IOIteratorNext(iter);
        if (svc == c.IO_OBJECT_NULL) break;
        var id: u64 = 0;
        _ = c.IORegistryEntryGetRegistryEntryID(svc, &id);
        // warn: rare (only on real keyboard enumeration changes), so it
        // stays in the ReleaseFast log as the record of why we re-seized.
        log.warn("keyboard {s}: entry_id={d}", .{ kind, id });
        _ = c.IOObjectRelease(svc);
    }
}

fn matchedCallback(refcon: ?*anyopaque, iterator: c.io_iterator_t) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(refcon orelse return));
    drainAndLog(iterator, "matched");
    self.on_change(self.on_change_ctx);
}

fn terminatedCallback(refcon: ?*anyopaque, iterator: c.io_iterator_t) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(refcon orelse return));
    drainAndLog(iterator, "terminated");
    self.on_change(self.on_change_ctx);
}
