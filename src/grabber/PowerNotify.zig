//! System sleep/wake notifications via IORegisterForSystemPower.
//!
//! Why: after a long lid-close → sleep → wake cycle, the IOHIDManager
//! we set up at startup keeps holding stale IOHIDDeviceRefs and stops
//! delivering input. The grabber's CFRunLoop sits in mach_msg forever
//! and the user's builtin keyboard appears dead. Re-running the
//! current apply_rules path on wake re-creates the manager and the
//! seize against the post-wake device set.
//!
//! Logging: every transition is logged to the grabber log (Can/Will
//! sleep, Will/Has power-on) so the next incident is self-evident
//! without needing pmset cross-reference.
//!
//! Lifetime: one PowerNotify per Daemon. Init schedules a run-loop
//! source on the current run loop; deinit removes it and releases the
//! port + root-domain connection. Ack semantics: Can/WillSleep must
//! be acknowledged with IOAllowPowerChange or sleep gets blocked
//! until our process dies.

const std = @import("std");
const c = @import("c.zig");

const log = std.log.scoped(.power);

pub const WakeCallback = *const fn (ctx: ?*anyopaque) void;

allocator: std.mem.Allocator,
root_port: c.io_connect_t = 0,
notifier: c.io_object_t = 0,
notify_port: c.IONotificationPortRef = null,
run_loop_source: c.CFRunLoopSourceRef = null,
on_wake: WakeCallback,
on_wake_ctx: ?*anyopaque,
/// Set by the registered C callback. Read-only otherwise.
last_message: u32 = 0,

const Self = @This();

/// Singleton — the C callback is a global function pointer with no
/// closure capture. One Daemon → one PowerNotify → one global.
var instance: ?*Self = null;

pub fn init(
    allocator: std.mem.Allocator,
    on_wake: WakeCallback,
    on_wake_ctx: ?*anyopaque,
) !*Self {
    if (instance != null) return error.AlreadyInitialized;

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .on_wake = on_wake,
        .on_wake_ctx = on_wake_ctx,
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
    log.info("registered for system power notifications", .{});
    return self;
}

pub fn deinit(self: *Self) void {
    if (self.run_loop_source) |src| {
        c.CFRunLoopRemoveSource(c.CFRunLoopGetCurrent(), src, c.kCFRunLoopDefaultMode);
        // The source is owned by the notify port — don't CFRelease it.
        self.run_loop_source = null;
    }
    if (self.notifier != 0) {
        _ = c.IODeregisterForSystemPower(&self.notifier);
        self.notifier = 0;
    }
    if (self.notify_port) |p| {
        c.IONotificationPortDestroy(p);
        self.notify_port = null;
    }
    // root_port is a user-client connection owned by IORegisterForSystemPower;
    // IODeregisterForSystemPower closes it for us. Don't IOServiceClose it.
    self.root_port = 0;
    instance = null;
    self.allocator.destroy(self);
}

fn powerCallback(
    refcon: ?*anyopaque,
    service: c.io_service_t,
    messageType: u32,
    messageArgument: ?*anyopaque,
) callconv(.c) void {
    _ = service;
    const self: *Self = @ptrCast(@alignCast(refcon orelse return));
    self.last_message = messageType;

    // messageArgument is treated as an intptr_t notification ID for ack.
    const arg_id: isize = @bitCast(@intFromPtr(messageArgument));

    // info level: these fire several times a day, so they stay out of
    // the release log (ReleaseFast compiles out < warn) and don't pile
    // up on users' machines. Build ReleaseSafe to see them when tracing
    // a "keyboard dead after lid sleep" recurrence.
    switch (messageType) {
        c.kIOMessageCanSystemSleep => {
            log.info("can system sleep — ack", .{});
            _ = c.IOAllowPowerChange(self.root_port, arg_id);
        },
        c.kIOMessageSystemWillSleep => {
            log.info("system will sleep — ack", .{});
            _ = c.IOAllowPowerChange(self.root_port, arg_id);
        },
        c.kIOMessageSystemWillPowerOn => {
            log.info("system will power on (early wake)", .{});
        },
        c.kIOMessageSystemHasPoweredOn => {
            log.info("system has powered on — invoking wake handler", .{});
            self.on_wake(self.on_wake_ctx);
        },
        else => {
            log.info("unhandled power message: 0x{X:0>8}", .{messageType});
        },
    }
}
