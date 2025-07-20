const std = @import("std");
const DeviceManager = @import("DeviceManager.zig");
const c = @import("c.zig");

// Track modifier state
var ctrl_pressed = false;

// Alternative echo mode using HID input callbacks to show device-specific input
pub fn echoHID() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize device manager
    const device_manager = try DeviceManager.create(allocator);
    defer device_manager.destroy();

    std.debug.print("Ctrl+C to exit\n", .{});
    std.debug.print("Monitoring keyboard devices with HID input...\n\n", .{});

    // Register input callbacks for all keyboard devices
    try device_manager.registerInputCallbacks(keyboardInputCallback, device_manager);
    
    // Run the event loop
    c.CFRunLoopRun();
}

fn keyboardInputCallback(context: ?*anyopaque, result: c.IOReturn, sender: ?*anyopaque, value: c.IOHIDValueRef) callconv(.c) void {
    _ = result;

    const device_manager = @as(*DeviceManager, @ptrCast(@alignCast(context)));
    const device = @as(c.IOHIDDeviceRef, @ptrCast(sender));

    // Get device info
    const device_info = device_manager.getDeviceInfo(device) orelse {
        std.debug.print("Unknown device\n", .{});
        return;
    };

    // Get the element that generated this value
    const element = c.IOHIDValueGetElement(value);
    const usage_page = c.IOHIDElementGetUsagePage(element);
    const usage = c.IOHIDElementGetUsage(element);

    // We're interested in keyboard usage page
    if (usage_page == c.kHIDPage_KeyboardOrKeypad) {
        const pressed = c.IOHIDValueGetIntegerValue(value) != 0;
        const key_name = getKeyName(usage);
        
        if (key_name) |name| {
            const event_type = if (pressed) "DOWN" else "UP  ";
            std.debug.print("[{s} (0x{x:0>4}:0x{x:0>4})] {s} {s}\n", .{ 
                device_info.name, 
                device_info.vendor_id, 
                device_info.product_id, 
                event_type,
                name 
            });

            // Check for Ctrl+C
            if (usage == 0x06 and ctrl_pressed and pressed) { // 'c' key in HID usage
                std.debug.print("\nCtrl+C pressed - exiting\n", .{});
                std.posix.exit(0);
            }
        }

        // Track ctrl state
        if (usage == 0xE0) { // Left Control
            ctrl_pressed = pressed;
        } else if (usage == 0xE4) { // Right Control
            ctrl_pressed = pressed;
        }
    }
}

fn getKeyName(usage: u32) ?[]const u8 {
    return switch (usage) {
        // Letters A-Z
        0x04 => "a",
        0x05 => "b",
        0x06 => "c",
        0x07 => "d",
        0x08 => "e",
        0x09 => "f",
        0x0A => "g",
        0x0B => "h",
        0x0C => "i",
        0x0D => "j",
        0x0E => "k",
        0x0F => "l",
        0x10 => "m",
        0x11 => "n",
        0x12 => "o",
        0x13 => "p",
        0x14 => "q",
        0x15 => "r",
        0x16 => "s",
        0x17 => "t",
        0x18 => "u",
        0x19 => "v",
        0x1A => "w",
        0x1B => "x",
        0x1C => "y",
        0x1D => "z",
        
        // Numbers
        0x1E => "1",
        0x1F => "2",
        0x20 => "3",
        0x21 => "4",
        0x22 => "5",
        0x23 => "6",
        0x24 => "7",
        0x25 => "8",
        0x26 => "9",
        0x27 => "0",
        
        // Special keys
        0x28 => "return",
        0x29 => "escape",
        0x2A => "delete",
        0x2B => "tab",
        0x2C => "space",
        0x2D => "hyphen",        // - _
        0x2E => "equal",         // = +
        0x2F => "lbracket",      // [ {
        0x30 => "rbracket",      // ] }
        0x31 => "backslash",     // \ |
        0x32 => "semicolon",     // ; :
        0x33 => "apostrophe",    // ' "
        0x34 => "grave",         // ` ~
        0x35 => "comma",         // , <
        0x36 => "period",        // . >
        0x37 => "slash",         // / ?
        0x38 => "capslock",
        
        // Function keys
        0x3A => "f1",
        0x3B => "f2",
        0x3C => "f3",
        0x3D => "f4",
        0x3E => "f5",
        0x3F => "f6",
        0x40 => "f7",
        0x41 => "f8",
        0x42 => "f9",
        0x43 => "f10",
        0x44 => "f11",
        0x45 => "f12",
        0x68 => "f13",
        0x69 => "f14",
        0x6A => "f15",
        0x6B => "f16",
        0x6C => "f17",
        0x6D => "f18",
        0x6E => "f19",
        0x6F => "f20",
        
        // Control keys
        0x46 => "printscreen",
        0x47 => "scrolllock",
        0x48 => "pause",
        0x49 => "insert",
        0x4A => "home",
        0x4B => "pageup",
        0x4C => "forwarddelete",
        0x4D => "end",
        0x4E => "pagedown",
        0x4F => "right",
        0x50 => "left",
        0x51 => "down",
        0x52 => "up",
        
        // Keypad
        0x53 => "numlock",
        0x54 => "keypad/",
        0x55 => "keypad*",
        0x56 => "keypad-",
        0x57 => "keypad+",
        0x58 => "keypadenter",
        0x59 => "keypad1",
        0x5A => "keypad2",
        0x5B => "keypad3",
        0x5C => "keypad4",
        0x5D => "keypad5",
        0x5E => "keypad6",
        0x5F => "keypad7",
        0x60 => "keypad8",
        0x61 => "keypad9",
        0x62 => "keypad0",
        0x63 => "keypad.",
        0x67 => "keypad=",
        0x85 => "keypad,",
        
        // Modifiers
        0xE0 => "lctrl",
        0xE1 => "lshift",
        0xE2 => "lalt",
        0xE3 => "lcmd",
        0xE4 => "rctrl",
        0xE5 => "rshift",
        0xE6 => "ralt",
        0xE7 => "rcmd",
        
        // Media keys
        0x7F => "mute",
        0x80 => "volumeup",
        0x81 => "volumedown",
        0x9B => "mediastop",
        0x9C => "mediaprevious",
        0x9D => "mediaplay",
        0x9E => "medianext",
        
        // Additional keys
        0x64 => "nonus_backslash",  // Non-US \ and |
        0x65 => "application",       // Windows menu key
        0x66 => "power",
        0x75 => "help",
        0x76 => "menu",
        0x77 => "select",
        0x78 => "stop",
        0x79 => "again",
        0x7A => "undo",
        0x7B => "cut",
        0x7C => "copy",
        0x7D => "paste",
        0x7E => "find",
        
        // International keys
        0x87 => "international1",    // JIS _ and |
        0x88 => "international2",    // JIS Katakana/Hiragana
        0x89 => "international3",    // JIS Yen
        0x8A => "international4",    // JIS Henkan
        0x8B => "international5",    // JIS Muhenkan
        0x8C => "international6",    // JIS ,
        0x8D => "international7",
        0x8E => "international8",
        0x8F => "international9",
        0x90 => "lang1",            // Korean Hangul/English
        0x91 => "lang2",            // Korean Hanja
        0x92 => "lang3",            // Japanese Katakana
        0x93 => "lang4",            // Japanese Hiragana
        0x94 => "lang5",            // Japanese Zenkaku/Hankaku
        
        else => null,
    };
}

test "HID echo mode" {
    // This would block, so we don't run it in tests
}