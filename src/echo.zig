const std = @import("std");
const EventTap = @import("EventTap.zig");
const Keycodes = @import("Keycodes.zig");

const c = @import("c.zig").c;
const NSApplicationLoad = @import("c.zig").NSApplicationLoad;

pub fn echo() !void {
    // NSApplicationLoad();
    const mask: u32 = (1 << c.kCGEventKeyDown) |
        (1 << c.kCGEventFlagsChanged) |
        (1 << c.kCGEventLeftMouseDown) |
        (1 << c.kCGEventRightMouseDown) |
        (1 << c.kCGEventOtherMouseDown);
    var event_tap = EventTap{ .mask = mask };
    defer event_tap.deinit();
    std.debug.print("Ctrl+C to exit\n", .{});
    try event_tap.begin(callback, null);
    c.CFRunLoopRun();
}

fn callback(_: c.CGEventTapProxy, typ: c.CGEventType, event: c.CGEventRef, _: ?*anyopaque) callconv(.c) c.CGEventRef {
    switch (typ) {
        c.kCGEventKeyDown => return printKeydown(event) catch |err| {
            std.debug.print("Error: {}\n", .{err});
            return @ptrFromInt(0);
        },
        // c.kCGEventFlagsChanged => printFlagsChanged(event),
        c.kCGEventLeftMouseDown, c.kCGEventRightMouseDown, c.kCGEventOtherMouseDown => {
            const button = c.CGEventGetIntegerValueField(event, c.kCGMouseEventButtonNumber);
            std.debug.print("Mouse button: {d}\n", .{button});
            return @ptrFromInt(0);
        },
        else => {
            // std.debug.print("Event type: {any}\n", .{typ});
            return event;
        },
    }
}

fn printKeydown(event: c.CGEventRef) !c.CGEventRef {
    const keycode = c.CGEventGetIntegerValueField(event, c.kCGKeyboardEventKeycode);

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
    // if (flags & c.kCGEventFlagMaskNonCoalesced != 0) {
    //     std.debug.print("NonCoalesced ", .{});
    // }
    if (flags & c.kCGEventFlagMaskAlphaShift != 0) {
        std.debug.print("AlphaShift ", .{});
    }

    // const chars = createStringForKey(@intCast(u16, keycode), gpa_allocator) catch @panic("createStringForKey failed");
    // defer gpa_allocator.free(chars);
    // std.debug.print("typeof chars: {}, length: {}\n", .{ @TypeOf(chars), chars.len });
    // std.debug.print("key: {s}", .{chars});
    const chars = Keycodes.getKeyString(@intCast(keycode));
    std.debug.print("\t{s}\tkeycode: 0x{x:0>2}\n", .{ chars, keycode });
    // print("\tkey: '{s}' (0x{x:0>2})\n", .{ key, keycode });

    // var buffer: [255]u8 = undefined;
    // try translateKey(&buffer, @intCast(keycode), @intCast(flags));
    // const s = std.mem.sliceTo(buffer[0..], 0);
    // std.debug.print("\t{s}\tkeycode: 0x{x:0<2}\n", .{ s, keycode });

    return @ptrFromInt(0);
}

fn translateKey(buffer: *[255]u8, keyCode: u16, modifierState: u32) !void {
    const keyboard = c.TISCopyCurrentASCIICapableKeyboardLayoutInputSource();
    const uchr: c.CFDataRef = @ptrCast(c.TISGetInputSourceProperty(keyboard, c.kTISPropertyUnicodeKeyLayoutData));
    defer c.CFRelease(keyboard);

    const keyboard_layout: ?*c.UCKeyboardLayout = @ptrCast(@alignCast(@constCast(c.CFDataGetBytePtr(uchr))));
    if (keyboard_layout == null) {
        return error.@"Failed to get keyboard layout";
    }

    var len: c.UniCharCount = 0;
    var chars: [255]u16 = undefined;
    var state: c.UInt32 = 0;

    const ret = c.UCKeyTranslate(
        keyboard_layout,
        keyCode,
        c.kUCKeyActionDisplay,
        modifierState & 0x0,
        c.LMGetKbdType(),
        c.kUCKeyTranslateNoDeadKeysMask,
        &state,
        chars.len,
        &len,
        &chars,
    );

    if (ret != c.noErr) {
        std.debug.print("ret: {d}\n", .{ret});
        return error.@"Failed to translate key";
    }

    const cfstring = c.CFStringCreateWithCharacters(c.kCFAllocatorDefault, &chars, @intCast(len));
    defer c.CFRelease(cfstring);

    const num_bytes = c.CFStringGetMaximumSizeForEncoding(c.CFStringGetLength(cfstring), c.kCFStringEncodingUTF8);
    if (num_bytes > 64) {
        @panic("num_bytes for cfstring > 64");
    }
    if (c.CFStringGetCString(cfstring, buffer, num_bytes, c.kCFStringEncodingUTF8) == c.false) {
        std.debug.print("str {?x} len: {d}\n", .{ cfstring.?, num_bytes });
        std.debug.print("chars: {x}\n", .{chars});
        return error.@"Failed to get c string from CFString";
    }
}
