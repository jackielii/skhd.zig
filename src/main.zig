const std = @import("std");
const c = @cImport(@cInclude("Carbon/Carbon.h"));

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const gpa_allocator = gpa.allocator();

pub extern fn NSApplicationLoad() void;
pub export fn callback(_: c.CGEventTapProxy, typ: c.CGEventType, event: c.CGEventRef, _: ?*anyopaque) c.CGEventRef {
    if (typ != c.kCGEventKeyDown) {
        return event;
    }
    var keycode = c.CGEventGetIntegerValueField(event, c.kCGKeyboardEventKeycode);
    // std.debug.print("type of keycode: {}\n", .{@TypeOf(keycode)});

    var flags: c.CGEventFlags = c.CGEventGetFlags(event);
    if (keycode == c.kVK_ANSI_C and flags & c.kCGEventFlagMaskControl != 0) {
        std.debug.print("Ctrl+C pressed\n", .{});
        std.os.exit(0);
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
    std.debug.print("\t{s}\tkeycode: 0x{x:0<2}\n", .{ chars, @bitCast(u64, keycode) });

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
    var mask: u32 = 1 << c.kCGEventKeyDown;
    std.debug.print("mask: 0x{x}\n", .{mask});

    var handle: c.CFMachPortRef = c.CGEventTapCreate(c.kCGSessionEventTap, c.kCGHeadInsertEventTap, c.kCGEventTapOptionDefault, mask, &callback, null);
    defer c.CFRelease(handle);
    var enabled = c.CGEventTapIsEnabled(handle);
    if (!enabled) {
        std.debug.print("Failed to enable event tap", .{});
        std.os.exit(1);
    }

    var loopsource = c.CFMachPortCreateRunLoopSource(c.kCFAllocatorDefault, handle, 0);
    defer c.CFRelease(loopsource);

    c.CFRunLoopAddSource(c.CFRunLoopGetMain(), loopsource, c.kCFRunLoopCommonModes);
    NSApplicationLoad();
    c.CFRunLoopRun();
}

const expect = std.testing.expect;

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

fn strForKey(keyCode: i64) []const u8 {
    return switch (keyCode) {
        0 => "a",
        1 => "s",
        2 => "d",
        3 => "f",
        4 => "h",
        5 => "g",
        6 => "z",
        7 => "x",
        8 => "c",
        9 => "v",
        // what is 10?
        11 => "b",
        12 => "q",
        13 => "w",
        14 => "e",
        15 => "r",
        16 => "y",
        17 => "t",
        18 => "1",
        19 => "2",
        20 => "3",
        21 => "4",
        22 => "6",
        23 => "5",
        24 => "=",
        25 => "9",
        26 => "7",
        27 => "-",
        28 => "8",
        29 => "0",
        30 => "]",
        31 => "o",
        32 => "u",
        33 => "[",
        34 => "i",
        35 => "p",
        36 => "RETURN",
        37 => "l",
        38 => "j",
        39 => "'",
        40 => "k",
        41 => ";",
        42 => "\\",
        43 => ",",
        44 => "/",
        45 => "n",
        46 => "m",
        47 => ".",
        48 => "TAB",
        49 => "SPACE",
        50 => "`",
        51 => "DELETE",
        52 => "ENTER",
        53 => "ESCAPE",

        65 => ".",

        67 => "*",

        69 => "+",

        71 => "CLEAR",

        75 => "/",
        76 => "ENTER",

        78 => "-",

        81 => "=",
        82 => "0",
        83 => "1",
        84 => "2",
        85 => "3",
        86 => "4",
        87 => "5",
        88 => "6",
        89 => "7",

        91 => "8",
        92 => "9",

        96 => "F5",
        97 => "F6",
        98 => "F7",
        99 => "F3",
        100 => "F8",
        101 => "F9",

        103 => "F11",

        105 => "F13",

        107 => "F14",

        109 => "F10",

        111 => "F12",

        113 => "F15",
        114 => "HELP",
        115 => "HOME",
        116 => "PGUP",
        117 => "DELETE",
        118 => "F4",
        119 => "END",
        120 => "F2",
        121 => "PGDN",
        122 => "F1",
        123 => "LEFT",
        124 => "RIGHT",
        125 => "DOWN",
        126 => "UP",

        else => "unknown keycode",
    };
}

fn createStringForKey(keyCode: c.CGKeyCode, allocator: std.mem.Allocator) ![]u8 {
    var currentKeyboard = c.TISCopyCurrentKeyboardInputSource();
    var layoutData = @ptrCast(c.CFDataRef, c.TISGetInputSourceProperty(currentKeyboard, c.kTISPropertyUnicodeKeyLayoutData));
    var keyboardLayout = @ptrCast(*const c.UCKeyboardLayout, @alignCast(@alignOf(*c.UCKeyboardLayout), c.CFDataGetBytePtr(layoutData)));
    // var keyboardLayout = @ptrCast(*c.UCKeyboardLayout, c.CFDataGetBytePtr(layoutData));

    var keysDown: c.UInt32 = 0;
    var chars: [4]c.UniChar = undefined;
    // std.debug.print("typeof chars: {}\n", .{@TypeOf(chars)});
    var realLength: c.UniCharCount = 0;

    _ = c.UCKeyTranslate(
        //
        // keyLayoutPtr
        // A pointer to the first element in a resource of type 'uchr'. Pass a pointer to the 'uchr' resource that you wish the UCKeyTranslate function to use when converting the virtual key code to a Unicode character. The resource handle associated with this pointer need not be locked, since the UCKeyTranslate function does not move memory.
        keyboardLayout,

        // virtualKeyCode
        // An unsigned 16-bit integer. Pass a value specifying the virtual key code that is to be translated. For ADB keyboards, virtual key codes are in the range from 0 to 127.
        keyCode,

        //
        // keyAction
        // An unsigned 16-bit integer. Pass a value specifying the current key action. See Key Actions for descriptions of possible values.
        c.kUCKeyActionDisplay,

        //
        // modifierKeyState
        // An unsigned 32-bit integer. Pass a bit mask indicating the current state of various modifier keys. You can obtain this value from the modifiers field of the event record as follows:
        0,

        //
        // modifierKeyState = ((EventRecord.modifiers) >> 8) & 0xFF;
        // keyboardType
        // An unsigned 32-bit integer. Pass a value specifying the physical keyboard type (that is, the keyboard shape shown by Key Caps). You can call the function LMGetKbdType for this value.
        c.LMGetKbdType(),

        //
        // keyTranslateOptions
        // A bit mask of options for controlling the UCKeyTranslate function. See Key Translation Options Flag and Key Translation Options Mask for descriptions of possible values.
        c.kUCKeyTranslateNoDeadKeysBit,

        //
        // deadKeyState
        // A pointer to an unsigned 32-bit value, initialized to zero. The UCKeyTranslate function uses this value to store private information about the current dead key state.
        &keysDown,

        //
        // maxStringLength
        // A value of type UniCharCount. Pass the number of 16-bit Unicode characters that are contained in the buffer passed in the unicodeString parameter. This may be a value of up to 255, although it would be rare to get more than 4 characters.
        4,

        //
        // actualStringLength
        // A pointer to a value of type UniCharCount. On return this value contains the actual number of Unicode characters placed into the buffer passed in the unicodeString parameter.
        &realLength,

        //
        // unicodeString
        // An array of values of type UniChar. Pass a pointer to the buffer whose sized is specified in the maxStringLength parameter. On return, the buffer contains a string of Unicode characters resulting from the virtual key code being handled. The number of characters in this string is less than or equal to the value specified in the maxStringLength parameter.
        &chars,

        //
        // Return Value
        // A result code. If you pass NULL in the keyLayoutPtr parameter, UCKeyTranslate returns paramErr. The UCKeyTranslate function also returns paramErr for an invalid 'uchr' resource format or for invalid virtualKeyCode or keyAction values, as well as for NULL pointers to output values. The result kUCOutputBufferTooSmall (-25340) is returned for an output string length greater than maxStringLength.
    );

    c.CFRelease(currentKeyboard);

    // return chars[0..realLength].ptr;
    // std.debug.print("type: {}\n", .{@TypeOf(chars[0..realLength].ptr)});
    // var s = "good morning".*;
    // std.debug.print("s: {s}, typeof: {}\n", .{ s, @TypeOf(s[0..realLength]) });

    // std.debug.print("chars: {s}, len: {any}\n", .{ chars[0..realLength], realLength });

    const utf8string = try std.unicode.utf16leToUtf8Alloc(allocator, chars[0..realLength]);
    return utf8string;
    // _ = utf8string;
    // var result = try allocator.alloc(u8, realLength);
    //
    // var i: usize = 0;
    // while (i < realLength) : (i += 1) {
    //     result[i] = @intCast(u8, chars[i]);
    // }
    //
    // return result;
}
