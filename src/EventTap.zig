const std = @import("std");
const c = @import("c.zig");

handle: c.CFMachPortRef = null,
runloop_source: c.CFRunLoopSourceRef = null,
mask: c.CGEventMask,

const EventTap = @This();
const log = std.log.scoped(.event_tap);

pub fn enabled(self: *EventTap) bool {
    return self.handle != null and c.CGEventTapIsEnabled(self.handle);
}

// pub const CGEventTapCallBack = ?*const fn (CGEventTapProxy, CGEventType, CGEventRef, ?*anyopaque) callconv(.c) CGEventRef;

pub fn begin(self: *EventTap, callback: c.CGEventTapCallBack, user_info: ?*anyopaque) !void {
    // CGEventTapCreate can transiently return NULL during early login on macOS
    // (Tahoe especially) when WindowServer/TCC haven't finished coming up, even
    // though accessibility permissions are granted. Retry briefly before giving
    // up; a real permissions denial will fail every attempt and surface the
    // same error after the retry budget is spent.
    const max_attempts: u8 = 10;
    const retry_delay_ns: u64 = 500 * std.time.ns_per_ms;

    var attempt: u8 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        self.handle = c.CGEventTapCreate(c.kCGSessionEventTap, c.kCGHeadInsertEventTap, //
            c.kCGEventTapOptionDefault, self.mask, callback, user_info);
        if (self.enabled()) {
            self.runloop_source = c.CFMachPortCreateRunLoopSource(c.kCFAllocatorDefault, self.handle, 0);
            c.CFRunLoopAddSource(c.CFRunLoopGetMain(), self.runloop_source, c.kCFRunLoopCommonModes);
            if (attempt > 0) log.info("Event tap created on attempt {d}/{d}", .{ attempt + 1, max_attempts });
            return;
        }
        if (attempt + 1 < max_attempts) {
            log.warn("Event tap creation failed (attempt {d}/{d}), retrying in 500ms...", .{ attempt + 1, max_attempts });
            std.time.sleep(retry_delay_ns);
        }
    }
    return error.AccessibilityPermissionDenied;
}

pub fn deinit(self: *EventTap) void {
    if (self.handle == null) return;
    // Clean up regardless of enabled state — when the system disables the tap
    // (e.g. accessibility revoked at runtime), `enabled()` is false but the
    // CFMachPort and run loop source are still installed and must be torn
    // down or the keyboard remains captured.
    c.CGEventTapEnable(self.handle, false);
    c.CFMachPortInvalidate(self.handle);
    if (self.runloop_source != null) {
        c.CFRunLoopRemoveSource(c.CFRunLoopGetMain(), self.runloop_source, c.kCFRunLoopCommonModes);
        c.CFRelease(self.runloop_source);
        self.runloop_source = null;
    }
    c.CFRelease(self.handle);
    self.handle = null;
}

// This test would block forever as it runs an actual event tap
// test "EventTap" {
//     var event_tap = EventTap{ .mask = (1 << c.kCGEventKeyDown) | (1 << c.NX_SYSDEFINED) };
//     defer event_tap.deinit();

//     const callback = struct {
//         fn f(proxy: c.CGEventTapProxy, typ: c.CGEventType, event: c.CGEventRef, _: ?*anyopaque) callconv(.c) c.CGEventRef {
//             _ = proxy;
//             if (typ == c.kCGEventKeyDown) {
//                 const keycode = c.CGEventGetIntegerValueField(event, c.kCGKeyboardEventKeycode);
//                 const flags = c.CGEventGetFlags(event);
//                 // Control + C
//                 if (keycode == c.kVK_ANSI_C and flags & c.kCGEventFlagMaskControl != 0) {
//                     std.process.exit(0);
//                 }
//             }
//             std.debug.print("Event: {any}\n", .{event.?});
//             return event;
//         }
//     };
//     try event_tap.run(callback.f, null);
// }
