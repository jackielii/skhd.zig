const std = @import("std");
const c = @cImport(@cInclude("Carbon/Carbon.h"));
const strForKey = @import("echo.zig").strForKey;

pub extern fn NSApplicationLoad() void;
pub export fn callback(_: c.CGEventTapProxy, typ: c.CGEventType, event: c.CGEventRef, _: ?*anyopaque) c.CGEventRef {
    if (typ != c.kCGEventKeyDown) {
        return event;
    }
    const keycode = c.CGEventGetIntegerValueField(event, c.kCGKeyboardEventKeycode);
    // std.debug.print("type of keycode: {}\n", .{@TypeOf(keycode)});

    const flags: c.CGEventFlags = c.CGEventGetFlags(event);
    if (keycode == c.kVK_ANSI_C and flags & c.kCGEventFlagMaskControl != 0) {
        std.debug.print("Ctrl+C pressed\n", .{});
        std.posix.exit(0);
    }
    if (flags & c.kCGEventFlagMaskShift != 0) {
        std.debug.print("Shift ", .{});
    }
    if (flags & c.kCGEventFlagMaskControl != 0) {
        std.debug.print("Ctrl ", .{});
    }
    if (flags & c.kCGEventFlagMaskAlternate != 0) {
        std.debug.print("Alt ", .{});
    }
    if (flags & c.kCGEventFlagMaskCommand != 0) {
        std.debug.print("Cmd ", .{});
    }
    if (flags & c.kCGEventFlagMaskSecondaryFn != 0) {
        std.debug.print("Fn ", .{});
    }
    if (flags & c.kCGEventFlagMaskNumericPad != 0) {
        std.debug.print("Num ", .{});
    }
    if (flags & c.kCGEventFlagMaskHelp != 0) {
        std.debug.print("Help ", .{});
    }
    if (flags & c.kCGEventFlagMaskNonCoalesced != 0) {
        std.debug.print("NonCoalesced ", .{});
    }
    if (flags & c.kCGEventFlagMaskAlphaShift != 0) {
        std.debug.print("AlphaShift ", .{});
    }

    // const chars = createStringForKey(@intCast(u16, keycode), gpa_allocator) catch @panic("createStringForKey failed");
    // defer gpa_allocator.free(chars);
    // std.debug.print("typeof chars: {}, length: {}\n", .{ @TypeOf(chars), chars.len });
    // std.debug.print("key: {s}", .{chars});
    const chars = strForKey(keycode);
    const keyCodeBit: i64 = @bitCast(keycode);
    std.debug.print("\t{s}\tkeycode: 0x{x:0<2}\n", .{ chars, keyCodeBit });

    // c.CGEventSetFlags(event, c.kCGEventFlagMaskShift);
    // c.CGEventSetIntegerValueField(event, c.kCGKeyboardEventKeycode, c.kVK_ANSI_X);
    // return event;
    // var str = createDynamicString() catch |err| {
    //     std.debug.print("Error: {}\n", .{err});
    //     return event;
    // };
    // std.debug.print("createDynamicString: {s}\n", .{str});

    return null;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        //fail test; can't try in defer as defer is executed after we return
        if (deinit_status == .leak) {
            std.log.err("memory leak", .{});
        }
    }
    const alloc = gpa.allocator();
    _ = alloc;

    const mask: u32 = 1 << c.kCGEventKeyDown;
    std.debug.print("mask: 0x{x}\n", .{mask});

    const handle: c.CFMachPortRef = c.CGEventTapCreate(c.kCGSessionEventTap, c.kCGHeadInsertEventTap, c.kCGEventTapOptionDefault, mask, &callback, null);
    defer c.CFRelease(handle);
    const enabled = c.CGEventTapIsEnabled(handle);
    if (!enabled) {
        std.debug.print("Failed to enable event tap", .{});
        std.posix.exit(1);
    }

    const loopsource = c.CFMachPortCreateRunLoopSource(c.kCFAllocatorDefault, handle, 0);
    defer c.CFRelease(loopsource);

    c.CFRunLoopAddSource(c.CFRunLoopGetMain(), loopsource, c.kCFRunLoopCommonModes);
    NSApplicationLoad();
    c.CFRunLoopRun();
}

test {
    std.testing.refAllDeclsRecursive(@This());

    std.testing.refAllDecls(@import("parse.zig"));
}
