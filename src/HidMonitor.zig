//! IOHIDManager wrapper for per-event device attribution.
//!
//! Subscribes (read-only, no seize) to keyboard-class HID input events on
//! the macOS HID system. Each input value is appended to a fixed-size ring
//! buffer keyed by `mach_absolute_time`. The CGEventTap callback then asks
//! `findRecentDevice(timestamp, window_ns)` to attribute its event to a
//! source device by timestamp proximity.
//!
//! Permission: requires Input Monitoring. `IOHIDManagerOpen` returns a
//! non-zero IOReturn if permission is denied; the daemon logs and
//! continues without device matching.

const std = @import("std");
const c = @import("c.zig");
const log = std.log.scoped(.hid_monitor);

const HidMonitor = @This();

/// HID Usage Tables (USB-IF, stable). The IOHIDUsageTables.h header is not
/// shipped in the Command Line Tools SDK so we declare what we need.
pub const kHIDPage_GenericDesktop: u32 = 0x01;
pub const kHIDUsage_GD_Keyboard: u32 = 0x06;
pub const kHIDPage_KeyboardOrKeypad: u32 = 0x07;

const RING_SIZE: usize = 256;

pub const RingEntry = struct {
    timestamp: u64,
    vendor: u32,
    product: u32,
    /// HID usage page (e.g. 0x07 for Keyboard/Keypad).
    usage_page: u32,
    /// HID usage code (e.g. 0x04 for KeyboardA). NOT a Mac virtual keycode;
    /// for cross-stream timestamp correlation only.
    usage: u32,
    value: i32,
};

pub const DeviceInfo = struct {
    vendor: u32,
    product: u32,
    /// Owned. Heap-allocated copy of the IOHIDDevice's "Product" property
    /// (e.g. "HHKB-Hybrid"). Empty if the device exposes no product string.
    product_name: []u8,
    transport: Transport,
};

pub const Transport = enum {
    usb,
    bluetooth,
    other,
};

/// Cached `mach_timebase_info()` for converting `IOHIDValueGetTimeStamp`
/// (raw mach_absolute_time ticks) into nanoseconds. On Apple Silicon
/// the ratio is typically 125/3 (~41.67 ns/tick); on Intel it's 1/1
/// (ticks already equal nanoseconds). CGEventGetTimestamp returns
/// nanoseconds pre-converted (despite Apple's docs implying otherwise),
/// so we have to align HID timestamps to that unit before correlating.
var timebase_numer: u32 = 0;
var timebase_denom: u32 = 0;

extern "c" fn mach_timebase_info(info: *mach_timebase_info_data) c_int;

const mach_timebase_info_data = extern struct {
    numer: u32,
    denom: u32,
};

fn ticksToNanos(ticks: u64) u64 {
    if (timebase_denom == 0) return ticks; // not initialised; fall back
    // (ticks * numer) / denom — multiply first for precision. ticks is
    // u64; even on Apple Silicon it won't overflow for any realistic
    // uptime.
    return (ticks * timebase_numer) / timebase_denom;
}

allocator: std.mem.Allocator,
manager: c.IOHIDManagerRef,
/// Ring of recent HID input events. Single-producer (HID callback on
/// main run loop), single-consumer (CGEventTap callback on the same run
/// loop). No locking needed — both callbacks are serialized through
/// `CFRunLoopGetMain()`.
ring: [RING_SIZE]RingEntry,
/// Index of the next slot to write. Wraps around RING_SIZE.
ring_pos: usize,
/// Map IOHIDDeviceRef -> {vendor, product, name, transport}. Populated by
/// device-matching callback; consulted by input-value callback to enrich
/// each event with vendor/product before ring insertion.
devices: std.AutoHashMapUnmanaged(c.IOHIDDeviceRef, DeviceInfo),
/// True once `IOHIDManagerOpen` has returned success and the run-loop
/// schedule has happened. False if permission was denied — daemon
/// continues without device matching.
opened: bool,

pub fn init(allocator: std.mem.Allocator) !*HidMonitor {
    // One-time mach_timebase setup. Cheap to do here; the values are
    // constant for the life of the process.
    if (timebase_denom == 0) {
        var info: mach_timebase_info_data = .{ .numer = 0, .denom = 0 };
        if (mach_timebase_info(&info) == 0 and info.denom != 0) {
            timebase_numer = info.numer;
            timebase_denom = info.denom;
            log.info("mach_timebase: numer={d} denom={d} ({d:.2} ns/tick)", .{
                info.numer,
                info.denom,
                @as(f64, @floatFromInt(info.numer)) / @as(f64, @floatFromInt(info.denom)),
            });
        } else {
            log.warn("mach_timebase_info failed; HID timestamps will not be unit-aligned with CGEvent. Correlation will likely miss.", .{});
        }
    }

    const self = try allocator.create(HidMonitor);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .manager = c.IOHIDManagerCreate(c.kCFAllocatorDefault, c.kIOHIDOptionsTypeNone) orelse return error.IOHIDManagerCreateFailed,
        .ring = [_]RingEntry{std.mem.zeroes(RingEntry)} ** RING_SIZE,
        .ring_pos = 0,
        .devices = .empty,
        .opened = false,
    };
    errdefer c.CFRelease(self.manager);

    // Match keyboard-class HID devices.
    const matching = try buildKeyboardMatchingDict();
    defer c.CFRelease(matching);
    c.IOHIDManagerSetDeviceMatching(self.manager, matching);

    // Register callbacks before opening so we hear about every device that
    // matches the dictionary at open time.
    c.IOHIDManagerRegisterDeviceMatchingCallback(self.manager, deviceAddedCallback, self);
    c.IOHIDManagerRegisterDeviceRemovalCallback(self.manager, deviceRemovedCallback, self);
    c.IOHIDManagerRegisterInputValueCallback(self.manager, inputValueCallback, self);

    return self;
}

/// Open the manager (Input Monitoring permission gate) and schedule on
/// the main run loop. Returns false if permission is denied. Caller logs.
pub fn open(self: *HidMonitor) bool {
    const rc = c.IOHIDManagerOpen(self.manager, c.kIOHIDOptionsTypeNone);
    if (rc != 0) {
        log.warn("IOHIDManagerOpen failed (0x{x}). Likely Input Monitoring permission denied. Per-device matching disabled.", .{rc});
        return false;
    }
    c.IOHIDManagerScheduleWithRunLoop(self.manager, c.CFRunLoopGetMain(), c.kCFRunLoopCommonModes);
    self.opened = true;
    return true;
}

/// Synchronous device enumeration for `--list-devices`. Opens the manager
/// and populates `self.devices` directly via `IOHIDManagerCopyDevices`,
/// without scheduling a run loop. Returns `error.PermissionDenied` when
/// the open fails (typically Input Monitoring not yet granted).
pub fn enumerateNow(self: *HidMonitor) !void {
    const rc = c.IOHIDManagerOpen(self.manager, c.kIOHIDOptionsTypeNone);
    if (rc != 0) return error.PermissionDenied;
    self.opened = true;

    const set = c.IOHIDManagerCopyDevices(self.manager) orelse return;
    defer c.CFRelease(set);

    const count = c.CFSetGetCount(set);
    if (count == 0) return;

    const buf = try self.allocator.alloc(c.IOHIDDeviceRef, @intCast(count));
    defer self.allocator.free(buf);
    c.CFSetGetValues(set, @ptrCast(buf.ptr));

    for (buf) |dev| {
        if (dev == null) continue;
        const info = readDeviceInfo(self.allocator, dev) catch continue;
        self.devices.put(self.allocator, dev, info) catch {
            self.allocator.free(info.product_name);
        };
    }
}

pub fn deinit(self: *HidMonitor) void {
    if (self.opened) {
        c.IOHIDManagerUnscheduleFromRunLoop(self.manager, c.CFRunLoopGetMain(), c.kCFRunLoopCommonModes);
        _ = c.IOHIDManagerClose(self.manager, c.kIOHIDOptionsTypeNone);
    }

    var it = self.devices.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.value_ptr.product_name);
    }
    self.devices.deinit(self.allocator);

    c.CFRelease(self.manager);
    self.allocator.destroy(self);
}

/// Walk the ring buffer backwards from the most recent write and return
/// the device whose HID input timestamp is within `window_ns` of `now_ns`.
/// Returns null on no match (caller falls through to device-agnostic
/// rule lookup). `now_ns` is in nanoseconds (CGEventGetTimestamp's unit).
pub fn findRecentDevice(self: *const HidMonitor, now_ns: u64, window_ns: u64) ?DeviceID {
    if (!self.opened) return null;

    // Search from most recent backwards. Two-fingered loop because ring is
    // circular: stop after RING_SIZE iterations or when timestamps fall
    // outside the window.
    var i: usize = 0;
    while (i < RING_SIZE) : (i += 1) {
        const idx = (self.ring_pos + RING_SIZE - 1 - i) % RING_SIZE;
        const entry = self.ring[idx];
        if (entry.timestamp == 0) continue; // empty slot
        // Only correlate within the window. Entries are written in
        // timestamp order; once we're past the window, older entries are
        // also too old.
        const diff = if (now_ns >= entry.timestamp)
            now_ns - entry.timestamp
        else
            entry.timestamp - now_ns;
        if (diff > window_ns) {
            // If the entry is older than the window, everything before it
            // is also too old — short-circuit.
            if (now_ns >= entry.timestamp) return null;
            continue;
        }
        return DeviceID{ .vendor = entry.vendor, .product = entry.product };
    }
    return null;
}

pub const DeviceID = struct {
    vendor: u32,
    product: u32,
};

/// Snapshot of currently-connected matched devices. Caller-owned slice;
/// `product_name` slices remain owned by HidMonitor and are valid until
/// the next device-removal callback. Used by `--list-devices`.
pub fn snapshotDevices(self: *const HidMonitor, allocator: std.mem.Allocator) ![]DeviceListEntry {
    var out = std.ArrayList(DeviceListEntry).init(allocator);
    errdefer out.deinit();
    var it = self.devices.iterator();
    while (it.next()) |entry| {
        try out.append(.{
            .vendor = entry.value_ptr.vendor,
            .product = entry.value_ptr.product,
            .product_name = entry.value_ptr.product_name,
            .transport = entry.value_ptr.transport,
        });
    }
    return try out.toOwnedSlice();
}

pub const DeviceListEntry = struct {
    vendor: u32,
    product: u32,
    product_name: []const u8,
    transport: Transport,
};

// ── Internals ───────────────────────────────────────────────────────────

fn buildKeyboardMatchingDict() !c.CFDictionaryRef {
    // Two-key dict: { DeviceUsagePage: GenericDesktop, DeviceUsage: Keyboard }
    const page_key = makeCFString("DeviceUsagePage") orelse return error.CFStringFailed;
    defer c.CFRelease(page_key);
    const usage_key = makeCFString("DeviceUsage") orelse return error.CFStringFailed;
    defer c.CFRelease(usage_key);

    var page_val: i32 = @intCast(kHIDPage_GenericDesktop);
    const page_num = c.CFNumberCreate(c.kCFAllocatorDefault, c.kCFNumberIntType, &page_val) orelse return error.CFNumberFailed;
    defer c.CFRelease(page_num);

    var usage_val: i32 = @intCast(kHIDUsage_GD_Keyboard);
    const usage_num = c.CFNumberCreate(c.kCFAllocatorDefault, c.kCFNumberIntType, &usage_val) orelse return error.CFNumberFailed;
    defer c.CFRelease(usage_num);

    var keys = [_]?*const anyopaque{ page_key, usage_key };
    var vals = [_]?*const anyopaque{ page_num, usage_num };

    return c.CFDictionaryCreate(
        c.kCFAllocatorDefault,
        @ptrCast(&keys),
        @ptrCast(&vals),
        2,
        &c.kCFTypeDictionaryKeyCallBacks,
        &c.kCFTypeDictionaryValueCallBacks,
    ) orelse return error.CFDictionaryFailed;
}

fn makeCFString(literal: [:0]const u8) ?c.CFStringRef {
    return c.CFStringCreateWithCString(c.kCFAllocatorDefault, literal.ptr, c.kCFStringEncodingUTF8);
}

fn deviceAddedCallback(ctx: ?*anyopaque, _: c.IOReturn, _: ?*anyopaque, device: c.IOHIDDeviceRef) callconv(.c) void {
    const self: *HidMonitor = @ptrCast(@alignCast(ctx orelse return));
    const info = readDeviceInfo(self.allocator, device) catch |err| {
        log.warn("failed to read device info: {s}", .{@errorName(err)});
        return;
    };
    self.devices.put(self.allocator, device, info) catch |err| {
        log.warn("failed to record device: {s}", .{@errorName(err)});
        self.allocator.free(info.product_name);
        return;
    };
    log.info("device added: {s} (0x{x:0>4}:0x{x:0>4}, {s})", .{
        info.product_name,
        info.vendor,
        info.product,
        @tagName(info.transport),
    });
}

fn deviceRemovedCallback(ctx: ?*anyopaque, _: c.IOReturn, _: ?*anyopaque, device: c.IOHIDDeviceRef) callconv(.c) void {
    const self: *HidMonitor = @ptrCast(@alignCast(ctx orelse return));
    if (self.devices.fetchRemove(device)) |kv| {
        log.info("device removed: {s} (0x{x:0>4}:0x{x:0>4})", .{ kv.value.product_name, kv.value.vendor, kv.value.product });
        self.allocator.free(kv.value.product_name);
    }
}

fn inputValueCallback(ctx: ?*anyopaque, _: c.IOReturn, _: ?*anyopaque, value: c.IOHIDValueRef) callconv(.c) void {
    const self: *HidMonitor = @ptrCast(@alignCast(ctx orelse return));
    const elem = c.IOHIDValueGetElement(value) orelse return;
    const device = c.IOHIDElementGetDevice(elem) orelse return;
    const info = self.devices.get(device) orelse return; // unknown device, skip

    // IOHIDValueGetTimeStamp returns raw mach_absolute_time ticks;
    // CGEventGetTimestamp returns nanoseconds. Convert here so the ring
    // buffer holds nanoseconds end-to-end.
    const ts_ns = ticksToNanos(c.IOHIDValueGetTimeStamp(value));
    const usage_page = c.IOHIDElementGetUsagePage(elem);
    const usage = c.IOHIDElementGetUsage(elem);
    const v: i32 = @truncate(c.IOHIDValueGetIntegerValue(value));

    self.ring[self.ring_pos] = .{
        .timestamp = ts_ns,
        .vendor = info.vendor,
        .product = info.product,
        .usage_page = usage_page,
        .usage = usage,
        .value = v,
    };
    self.ring_pos = (self.ring_pos + 1) % RING_SIZE;

    // Diagnostic: surface every keyboard-page key event so the user can
    // see whether IOHIDManager is actually capturing the same physical
    // events that CGEventTap is later asked to attribute.
    if (usage_page == kHIDPage_KeyboardOrKeypad and v != 0) {
        log.debug("hid event: usage=0x{x:0>2} value={d} device=0x{x:0>4}:0x{x:0>4} ts={d}ns", .{ usage, v, info.vendor, info.product, ts_ns });
    }
}

fn readDeviceInfo(allocator: std.mem.Allocator, device: c.IOHIDDeviceRef) !DeviceInfo {
    const vendor = readU32Property(device, "VendorID") orelse 0;
    const product = readU32Property(device, "ProductID") orelse 0;
    const product_name = try readStringProperty(allocator, device, "Product");
    errdefer allocator.free(product_name);
    const transport = readTransport(device);
    return DeviceInfo{
        .vendor = vendor,
        .product = product,
        .product_name = product_name,
        .transport = transport,
    };
}

fn readU32Property(device: c.IOHIDDeviceRef, key: [:0]const u8) ?u32 {
    const k = makeCFString(key) orelse return null;
    defer c.CFRelease(k);
    const ref = c.IOHIDDeviceGetProperty(device, k) orelse return null;
    var out: i32 = 0;
    if (c.CFNumberGetValue(@ptrCast(ref), c.kCFNumberIntType, &out) == 0) return null;
    return @bitCast(out);
}

fn readStringProperty(allocator: std.mem.Allocator, device: c.IOHIDDeviceRef, key: [:0]const u8) ![]u8 {
    const k = makeCFString(key) orelse return try allocator.dupe(u8, "");
    defer c.CFRelease(k);
    const ref = c.IOHIDDeviceGetProperty(device, k) orelse return try allocator.dupe(u8, "");
    const cstr = c.CFStringGetCStringPtr(@ptrCast(ref), c.kCFStringEncodingUTF8);
    if (cstr) |p| {
        return try allocator.dupe(u8, std.mem.span(p));
    }
    // Fallback: copy via fixed buffer.
    var buf: [256]u8 = undefined;
    if (c.CFStringGetCString(@ptrCast(ref), &buf, buf.len, c.kCFStringEncodingUTF8) == 0) {
        return try allocator.dupe(u8, "");
    }
    return try allocator.dupe(u8, std.mem.sliceTo(&buf, 0));
}

fn readTransport(device: c.IOHIDDeviceRef) Transport {
    const k = makeCFString("Transport") orelse return .other;
    defer c.CFRelease(k);
    const ref = c.IOHIDDeviceGetProperty(device, k) orelse return .other;
    var buf: [64]u8 = undefined;
    if (c.CFStringGetCString(@ptrCast(ref), &buf, buf.len, c.kCFStringEncodingUTF8) == 0) return .other;
    const s = std.mem.sliceTo(&buf, 0);
    if (std.ascii.eqlIgnoreCase(s, "USB")) return .usb;
    if (std.ascii.eqlIgnoreCase(s, "Bluetooth")) return .bluetooth;
    return .other;
}
