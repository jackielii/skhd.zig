const std = @import("std");
const c = @cImport({
    @cInclude("IOKit/hidsystem/ev_keymap.h");
});

pub const hotkey_flag = enum(u32) {
    Hotkey_Flag_Alt = 1 << 0,
    Hotkey_Flag_LAlt = 1 << 1,
    Hotkey_Flag_RAlt = 1 << 2,
    Hotkey_Flag_Shift = 1 << 3,
    Hotkey_Flag_LShift = 1 << 4,
    Hotkey_Flag_RShift = 1 << 5,
    Hotkey_Flag_Cmd = 1 << 6,
    Hotkey_Flag_LCmd = 1 << 7,
    Hotkey_Flag_RCmd = 1 << 8,
    Hotkey_Flag_Control = 1 << 9,
    Hotkey_Flag_LControl = 1 << 10,
    Hotkey_Flag_RControl = 1 << 11,
    Hotkey_Flag_Fn = 1 << 12,
    Hotkey_Flag_Passthrough = 1 << 13,
    Hotkey_Flag_Activate = 1 << 14,
    Hotkey_Flag_NX = 1 << 15,
    Hotkey_Flag_Hyper = 1 << 6 // Cmd
    | 1 << 0 // alt
    | 1 << 3 // shift
    | 1 << 9, // control
    Hotkey_Flag_Meh = 1 << 9 // control
    | 1 << 3 // shift
    | 1 << 0, // alt
    comptime {
        std.debug.assert(@intFromEnum(hotkey_flag.Hotkey_Flag_Hyper) ==
            @intFromEnum(hotkey_flag.Hotkey_Flag_Cmd) |
            @intFromEnum(hotkey_flag.Hotkey_Flag_Alt) |
            @intFromEnum(hotkey_flag.Hotkey_Flag_Shift) |
            @intFromEnum(hotkey_flag.Hotkey_Flag_Control));

        std.debug.assert(@intFromEnum(hotkey_flag.Hotkey_Flag_Meh) ==
            @intFromEnum(hotkey_flag.Hotkey_Flag_Control) |
            @intFromEnum(hotkey_flag.Hotkey_Flag_Shift) |
            @intFromEnum(hotkey_flag.Hotkey_Flag_Alt));
    }
    // Hotkey_Flag_Meh = .Hotkey_Flag_Control | .Hotkey_Flag_Shift | .Hotkey_Flag_Alt,
    // Hotkey_Flag_Hyper = ( //
    //     hotkey_flag.Hotkey_Flag_Cmd |
    //     hotkey_flag.Hotkey_Flag_Alt |
    //     hotkey_flag.Hotkey_Flag_Shift |
    //     hotkey_flag.Hotkey_Flag_Control),
    // Hotkey_Flag_Meh = ( //
    //     hotkey_flag.Hotkey_Flag_Control |
    //     hotkey_flag.Hotkey_Flag_Shift |
    //     hotkey_flag.Hotkey_Flag_Alt),
};

pub const modifier_flags_str = [_][]const u8{
    "alt",   "lalt",   "ralt",
    "shift", "lshift", "rshift",
    "cmd",   "lcmd",   "rcmd",
    "ctrl",  "lctrl",  "rctrl",
    "fn",    "hyper",  "meh",
};

pub const modifier_flags_value = [_]u32{
    @intFromEnum(hotkey_flag.Hotkey_Flag_Alt),     @intFromEnum(hotkey_flag.Hotkey_Flag_LAlt),     @intFromEnum(hotkey_flag.Hotkey_Flag_RAlt),
    @intFromEnum(hotkey_flag.Hotkey_Flag_Shift),   @intFromEnum(hotkey_flag.Hotkey_Flag_LShift),   @intFromEnum(hotkey_flag.Hotkey_Flag_RShift),
    @intFromEnum(hotkey_flag.Hotkey_Flag_Cmd),     @intFromEnum(hotkey_flag.Hotkey_Flag_LCmd),     @intFromEnum(hotkey_flag.Hotkey_Flag_RCmd),
    @intFromEnum(hotkey_flag.Hotkey_Flag_Control), @intFromEnum(hotkey_flag.Hotkey_Flag_LControl), @intFromEnum(hotkey_flag.Hotkey_Flag_RControl),
};

pub const literal_keycode_str = [_][]const u8{
    "return",          "tab",             "space",             "backspace",
    "escape",          "delete",          "home",              "end",
    "pageup",          "pagedown",        "insert",            "left",
    "right",           "up",              "down",              "f1",
    "f2",              "f3",              "f4",                "f5",
    "f6",              "f7",              "f8",                "f9",
    "f10",             "f11",             "f12",               "f13",
    "f14",             "f15",             "f16",               "f17",
    "f18",             "f19",             "f20",               "sound_up",
    "sound_down",      "mute",            "play",              "previous",
    "next",            "rewind",          "fast",              "brightness_up",
    "brightness_down", "illumination_up", "illumination_down",
};

pub const KEY_HAS_IMPLICIT_FN_MOD = 4;
pub const KEY_HAS_IMPLICIT_NX_MOD = 35;

pub const literal_keycode_value = [_]u32{
    c.kVK_Return,                 c.kVK_Tab,                      c.kVK_Space,
    c.kVK_Delete,                 c.kVK_Escape,                   c.kVK_ForwardDelete,
    c.kVK_Home,                   c.kVK_End,                      c.kVK_PageUp,
    c.kVK_PageDown,               c.kVK_Help,                     c.kVK_LeftArrow,
    c.kVK_RightArrow,             c.kVK_UpArrow,                  c.kVK_DownArrow,
    c.kVK_F1,                     c.kVK_F2,                       c.kVK_F3,
    c.kVK_F4,                     c.kVK_F5,                       c.kVK_F6,
    c.kVK_F7,                     c.kVK_F8,                       c.kVK_F9,
    c.kVK_F10,                    c.kVK_F11,                      c.kVK_F12,
    c.kVK_F13,                    c.kVK_F14,                      c.kVK_F15,
    c.kVK_F16,                    c.kVK_F17,                      c.kVK_F18,
    c.kVK_F19,                    c.kVK_F20,

    // zig fmt: off
    c.NX_KEYTYPE_SOUND_UP,        c.NX_KEYTYPE_SOUND_DOWN,      c.NX_KEYTYPE_MUTE,
    c.NX_KEYTYPE_PLAY,            c.NX_KEYTYPE_PREVIOUS,        c.NX_KEYTYPE_NEXT,
    c.NX_KEYTYPE_REWIND,          c.NX_KEYTYPE_FAST,            c.NX_KEYTYPE_BRIGHTNESS_UP,
    c.NX_KEYTYPE_BRIGHTNESS_DOWN, c.NX_KEYTYPE_ILLUMINATION_UP, c.NX_KEYTYPE_ILLUMINATION_DOWN,
};

test "enum" {
    _ = hotkey_flag.Hotkey_Flag_Hyper;
}
