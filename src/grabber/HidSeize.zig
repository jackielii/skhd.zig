//! IOHIDManager-based seize for the grabber.
//!
//! Opens a set of (vendor, product) keyboards with
//! `kIOHIDOptionsTypeSeizeDevice`. While seized, those devices'
//! input events bypass the normal HID stack — only this process's
//! input value callback receives them. The grabber then either
//! transforms (D4: tap-hold) or passes them straight through to the
//! Karabiner virtual HID device (D3: this module).
//!
//! Requires root: `IOHIDDeviceOpen(seize)` returns
//! `kIOReturnNotPrivileged` for non-root callers.
//!
//! Thread model: callbacks fire on the CFRunLoop thread we schedule
//! against. The caller is expected to drive that run loop on the
//! main thread.

const std = @import("std");
const builtin = @import("builtin");

const c = @import("c.zig");

const log = std.log.scoped(.hid_seize);

pub const Match = struct {
    vendor: u32,
    product: u32,
};

/// One HID input value, decoded from `IOHIDValueRef`. Only what the
/// pass-through path actually needs.
pub const Event = struct {
    usage_page: u32,
    usage: u32,
    /// 1 for keydown / modifier set; 0 for keyup / modifier clear.
    /// Booleans abstract over IOHIDValueGetIntegerValue's CFIndex.
    pressed: bool,
};

pub const Callback = *const fn (ctx: ?*anyopaque, event: Event) void;

/// Singleton state. IOKit callbacks are C function pointers with no
/// closure capture, so they need to find their way back to whatever
/// owns the manager. We use one process-wide HidSeize anyway, so a
/// global is the simplest representation.
var instance: ?*Self = null;

allocator: std.mem.Allocator,
manager: c.IOHIDManagerRef,
callback: Callback,
callback_ctx: ?*anyopaque,
running: bool = false,
/// Open options actually applied to IOHIDManagerOpen. Tracked so
/// stop() can mirror the same options on close.
open_options: u32 = 0,
/// Owned copy of the matches passed to setMatches. Reused by
/// disableCapsLockDelayOnMatches to filter event-system services
/// to just the ones we seized.
owned_matches: []Match = &.{},

const Self = @This();

pub fn init(allocator: std.mem.Allocator, callback: Callback, callback_ctx: ?*anyopaque) !*Self {
    if (instance != null) return error.AlreadyInitialized;

    const manager = c.IOHIDManagerCreate(c.kCFAllocatorDefault, c.kIOHIDOptionsTypeNone);
    if (manager == null) return error.IOHIDManagerCreateFailed;
    errdefer c.CFRelease(manager);

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .manager = manager,
        .callback = callback,
        .callback_ctx = callback_ctx,
    };
    instance = self;
    return self;
}

pub fn deinit(self: *Self) void {
    if (self.running) self.stop();
    if (self.owned_matches.len > 0) self.allocator.free(self.owned_matches);
    c.CFRelease(self.manager);
    instance = null;
    self.allocator.destroy(self);
}

/// Build a CFArray of dictionaries, one per match, and apply it as
/// the manager's matching filter. Must be called before `start`.
///
/// We deliberately constrain to (Generic Desktop / Keyboard) only.
/// Apple's built-in MacBook keyboard exposes other HID services on
/// the same (vendor, product) — Apple Vendor at (0xFF00, 0x0B) for
/// media keys, AppleMultitouchDevice at (0x0D, 0x0C) for the
/// trackpad, etc. Seizing those is either disallowed by the kernel
/// (`kIOReturnExclusiveAccess`) or breaks pointer/media input. By
/// matching the keyboard service alone, the media-key service emits
/// directly to the OS unchanged — F-row default actions keep working.
pub fn setMatches(self: *Self, matches: []const Match) !void {
    if (self.running) return error.AlreadyRunning;

    if (self.owned_matches.len > 0) self.allocator.free(self.owned_matches);
    self.owned_matches = try self.allocator.dupe(Match, matches);
    errdefer {
        self.allocator.free(self.owned_matches);
        self.owned_matches = &.{};
    }

    const dicts = c.CFArrayCreateMutable(c.kCFAllocatorDefault, @intCast(matches.len), &c.kCFTypeArrayCallBacks);
    if (dicts == null) return error.CFArrayCreateFailed;
    defer c.CFRelease(dicts);

    for (matches) |m| {
        const dict = c.CFDictionaryCreateMutable(
            c.kCFAllocatorDefault,
            4,
            &c.kCFTypeDictionaryKeyCallBacks,
            &c.kCFTypeDictionaryValueCallBacks,
        );
        if (dict == null) return error.CFDictionaryCreateFailed;
        defer c.CFRelease(dict);

        const vendor_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, c.kIOHIDVendorIDKey, c.kCFStringEncodingUTF8);
        defer c.CFRelease(vendor_key);
        const product_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, c.kIOHIDProductIDKey, c.kCFStringEncodingUTF8);
        defer c.CFRelease(product_key);
        const usage_page_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, c.kIOHIDPrimaryUsagePageKey, c.kCFStringEncodingUTF8);
        defer c.CFRelease(usage_page_key);
        const usage_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, c.kIOHIDPrimaryUsageKey, c.kCFStringEncodingUTF8);
        defer c.CFRelease(usage_key);

        var vendor: i32 = @intCast(m.vendor);
        var product: i32 = @intCast(m.product);
        var usage_page: i32 = c.kHIDPage_GenericDesktop;
        var usage: i32 = c.kHIDUsage_GD_Keyboard;

        const vendor_num = c.CFNumberCreate(c.kCFAllocatorDefault, c.kCFNumberSInt32Type, &vendor);
        defer c.CFRelease(vendor_num);
        const product_num = c.CFNumberCreate(c.kCFAllocatorDefault, c.kCFNumberSInt32Type, &product);
        defer c.CFRelease(product_num);
        const usage_page_num = c.CFNumberCreate(c.kCFAllocatorDefault, c.kCFNumberSInt32Type, &usage_page);
        defer c.CFRelease(usage_page_num);
        const usage_num = c.CFNumberCreate(c.kCFAllocatorDefault, c.kCFNumberSInt32Type, &usage);
        defer c.CFRelease(usage_num);

        c.CFDictionarySetValue(dict, vendor_key, vendor_num);
        c.CFDictionarySetValue(dict, product_key, product_num);
        c.CFDictionarySetValue(dict, usage_page_key, usage_page_num);
        c.CFDictionarySetValue(dict, usage_key, usage_num);

        c.CFArrayAppendValue(dicts, dict);
    }

    c.IOHIDManagerSetDeviceMatchingMultiple(self.manager, dicts);
}

/// Schedule the manager on the current run loop and open it.
///
/// `mode = .seize` opens with `kIOHIDOptionsTypeSeizeDevice` so the
/// matched keyboards' events bypass the kernel HID stack and only
/// flow into our `callback`.
///
/// `mode = .observe` opens passively — the kernel still sees the
/// device's events and routes them to the foreground app; we get a
/// copy via the callback. Used for diagnostics: confirms our matching
/// + run-loop wiring before troubleshooting seize-specific issues.
pub const Mode = enum { seize, observe };

pub fn start(self: *Self, mode: Mode) !void {
    if (self.running) return;

    c.IOHIDManagerRegisterInputValueCallback(self.manager, valueCallback, self);
    // Per-device add/remove notifications. Logging-only — re-seize on
    // wake is driven by PowerNotify so we don't double-trigger here.
    // These fire after manager open: matching for the initial
    // population and again for any device that re-enumerates (e.g.
    // unplug/replug, or post-sleep stale-ref replacement).
    c.IOHIDManagerRegisterDeviceMatchingCallback(self.manager, deviceMatchedCallback, self);
    c.IOHIDManagerRegisterDeviceRemovalCallback(self.manager, deviceRemovedCallback, self);
    c.IOHIDManagerScheduleWithRunLoop(self.manager, c.CFRunLoopGetCurrent(), c.kCFRunLoopDefaultMode);

    self.open_options = switch (mode) {
        .seize => c.kIOHIDOptionsTypeSeizeDevice,
        .observe => c.kIOHIDOptionsTypeNone,
    };
    const r = c.IOHIDManagerOpen(self.manager, self.open_options);
    if (r != c.kIOReturnSuccess) {
        c.IOHIDManagerUnscheduleFromRunLoop(self.manager, c.CFRunLoopGetCurrent(), c.kCFRunLoopDefaultMode);
        log.err("IOHIDManagerOpen seize failed: 0x{X:0>8}", .{@as(u32, @bitCast(r))});
        return switch (r) {
            c.kIOReturnNotPrivileged => error.NotPrivileged,
            // kIOReturnNotPermitted: macOS TCC layer denied the
            // operation — usually means the binary needs to be
            // approved in System Settings → Privacy & Security →
            // Input Monitoring. The first attempt triggers the
            // approval dialog; subsequent runs are silent.
            c.kIOReturnNotPermitted => error.NotPermitted,
            c.kIOReturnExclusiveAccess => error.DeviceAlreadySeized,
            else => error.IOHIDManagerOpenFailed,
        };
    }

    self.running = true;

    const matched = c.IOHIDManagerCopyDevices(self.manager);
    const count: usize = if (matched) |s| @intCast(c.CFSetGetCount(s)) else 0;
    log.info("seized matching devices (options=0x{x}, matched_count={d})", .{ self.open_options, count });
    if (count == 0) {
        log.warn("matching dictionary captured 0 devices — vendor/product mismatch?", .{});
    }
    if (matched) |s| c.CFRelease(s);

    if (mode == .seize) {
        self.disableCapsLockDelayOnMatches(self.owned_matches);
    }
}

/// Set HIDKeyboardCapsLockDelayOverride=0 on every event-system
/// service. Disables Apple's firmware-level "hold caps_lock for ~150ms
/// to toggle" behavior — without this the toggle still fires through
/// a side channel that IOHIDManager seize doesn't capture, so
/// caps_lock-as-ctrl works at the FSM level but the OS's caps_lock
/// state diverges (LED on, caps stuck).
///
/// Going through `IOHIDEventSystemClient` (private API) is what
/// Karabiner does — `IOHIDDeviceSetProperty` returns success but the
/// property is silently rejected, and `hidutil property --set`
/// likewise doesn't persist. The event-system path takes effect.
///
/// We don't try to filter by vendor/product (event-system services
/// don't expose those keys reliably) — setting the property on
/// services that don't accept it is a no-op, and any keyboard where
/// it does apply benefits from the same behavior we'd want.
fn disableCapsLockDelayOnMatches(self: *Self, matches: []const Match) void {
    _ = self;
    _ = matches;
    const evs = c.IOHIDEventSystemClientCreateSimpleClient(c.kCFAllocatorDefault);
    if (evs == null) {
        log.warn("IOHIDEventSystemClientCreateSimpleClient failed — caps_lock firmware toggle stays enabled", .{});
        return;
    }
    defer c.CFRelease(evs);

    const services = c.IOHIDEventSystemClientCopyServices(evs);
    if (services == null) {
        log.warn("IOHIDEventSystemClientCopyServices returned null", .{});
        return;
    }
    defer c.CFRelease(services);

    const delay_key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, c.kIOHIDKeyboardCapsLockDelayOverrideKey, c.kCFStringEncodingUTF8);
    if (delay_key == null) return;
    defer c.CFRelease(delay_key);

    var zero: i32 = 0;
    const zero_cf = c.CFNumberCreate(c.kCFAllocatorDefault, c.kCFNumberSInt32Type, &zero);
    if (zero_cf == null) return;
    defer c.CFRelease(zero_cf);

    var applied: usize = 0;
    const total = c.CFArrayGetCount(services);
    var i: c.CFIndex = 0;
    while (i < total) : (i += 1) {
        const raw = c.CFArrayGetValueAtIndex(services, i) orelse continue;
        const svc: c.IOHIDServiceClientRef = @constCast(raw);
        const ok = c.IOHIDServiceClientSetProperty(svc, delay_key, zero_cf);
        if (ok != 0) applied += 1;
    }
    log.info("HIDKeyboardCapsLockDelayOverride=0 applied to {d}/{d} service(s)", .{ applied, total });
}

pub fn stop(self: *Self) void {
    if (!self.running) return;
    _ = c.IOHIDManagerClose(self.manager, self.open_options);
    c.IOHIDManagerUnscheduleFromRunLoop(self.manager, c.CFRunLoopGetCurrent(), c.kCFRunLoopDefaultMode);
    self.running = false;
    log.info("released seize", .{});
}

fn deviceIdsLog(prefix: []const u8, device: c.IOHIDDeviceRef) void {
    const vendor = deviceI32Property(device, c.kIOHIDVendorIDKey);
    const product = deviceI32Property(device, c.kIOHIDProductIDKey);
    // info: fires on every apply_rules and device add/remove, so it's
    // compiled out of the release build (ReleaseFast keeps only warn+)
    // and won't accumulate on users' machines. Visible in a ReleaseSafe
    // build for "did our seized device disappear?" tracing.
    log.info("{s}: vendor=0x{X:0>4} product=0x{X:0>4}", .{ prefix, vendor, product });
}

fn deviceI32Property(device: c.IOHIDDeviceRef, key_cstr: [*:0]const u8) u32 {
    const key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, key_cstr, c.kCFStringEncodingUTF8);
    if (key == null) return 0;
    defer c.CFRelease(key);
    const value = c.IOHIDDeviceGetProperty(device, key);
    if (value == null) return 0;
    var out: i32 = 0;
    _ = c.CFNumberGetValue(value, c.kCFNumberSInt32Type, &out);
    return @bitCast(out);
}

fn deviceMatchedCallback(
    ctx: ?*anyopaque,
    result: c.IOReturn,
    sender: ?*anyopaque,
    device: c.IOHIDDeviceRef,
) callconv(.c) void {
    _ = ctx;
    _ = sender;
    if (result != c.kIOReturnSuccess) return;
    deviceIdsLog("device matched", device);
}

fn deviceRemovedCallback(
    ctx: ?*anyopaque,
    result: c.IOReturn,
    sender: ?*anyopaque,
    device: c.IOHIDDeviceRef,
) callconv(.c) void {
    _ = ctx;
    _ = sender;
    if (result != c.kIOReturnSuccess) return;
    deviceIdsLog("device removed", device);
}

fn valueCallback(
    ctx: ?*anyopaque,
    result: c.IOReturn,
    sender: ?*anyopaque,
    value: c.IOHIDValueRef,
) callconv(.c) void {
    _ = sender;
    if (result != c.kIOReturnSuccess) return;
    const self: *Self = @ptrCast(@alignCast(ctx orelse return));

    const element = c.IOHIDValueGetElement(value);
    if (element == null) return;

    const usage_page = c.IOHIDElementGetUsagePage(element);
    const usage = c.IOHIDElementGetUsage(element);
    const int_value = c.IOHIDValueGetIntegerValue(value);

    self.callback(self.callback_ctx, .{
        .usage_page = usage_page,
        .usage = usage,
        .pressed = int_value != 0,
    });
}
