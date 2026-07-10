//! Power-source hook: battery diagnostics + the cord-flip master
//! restore trigger.
//!
//! Diagnostics (Debug/ReleaseSafe only, comptime-gated): one log line
//! per power-source change — AC vs battery, capacity %, charging, and
//! the system low-battery warning level. Motivated by the 2026-07-10
//! mid-session dead keyboard at ~20% battery: low-battery transitions
//! were invisible in the log, so we couldn't correlate.
//!
//! Cord-flip trigger (ALL builds): unplugging/replugging the charger
//! `flips_required` times within `flip_window_ns` fires `on_trigger` —
//! the master restore action for a dead builtin keyboard. The power
//! connector is the only deliberate physical channel that survives that
//! failure: the seize holds the keyboard exclusively (all key input is
//! invisible to everyone), Touch ID/power button never reaches the HID
//! stack (SMC-handled), and the un-seized vendor HID services turned
//! out to be output-only. External keyboards don't need this — replug
//! re-enumerates and DeviceNotify re-seizes.
//!
//! Event-driven (IOPS runloop source), no polling. Steady-state cost in
//! ReleaseFast is one power-source-state read per IOPS event (battery %
//! changes, plug/unplug — a handful per hour).

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig");

const log = std.log.scoped(.power_source);

/// Verbose per-change state logging compiles in only where .info is
/// visible (mirrors `power_diagnostics_supported` reasoning in main.zig).
const diagnostics_supported = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

/// Master restore: 4 AC<->battery transitions (unplug+replug twice)
/// within 10s. Deliberate and physical — never happens by accident.
pub const flips_required: u8 = 4;
pub const flip_window_ns: u64 = 10 * std.time.ns_per_s;

pub const Callback = *const fn (ctx: ?*anyopaque) void;

/// Human name for an IOPSGetBatteryWarningLevel() value.
pub fn warningName(level: c_int) []const u8 {
    return switch (level) {
        c.kIOPSLowBatteryWarningNone => "none",
        c.kIOPSLowBatteryWarningEarly => "early",
        c.kIOPSLowBatteryWarningFinal => "final",
        else => "unknown",
    };
}

/// Pure transition counter: fires when `required` events land within
/// `window_ns`. Time is injected for tests.
pub const FlipDetector = struct {
    required: u8,
    window_ns: u64,
    /// Recent event timestamps (ns). required <= 8.
    times: [8]u64 = @splat(0),
    count: u8 = 0,

    pub fn feed(self: *FlipDetector, now_ns: u64) bool {
        // Drop events that fell out of the window, then append.
        var kept: u8 = 0;
        var tmp: [8]u64 = @splat(0);
        for (self.times[0..self.count]) |t| {
            if (now_ns -| t <= self.window_ns) {
                tmp[kept] = t;
                kept += 1;
            }
        }
        tmp[kept] = now_ns;
        kept += 1;
        self.times = tmp;
        self.count = kept;

        if (kept >= self.required) {
            self.count = 0; // reset so the next flip starts a new sequence
            return true;
        }
        return false;
    }
};

allocator: std.mem.Allocator,
run_loop_source: c.CFRunLoopSourceRef = null,
on_trigger: Callback,
ctx: ?*anyopaque,
detector: FlipDetector,
/// Last observed AC state; flips are detected as changes to it.
/// null until the first successful read.
on_ac: ?bool = null,
/// Monotonic clock for the flip window (std.time.Timer was removed in
/// Zig 0.16; `.awake` maps to CLOCK_UPTIME_RAW on macOS).
io: std.Io,
epoch_ns: i128,

const Self = @This();

/// Singleton — IOPS callback has a context pointer, but we keep the
/// one-per-daemon convention used by PowerNotify/HidSeize.
var instance: ?*Self = null;

pub fn init(allocator: std.mem.Allocator, io: std.Io, on_trigger: Callback, ctx: ?*anyopaque) !*Self {
    if (instance != null) return error.AlreadyInitialized;

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .on_trigger = on_trigger,
        .ctx = ctx,
        .detector = .{ .required = flips_required, .window_ns = flip_window_ns },
        .io = io,
        .epoch_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds,
    };
    instance = self;
    errdefer instance = null;

    const source = c.IOPSNotificationCreateRunLoopSource(powerSourceCallback, self);
    if (source == null) {
        log.warn("IOPSNotificationCreateRunLoopSource failed — cord-flip restore + battery diagnostics disabled", .{});
        return error.SourceCreateFailed;
    }
    c.CFRunLoopAddSource(c.CFRunLoopGetCurrent(), source, c.kCFRunLoopDefaultMode);
    self.run_loop_source = source;

    self.on_ac = readAcState(); // baseline, so the first real flip counts as one
    log.info("power-source hook registered: cord-flip x{d} within {d}s forces reseize", .{
        flips_required, flip_window_ns / std.time.ns_per_s,
    });
    if (comptime diagnostics_supported) logCurrentState();
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
    const self: *Self = @ptrCast(@alignCast(context orelse return));

    if (comptime diagnostics_supported) logCurrentState();

    const now_ac = readAcState() orelse return;
    if (self.on_ac) |prev| {
        if (now_ac != prev) {
            self.on_ac = now_ac;
            const delta = std.Io.Clock.Timestamp.now(self.io, .awake).raw.nanoseconds - self.epoch_ns;
            const now_ns: u64 = if (delta < 0) 0 else @intCast(delta);
            if (self.detector.feed(now_ns)) {
                log.warn("master restore: {d} power-cord flips within {d}s — forcing vhidd+seize rebuild", .{
                    flips_required, flip_window_ns / std.time.ns_per_s,
                });
                self.on_trigger(self.ctx);
            }
        }
    } else {
        self.on_ac = now_ac; // first successful read after an earlier failure
    }
}

/// True if the (first) power source reports AC; null if unreadable
/// (no battery, transient CF failure).
fn readAcState() ?bool {
    const blob = c.IOPSCopyPowerSourcesInfo();
    if (blob == null) return null;
    defer c.CFRelease(blob);
    const list = c.IOPSCopyPowerSourcesList(blob);
    if (list == null) return null;
    defer c.CFRelease(list);
    if (c.CFArrayGetCount(list) == 0) return null;
    const ps = c.CFArrayGetValueAtIndex(list, 0);
    const desc = c.IOPSGetPowerSourceDescription(blob, @constCast(ps));
    if (desc == null) return null;
    return dictStrEquals(desc, c.kIOPSPowerSourceStateKey, c.kIOPSACPowerValue);
}

/// Read the current power-source blob and log one line per source.
/// All CF objects are created and released inside this call.
/// Diagnostics only — callers comptime-gate on `diagnostics_supported`.
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

test "FlipDetector fires on N flips inside the window and resets after firing" {
    var d: FlipDetector = .{ .required = 4, .window_ns = 10 * std.time.ns_per_s };
    const s = std.time.ns_per_s;
    try testing.expect(!d.feed(0 * s));
    try testing.expect(!d.feed(2 * s));
    try testing.expect(!d.feed(4 * s));
    try testing.expect(d.feed(6 * s)); // 4th flip → fire
    // After firing the sequence starts over.
    try testing.expect(!d.feed(7 * s));
}

test "FlipDetector: flips outside the window age out" {
    var d: FlipDetector = .{ .required = 3, .window_ns = 5 * std.time.ns_per_s };
    const s = std.time.ns_per_s;
    try testing.expect(!d.feed(0 * s));
    try testing.expect(!d.feed(1 * s));
    // 3rd flip at 20s: the first two are stale → only it survives.
    try testing.expect(!d.feed(20 * s));
    try testing.expect(!d.feed(21 * s));
    try testing.expect(d.feed(22 * s));
}

test "FlipDetector: slow charger churn never fires" {
    // A flaky charger flapping once a minute must not trigger a rebuild.
    var d: FlipDetector = .{ .required = 4, .window_ns = 10 * std.time.ns_per_s };
    const s = std.time.ns_per_s;
    var t: u64 = 0;
    while (t < 3600 * s) : (t += 60 * s) {
        try testing.expect(!d.feed(t));
    }
}
