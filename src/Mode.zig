// struct mode
// {
//     char *name;
//     char *command;
//     bool capture;
//     bool initialized;
//     struct table hotkey_map;
// };
const std = @import("std");
const Hotkey = @import("./Hotkey.zig");
const utils = @import("./utils.zig");

const Mode = @This();

allocator: std.mem.Allocator,
name: []const u8,
command: ?[]const u8 = null,
capture: bool = false,
initialized: bool = false,
hotkey_map: std.ArrayHashMapUnmanaged(*Hotkey, void, struct {
    pub fn hash(self: @This(), key: *Hotkey) u32 {
        _ = self;
        return @as(u32, @bitCast(key.flags)) ^ key.key;
    }
    pub fn eql(self: @This(), a: *Hotkey, b: *Hotkey, _: anytype) bool {
        _ = self;
        return Hotkey.eql(a, b);
    }
}, false),

pub fn init(allocator: std.mem.Allocator, name: []const u8) !Mode {
    return Mode{
        .allocator = allocator,
        .name = try allocator.dupe(u8, name),
        .capture = false,
        .initialized = true,
        .hotkey_map = .empty,
    };
}

pub fn deinit(self: *Mode) void {
    self.allocator.free(self.name);
    if (self.command) |cmd| self.allocator.free(cmd);
    {
        var it = self.hotkey_map.iterator();
        while (it.next()) |kv| {
            kv.key_ptr.*.destroy();
        }
        self.hotkey_map.deinit(self.allocator);
    }
    self.* = undefined;
}

pub fn set_command(self: *Mode, command: []const u8) !void {
    if (self.command) |cmd| self.allocator.free(cmd);
    self.command = try self.allocator.dupe(u8, command);
}

pub fn format(self: *const Mode, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    // if (fmt.len != 0) {
    //     std.fmt.invalidFmtError(fmt, self);
    // }
    _ = fmt;
    try writer.print("Mode{{", .{});
    try writer.print("\n  name: {s}", .{self.name});
    try writer.print("\n  command: {?s}", .{self.command});
    try writer.print("\n  capture: {}", .{self.capture});
    try writer.print("\n  initialized: {}", .{self.initialized});
    try writer.print("\n  hotkey_map: {{\n", .{});
    {
        var it = self.hotkey_map.iterator();
        while (it.next()) |kv| {
            try utils.indentPrint(self.allocator, writer, "    ", "{}", kv.key_ptr.*);
        }
    }
    try writer.print("\n  }}", .{});
    try writer.print("\n}}", .{});
}

pub fn add_hotkey(self: *Mode, hotkey: *Hotkey) !void {
    try self.hotkey_map.put(self.allocator, hotkey, {});
}

test "init" {
    const alloc = std.testing.allocator;
    var mode = try Mode.init(alloc, "default");
    defer mode.deinit();

    var key = try Hotkey.create(alloc);
    try key.add_process_name("notepad.exe");
    try key.add_mode(&mode);
    try mode.add_hotkey(key);

    const string = try std.fmt.allocPrint(alloc, "{}", .{mode});
    defer alloc.free(string);
    std.debug.print("{s}\n", .{string});
}

test "hotkey map" {
    const HotkeyMap = std.ArrayHashMap(Hotkey, void, struct {
        pub fn hash(self: @This(), key: Hotkey) u32 {
            _ = self;
            return @as(u32, @bitCast(key.flags)) ^ key.key;
        }
        pub fn eql(self: @This(), a: Hotkey, b: Hotkey, _: anytype) bool {
            _ = self;
            return Hotkey.eql(a, b);
        }
    }, false);
    const alloc = std.testing.allocator;
    var m = HotkeyMap.init(alloc);
    defer m.deinit();

    var key1 = try Hotkey.create(alloc);
    defer key1.destroy();
    key1.flags = Hotkey.ModifierFlag{ .alt = true };
    key1.key = 0x2;
    try key1.add_process_name("notepad.exe");
    std.debug.print("{}\n", .{key1});

    var key2 = try Hotkey.create(alloc);
    key2.flags = Hotkey.ModifierFlag{ .alt = true };
    key2.key = 0x2;
    defer key2.destroy();
    std.debug.print("{}\n", .{key2});

    var key1d = try Hotkey.create(alloc);
    defer key1d.destroy();
    key1d.flags = Hotkey.ModifierFlag{ .cmd = true };
    key1d.key = 0x2;
    try key1d.add_process_name("notepad.exe");
    std.debug.print("{}\n", .{key1d});

    try m.put(key1, {});
    try m.put(key2, {});
    try m.put(key1d, {});
    try std.testing.expectEqual(2, m.count());
}
