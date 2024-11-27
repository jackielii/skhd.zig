const std = @import("std");
const c = @cImport({
    @cInclude("Carbon/Carbon.h");
    @cInclude("IOKit/hidsystem/ev_keymap.h");
});

pub const ModifierFlag = packed struct(u32) {
    alt: bool = false,
    lalt: bool = false,
    ralt: bool = false,
    shift: bool = false,
    lshift: bool = false,
    rshift: bool = false,
    cmd: bool = false,
    lcmd: bool = false,
    rcmd: bool = false,
    control: bool = false,
    lcontrol: bool = false,
    rcontrol: bool = false,
    @"fn": bool = false,
    passthrough: bool = false,
    activate: bool = false,
    nx: bool = false,
    _: u16 = 0,
    pub const hyper: ModifierFlag = .{
        .cmd = true,
        .alt = true,
        .shift = true,
        .control = true,
    };
    pub const meh: ModifierFlag = .{
        .control = true,
        .shift = true,
        .alt = true,
    };

    pub fn get(text: []const u8) ?ModifierFlag {
        return modifier_flags_map.get(text);
    }

    pub fn merge(self: ModifierFlag, other: ModifierFlag) ModifierFlag {
        const m1: u32 = @bitCast(self);
        const m2: u32 = @bitCast(other);
        return @bitCast(m1 | m2);
    }
    pub fn format(self: *const ModifierFlag, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;

        var i: u32 = 0;
        inline for (@typeInfo(@This()).@"struct".fields) |field| {
            const name = field.name;
            if (field.type != bool) continue;
            const value = @field(self, name);
            if (value) {
                if (i != 0) try writer.print(", ", .{});
                try writer.print("{s}", .{name});
                i += 1;
            }
        }
    }
};

test "format ModifierFlag" {
    const flag = ModifierFlag{ .alt = true, .shift = true };
    std.debug.print("{s}", .{flag});
}

const modifier_flags_map = std.StaticStringMap(ModifierFlag).initComptime(.{
    .{ "alt", ModifierFlag{ .alt = true } },
    .{ "lalt", ModifierFlag{ .lalt = true } },
    .{ "ralt", ModifierFlag{ .ralt = true } },
    .{ "shift", ModifierFlag{ .shift = true } },
    .{ "lshift", ModifierFlag{ .lshift = true } },
    .{ "rshift", ModifierFlag{ .rshift = true } },
    .{ "cmd", ModifierFlag{ .cmd = true } },
    .{ "lcmd", ModifierFlag{ .lcmd = true } },
    .{ "rcmd", ModifierFlag{ .rcmd = true } },
    .{ "ctrl", ModifierFlag{ .control = true } },
    .{ "lctrl", ModifierFlag{ .lcontrol = true } },
    .{ "rctrl", ModifierFlag{ .rcontrol = true } },
    .{ "fn", ModifierFlag{ .@"fn" = true } },
    .{ "hyper", ModifierFlag.hyper },
    .{ "meh", ModifierFlag.meh },
});

test "is_modifier" {
    const flag = ModifierFlag.get("alt");
    try std.testing.expectEqual(flag, ModifierFlag{ .alt = true });
    try std.testing.expectEqual(ModifierFlag.get("xx"), null);
}

pub const literal_keycode_str = [_][]const u8{
    "return",          "tab",           "space",
    "backspace",       "escape",

    // zig fmt: off

    // Fn mod
    "delete",          "home",            "end", 
    "pageup",          "pagedown",        "insert",
    "left",            "right",           "up",
    "down",            "f1",              "f2",
    "f3",              "f4",              "f5",
    "f6",              "f7",              "f8",
    "f9",              "f10",             "f11",
    "f12",             "f13",             "f14",
    "f15",             "f16",             "f17",
    "f18",             "f19",             "f20",

    // NX mod
    "sound_up",        "sound_down",      "mute",
    "play",            "previous",        "next",
    "rewind",          "fast",            "brightness_up",
    "brightness_down", "illumination_up", "illumination_down",
    // zig fmt: on
};

pub const KEY_HAS_IMPLICIT_FN_MOD = 4;
pub const KEY_HAS_IMPLICIT_NX_MOD = 35;

pub const literal_keycode_value = [_]u32{
    c.kVK_Return,                 c.kVK_Tab,                  c.kVK_Space,
    c.kVK_Delete,                 c.kVK_Escape,

    // zig fmt: off

    // Fn mod
    c.kVK_ForwardDelete, c.kVK_Home,       c.kVK_End,
    c.kVK_PageUp,        c.kVK_PageDown,   c.kVK_Help,
    c.kVK_LeftArrow,     c.kVK_RightArrow, c.kVK_UpArrow,
    c.kVK_DownArrow,     c.kVK_F1,         c.kVK_F2,
    c.kVK_F3,            c.kVK_F4,         c.kVK_F5,
    c.kVK_F6,            c.kVK_F7,         c.kVK_F8,
    c.kVK_F9,            c.kVK_F10,        c.kVK_F11,
    c.kVK_F12,           c.kVK_F13,        c.kVK_F14,
    c.kVK_F15,           c.kVK_F16,        c.kVK_F17,
    c.kVK_F18,           c.kVK_F19,        c.kVK_F20,

    // NX mod
    c.NX_KEYTYPE_SOUND_UP,        c.NX_KEYTYPE_SOUND_DOWN,      c.NX_KEYTYPE_MUTE,
    c.NX_KEYTYPE_PLAY,            c.NX_KEYTYPE_PREVIOUS,        c.NX_KEYTYPE_NEXT,
    c.NX_KEYTYPE_REWIND,          c.NX_KEYTYPE_FAST,            c.NX_KEYTYPE_BRIGHTNESS_UP,
    c.NX_KEYTYPE_BRIGHTNESS_DOWN, c.NX_KEYTYPE_ILLUMINATION_UP, c.NX_KEYTYPE_ILLUMINATION_DOWN,
    // zig fmt: on
};
