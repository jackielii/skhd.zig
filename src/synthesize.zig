const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig");
const Parser = @import("Parser.zig");
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
    var parser = try Parser.init(allocator, io);
    defer parser.deinit();

    // parseKeySpec accepts a chord and nothing else — no modes, no process
    // lists, no actions — so failures here describe the key the user typed
    // rather than config-file grammar they never wrote.
    const chord = parser.parseKeySpec(key_string) catch |err| {
        if (err != error.ParseErrorOccurred) return err;
        // Diagnostics are the point of this path, but they would pollute test
        // output — the tests assert on the returned error, not the text.
        if (!builtin.is_test) {
            std.debug.print("skhd: '{s}' is not a valid key combination.\n", .{key_string});
            if (parser.error_info) |parse_err| {
                std.debug.print("  {f}\n", .{parse_err});
            }
            // Don't echo the spec back into the -t suggestion: for a genuine
            // typo like 'cmd - zzz' it would advise typing that as literal
            // text, which is never what the user wanted.
            std.debug.print("  -k/--key takes one key combination: 'cmd - q', 'shift - a', 'f19', '0x0C'.\n", .{});
            std.debug.print("  To type literal text, use -t/--text instead.\n", .{});
        }
        return error.InvalidKeySpec;
    };

    // Disable local event suppression and state combining for clean synthesis
    _ = c.CGSetLocalEventsSuppressionInterval(0.0);
    _ = c.CGEnableEventStateCombining(false);

    synthesizeModifiers(chord.flags, true);
    createAndPostKeyEvent(@intCast(chord.key), true);
    createAndPostKeyEvent(@intCast(chord.key), false);
    synthesizeModifiers(chord.flags, false);

    std.log.scoped(.synthesize).debug("Synthesized key: {any} + {s}", .{ chord.flags, Keycodes.getKeyString(chord.key) });
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
    // Never fire real keystrokes into the developer's session from a test.
    // Same guard, same reason, as forwardKey in skhd.zig.
    if (builtin.is_test) return;
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

test "synthesizeKey accepts valid keyspecs" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // createAndPostKeyEvent no-ops under test, so this exercises parse and
    // dispatch without firing keystrokes into the session running the suite.
    try synthesizeKey(allocator, io, "cmd - space");
    try synthesizeKey(allocator, io, "f19");
    try synthesizeKey(allocator, io, "0x0C");
}
