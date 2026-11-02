//! Re-establishes per-device state when a configured keyboard
//! (re-)enumerates: it was replugged, woke, or a KVM or dock switched it
//! away and back. Each time, macOS creates a new HID service for it.
//!
//! Two things die or go missing with a keyboard's old HID service:
//!
//! - The `.remap` UserKeyMapping, which lives on the service. This re-sets
//!   it on the devices skhd applied it to, and only those. A reload would
//!   clear and re-set every device, opening a window in which every key
//!   acts unmapped; a caps_lock remapped away can latch caps lock on there
//!   with no key left to turn it off.
//! - The grabber's rules for a device that was absent when the agent last
//!   forwarded them: the agent drops those, so the grabber never seizes the
//!   device once it arrives. This re-forwards when such a device appears.

const std = @import("std");
const c = @import("c.zig");
const DeviceNotify = @import("grabber/DeviceNotify.zig");
const Hidutil = @import("Hidutil.zig");
const Mappings = @import("Mappings.zig");

const log = std.log.scoped(.keyboard_watch);

const KeyboardWatch = @This();

/// Seconds between re-apply passes, counted from the last relevant batch.
/// The first waits out a device enumerating several services in quick
/// succession (wireless receivers and composite keyboards do). The second covers hidutil not yet seeing the new service at
/// the first pass; re-setting an intact mapping is harmless.
const reapply_gaps_s = [_]f64{ 1, 4 };

pub const Options = struct {
    mappings: *const Mappings,
    /// The owner's hidutil slot. Null while the config has no colon-form
    /// remaps; read at each pass because a reload can create it.
    hidutil: *const ?*Hidutil,
    /// Devices the last grabber forward skipped because they weren't
    /// connected. Owned by the caller and rebuilt on each forward.
    grabber_absent: *const std.ArrayListUnmanaged(Hidutil.VendorProduct),
    /// Replace the grabber subscription with one built from the devices
    /// connected now.
    reforward: *const fn (ctx: ?*anyopaque) void,
    reforward_ctx: ?*anyopaque,
};

allocator: std.mem.Allocator,
opts: Options,
notify: *DeviceNotify,
pending: Pending = .{},
timer: c.CFRunLoopTimerRef = null,
attempt: usize = 0,

/// Which configured devices a keyboard arrival matters to.
const Interest = struct {
    applied: []const Hidutil.VendorProduct,
    absent: []const Hidutil.VendorProduct,

    fn has(self: Interest, kb: Hidutil.Keyboard) bool {
        return targetsAny(self.applied, kb) or targetsAny(self.absent, kb);
    }
};

fn targetsAny(devices: []const Hidutil.VendorProduct, kb: Hidutil.Keyboard) bool {
    for (devices) |vp| {
        if (Hidutil.targets(vp, kb)) return true;
    }
    return false;
}

/// Keyboards that matched since the last completed pass sequence,
/// restricted to the ones some configured device targets.
const Pending = struct {
    keyboards: [DeviceNotify.max_batch]Hidutil.Keyboard = undefined,
    len: usize = 0,
    /// More keyboards matched than `keyboards` holds: act on everything.
    all: bool = false,

    /// Record the relevant keyboards of a batch. Returns whether anything
    /// relevant arrived, i.e. whether a pass is due.
    fn add(self: *Pending, interest: Interest, change: DeviceNotify.Change) bool {
        if (change.kind != .matched) return false;
        var relevant = change.overflowed;
        if (change.overflowed) self.all = true;
        for (change.devices) |kb| {
            if (!interest.has(kb)) continue;
            relevant = true;
            if (self.contains(kb)) continue;
            if (self.len == self.keyboards.len) {
                self.all = true;
                continue;
            }
            self.keyboards[self.len] = kb;
            self.len += 1;
        }
        return relevant;
    }

    fn wants(self: *const Pending, device: Hidutil.VendorProduct) bool {
        if (self.all) return true;
        for (self.keyboards[0..self.len]) |kb| {
            if (Hidutil.targets(device, kb)) return true;
        }
        return false;
    }

    fn wantsAny(self: *const Pending, devices: []const Hidutil.VendorProduct) bool {
        for (devices) |vp| {
            if (self.wants(vp)) return true;
        }
        return false;
    }

    fn contains(self: *const Pending, kb: Hidutil.Keyboard) bool {
        for (self.keyboards[0..self.len]) |k| {
            if (std.meta.eql(k, kb)) return true;
        }
        return false;
    }
};

/// Start watching. Must run on the main run loop's thread; the keyboards
/// present now are taken as already handled.
pub fn init(allocator: std.mem.Allocator, opts: Options) !*KeyboardWatch {
    const self = try allocator.create(KeyboardWatch);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .opts = opts,
        .notify = undefined,
    };
    self.notify = try DeviceNotify.init(allocator, onChange, self);
    return self;
}

pub fn deinit(self: *KeyboardWatch) void {
    self.cancelTimer();
    self.notify.deinit();
    self.allocator.destroy(self);
}

fn applied(self: *const KeyboardWatch) []const Hidutil.VendorProduct {
    const h = self.opts.hidutil.* orelse return &.{};
    return h.applied_devices.items;
}

fn onChange(ctx: ?*anyopaque, change: DeviceNotify.Change) void {
    const self: *KeyboardWatch = @ptrCast(@alignCast(ctx orelse return));
    const interest: Interest = .{ .applied = self.applied(), .absent = self.opts.grabber_absent.items };
    if (!self.pending.add(interest, change)) return;
    self.attempt = 0;
    self.armTimer();
}

fn armTimer(self: *KeyboardWatch) void {
    self.cancelTimer();
    var ctx = c.CFRunLoopTimerContext{
        .version = 0,
        .info = self,
        .retain = null,
        .release = null,
        .copyDescription = null,
    };
    const fire_at = c.CFAbsoluteTimeGetCurrent() + reapply_gaps_s[self.attempt];
    self.timer = c.CFRunLoopTimerCreate(c.kCFAllocatorDefault, fire_at, 0, 0, 0, timerCallback, &ctx);
    if (self.timer == null) {
        log.warn("could not create keyboard re-apply timer; a re-enumerated keyboard stays unhandled until the next reload", .{});
        return;
    }
    c.CFRunLoopAddTimer(c.CFRunLoopGetMain(), self.timer, c.kCFRunLoopCommonModes);
}

fn cancelTimer(self: *KeyboardWatch) void {
    if (self.timer) |t| {
        c.CFRunLoopTimerInvalidate(t);
        c.CFRelease(t);
        self.timer = null;
    }
}

/// Runs on the main run loop, which also drives the event tap, and each
/// re-apply is a blocking hidutil spawn: 6–20ms apiece (measured on an
/// Apple Silicon Mac), so a pass over a few devices holds keystrokes for
/// tens of milliseconds. The tap queues them rather than dropping them, and startup
/// and reload already block the same way.
fn timerCallback(_: c.CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const self: *KeyboardWatch = @ptrCast(@alignCast(info orelse return));
    self.cancelTimer();

    // Once is enough: the forward re-checks presence itself, and a second
    // reconnect would only churn the grabber's seize.
    if (self.attempt == 0 and self.pending.wantsAny(self.opts.grabber_absent.items)) {
        log.info("a keyboard skipped at the last grabber forward is now connected — re-forwarding rules", .{});
        self.opts.reforward(self.opts.reforward_ctx);
    }

    if (self.opts.hidutil.*) |h| {
        for (h.applied_devices.items) |vp| {
            if (!self.pending.wants(vp)) continue;
            log.info("re-applying remap on {x:0>4}:{x:0>4} after re-enumeration (pass {d}/{d})", .{ vp.vendor, vp.product, self.attempt + 1, reapply_gaps_s.len });
            h.reapplyDevice(self.opts.mappings, vp) catch |err| {
                log.warn("re-applying remap on {x:0>4}:{x:0>4} failed: {s}", .{ vp.vendor, vp.product, @errorName(err) });
            };
        }
    }

    self.attempt += 1;
    if (self.attempt < reapply_gaps_s.len) {
        self.armTimer();
        return;
    }
    self.pending = .{};
}

const testing = std.testing;

const receiver: Hidutil.VendorProduct = .{ .vendor = 0x046D, .product = 0xC548 };
const unifying: Hidutil.VendorProduct = .{ .vendor = 0x046D, .product = 0xC52B };
const builtin_kb: Hidutil.VendorProduct = .{ .vendor = 0, .product = 0 };

fn matched(devices: []const DeviceNotify.Device) DeviceNotify.Change {
    return .{ .kind = .matched, .devices = devices, .overflowed = false };
}

fn onlyApplied(devices: []const Hidutil.VendorProduct) Interest {
    return .{ .applied = devices, .absent = &.{} };
}

test "Pending: a remapped keyboard re-enumerating is due a re-apply of that device only" {
    var p: Pending = .{};
    const applied_devs = [_]Hidutil.VendorProduct{ receiver, builtin_kb };
    try testing.expect(p.add(onlyApplied(&applied_devs), matched(&.{.{ .vendor = 0x046D, .product = 0xC548, .built_in = false }})));
    try testing.expect(p.wants(receiver));
    try testing.expect(!p.wants(builtin_kb));
}

test "Pending: unrelated keyboards don't trigger a pass" {
    var p: Pending = .{};
    const applied_devs = [_]Hidutil.VendorProduct{receiver};
    // Karabiner's VirtualHIDKeyboard re-enumerates on every vhidd reconnect.
    try testing.expect(!p.add(onlyApplied(&applied_devs), matched(&.{.{ .vendor = 0x16C0, .product = 0x27DB, .built_in = false }})));
    try testing.expect(!p.wants(receiver));
}

test "Pending: terminations are ignored" {
    var p: Pending = .{};
    const applied_devs = [_]Hidutil.VendorProduct{receiver};
    const gone: DeviceNotify.Change = .{
        .kind = .terminated,
        .devices = &.{.{ .vendor = 0x046D, .product = 0xC548, .built_in = false }},
        .overflowed = false,
    };
    try testing.expect(!p.add(onlyApplied(&applied_devs), gone));
}

test "Pending: the built-in keyboard reads as 0/0 and maps to the 0/0 alias" {
    var p: Pending = .{};
    const applied_devs = [_]Hidutil.VendorProduct{builtin_kb};
    try testing.expect(p.add(onlyApplied(&applied_devs), matched(&.{.{ .vendor = 0, .product = 0, .built_in = true }})));
    try testing.expect(p.wants(builtin_kb));
}

test "Pending: one receiver's several services accumulate once" {
    var p: Pending = .{};
    const applied_devs = [_]Hidutil.VendorProduct{receiver};
    const svc: DeviceNotify.Device = .{ .vendor = 0x046D, .product = 0xC548, .built_in = false };
    try testing.expect(p.add(onlyApplied(&applied_devs), matched(&.{ svc, svc })));
    try testing.expect(p.add(onlyApplied(&applied_devs), matched(&.{svc})));
    try testing.expectEqual(@as(usize, 1), p.len);
}

test "Pending: an overflowed batch acts on every device" {
    var p: Pending = .{};
    const applied_devs = [_]Hidutil.VendorProduct{ receiver, builtin_kb };
    const batch: DeviceNotify.Change = .{ .kind = .matched, .devices = &.{}, .overflowed = true };
    try testing.expect(p.add(onlyApplied(&applied_devs), batch));
    try testing.expect(p.wants(receiver));
    try testing.expect(p.wants(builtin_kb));
}

test "Pending: a keyboard skipped at the last grabber forward arriving is due a re-forward" {
    // A keyboard disconnected when the agent forwarded its rules (unplugged,
    // or switched away) needs them once it connects: the grabber has no rule
    // for it, so its own re-seize on enumeration doesn't cover it.
    var p: Pending = .{};
    const absent = [_]Hidutil.VendorProduct{unifying};
    const interest: Interest = .{ .applied = &.{}, .absent = &absent };
    try testing.expect(p.add(interest, matched(&.{.{ .vendor = 0x046D, .product = 0xC52B, .built_in = false }})));
    try testing.expect(p.wantsAny(&absent));
}

test "Pending: an already-forwarded keyboard re-enumerating needs no re-forward" {
    // The grabber's own DeviceNotify re-seizes devices it has rules for.
    var p: Pending = .{};
    const absent = [_]Hidutil.VendorProduct{unifying};
    const applied_devs = [_]Hidutil.VendorProduct{receiver};
    const interest: Interest = .{ .applied = &applied_devs, .absent = &absent };
    try testing.expect(p.add(interest, matched(&.{.{ .vendor = 0x046D, .product = 0xC548, .built_in = false }})));
    try testing.expect(!p.wantsAny(&absent));
}
