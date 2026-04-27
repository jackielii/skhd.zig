//! Mapping from skhd keysym names to HID Keyboard/Keypad usage codes
//! (page 0x07). Used by `.remap` to translate config names like
//! "caps_lock" / "lctrl" into the values `hidutil` expects.
//!
//! hidutil represents each remap entry as a 64-bit src/dst pair where
//! the upper 32 bits are the usage page and the lower 32 bits are the
//! usage. `fullUsage(usage)` packs the keyboard page (0x07) for callers.
//!
//! Names are HID-standard (physical-position, layout-independent) and
//! deliberately differ from skhd's macOS-virtual-keycode names you see
//! in `skhd -o` output. Examples:
//!   - `grave` here = HID 0x35 = the top-left key. On US that's
//!     `` ` /~ ``; on UK ISO it's `§/±`.
//!   - `non_us_backslash` = HID 0x64 = the ISO-only key between left
//!     shift and `Z`. UK ISO sends `` ` /~ `` from this key.
//!
//! When a `.remap` lookup fails, the parser error lists every name in
//! this table so users can discover the right one without reading the
//! source.
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

/// All known names in declaration order. Used by the parser to list
/// available names when a `.remap` source or destination doesn't
/// resolve.
pub fn knownNames() []const []const u8 {
    return Map.keys();
}

/// Static name → usage table. HID-standard physical-position names —
/// see the file-level comment for how these differ from skhd's macOS
/// virtual-keycode names.
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

    // Letters
    .{ "a", 0x04 }, .{ "b", 0x05 }, .{ "c", 0x06 }, .{ "d", 0x07 },
    .{ "e", 0x08 }, .{ "f", 0x09 }, .{ "g", 0x0A }, .{ "h", 0x0B },
    .{ "i", 0x0C }, .{ "j", 0x0D }, .{ "k", 0x0E }, .{ "l", 0x0F },
    .{ "m", 0x10 }, .{ "n", 0x11 }, .{ "o", 0x12 }, .{ "p", 0x13 },
    .{ "q", 0x14 }, .{ "r", 0x15 }, .{ "s", 0x16 }, .{ "t", 0x17 },
    .{ "u", 0x18 }, .{ "v", 0x19 }, .{ "w", 0x1A }, .{ "x", 0x1B },
    .{ "y", 0x1C }, .{ "z", 0x1D },

    // Digits (top row)
    .{ "1", 0x1E }, .{ "2", 0x1F }, .{ "3", 0x20 }, .{ "4", 0x21 },
    .{ "5", 0x22 }, .{ "6", 0x23 }, .{ "7", 0x24 }, .{ "8", 0x25 },
    .{ "9", 0x26 }, .{ "0", 0x27 },

    // Punctuation (US layout positions; HID is layout-independent so
    // these refer to physical keys, not character output).
    .{ "minus",            0x2D }, // -/_  (right of 0)
    .{ "equal",            0x2E }, // =/+
    .{ "lbracket",         0x2F }, // [/{
    .{ "rbracket",         0x30 }, // ]/}
    .{ "backslash",        0x31 }, // \/| (US, above return)
    .{ "non_us_hash",      0x32 }, // # on some ISO layouts (rarely needed)
    .{ "semicolon",        0x33 }, // ;/:
    .{ "quote",            0x34 }, // '/"
    .{ "grave",            0x35 }, // top-left key — `/~ on US, §/± on UK ISO
    .{ "comma",            0x36 }, // ,/<
    .{ "period",           0x37 }, // ./>
    .{ "slash",            0x38 }, // ///
    .{ "non_us_backslash", 0x64 }, // ISO-only key between L-shift and Z
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
