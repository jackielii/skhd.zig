//! Power-source / battery diagnostics (Debug/ReleaseSafe only — the
//! caller comptime-gates init). Registers an IOPS runloop source and
//! logs one line per power-source change: AC vs battery, capacity %,
//! charging, and the system low-battery warning level. Pure logging —
//! no recovery action. Motivated by the 2026-07-10 mid-session dead
//! keyboard at ~20% battery: low-battery transitions were invisible in
//! the log, so we couldn't correlate. Event-driven, no polling.

const std = @import("std");
const c = @import("c.zig");

const log = std.log.scoped(.power_source);

/// Human name for an IOPSGetBatteryWarningLevel() value.
pub fn warningName(level: c_int) []const u8 {
    return switch (level) {
        c.kIOPSLowBatteryWarningNone => "none",
        c.kIOPSLowBatteryWarningEarly => "early",
        c.kIOPSLowBatteryWarningFinal => "final",
        else => "unknown",
    };
}

allocator: std.mem.Allocator,
run_loop_source: c.CFRunLoopSourceRef = null,

const Self = @This();

/// Singleton — IOPS callback has a context pointer, but we keep the
/// one-per-daemon convention used by PowerNotify/HidSeize.
var instance: ?*Self = null;

pub fn init(allocator: std.mem.Allocator) !*Self {
    if (instance != null) return error.AlreadyInitialized;

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{ .allocator = allocator };
    instance = self;
    errdefer instance = null;

    const source = c.IOPSNotificationCreateRunLoopSource(powerSourceCallback, self);
    if (source == null) {
        log.warn("IOPSNotificationCreateRunLoopSource failed — power-source diagnostics disabled", .{});
        return error.SourceCreateFailed;
    }
    c.CFRunLoopAddSource(c.CFRunLoopGetCurrent(), source, c.kCFRunLoopDefaultMode);
    self.run_loop_source = source;

    log.info("power-source diagnostics registered", .{});
    logCurrentState(); // baseline line so the log always has a reference point
    return self;
}

pub fn deinit(self: *Self) void {
    if (self.run_loop_source) |src| {
        c.CFRunLoopRemoveSource(c.CFRunLoopGetCurrent(), src, c.kCFRunLoopDefaultMode);
        c.CFRelease(src); // IOPSNotificationCreateRunLoopSource follows the Create rule
        self.run_loop_source = null;
    }
    instance = null;
    self.allocator.destroy(self);
}

fn powerSourceCallback(context: ?*anyopaque) callconv(.c) void {
    _ = context;
    logCurrentState();
}

/// Read the current power-source blob and log one line per source.
/// All CF objects are created and released inside this call.
fn logCurrentState() void {
    const warn_level = c.IOPSGetBatteryWarningLevel();

    const blob = c.IOPSCopyPowerSourcesInfo();
    if (blob == null) {
        log.info("power source: (IOPSCopyPowerSourcesInfo failed) warn={s}", .{warningName(warn_level)});
        return;
    }
    defer c.CFRelease(blob);

    const list = c.IOPSCopyPowerSourcesList(blob);
    if (list == null) {
        log.info("power source: (no source list) warn={s}", .{warningName(warn_level)});
        return;
    }
    defer c.CFRelease(list);

    const count = c.CFArrayGetCount(list);
    if (count == 0) {
        // Desktop / no battery — still log the transition trigger.
        log.info("power source: no battery sources warn={s}", .{warningName(warn_level)});
        return;
    }

    var i: c.CFIndex = 0;
    while (i < count) : (i += 1) {
        const ps = c.CFArrayGetValueAtIndex(list, i);
        const desc = c.IOPSGetPowerSourceDescription(blob, @constCast(ps));
        if (desc == null) continue;

        const on_ac = dictStrEquals(desc, c.kIOPSPowerSourceStateKey, c.kIOPSACPowerValue);
        const current = dictInt(desc, c.kIOPSCurrentCapacityKey) orelse -1;
        const max = dictInt(desc, c.kIOPSMaxCapacityKey) orelse -1;
        const charging = dictBool(desc, c.kIOPSIsChargingKey) orelse false;
        const pct: i32 = if (max > 0) @divTrunc(current * 100, max) else current;

        log.info("power source: state={s} pct={d}% charging={} warn={s}", .{
            if (on_ac) "AC" else "battery", pct, charging, warningName(warn_level),
        });
    }
}

/// Read an i32 CFNumber value for a string key; null if absent.
fn dictInt(dict: c.CFDictionaryRef, key_lit: [*:0]const u8) ?i32 {
    const key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, key_lit, c.kCFStringEncodingUTF8);
    if (key == null) return null;
    defer c.CFRelease(key);
    const val = c.CFDictionaryGetValue(dict, key) orelse return null;
    var out: i32 = 0;
    if (c.CFNumberGetValue(@constCast(val), c.kCFNumberSInt32Type, &out) == 0) return null;
    return out;
}

/// Read a CFBoolean value for a string key; null if absent.
fn dictBool(dict: c.CFDictionaryRef, key_lit: [*:0]const u8) ?bool {
    const key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, key_lit, c.kCFStringEncodingUTF8);
    if (key == null) return null;
    defer c.CFRelease(key);
    const val = c.CFDictionaryGetValue(dict, key) orelse return null;
    return c.CFBooleanGetValue(val) != 0;
}

/// True if dict[key] is a CFString equal to `expect_lit`.
fn dictStrEquals(dict: c.CFDictionaryRef, key_lit: [*:0]const u8, expect_lit: [*:0]const u8) bool {
    const key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, key_lit, c.kCFStringEncodingUTF8);
    if (key == null) return false;
    defer c.CFRelease(key);
    const val = c.CFDictionaryGetValue(dict, key) orelse return false;
    const expect = c.CFStringCreateWithCString(c.kCFAllocatorDefault, expect_lit, c.kCFStringEncodingUTF8);
    if (expect == null) return false;
    defer c.CFRelease(expect);
    return c.CFStringCompare(@constCast(val), expect, 0) == c.kCFCompareEqualTo;
}

const testing = std.testing;

test "warningName maps the three documented levels and falls back to unknown" {
    try testing.expectEqualStrings("none", warningName(c.kIOPSLowBatteryWarningNone));
    try testing.expectEqualStrings("early", warningName(c.kIOPSLowBatteryWarningEarly));
    try testing.expectEqualStrings("final", warningName(c.kIOPSLowBatteryWarningFinal));
    try testing.expectEqualStrings("unknown", warningName(-1));
}
