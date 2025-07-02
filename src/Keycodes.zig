const std = @import("std");
const c = @import("c.zig");

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
    // Verify formatting works without printing
    const formatted = try std.fmt.allocPrint(std.testing.allocator, "{s}", .{flag});
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("alt, shift", formatted);
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
    
    // Just verify the keymap was initialized with some expected values
    try std.testing.expect(self.keymap_table.contains("a"));
    try std.testing.expect(self.keymap_table.contains("1"));
    try std.testing.expect(self.keymap_table.count() > 20); // Should have many keys
    
    // Verify literal keycodes exist in the arrays
    try std.testing.expect(literal_keycode_str.len > 0);
    try std.testing.expect(literal_keycode_value.len == literal_keycode_str.len);
}

/// Format modifier flags and key into a human-readable string
pub fn formatKeyPress(allocator: std.mem.Allocator, flags: ModifierFlag, keyCode: u32) ![]u8 {
    var modifiers = std.ArrayList([]const u8).init(allocator);
    defer modifiers.deinit();

    // Add modifiers in a consistent order
    if (flags.lcmd or flags.cmd) try modifiers.append("lcmd");
    if (flags.rcmd) try modifiers.append("rcmd");
    if (flags.lalt or flags.alt) try modifiers.append("lalt");
    if (flags.ralt) try modifiers.append("ralt");
    if (flags.lshift or flags.shift) try modifiers.append("lshift");
    if (flags.rshift) try modifiers.append("rshift");
    if (flags.lcontrol or flags.control) try modifiers.append("lctrl");
    if (flags.rcontrol) try modifiers.append("rctrl");
    if (flags.@"fn") try modifiers.append("fn");

    // Get the key
    const key = getKeyString(keyCode);

    // Format according to skhd convention: modifiers joined with + and final key with -
    if (modifiers.items.len > 0) {
        const modifier_str = try std.mem.join(allocator, " + ", modifiers.items);
        defer allocator.free(modifier_str);
        return std.fmt.allocPrint(allocator, "{s} - {s}", .{ modifier_str, key });
    } else {
        // No modifiers, just return the key
        return allocator.dupe(u8, key);
    }
}

/// Get a human-readable string representation of a keycode
pub fn getKeyString(keyCode: u32) []const u8 {
    return switch (keyCode) {
        0 => "a",
        1 => "s",
        2 => "d",
        3 => "f",
        4 => "h",
        5 => "g",
        6 => "z",
        7 => "x",
        8 => "c",
        9 => "v",
        10 => "§",
        11 => "b",
        12 => "q",
        13 => "w",
        14 => "e",
        15 => "r",
        16 => "y",
        17 => "t",
        18 => "1",
        19 => "2",
        20 => "3",
        21 => "4",
        22 => "6",
        23 => "5",
        24 => "=",
        25 => "9",
        26 => "7",
        27 => "-",
        28 => "8",
        29 => "0",
        30 => "]",
        31 => "o",
        32 => "u",
        33 => "[",
        34 => "i",
        35 => "p",
        36 => "RETURN",
        37 => "l",
        38 => "j",
        39 => "'",
        40 => "k",
        41 => ";",
        42 => "\\",
        43 => ",",
        44 => "/",
        45 => "n",
        46 => "m",
        47 => ".",
        48 => "TAB",
        49 => "SPACE",
        50 => "`",
        51 => "DELETE",
        52 => "ENTER",
        53 => "ESCAPE",

        65 => ".",

        67 => "*",

        69 => "+",

        71 => "CLEAR",

        75 => "/",
        76 => "ENTER",

        78 => "-",

        81 => "=",
        82 => "0",
        83 => "1",
        84 => "2",
        85 => "3",
        86 => "4",
        87 => "5",
        88 => "6",
        89 => "7",

        91 => "8",
        92 => "9",

        0xb0 => "F5",
        96 => "F5",
        97 => "F6",
        98 => "F7",
        99 => "F3",
        100 => "F8",
        101 => "F9",

        103 => "F11",

        105 => "F13",

        107 => "F14",

        109 => "F10",

        111 => "F12",

        113 => "F15",
        114 => "HELP",
        115 => "HOME",
        116 => "PGUP",
        117 => "DELETE",
        118 => "F4",
        119 => "END",
        120 => "F2",
        121 => "PGDN",
        122 => "F1",
        123 => "LEFT",
        124 => "RIGHT",
        125 => "DOWN",
        126 => "UP",

        else => "unknown",
    };
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

    // Verify the cast worked correctly
    try std.testing.expectEqualStrings("abc", ptr[0..3]);
    try std.testing.expectEqualStrings("abc", sentinalSlice[0..3]);

    const span = std.mem.sliceTo(buf, 0);
    try std.testing.expectEqualStrings("abc", span);
    // alloc.free(span);
    // alloc.free(ptr);
}
