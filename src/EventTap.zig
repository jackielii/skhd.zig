const std = @import("std");
const c = @import("c.zig");

handle: c.CFMachPortRef = null,
runloop_source: c.CFRunLoopSourceRef = null,
mask: c.CGEventMask,

const EventTap = @This();

pub fn enabled(self: *EventTap) bool {
    return self.handle != null and c.CGEventTapIsEnabled(self.handle);
}

// pub const CGEventTapCallBack = ?*const fn (CGEventTapProxy, CGEventType, CGEventRef, ?*anyopaque) callconv(.c) CGEventRef;

pub fn begin(self: *EventTap, callback: c.CGEventTapCallBack, user_info: ?*anyopaque) !void {
    self.handle = c.CGEventTapCreate(c.kCGSessionEventTap, c.kCGHeadInsertEventTap, //
        c.kCGEventTapOptionDefault, self.mask, callback, user_info);
    if (self.enabled()) {
        self.runloop_source = c.CFMachPortCreateRunLoopSource(c.kCFAllocatorDefault, self.handle, 0);
        c.CFRunLoopAddSource(c.CFRunLoopGetMain(), self.runloop_source, c.kCFRunLoopCommonModes);
    } else {
        return error.AccessibilityPermissionDenied;
    }
}

pub fn deinit(self: *EventTap) void {
    if (self.enabled()) {
        c.CGEventTapEnable(self.handle, false);
        c.CFMachPortInvalidate(self.handle);
        c.CFRunLoopRemoveSource(c.CFRunLoopGetMain(), self.runloop_source, c.kCFRunLoopCommonModes);
        c.CFRelease(self.runloop_source);
        c.CFRelease(self.handle);
        self.handle = null;
    }
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
