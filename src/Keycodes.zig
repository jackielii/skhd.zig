const std = @import("std");

const c = @cImport({
    @cInclude("Carbon/Carbon.h");
    @cInclude("IOKit/hidsystem/ev_keymap.h");
});

const layout_dependent_keycodes = [_]u32{
    c.kVK_ANSI_A,            c.kVK_ANSI_B,           c.kVK_ANSI_C,
    c.kVK_ANSI_D,            c.kVK_ANSI_E,           c.kVK_ANSI_F,
    c.kVK_ANSI_G,            c.kVK_ANSI_H,           c.kVK_ANSI_I,
    c.kVK_ANSI_J,            c.kVK_ANSI_K,           c.kVK_ANSI_L,
    c.kVK_ANSI_M,            c.kVK_ANSI_N,           c.kVK_ANSI_O,
    c.kVK_ANSI_P,            c.kVK_ANSI_Q,           c.kVK_ANSI_R,
    c.kVK_ANSI_S,            c.kVK_ANSI_T,           c.kVK_ANSI_U,
    c.kVK_ANSI_V,            c.kVK_ANSI_W,           c.kVK_ANSI_X,
    c.kVK_ANSI_Y,            c.kVK_ANSI_Z,           c.kVK_ANSI_0,
    c.kVK_ANSI_1,            c.kVK_ANSI_2,           c.kVK_ANSI_3,
    c.kVK_ANSI_4,            c.kVK_ANSI_5,           c.kVK_ANSI_6,
    c.kVK_ANSI_7,            c.kVK_ANSI_8,           c.kVK_ANSI_9,
    c.kVK_ANSI_Grave,        c.kVK_ANSI_Equal,       c.kVK_ANSI_Minus,
    c.kVK_ANSI_RightBracket, c.kVK_ANSI_LeftBracket, c.kVK_ANSI_Quote,
    c.kVK_ANSI_Semicolon,    c.kVK_ANSI_Backslash,   c.kVK_ANSI_Comma,
    c.kVK_ANSI_Slash,        c.kVK_ANSI_Period,      c.kVK_ISO_Section,
};

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

alloc: std.mem.Allocator = undefined,
keymap_table: std.StringArrayHashMap(u32) = undefined,

// const context = struct {
//     pub fn hash(self: @This(), s: []const u8) u32 {
//         _ = self;
//         const ss = std.mem.sliceTo(s, 0);
//         // std.debug.print("hash: {any}\n", .{ss});
//         return std.array_hash_map.hashString(ss);
//     }
//     pub fn eql(self: @This(), a: []const u8, b: []const u8, b_index: usize) bool {
//         _ = self;
//         _ = b_index;
//         // return std.array_hash_map.eqlString(a, b);
//         // std.debug.print("a: {any}, b: {any}\n", .{ a, b });
//         const aa = std.mem.sliceTo(a, 0);
//         const bb = std.mem.sliceTo(b, 0);
//         return std.mem.eql(u8, aa, bb);
//     }
// };

const Keycodes = @This();

pub fn init(alloc: std.mem.Allocator) !Keycodes {
    const keyboard = c.TISCopyCurrentASCIICapableKeyboardLayoutInputSource();
    const uchr: c.CFDataRef = @ptrCast(c.TISGetInputSourceProperty(keyboard, c.kTISPropertyUnicodeKeyLayoutData));
    defer c.CFRelease(keyboard);

    const keyboard_layout: ?*c.UCKeyboardLayout = @constCast(@ptrCast(@alignCast(c.CFDataGetBytePtr(uchr))));
    if (keyboard_layout == null) {
        return error.@"Failed to get keyboard layout";
    }

    var keymap_table = std.StringArrayHashMap(u32).init(alloc);

    var len: c.UniCharCount = 0;
    var chars = [_]c.UniChar{0} ** 255;
    var state: c.UInt32 = 0;

    for (layout_dependent_keycodes) |keycode| {
        const ret = c.UCKeyTranslate(
            keyboard_layout,
            @intCast(keycode),
            c.kUCKeyActionDisplay,
            0,
            c.LMGetKbdType(),
            c.kUCKeyTranslateNoDeadKeysMask,
            &state,
            chars.len,
            &len,
            &chars,
        );
        if (ret == c.noErr and len > 0) {
            const key_cfstring = c.CFStringCreateWithCharacters(c.kCFAllocatorDefault, &chars, @intCast(len));
            defer c.CFRelease(key_cfstring);
            const key_string = try copy_cfstring(alloc, key_cfstring);
            try keymap_table.put(key_string, keycode);
        }
    }

    return Keycodes{ .keymap_table = keymap_table, .alloc = alloc };
}

pub fn deinit(self: *Keycodes) void {
    // std.debug.print("size: {}\n", .{self.keymap_table.count()});
    var it = self.keymap_table.iterator();
    while (it.next()) |kv| {
        self.alloc.free(kv.key_ptr.*);
    }
    self.keymap_table.deinit();
}

pub fn get_keycode(self: *Keycodes, key: []const u8) !u32 {
    const key_string = self.keymap_table.get(key) orelse return error.@"Key not found";
    return key_string;
}

fn copy_cfstring(alloc: std.mem.Allocator, cfstring: c.CFStringRef) ![]u8 {
    // const n = c.CFStringGetLength(cfstring);
    const num_bytes = c.CFStringGetMaximumSizeForEncoding(c.CFStringGetLength(cfstring), c.kCFStringEncodingUTF8);
    if (num_bytes > 64) {
        @panic("num_bytes for cfstring > 64");
    }
    // std.debug.print("n: {}, max_num_bytes: {}\n", .{ n, num_bytes });
    var buffer: [64]u8 = undefined;
    // const buffer = try alloc.alloc(u8, @intCast(num_bytes));
    // defer alloc.free(buffer);

    if (c.CFStringGetCString(cfstring, &buffer, num_bytes, c.kCFStringEncodingUTF8) == c.false) {
        return error.@"Failed to copy CFString";
    }

    const ret = try alloc.dupe(u8, std.mem.sliceTo(buffer[0..], 0));
    return ret;
}

test "init_keycode_map" {
    const alloc = std.testing.allocator;
    var self = try init(alloc);
    defer self.deinit();
    var it = self.keymap_table.iterator();
    while (it.next()) |kv| {
        std.debug.print("{s}: {x}: 0x{x}\n", .{ kv.key_ptr.*, kv.key_ptr.*, kv.value_ptr.* });
    }
}

test "ptrcast" {
    const alloc = std.testing.allocator;
    var buf = try alloc.alloc(u8, 10);
    defer alloc.free(buf);

    buf[0] = 'a';
    buf[1] = 'b';
    buf[2] = 'c';
    buf[3] = 0;

    const ptr: [*:0]u8 = @ptrCast(buf.ptr);
    const sentinalSlice: [:0]const u8 = @ptrCast(buf);

    std.debug.print("{s}\n", .{ptr});
    std.debug.print("{s}\n", .{sentinalSlice.ptr});

    const span = std.mem.sliceTo(buf, 0);
    std.debug.print("{s}\n", .{span});
    // alloc.free(span);
    // alloc.free(ptr);
}
