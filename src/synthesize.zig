const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig");
const Parser = @import("Parser.zig");
const Mappings = @import("Mappings.zig");
const Hotkey = @import("Hotkey.zig");
const Keycodes = @import("Keycodes.zig");
const ModifierFlag = Keycodes.ModifierFlag;
const log = std.log.scoped(.synthesize);

// Modifier keycodes from original skhd
const Modifier_Keycode_Alt = 0x3A;
const Modifier_Keycode_Shift = 0x38;
const Modifier_Keycode_Cmd = 0x37;
const Modifier_Keycode_Ctrl = 0x3B;
const Modifier_Keycode_Fn = 0x3F;

/// Synthesize a keypress from a key specification string (e.g., "cmd - space")
pub fn synthesizeKey(allocator: std.mem.Allocator, io: std.Io, key_string: []const u8) !void {
    // Parse the key string
    var parser = try Parser.init(allocator, io);
    defer parser.deinit();

    // Create temporary mappings just for parsing
    var mappings = try Mappings.init(allocator, io);
    defer mappings.deinit();

    // For synthesis, we need to add a dummy command since the parser expects a complete hotkey
    // The command won't be executed, we just need it for parsing
    const key_with_command = try std.fmt.allocPrint(allocator, "{s} : __dummy__", .{key_string});
    defer allocator.free(key_with_command);

    // Parse the key specification with dummy command.
    //
    // `-k` takes a keyspec, not text, so prose lands here as a parse failure —
    // typically deep inside parse_mode, since a leading word lexes as an
    // identifier and reads as a mode name. Surface the parser's own diagnostic
    // and return a typed error; a bare `try` would give the caller
    // error.ParseErrorOccurred and a Zig backtrace instead.
    parser.parse(&mappings, key_with_command) catch |err| {
        if (err != error.ParseErrorOccurred) return err;
        // Diagnostics are the point of this path, but they would pollute test
        // output — the tests assert on the returned error, not the text.
        if (!builtin.is_test) {
            std.debug.print("skhd: '{s}' is not a valid keyspec for -k/--key.\n", .{key_string});
            if (parser.error_info) |parse_err| {
                std.debug.print("  {f}\n", .{parse_err});
            }
            std.debug.print("  hint: -k expects a key combination (e.g. 'cmd - q'). To type text, use -t/--text.\n", .{});
        }
        return error.InvalidKeySpec;
    };

    // Find the first hotkey that was parsed
    var mode_iter = mappings.mode_map.iterator();
    if (mode_iter.next()) |mode_entry| {
        const mode = mode_entry.value_ptr.*;
        var hotkey_iter = mode.hotkey_map.iterator();
        if (hotkey_iter.next()) |hotkey_entry| {
            const hotkey = hotkey_entry.key_ptr.*;

            // Disable local event suppression and state combining for clean synthesis
            _ = c.CGSetLocalEventsSuppressionInterval(0.0);
            _ = c.CGEnableEventStateCombining(false);

            // Press modifiers down
            synthesizeModifiers(hotkey.chords[0].flags, true);

            // Press the main key down
            createAndPostKeyEvent(@intCast(hotkey.chords[0].key), true);

            // Release the main key
            createAndPostKeyEvent(@intCast(hotkey.chords[0].key), false);

            // Release modifiers
            synthesizeModifiers(hotkey.chords[0].flags, false);

            std.log.scoped(.synthesize).debug("Synthesized key: {any} + {s}", .{ hotkey.chords[0].flags, Keycodes.getKeyString(hotkey.chords[0].key) });
        } else {
            // Parsed, but produced no hotkey — nothing to synthesize.
            if (!builtin.is_test) std.debug.print("skhd: '{s}' did not resolve to a key for -k/--key.\n", .{key_string});
            return error.InvalidKeySpec;
        }
    } else {
        std.debug.print("skhd: '{s}' did not resolve to a key for -k/--key.\n", .{key_string});
        return error.InvalidKeySpec;
    }
}

/// Synthesize text input
pub fn synthesizeText(allocator: std.mem.Allocator, io: std.Io, text: []const u8) !void {
    _ = allocator;

    const text_ref = c.CFStringCreateWithBytes(
        c.kCFAllocatorDefault,
        text.ptr,
        @intCast(text.len),
        c.kCFStringEncodingUTF8,
        0,
    );
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
        var chars: [1]c.UniChar = .{c.CFStringGetCharacterAtIndex(text_ref, i)};

        // Set the unicode character for both events
        c.CGEventKeyboardSetUnicodeString(down_event, 1, &chars);
        c.CGEventPost(c.kCGAnnotatedSessionEventTap, down_event);

        // Small delay between key down and up so the receiving app
        // sees a real keystroke, not a one-tick spike.
        std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};

        c.CGEventKeyboardSetUnicodeString(up_event, 1, &chars);
        c.CGEventPost(c.kCGAnnotatedSessionEventTap, up_event);
    }

    std.log.scoped(.synthesize).debug("Synthesized text: {s}", .{text});
}

fn createAndPostKeyEvent(keycode: u16, pressed: bool) void {
    // Use the deprecated but working CGPostKeyboardEvent for now
    // This matches the original skhd implementation
    _ = c.CGPostKeyboardEvent(0, keycode, pressed);
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

test "synthesizeKey reports a bad keyspec instead of leaking a parse error" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // `-k` takes a keyspec, not prose. "hello" lexes as an identifier, so the
    // parser reads it as a mode name and fails deep inside parse_mode. Callers
    // must get a typed error they can report, not error.ParseErrorOccurred
    // plus a Zig backtrace. (`-t/--text` is the tool for text.)
    try testing.expectError(error.InvalidKeySpec, synthesizeKey(allocator, io, "hello world"));

    // Empty spec is the same class of mistake.
    try testing.expectError(error.InvalidKeySpec, synthesizeKey(allocator, io, ""));
}

test "synthesize key parsing" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Test that we can parse a simple key specification
    var parser = try Parser.init(allocator, io);
    defer parser.deinit();

    var mappings = try Mappings.init(allocator, io);
    defer mappings.deinit();

    try parser.parse(&mappings, "cmd - space : echo test");

    // Should have a default mode with one hotkey
    const default_mode = mappings.mode_map.get("default");
    try testing.expect(default_mode != null);

    const hotkey_count = default_mode.?.hotkey_map.count();
    try testing.expect(hotkey_count == 1);
}
