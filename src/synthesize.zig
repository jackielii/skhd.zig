const std = @import("std");
const c = @import("c.zig");
const Parser = @import("Parser.zig");
const Mappings = @import("Mappings.zig");
const Hotkey = @import("Hotkey.zig");
const ModifierFlag = @import("Keycodes.zig").ModifierFlag;

// Modifier keycodes from original skhd
const Modifier_Keycode_Alt = 0x3A;
const Modifier_Keycode_Shift = 0x38;
const Modifier_Keycode_Cmd = 0x37;
const Modifier_Keycode_Ctrl = 0x3B;
const Modifier_Keycode_Fn = 0x3F;

/// Synthesize a keypress from a key specification string (e.g., "cmd - space")
pub fn synthesizeKey(allocator: std.mem.Allocator, key_string: []const u8) !void {
    // Parse the key string
    var parser = try Parser.init(allocator);
    defer parser.deinit();
    
    // Create temporary mappings just for parsing
    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();
    
    // Parse the key specification
    try parser.parse(&mappings, key_string);
    
    // Find the first hotkey that was parsed
    var mode_iter = mappings.mode_map.iterator();
    if (mode_iter.next()) |mode_entry| {
        const mode = mode_entry.value_ptr.*;
        var hotkey_iter = mode.hotkey_map.iterator();
        if (hotkey_iter.next()) |hotkey_entry| {
            const hotkey = hotkey_entry.key_ptr.*;
            
            // Disable local event suppression and state combining for clean synthesis
            _ = c.CGSetLocalEventsSuppressionInterval(0.0);
            _ = c.CGEnableEventStateCombining(0);
            
            // Press modifiers down
            synthesizeModifiers(hotkey.flags, true);
            
            // Press the main key down
            createAndPostKeyEvent(@intCast(hotkey.key), true);
            
            // Release the main key
            createAndPostKeyEvent(@intCast(hotkey.key), false);
            
            // Release modifiers
            synthesizeModifiers(hotkey.flags, false);
            
            std.log.scoped(.synthesize).debug("Synthesized key: {any} + {d}", .{ hotkey.flags, hotkey.key });
        } else {
            std.debug.print("Error: Failed to parse key specification: {s}\n", .{key_string});
        }
    } else {
        std.debug.print("Error: Failed to parse key specification: {s}\n", .{key_string});
    }
}

/// Synthesize text input
pub fn synthesizeText(allocator: std.mem.Allocator, text: []const u8) !void {
    _ = allocator;
    
    // Convert text to CFString
    const text_ref = c.CFStringCreateWithCString(null, text.ptr, c.kCFStringEncodingUTF8);
    defer c.CFRelease(text_ref);
    
    const text_length = c.CFStringGetLength(text_ref);
    
    // Create key down and key up events
    const down_event = c.CGEventCreateKeyboardEvent(null, 0, true);
    defer c.CFRelease(down_event);
    
    const up_event = c.CGEventCreateKeyboardEvent(null, 0, false);
    defer c.CFRelease(up_event);
    
    // Clear any flags
    c.CGEventSetFlags(down_event, 0);
    c.CGEventSetFlags(up_event, 0);
    
    // Send each character
    var i: c.CFIndex = 0;
    while (i < text_length) : (i += 1) {
        const char = c.CFStringGetCharacterAtIndex(text_ref, i);
        
        // Set the unicode character for both events
        c.CGEventKeyboardSetUnicodeString(down_event, 1, &char);
        c.CGEventPost(c.kCGAnnotatedSessionEventTap, down_event);
        
        // Small delay between key down and up
        std.time.sleep(1000 * 1000); // 1ms in nanoseconds
        
        c.CGEventKeyboardSetUnicodeString(up_event, 1, &char);
        c.CGEventPost(c.kCGAnnotatedSessionEventTap, up_event);
    }
    
    std.log.scoped(.synthesize).debug("Synthesized text: {s}", .{text});
}

fn createAndPostKeyEvent(keycode: u16, pressed: bool) void {
    // Use the deprecated but working CGPostKeyboardEvent for now
    // This matches the original skhd implementation
    _ = c.CGPostKeyboardEvent(0, keycode, if (pressed) 1 else 0);
}

fn synthesizeModifiers(flags: ModifierFlag, pressed: bool) void {
    if (flags.alt or flags.lalt or flags.ralt) {
        createAndPostKeyEvent(Modifier_Keycode_Alt, pressed);
    }
    
    if (flags.shift or flags.lshift or flags.rshift) {
        createAndPostKeyEvent(Modifier_Keycode_Shift, pressed);
    }
    
    if (flags.cmd or flags.lcmd or flags.rcmd) {
        createAndPostKeyEvent(Modifier_Keycode_Cmd, pressed);
    }
    
    if (flags.control or flags.lcontrol or flags.rcontrol) {
        createAndPostKeyEvent(Modifier_Keycode_Ctrl, pressed);
    }
    
    if (flags.@"fn") {
        createAndPostKeyEvent(Modifier_Keycode_Fn, pressed);
    }
}

test "synthesize key parsing" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Test that we can parse a simple key specification
    var parser = try Parser.init(allocator);
    defer parser.deinit();
    
    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();
    
    try parser.parse(&mappings, "cmd - space");
    
    // Should have a default mode with one hotkey
    const default_mode = mappings.mode_map.get("default");
    try testing.expect(default_mode != null);
    
    const hotkey_count = default_mode.?.hotkey_map.count();
    try testing.expect(hotkey_count == 1);
}