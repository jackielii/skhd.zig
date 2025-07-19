const std = @import("std");
const DeviceManager = @import("DeviceManager.zig");
const Keycodes = @import("Keycodes.zig");
const c = @import("c.zig");

// Track modifier state
var ctrl_pressed = false;

// Alternative echo mode using HID input callbacks to show device-specific input
// This uses BOTH CGEventTap (to intercept) and IOHIDManager (to identify devices)
pub fn echoHID() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize device manager
    const device_manager = try DeviceManager.create(allocator);
    defer device_manager.destroy();

    std.debug.print("Ctrl+C to exit\n", .{});
    std.debug.print("Monitoring and INTERCEPTING keyboard devices with HID input...\n\n", .{});

    // Register input callbacks for all keyboard devices
    try device_manager.registerInputCallbacks(keyboardInputCallback, device_manager);

    // ALSO create an event tap to intercept events
    const EventTap = @import("EventTap.zig");
    const mask: u32 = (1 << c.kCGEventKeyDown) |
        (1 << c.kCGEventFlagsChanged) |
        (1 << c.kCGEventLeftMouseDown) |
        (1 << c.kCGEventRightMouseDown) |
        (1 << c.kCGEventOtherMouseDown);
    var event_tap = EventTap{ .mask = mask };
    defer event_tap.deinit();
    
    try event_tap.begin(interceptCallback, null);

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

        // Only show key press events, not releases
        if (pressed) {
            // HID usage codes need to be converted to keycodes
            // For keyboard page, usage codes map differently than Carbon keycodes
            var key_name: []const u8 = "unknown";
            var keycode: u32 = 0;

            // Convert HID usage to a readable name
            switch (usage) {
                // Letters
                0x04 => {
                    key_name = "a";
                    keycode = 0x00;
                },
                0x05 => {
                    key_name = "b";
                    keycode = 0x0B;
                },
                0x06 => {
                    key_name = "c";
                    keycode = 0x08;
                },
                0x07 => {
                    key_name = "d";
                    keycode = 0x02;
                },
                0x08 => {
                    key_name = "e";
                    keycode = 0x0E;
                },
                0x09 => {
                    key_name = "f";
                    keycode = 0x03;
                },
                0x0A => {
                    key_name = "g";
                    keycode = 0x05;
                },
                0x0B => {
                    key_name = "h";
                    keycode = 0x04;
                },
                0x0C => {
                    key_name = "i";
                    keycode = 0x22;
                },
                0x0D => {
                    key_name = "j";
                    keycode = 0x26;
                },
                0x0E => {
                    key_name = "k";
                    keycode = 0x28;
                },
                0x0F => {
                    key_name = "l";
                    keycode = 0x25;
                },
                0x10 => {
                    key_name = "m";
                    keycode = 0x2E;
                },
                0x11 => {
                    key_name = "n";
                    keycode = 0x2D;
                },
                0x12 => {
                    key_name = "o";
                    keycode = 0x1F;
                },
                0x13 => {
                    key_name = "p";
                    keycode = 0x23;
                },
                0x14 => {
                    key_name = "q";
                    keycode = 0x0C;
                },
                0x15 => {
                    key_name = "r";
                    keycode = 0x0F;
                },
                0x16 => {
                    key_name = "s";
                    keycode = 0x01;
                },
                0x17 => {
                    key_name = "t";
                    keycode = 0x11;
                },
                0x18 => {
                    key_name = "u";
                    keycode = 0x20;
                },
                0x19 => {
                    key_name = "v";
                    keycode = 0x09;
                },
                0x1A => {
                    key_name = "w";
                    keycode = 0x0D;
                },
                0x1B => {
                    key_name = "x";
                    keycode = 0x07;
                },
                0x1C => {
                    key_name = "y";
                    keycode = 0x10;
                },
                0x1D => {
                    key_name = "z";
                    keycode = 0x06;
                },
                // Numbers
                0x1E => {
                    key_name = "1";
                    keycode = 0x12;
                },
                0x1F => {
                    key_name = "2";
                    keycode = 0x13;
                },
                0x20 => {
                    key_name = "3";
                    keycode = 0x14;
                },
                0x21 => {
                    key_name = "4";
                    keycode = 0x15;
                },
                0x22 => {
                    key_name = "5";
                    keycode = 0x17;
                },
                0x23 => {
                    key_name = "6";
                    keycode = 0x16;
                },
                0x24 => {
                    key_name = "7";
                    keycode = 0x1A;
                },
                0x25 => {
                    key_name = "8";
                    keycode = 0x1C;
                },
                0x26 => {
                    key_name = "9";
                    keycode = 0x19;
                },
                0x27 => {
                    key_name = "0";
                    keycode = 0x1D;
                },
                0x28 => {
                    key_name = "return";
                    keycode = 0x24;
                },
                0x29 => {
                    key_name = "escape";
                    keycode = 0x35;
                },
                0x2A => {
                    key_name = "delete";
                    keycode = 0x33;
                },
                0x2B => {
                    key_name = "tab";
                    keycode = 0x30;
                },
                0x2C => {
                    key_name = "space";
                    keycode = 0x31;
                },
                // Modifiers
                0xE0 => {
                    key_name = "ctrl";
                    keycode = 0x3B;
                    ctrl_pressed = true;
                },
                0xE1 => {
                    key_name = "shift";
                    keycode = 0x38;
                },
                0xE2 => {
                    key_name = "alt";
                    keycode = 0x3A;
                },
                0xE3 => {
                    key_name = "cmd";
                    keycode = 0x37;
                },
                else => {
                    if (usage < 0x100) {
                        key_name = "unknown";
                    } else {
                        // Likely a key release or invalid usage
                        return;
                    }
                },
            }

            std.debug.print("[{s} (0x{x:0>4}:0x{x:0>4})] \t{s}\tHID usage: 0x{x:0>2}\n", .{ device_info.name, device_info.vendor_id, device_info.product_id, key_name, usage });

            // Check for Ctrl+C
            if (usage == 0x06 and ctrl_pressed) { // 'c' key in HID usage
                std.debug.print("\nCtrl+C pressed - exiting\n", .{});
                std.posix.exit(0);
            }
        } else {
            // Key release - check if it's ctrl
            if (usage == 0xE0) {
                ctrl_pressed = false;
            }
        }
    }
}

// CGEventTap callback that just intercepts (consumes) all events
fn interceptCallback(_: c.CGEventTapProxy, typ: c.CGEventType, event: c.CGEventRef, _: ?*anyopaque) callconv(.c) c.CGEventRef {
    switch (typ) {
        c.kCGEventKeyDown => {
            // Check for Ctrl+C to exit
            const keycode = c.CGEventGetIntegerValueField(event, c.kCGKeyboardEventKeycode);
            const flags = c.CGEventGetFlags(event);
            if (keycode == c.kVK_ANSI_C and flags & c.kCGEventFlagMaskControl != 0) {
                std.debug.print("\nCtrl+C pressed - exiting\n", .{});
                std.posix.exit(0);
            }
            return @ptrFromInt(0); // Consume the event
        },
        c.kCGEventLeftMouseDown, c.kCGEventRightMouseDown, c.kCGEventOtherMouseDown => {
            return @ptrFromInt(0); // Consume mouse events
        },
        else => return event,
    }
}

test "HID echo mode" {
    // This would block, so we don't run it in tests
}

