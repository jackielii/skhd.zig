//! Mapping from skhd keysym names to HID Keyboard/Keypad usage codes
//! (page 0x07). Used by `.remap` to translate config names like
//! "caps_lock" / "lctrl" into the values `hidutil` expects.
//!
//! hidutil represents each remap entry as a 64-bit src/dst pair where
//! the upper 32 bits are the usage page and the lower 32 bits are the
//! usage. `fullUsage(usage)` packs the keyboard page (0x07) for callers.
//!
//! Only the keysyms relevant to typical remap targets are listed —
//! modifiers, caps_lock, escape, space, return, tab, delete, F-keys,
//! and the F18/F19/F20 proxy slots used by Phase 3 to intercept toggle-
//! quirky keys like caps_lock. A and 1 are included for tests.
const std = @import("std");

pub const HID_PAGE_KEYBOARD: u64 = 0x07;

/// Pack a keyboard-page usage into the 64-bit value `hidutil` consumes:
/// `(0x07 << 32) | usage`.
pub inline fn fullUsage(usage: u32) u64 {
    return (HID_PAGE_KEYBOARD << 32) | usage;
}

/// Look up a skhd keysym name and return its HID usage byte (just the
/// usage, page is implied 0x07). Returns null when the name has no HID
/// equivalent we expose for `.remap`.
pub fn lookup(name: []const u8) ?u32 {
    return Map.get(name);
}

/// Static name → usage table. Names match skhd's existing literal
/// keycode strings and modifier names so the user writes config the
/// same way they do for hotkeys.
const Map = std.StaticStringMap(u32).initComptime(&.{
    // Modifiers
    .{ "lctrl", 0xE0 },
    .{ "lshift", 0xE1 },
    .{ "lalt", 0xE2 },
    .{ "lcmd", 0xE3 },
    .{ "rctrl", 0xE4 },
    .{ "rshift", 0xE5 },
    .{ "ralt", 0xE6 },
    .{ "rcmd", 0xE7 },

    // Toggles + control keys
    .{ "caps_lock", 0x39 },
    .{ "escape", 0x29 },
    .{ "return", 0x28 },
    .{ "tab", 0x2B },
    .{ "space", 0x2C },
    .{ "backspace", 0x2A },
    .{ "delete", 0x4C }, // Delete Forward
    .{ "insert", 0x49 },
    .{ "home", 0x4A },
    .{ "end", 0x4D },
    .{ "pageup", 0x4B },
    .{ "pagedown", 0x4E },
    .{ "left", 0x50 },
    .{ "right", 0x4F },
    .{ "up", 0x52 },
    .{ "down", 0x51 },

    // F-row (F1..F20)
    .{ "f1", 0x3A },  .{ "f2", 0x3B },  .{ "f3", 0x3C },  .{ "f4", 0x3D },
    .{ "f5", 0x3E },  .{ "f6", 0x3F },  .{ "f7", 0x40 },  .{ "f8", 0x41 },
    .{ "f9", 0x42 },  .{ "f10", 0x43 }, .{ "f11", 0x44 }, .{ "f12", 0x45 },
    .{ "f13", 0x68 }, .{ "f14", 0x69 }, .{ "f15", 0x6A }, .{ "f16", 0x6B },
    .{ "f17", 0x6C }, .{ "f18", 0x6D }, .{ "f19", 0x6E }, .{ "f20", 0x6F },

    // Letters/digits — for tests and the rare user that wants to remap
    // alphanumeric keys directly. Add more on demand.
    .{ "a", 0x04 }, .{ "b", 0x05 }, .{ "c", 0x06 },
    .{ "0", 0x27 }, .{ "1", 0x1E }, .{ "2", 0x1F },
});

test "lookup returns expected HID usage codes" {
    try std.testing.expectEqual(@as(?u32, 0x39), lookup("caps_lock"));
    try std.testing.expectEqual(@as(?u32, 0xE0), lookup("lctrl"));
    try std.testing.expectEqual(@as(?u32, 0x6D), lookup("f18"));
    try std.testing.expectEqual(@as(?u32, null), lookup("does_not_exist"));
}

test "fullUsage packs keyboard page" {
    try std.testing.expectEqual(@as(u64, 0x700000039), fullUsage(0x39));
    try std.testing.expectEqual(@as(u64, 0x7000000E0), fullUsage(0xE0));
}
