//! Event-driven keyboard (re-)enumeration notifications via
//! IOServiceAddMatchingNotification.
//!
//! Why: the grabber's seize silently dies when the built-in keyboard
//! re-enumerates across a `DarkWake from Deep Idle` — the old IORegistry
//! entry terminates, a new one appears, but that DarkWake never delivers
//! a full system power-on, so a wake-driven re-seize never fires and the
//! seize keeps holding the dead device (keyboard appears dead; verified —
//! old entry id 4294969998 → new 4295340270).
//!
//! This subscribes to the IOKit registry directly (kIOFirstMatch +
//! kIOTerminated on a keyboard matching dict). The kernel fires the
//! callback exactly when a keyboard appears or disappears, so we re-seize
//! precisely when needed — no polling, zero steady-state overhead on a
//! 24/7 daemon. This is the same mechanism Karabiner-Elements'
//! iokit_service_monitor is built on.
//!
//! The agent uses it too (KeyboardWatch): a keyboard that re-enumerates
//! gets a new HID service, and per-service state such as a `.remap`
//! UserKeyMapping is lost with the old one, so the agent re-applies it for
//! the devices each batch reports.
//!
//! Lifetime: one DeviceNotify per Daemon, and one per agent KeyboardWatch.
//! init creates an IONotificationPort on the current run loop and arms the
//! notifications by draining their initial iterators (the pre-existing
//! devices, which the caller has already handled — so the initial drain
//! does NOT call on_change). deinit removes the source and releases the
//! port + iterators.

const std = @import("std");
const c = @import("c.zig");

const log = std.log.scoped(.device_notify);

/// Invoked (on the run-loop thread, between run-loop sources) once per
/// batch of keyboards that enumerated or terminated.
pub const ChangeCallback = *const fn (ctx: ?*anyopaque, change: Change) void;

/// Most services reported per batch. One device can enumerate several
/// keyboard services at once; `Change.overflowed` covers the rest.
pub const max_batch = 8;

/// A keyboard service's identity, read off its registry node. FIFO
/// built-ins carry no VendorID/ProductID and read as 0/0.
pub const Device = struct {
    vendor: u32,
    product: u32,
    built_in: bool,
};

pub const Change = struct {
    kind: Kind,
    /// The first `max_batch` services in the batch. Borrowed for the
    /// duration of the callback only.
    devices: []const Device,
    /// The batch held more services than `devices` reports.
    overflowed: bool,

    pub const Kind = enum { matched, terminated };
};

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

/// Drain + log every service in the iterator, recording up to
/// `buf.len` of them. Draining is mandatory: it both reads the changed
/// services and re-arms the notification for the next event.
fn drain(iter: c.io_iterator_t, kind: Change.Kind, buf: []Device) Change {
    var n: usize = 0;
    var overflowed = false;
    while (true) {
        const svc = c.IOIteratorNext(iter);
        if (svc == c.IO_OBJECT_NULL) break;
        defer _ = c.IOObjectRelease(svc);
        var id: u64 = 0;
        _ = c.IORegistryEntryGetRegistryEntryID(svc, &id);
        const dev: Device = .{
            .vendor = registryU32(svc, c.kIOHIDVendorIDKey),
            .product = registryU32(svc, c.kIOHIDProductIDKey),
            // A direct registry read, so unlike IOHIDManager device
            // matching (see HidSeize) it does see Built-In.
            .built_in = registryBool(svc, "Built-In"),
        };
        // info, NOT warn: this fires on every keyboard enumeration change
        // (each wake, USB plug, vhidd reconnect) — routine operation, not
        // an anomaly. Compiled out of ReleaseFast so a forever-running
        // daemon's release log doesn't accumulate per-wake noise; visible
        // in a ReleaseSafe diagnostic build.
        log.info("keyboard {s}: entry_id={d} vendor=0x{X:0>4} product=0x{X:0>4} built_in={}", .{ @tagName(kind), id, dev.vendor, dev.product, dev.built_in });
        if (n == buf.len) {
            overflowed = true;
            continue;
        }
        buf[n] = dev;
        n += 1;
    }
    return .{ .kind = kind, .devices = buf[0..n], .overflowed = overflowed };
}

/// Read an integer property off a registry node; 0 when absent.
fn registryU32(svc: c.io_object_t, key_cstr: [*:0]const u8) u32 {
    const key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, key_cstr, c.kCFStringEncodingUTF8);
    if (key == null) return 0;
    defer c.CFRelease(key);
    const value = c.IORegistryEntryCreateCFProperty(svc, key, c.kCFAllocatorDefault, 0) orelse return 0;
    defer c.CFRelease(value);
    if (c.CFGetTypeID(value) != c.CFNumberGetTypeID()) return 0;
    var out: i32 = 0;
    _ = c.CFNumberGetValue(value, c.kCFNumberSInt32Type, &out);
    return @bitCast(out);
}

/// Read a boolean property off a registry node; false when absent.
fn registryBool(svc: c.io_object_t, key_cstr: [*:0]const u8) bool {
    const key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, key_cstr, c.kCFStringEncodingUTF8);
    if (key == null) return false;
    defer c.CFRelease(key);
    const value = c.IORegistryEntryCreateCFProperty(svc, key, c.kCFAllocatorDefault, 0) orelse return false;
    defer c.CFRelease(value);
    if (c.CFGetTypeID(value) != c.CFBooleanGetTypeID()) return false;
    return c.CFBooleanGetValue(value) != 0;
}

fn matchedCallback(refcon: ?*anyopaque, iterator: c.io_iterator_t) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(refcon orelse return));
    var buf: [max_batch]Device = undefined;
    self.on_change(self.on_change_ctx, drain(iterator, .matched, &buf));
}

fn terminatedCallback(refcon: ?*anyopaque, iterator: c.io_iterator_t) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(refcon orelse return));
    var buf: [max_batch]Device = undefined;
    self.on_change(self.on_change_ctx, drain(iterator, .terminated, &buf));
}

// Live check that `drain` reads real keyboards' identities: the registry
// property types and the VendorID-less built-in are the parts a unit test
// can't reach. Gated like HidSeize's live tests:
//
//     SKHD_HID_LIVE=1 zig build test
test "live: drain reads connected keyboards' vendor, product and built-in" {
    if (std.c.getenv("SKHD_HID_LIVE") == null) return error.SkipZigTest;

    const dict = c.IOServiceMatching(c.kIOHIDDeviceKey) orelse return error.MatchingDictFailed;
    setNumberKey(dict, c.kIOHIDPrimaryUsagePageKey, c.kHIDPage_GenericDesktop);
    setNumberKey(dict, c.kIOHIDPrimaryUsageKey, c.kHIDUsage_GD_Keyboard);
    var iter: c.io_iterator_t = c.IO_OBJECT_NULL;
    // Consumes the dict.
    if (c.IOServiceGetMatchingServices(c.kIOMainPortDefault, dict, &iter) != c.kIOReturnSuccess) return error.CannotVerify;
    defer _ = c.IOObjectRelease(iter);

    var buf: [max_batch]Device = undefined;
    const change = drain(iter, .matched, &buf);
    for (change.devices) |d| {
        std.debug.print("keyboard vendor=0x{X:0>4} product=0x{X:0>4} built_in={}\n", .{ d.vendor, d.product, d.built_in });
        // A built-in is matched by transport, never VID/PID (see HidSeize).
        if (d.built_in) try std.testing.expectEqual(@as(u32, 0), d.vendor);
    }
    try std.testing.expect(change.devices.len > 0);
}
