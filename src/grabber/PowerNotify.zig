//! System sleep/wake hook — releases the seize before sleep and
//! re-acquires it on wake, so the seize never spans the sleep power
//! transition.
//!
//! Root cause it addresses: holding an IOHIDManager seize across sleep
//! leaves it stale on wake — the keyboard powers down mid-sleep while
//! seized, and on wake the manager still reports the device (same
//! registry id, matched_count=1) but the event pipe is dead. Re-seizing
//! the same device in place does NOT revive it; only a full device
//! re-enumeration does. So instead we don't hold the seize across sleep
//! at all (the pattern Karabiner-Elements uses: devices are "ungrabbable
//! while system_sleeping").
//!
//! - kIOMessageSystemWillSleep → on_will_sleep (daemon tears down the
//!   seize, marks itself sleeping), THEN ack the sleep after a short
//!   delay so the release propagates to the kernel before the device
//!   powers down (Karabiner delays its ack ~1s for the same reason).
//! - kIOMessageSystemHasPoweredOn → on_wake (daemon clears sleeping and
//!   re-acquires a fresh seize on the now-healthy device).
//! - kIOMessageCanSystemSleep → ack immediately (we never veto sleep).
//!
//! Lifetime: one PowerNotify per Daemon. init registers for system power
//! and schedules its run-loop source; deinit removes it and releases the
//! port + root-domain connection + ack timer.

const std = @import("std");
const c = @import("c.zig");

const log = std.log.scoped(.power);

/// Delay between releasing the seize and acking SystemWillSleep, so the
/// IOHIDManagerClose has propagated in the kernel before the device loses
/// power. Matches Karabiner's 1s. It adds this much latency to sleep,
/// which is imperceptible for a lid close.
const will_sleep_ack_delay_s: f64 = 1.0;

pub const Callback = *const fn (ctx: ?*anyopaque) void;

allocator: std.mem.Allocator,
root_port: c.io_connect_t = 0,
notifier: c.io_object_t = 0,
notify_port: c.IONotificationPortRef = null,
run_loop_source: c.CFRunLoopSourceRef = null,
/// One-shot timer for the delayed SystemWillSleep ack.
ack_timer: c.CFRunLoopTimerRef = null,
/// Notification id captured at WillSleep, acked when ack_timer fires.
pending_ack_id: isize = 0,
on_will_sleep: Callback,
on_wake: Callback,
ctx: ?*anyopaque,

const Self = @This();

/// Singleton — the C callback's refcon carries `self`, but the ack timer
/// callback needs to find us too and CFRunLoopTimerContext is set up the
/// same way. One Daemon → one PowerNotify, so a global is simplest.
var instance: ?*Self = null;

pub fn init(
    allocator: std.mem.Allocator,
    on_will_sleep: Callback,
    on_wake: Callback,
    ctx: ?*anyopaque,
) !*Self {
    if (instance != null) return error.AlreadyInitialized;

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .on_will_sleep = on_will_sleep,
        .on_wake = on_wake,
        .ctx = ctx,
    };
    instance = self;
    errdefer instance = null;

    var port: c.IONotificationPortRef = null;
    var notifier: c.io_object_t = 0;
    const root_port = c.IORegisterForSystemPower(self, &port, powerCallback, &notifier);
    if (root_port == 0) {
        log.err("IORegisterForSystemPower returned MACH_PORT_NULL", .{});
        return error.RegisterFailed;
    }
    errdefer {
        _ = c.IODeregisterForSystemPower(&notifier);
        if (port) |p| c.IONotificationPortDestroy(p);
    }

    const source = c.IONotificationPortGetRunLoopSource(port);
    if (source == null) {
        log.err("IONotificationPortGetRunLoopSource returned null", .{});
        return error.RunLoopSourceFailed;
    }
    c.CFRunLoopAddSource(c.CFRunLoopGetCurrent(), source, c.kCFRunLoopDefaultMode);

    self.root_port = root_port;
    self.notifier = notifier;
    self.notify_port = port;
    self.run_loop_source = source;
    log.info("registered for system power notifications (release-on-sleep)", .{});
    return self;
}

pub fn deinit(self: *Self) void {
    self.cancelAckTimer();
    if (self.run_loop_source) |src| {
        c.CFRunLoopRemoveSource(c.CFRunLoopGetCurrent(), src, c.kCFRunLoopDefaultMode);
        self.run_loop_source = null; // owned by the port; don't release
    }
    if (self.notifier != 0) {
        _ = c.IODeregisterForSystemPower(&self.notifier);
        self.notifier = 0;
    }
    if (self.notify_port) |p| {
        c.IONotificationPortDestroy(p);
        self.notify_port = null;
    }
    self.root_port = 0;
    instance = null;
    self.allocator.destroy(self);
}

fn cancelAckTimer(self: *Self) void {
    if (self.ack_timer) |t| {
        c.CFRunLoopTimerInvalidate(t);
        c.CFRelease(t);
        self.ack_timer = null;
    }
}

fn powerCallback(
    refcon: ?*anyopaque,
    service: c.io_service_t,
    messageType: u32,
    messageArgument: ?*anyopaque,
) callconv(.c) void {
    _ = service;
    const self: *Self = @ptrCast(@alignCast(refcon orelse return));
    const arg_id: isize = @bitCast(@intFromPtr(messageArgument));

    switch (messageType) {
        c.kIOMessageCanSystemSleep => {
            // We never veto sleep — ack immediately.
            log.info("can system sleep — allowing", .{});
            _ = c.IOAllowPowerChange(self.root_port, arg_id);
        },
        c.kIOMessageSystemWillSleep => {
            log.info("system will sleep — releasing seize before sleep", .{});
            // Release the seize NOW (synchronous), then ack after a short
            // delay so the release lands before the device powers down.
            self.on_will_sleep(self.ctx);
            self.scheduleWillSleepAck(arg_id);
        },
        c.kIOMessageSystemWillPowerOn => {
            log.info("system will power on (early wake)", .{});
        },
        c.kIOMessageSystemHasPoweredOn => {
            log.info("system has powered on — re-acquiring seize", .{});
            self.on_wake(self.ctx);
        },
        else => {
            log.info("unhandled power message: 0x{X:0>8} arg={d}", .{ messageType, arg_id });
        },
    }
}

fn scheduleWillSleepAck(self: *Self, notification_id: isize) void {
    self.cancelAckTimer();
    self.pending_ack_id = notification_id;
    var timer_ctx: c.CFRunLoopTimerContext = .{
        .version = 0,
        .info = self,
        .retain = null,
        .release = null,
        .copyDescription = null,
    };
    const fire_at = c.CFAbsoluteTimeGetCurrent() + will_sleep_ack_delay_s;
    const timer = c.CFRunLoopTimerCreate(
        c.kCFAllocatorDefault,
        fire_at,
        0, // one-shot
        0,
        0,
        willSleepAckTimerCallback,
        &timer_ctx,
    );
    if (timer == null) {
        // Couldn't schedule the delayed ack — ack now so we don't block
        // sleep indefinitely. The seize is already released.
        log.warn("ack timer create failed — acking sleep immediately", .{});
        _ = c.IOAllowPowerChange(self.root_port, notification_id);
        return;
    }
    self.ack_timer = timer;
    c.CFRunLoopAddTimer(c.CFRunLoopGetCurrent(), timer, c.kCFRunLoopDefaultMode);
}

fn willSleepAckTimerCallback(_: c.CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(info orelse return));
    const id = self.pending_ack_id;
    self.cancelAckTimer();
    _ = c.IOAllowPowerChange(self.root_port, id);
}
