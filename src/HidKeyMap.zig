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

const c = @import("c.zig");

/// Convert a HID Keyboard/Keypad usage byte (what `HidKeyMap.lookup`
/// returns) into the Mac virtual keycode that CGEvent's
/// `kCGKeyboardEventKeycode` field carries. Used by the tap-hold state
/// machine to recognise its source key in the CGEventTap callback and
/// to synthesize the tap/hold actions via `CGEventCreateKeyboardEvent`.
///
/// Only the keysyms relevant to tap-hold sources/actions are mapped.
/// Returns null on unknown usage; caller should treat that rule as
/// non-actionable and log.
pub fn macVKForHidUsage(hid_usage: u32) ?u32 {
    return switch (hid_usage) {
        // Modifiers — use the Mac VK constants.
        0xE0 => c.kVK_Control,       // lctrl
        0xE1 => c.kVK_Shift,         // lshift
        0xE2 => c.kVK_Option,        // lalt
        0xE3 => c.kVK_Command,       // lcmd
        0xE4 => c.kVK_RightControl,  // rctrl
        0xE5 => c.kVK_RightShift,    // rshift
        0xE6 => c.kVK_RightOption,   // ralt
        0xE7 => c.kVK_RightCommand,  // rcmd

        0x39 => c.kVK_CapsLock,
        0x29 => c.kVK_Escape,
        0x28 => c.kVK_Return,
        0x2B => c.kVK_Tab,
        0x2C => c.kVK_Space,
        0x2A => c.kVK_Delete,
        0x4C => c.kVK_ForwardDelete,
        0x4A => c.kVK_Home,
        0x4D => c.kVK_End,
        0x4B => c.kVK_PageUp,
        0x4E => c.kVK_PageDown,
        0x50 => c.kVK_LeftArrow,
        0x4F => c.kVK_RightArrow,
        0x52 => c.kVK_UpArrow,
        0x51 => c.kVK_DownArrow,

        // F-keys — the proxy slot for caps_lock-class interception is
        // F18. F1..F20 covered for symmetry.
        0x3A => c.kVK_F1,  0x3B => c.kVK_F2,  0x3C => c.kVK_F3,  0x3D => c.kVK_F4,
        0x3E => c.kVK_F5,  0x3F => c.kVK_F6,  0x40 => c.kVK_F7,  0x41 => c.kVK_F8,
        0x42 => c.kVK_F9,  0x43 => c.kVK_F10, 0x44 => c.kVK_F11, 0x45 => c.kVK_F12,
        0x68 => c.kVK_F13, 0x69 => c.kVK_F14, 0x6A => c.kVK_F15, 0x6B => c.kVK_F16,
        0x6C => c.kVK_F17, 0x6D => c.kVK_F18, 0x6E => c.kVK_F19, 0x6F => c.kVK_F20,

        // Numpad-class proxies for caps_lock remapping.
        0x67 => c.kVK_ANSI_KeypadEquals,
        0x53 => c.kVK_ANSI_KeypadClear,

        else => null,
    };
}

/// CGEvent flag mask for a HID usage if it's a modifier; null otherwise.
/// When the tap-hold state machine commits to "hold" with a modifier
/// destination, it both synthesizes the modifier-down keycode (so the
/// OS sees a real modifier press) and stamps the same flag onto any
/// buffered events it replays so apps see them as modifier-chord.
pub fn modifierFlagForHidUsage(hid_usage: u32) ?u64 {
    return switch (hid_usage) {
        0xE0, 0xE4 => c.kCGEventFlagMaskControl,    // lctrl, rctrl
        0xE1, 0xE5 => c.kCGEventFlagMaskShift,      // lshift, rshift
        0xE2, 0xE6 => c.kCGEventFlagMaskAlternate,  // lalt, ralt
        0xE3, 0xE7 => c.kCGEventFlagMaskCommand,    // lcmd, rcmd
        else => null,
    };
}

/// True if the HID usage refers to a key whose interception requires
/// the F18 proxy. macOS toggles caps_lock state at IOKit level before
/// CGEventTap can suppress it; remapping at HID layer to a non-toggle
/// key (F18) sidesteps the toggle entirely.
pub fn needsProxy(hid_usage: u32) bool {
    return hid_usage == 0x39; // caps_lock; extend if/when other toggles appear
}

/// HID usage of the proxy key reserved for caps-class interception.
pub const PROXY_USAGE: u32 = 0x6D; // F18

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

    // Numpad keys — useful as proxy targets for caps_lock remapping
    // because macOS's caps-handling kernel layer doesn't seem to
    // special-case them (unlike F-keys and modifiers). Most laptop
    // users never type these, so intercepting them in the daemon is
    // safe.
    .{ "kp_equals", 0x67 },
    .{ "kp_clear", 0x53 },
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

test "macVKForHidUsage returns Mac VK for modifiers and common keys" {
    try std.testing.expectEqual(@as(?u32, c.kVK_Control), macVKForHidUsage(0xE0));
    try std.testing.expectEqual(@as(?u32, c.kVK_Escape), macVKForHidUsage(0x29));
    try std.testing.expectEqual(@as(?u32, c.kVK_F18), macVKForHidUsage(0x6D));
    try std.testing.expectEqual(@as(?u32, c.kVK_CapsLock), macVKForHidUsage(0x39));
    try std.testing.expectEqual(@as(?u32, null), macVKForHidUsage(0xFF));
}

test "modifierFlagForHidUsage classifies modifier vs non-modifier" {
    try std.testing.expectEqual(@as(?u64, c.kCGEventFlagMaskControl), modifierFlagForHidUsage(0xE0));
    try std.testing.expectEqual(@as(?u64, c.kCGEventFlagMaskShift), modifierFlagForHidUsage(0xE1));
    try std.testing.expectEqual(@as(?u64, null), modifierFlagForHidUsage(0x29)); // escape
    try std.testing.expectEqual(@as(?u64, null), modifierFlagForHidUsage(0x39)); // caps_lock
}

test "needsProxy true only for caps_lock" {
    try std.testing.expect(needsProxy(0x39));
    try std.testing.expect(!needsProxy(0x2C)); // space
    try std.testing.expect(!needsProxy(0xE0)); // lctrl
}
