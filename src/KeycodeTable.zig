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

const KeycodeTable = @This();

pub fn init(alloc: std.mem.Allocator) !KeycodeTable {
    const keyboard = c.TISCopyCurrentASCIICapableKeyboardLayoutInputSource();
    const uchr: c.CFDataRef = @ptrCast(c.TISGetInputSourceProperty(keyboard, c.kTISPropertyUnicodeKeyLayoutData));
    defer c.CFRelease(keyboard);

    const keyboard_layout: ?*c.UCKeyboardLayout = @constCast(@ptrCast(@alignCast(c.CFDataGetBytePtr(uchr))));
    if (keyboard_layout == null) {
        return error.@"Failed to get keyboard layout";
    }

    var keymap_table = std.StringArrayHashMap(u32).init(alloc);

    var len: c.UniCharCount = 0;
    var chars: [255]c.UniChar = @splat(0);
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

    return KeycodeTable{ .keymap_table = keymap_table, .alloc = alloc };
}

pub fn deinit(self: *KeycodeTable) void {
    var it = self.keymap_table.iterator();
    while (it.next()) |kv| {
        self.alloc.free(kv.key_ptr.*);
    }
    self.keymap_table.deinit();
}

pub fn get_keycode(self: *KeycodeTable, key: []const u8) !u32 {
    const key_string = self.keymap_table.get(key) orelse return error.@"Key not found";
    return key_string;
}

fn copy_cfstring(alloc: std.mem.Allocator, cfstring: c.CFStringRef) ![]u8 {
    // const n = c.CFStringGetLength(cfstring);
    const num_bytes = c.CFStringGetMaximumSizeForEncoding(c.CFStringGetLength(cfstring), c.kCFStringEncodingUTF8);
    // std.debug.print("n: {}, max_num_bytes: {}\n", .{ n, num_bytes });
    const buffer = try alloc.alloc(u8, @intCast(num_bytes));
    defer alloc.free(buffer);

    if (c.CFStringGetCString(cfstring, buffer.ptr, num_bytes, c.kCFStringEncodingUTF8) == c.false) {
        return error.@"Failed to copy CFString";
    }

    const ret = try alloc.dupe(u8, std.mem.sliceTo(buffer, 0));
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
