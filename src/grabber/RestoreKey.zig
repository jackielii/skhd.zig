//! Master restore key — a physical escape hatch for the "keyboard dead,
//! grabber healthy" failure family. A second, NON-seizing IOHIDManager
//! observes the built-in keyboard's un-seized HID services (Apple Vendor
//! 0xFF00 / Apple Vendor Top Case 0xFF0C — media/fn keys, which keep
//! emitting even when the seized GenericDesktop/Keyboard service is
//! dead). Pressing the trigger key `trigger_required` times within
//! `trigger_window_ns` fires the callback, which forces a full
//! vhidd+seize rebuild. Pure value callback — zero steady-state cost,
//! no timers, no polling. Ships in ALL build modes.
//!
//! Observe stage: every event the observer receives is logged at .info
//! ("restore-key observe: ...") so a ReleaseSafe soak can identify the
//! exact page/usage the fn key reports. Once confirmed, demote to
//! .debug and (if needed) fix the trigger constants below.

const std = @import("std");
const c = @import("c.zig");

const log = std.log.scoped(.restore_key);

/// fn key on Apple internal keyboards: kHIDPage_AppleVendorTopCase
/// (0x00FF) / kHIDUsage_AV_TopCase_KeyboardFn (0x0003). Best-known
/// candidate (matches Karabiner's usage tables); confirm empirically
/// via the observe-stage logs.
pub const trigger_usage_page: u32 = 0x00FF;
pub const trigger_usage: u32 = 0x0003;
pub const trigger_required: u8 = 5;
pub const trigger_window_ns: u64 = 2 * std.time.ns_per_s;

pub const Callback = *const fn (ctx: ?*anyopaque) void;

/// Pure press-sequence state machine: fires when `required` presses of
/// (usage_page, usage) land within `window_ns`. Releases and other
/// usages are ignored (they don't reset the sequence — vendor services
/// interleave telemetry/autorepeat events). Time is injected for tests.
pub const TriggerDetector = struct {
    usage_page: u32,
    usage: u32,
    required: u8,
    window_ns: u64,
    /// Recent press timestamps (ns). required <= 8.
    times: [8]u64 = @splat(0),
    count: u8 = 0,

    pub fn feed(self: *TriggerDetector, usage_page: u32, usage: u32, pressed: bool, now_ns: u64) bool {
        if (!pressed) return false;
        if (usage_page != self.usage_page or usage != self.usage) return false;

        // Drop presses that fell out of the window, then append.
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
            self.count = 0; // reset so further presses start a new sequence
            return true;
        }
        return false;
    }
};

allocator: std.mem.Allocator,
manager: c.IOHIDManagerRef,
trigger_cb: Callback,
ctx: ?*anyopaque,
detector: TriggerDetector,
/// Monotonic clock for the detector window (std.time.Timer was removed
/// in Zig 0.16; `.awake` maps to CLOCK_UPTIME_RAW on macOS — suspend
/// time is excluded, which is right for a 2s press window).
io: std.Io,
epoch_ns: i128,
opened: bool = false,

const Self = @This();

/// Singleton — same one-per-daemon convention as HidSeize/PowerNotify.
var instance: ?*Self = null;

pub fn init(allocator: std.mem.Allocator, io: std.Io, trigger_cb: Callback, ctx: ?*anyopaque) !*Self {
    if (instance != null) return error.AlreadyInitialized;

    const manager = c.IOHIDManagerCreate(c.kCFAllocatorDefault, c.kIOHIDOptionsTypeNone);
    if (manager == null) return error.IOHIDManagerCreateFailed;
    errdefer c.CFRelease(manager);

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .manager = manager,
        .trigger_cb = trigger_cb,
        .ctx = ctx,
        .detector = .{
            .usage_page = trigger_usage_page,
            .usage = trigger_usage,
            .required = trigger_required,
            .window_ns = trigger_window_ns,
        },
        .io = io,
        .epoch_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds,
    };
    instance = self;
    errdefer instance = null;

    // Match ONLY the un-seized vendor services of the built-in keyboard:
    //   {PrimaryUsagePage=0xFF0C}                    Apple Vendor Top Case
    //   {PrimaryUsagePage=0xFF00, VendorID=0x05AC}   Apple Vendor (Apple only)
    // Never GenericDesktop (page 1) — that's the seized keyboard service
    // (rival open would be rejected) and the trackpad (event flood).
    const dicts = c.CFArrayCreateMutable(c.kCFAllocatorDefault, 2, &c.kCFTypeArrayCallBacks);
    if (dicts == null) return error.CFArrayCreateFailed;
    defer c.CFRelease(dicts);
    try appendPageDict(dicts, 0xFF0C, null);
    try appendPageDict(dicts, 0xFF00, 0x05AC);
    c.IOHIDManagerSetDeviceMatchingMultiple(self.manager, dicts);

    c.IOHIDManagerRegisterInputValueCallback(self.manager, valueCallback, self);
    c.IOHIDManagerScheduleWithRunLoop(self.manager, c.CFRunLoopGetCurrent(), c.kCFRunLoopDefaultMode);

    const r = c.IOHIDManagerOpen(self.manager, c.kIOHIDOptionsTypeNone);
    if (r != c.kIOReturnSuccess) {
        // Non-fatal for the daemon: the restore key is an extra escape
        // hatch. warn (survives ReleaseFast) because a disarmed escape
        // hatch is worth knowing about.
        log.warn("restore-key observer open failed: 0x{X:0>8} — master restore key disarmed", .{@as(u32, @bitCast(r))});
        c.IOHIDManagerUnscheduleFromRunLoop(self.manager, c.CFRunLoopGetCurrent(), c.kCFRunLoopDefaultMode);
        return error.ObserverOpenFailed;
    }
    self.opened = true;
    log.info("restore-key observer armed: fn x{d} within {d}s forces reseize", .{
        trigger_required, trigger_window_ns / std.time.ns_per_s,
    });
    return self;
}

pub fn deinit(self: *Self) void {
    if (self.opened) {
        _ = c.IOHIDManagerClose(self.manager, c.kIOHIDOptionsTypeNone);
        c.IOHIDManagerUnscheduleFromRunLoop(self.manager, c.CFRunLoopGetCurrent(), c.kCFRunLoopDefaultMode);
    }
    c.CFRelease(self.manager);
    instance = null;
    self.allocator.destroy(self);
}

/// One {PrimaryUsagePage, [VendorID]} matching dict appended to `dicts`.
fn appendPageDict(dicts: c.CFMutableArrayRef, page: i32, vendor: ?i32) !void {
    const dict = c.CFDictionaryCreateMutable(
        c.kCFAllocatorDefault,
        2,
        &c.kCFTypeDictionaryKeyCallBacks,
        &c.kCFTypeDictionaryValueCallBacks,
    );
    if (dict == null) return error.CFDictionaryCreateFailed;
    defer c.CFRelease(dict);
    setDictInt(dict, c.kIOHIDPrimaryUsagePageKey, page);
    if (vendor) |v| setDictInt(dict, c.kIOHIDVendorIDKey, v);
    c.CFArrayAppendValue(dicts, dict);
}

fn setDictInt(dict: c.CFMutableDictionaryRef, key_cstr: [*:0]const u8, value: i32) void {
    const key = c.CFStringCreateWithCString(c.kCFAllocatorDefault, key_cstr, c.kCFStringEncodingUTF8);
    if (key == null) return;
    defer c.CFRelease(key);
    var v: i32 = value;
    const num = c.CFNumberCreate(c.kCFAllocatorDefault, c.kCFNumberSInt32Type, &v);
    if (num == null) return;
    defer c.CFRelease(num);
    c.CFDictionarySetValue(dict, key, num);
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
    const page = c.IOHIDElementGetUsagePage(element);
    const usage = c.IOHIDElementGetUsage(element);
    const pressed = c.IOHIDValueGetIntegerValue(value) != 0;

    // Observe stage: identify what fn/top-row keys report on this
    // hardware. .info so a ReleaseSafe soak captures it; demote to
    // .debug once the trigger usage is confirmed. These keys arrive
    // rarely (user-initiated) so this cannot swamp the log.
    log.info("restore-key observe: page=0x{X:0>4} usage=0x{X:0>4} pressed={}", .{ page, usage, pressed });

    if (self.detector.feed(page, usage, pressed, self.nowNs())) {
        log.warn("master restore key: {d}x fn detected — forcing vhidd+seize rebuild", .{trigger_required});
        self.trigger_cb(self.ctx);
    }
}

/// ns since init on the awake monotonic clock.
fn nowNs(self: *Self) u64 {
    const delta = std.Io.Clock.Timestamp.now(self.io, .awake).raw.nanoseconds - self.epoch_ns;
    return if (delta < 0) 0 else @intCast(delta);
}

const testing = std.testing;

test "TriggerDetector fires on N presses inside the window and resets after firing" {
    var d: TriggerDetector = .{ .usage_page = 0xFF, .usage = 3, .required = 5, .window_ns = 2 * std.time.ns_per_s };
    const ms = std.time.ns_per_ms;
    try testing.expect(!d.feed(0xFF, 3, true, 0 * ms));
    try testing.expect(!d.feed(0xFF, 3, true, 100 * ms));
    try testing.expect(!d.feed(0xFF, 3, true, 200 * ms));
    try testing.expect(!d.feed(0xFF, 3, true, 300 * ms));
    try testing.expect(d.feed(0xFF, 3, true, 400 * ms)); // 5th press → fire
    // After firing the sequence starts over.
    try testing.expect(!d.feed(0xFF, 3, true, 500 * ms));
}

test "TriggerDetector ignores releases and unrelated usages" {
    var d: TriggerDetector = .{ .usage_page = 0xFF, .usage = 3, .required = 2, .window_ns = 2 * std.time.ns_per_s };
    try testing.expect(!d.feed(0xFF, 3, false, 0)); // release: ignored
    try testing.expect(!d.feed(0x0C, 0xE9, true, 1)); // volume key: ignored, doesn't reset
    try testing.expect(!d.feed(0xFF, 3, true, 2));
    try testing.expect(!d.feed(0xFF, 3, false, 3)); // its own release: ignored
    try testing.expect(d.feed(0xFF, 3, true, 4)); // 2nd press → fire
}

test "TriggerDetector: presses outside the window age out" {
    var d: TriggerDetector = .{ .usage_page = 0xFF, .usage = 3, .required = 3, .window_ns = 1 * std.time.ns_per_s };
    const s = std.time.ns_per_s;
    try testing.expect(!d.feed(0xFF, 3, true, 0));
    try testing.expect(!d.feed(0xFF, 3, true, 1 * s / 2));
    // 3rd press at 3s: the first two are stale → only it survives.
    try testing.expect(!d.feed(0xFF, 3, true, 3 * s));
    try testing.expect(!d.feed(0xFF, 3, true, 3 * s + 100));
    try testing.expect(d.feed(0xFF, 3, true, 3 * s + 200));
}
