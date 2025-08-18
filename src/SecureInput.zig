const std = @import("std");
const c = @import("c.zig");

const SecureInput = @This();
const log = std.log.scoped(.secure_input);

allocator: std.mem.Allocator,
is_secure: bool = false,
notification_ref: ?c.CFUserNotificationRef = null,
check_timer: ?c.CFRunLoopTimerRef = null,

pub extern fn IsSecureEventInputEnabled() c.Boolean;

pub fn init(allocator: std.mem.Allocator) !*SecureInput {
    const self = try allocator.create(SecureInput);
    self.* = .{
        .allocator = allocator,
        .is_secure = false,
        .notification_ref = null,
        .check_timer = null,
    };

    return self;
}

pub fn deinit(self: *SecureInput) void {
    self.stopMonitoring();
    self.allocator.destroy(self);
}

pub fn startMonitoring(self: *SecureInput) void {
    self.checkAndUpdateStatus();

    var timer_context = c.CFRunLoopTimerContext{
        .version = 0,
        .info = self,
        .retain = null,
        .release = null,
        .copyDescription = null,
    };

    self.check_timer = c.CFRunLoopTimerCreate(c.kCFAllocatorDefault, c.CFAbsoluteTimeGetCurrent() + 1.0, 1.0, 0, 0, timerCallback, &timer_context);

    if (self.check_timer) |timer| {
        c.CFRunLoopAddTimer(c.CFRunLoopGetMain(), timer, c.kCFRunLoopCommonModes);
    }
}

pub fn stopMonitoring(self: *SecureInput) void {
    if (self.check_timer) |timer| {
        c.CFRunLoopTimerInvalidate(timer);
        c.CFRelease(timer);
        self.check_timer = null;
    }

    self.dismissNotification();
}

fn timerCallback(_: c.CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const self = @as(*SecureInput, @ptrCast(@alignCast(info.?)));
    self.checkAndUpdateStatus();
}

pub fn checkAndUpdateStatus(self: *SecureInput) void {
    log.debug("Checking secure input status", .{});
    const secure_input_enabled = IsSecureEventInputEnabled() != 0;

    if (secure_input_enabled != self.is_secure) {
        self.is_secure = secure_input_enabled;

        if (secure_input_enabled) {
            log.warn("Secure keyboard entry is enabled - hotkeys will not work", .{});
            self.showNotification();
        } else {
            log.info("Secure keyboard entry is disabled - hotkeys resumed", .{});
            self.dismissNotification();
        }
    }
}

fn showNotification(self: *SecureInput) void {
    self.dismissNotification();

    const header = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "skhd - Secure Input Active", c.kCFStringEncodingUTF8);
    defer if (header != null) c.CFRelease(header);

    const message = c.CFStringCreateWithCString(c.kCFAllocatorDefault, "Hotkeys are disabled while secure keyboard entry is active.\n\nThis usually happens when a password field is focused or certain apps like 1Password are active.\n\nHotkeys will resume automatically when secure input is disabled.", c.kCFStringEncodingUTF8);
    defer if (message != null) c.CFRelease(message);

    var err: c.SInt32 = 0;
    const keys = [_]?*const anyopaque{
        c.kCFUserNotificationAlertHeaderKey,
        c.kCFUserNotificationAlertMessageKey,
    };
    const values = [_]?*const anyopaque{
        header,
        message,
    };
    self.notification_ref = c.CFUserNotificationCreate(c.kCFAllocatorDefault, 0, c.kCFUserNotificationCautionAlertLevel | c.kCFUserNotificationNoDefaultButtonFlag, &err, c.CFDictionaryCreate(c.kCFAllocatorDefault, @constCast(@ptrCast(&keys)), @constCast(@ptrCast(&values)), 2, &c.kCFTypeDictionaryKeyCallBacks, &c.kCFTypeDictionaryValueCallBacks));

    if (err != 0) {
        log.err("Failed to create notification: {d}", .{err});
    }
}

fn dismissNotification(self: *SecureInput) void {
    if (self.notification_ref) |notification| {
        _ = c.CFUserNotificationCancel(notification);
        c.CFRelease(notification);
        self.notification_ref = null;
    }
}

pub fn isSecureInputEnabled(self: *const SecureInput) bool {
    return self.is_secure;
}

