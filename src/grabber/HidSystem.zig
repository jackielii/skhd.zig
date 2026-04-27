//! Minimal IOHIDSystem client for forcing caps_lock state off.
//!
//! When IOHIDManager seize captures an Apple-built-in keyboard, the
//! kernel's IOHIDSystem still receives caps_lock toggle through a
//! firmware side channel — Apple keyboards do their own ~150ms
//! hold-to-toggle, and the resulting state change reaches the OS
//! independently of the HID events we get via seize. Result: the OS
//! caps_lock state diverges, the menu-bar / LED show it on, and the
//! user's tap-hold remap can't undo it (their tap maps to escape, not
//! caps_lock).
//!
//! Same workaround Karabiner uses: open a connection to the
//! IOHIDSystem service and call IOHIDSetModifierLockState(false)
//! whenever a caps_lock event reaches us on a seized keyboard whose
//! taphold rule remaps 0x39 — that resets the kernel's view of
//! caps_lock state regardless of what the firmware just did.

const std = @import("std");
const c = @import("c.zig");

const log = std.log.scoped(.hid_system);

connect: c.io_connect_t,

const Self = @This();

pub fn init() !Self {
    const matching = c.IOServiceMatching("IOHIDSystem");
    if (matching == null) return error.IOServiceMatchingFailed;
    // IOServiceGetMatchingService consumes one reference on the
    // matching dict, so we don't release it ourselves.
    const service = c.IOServiceGetMatchingService(c.kIOMainPortDefault, matching);
    if (service == 0) return error.IOHIDSystemNotFound;
    defer _ = c.IOObjectRelease(service);

    var connect: c.io_connect_t = 0;
    const r = c.IOServiceOpen(service, c.mach_task_self_, c.kIOHIDParamConnectType, &connect);
    if (r != c.kIOReturnSuccess) {
        log.warn("IOServiceOpen IOHIDSystem failed: 0x{X:0>8}", .{@as(u32, @bitCast(r))});
        return error.IOHIDSystemOpenFailed;
    }
    return .{ .connect = connect };
}

pub fn deinit(self: *Self) void {
    _ = c.IOServiceClose(self.connect);
    self.connect = 0;
}

pub fn setCapsLockState(self: *Self, state: bool) void {
    const r = c.IOHIDSetModifierLockState(self.connect, c.NX_MODIFIERKEY_ALPHALOCK, @intFromBool(state));
    if (r != c.kIOReturnSuccess) {
        log.warn("IOHIDSetModifierLockState failed: 0x{X:0>8}", .{@as(u32, @bitCast(r))});
    }
}

pub fn getCapsLockState(self: *Self) ?bool {
    var state: u8 = 0;
    const r = c.IOHIDGetModifierLockState(self.connect, c.NX_MODIFIERKEY_ALPHALOCK, &state);
    if (r != c.kIOReturnSuccess) return null;
    return state != 0;
}
