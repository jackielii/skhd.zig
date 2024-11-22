// struct hotkey
// {
//     uint32_t flags;
//     uint32_t key;
//     char **process_name;
//     char **command;
//     char *wildcard_command;
//     struct mode **mode_list;
//     struct hotkey *forwarded_hotkey;
// };

const std = @import("std");
const Hotkey = @This();
const Mode = @import("Mode.zig");
const utils = @import("./utils.zig");

pub const HotkeyMap = std.ArrayHashMap(*Hotkey, void, hotkeyContext, false);

fn eql(a: *Hotkey, b: *Hotkey) bool {
    return a.flags == b.flags and a.key == b.key;
}

const hotkeyContext = struct {
    pub fn hash(self: @This(), key: *Hotkey) u32 {
        _ = self;
        return key.flags ^ key.key;
    }
    pub fn eql(self: @This(), a: *Hotkey, b: *Hotkey, _: anytype) bool {
        _ = self;
        return Hotkey.eql(a, b);
    }
};

allocator: std.mem.Allocator,
flags: u32 = undefined,
key: u32 = undefined,
process_names: std.ArrayList([]const u8) = undefined,
commands: std.ArrayList([]const u8) = undefined,
wildcard_command: ?[]const u8 = null,
forwarded_hotkey: ?*Hotkey = null,
mode_list: std.AutoArrayHashMap(*Mode, void) = undefined,

pub fn destroy(self: *Hotkey) void {
    for (self.process_names.items) |name| self.allocator.free(name);
    self.process_names.deinit();

    for (self.commands.items) |cmd| self.allocator.free(cmd);
    self.commands.deinit();

    if (self.wildcard_command) |wildcard_command| self.allocator.free(wildcard_command);
    if (self.forwarded_hotkey) |forwarded_hotkey| forwarded_hotkey.destroy();

    self.mode_list.deinit();
    self.allocator.destroy(self);
}

pub fn create(allocator: std.mem.Allocator) !*Hotkey {
    const hotkey = try allocator.create(Hotkey);
    hotkey.* = .{
        .allocator = allocator,
        .process_names = std.ArrayList([]const u8).init(allocator),
        .commands = std.ArrayList([]const u8).init(allocator),
        .mode_list = std.AutoArrayHashMap(*Mode, void).init(allocator),
    };
    return hotkey;
}

pub fn set_wilecard_command(self: *Hotkey, wildcard_command: []const u8) !void {
    if (self.wildcard_command) |old| self.allocator.free(old);
    self.wildcard_command = try self.allocator.dupe(u8, wildcard_command);
}

pub fn set_forwarded_hotkey(self: *Hotkey, forwarded_hotkey: *Hotkey) void {
    if (self.forwarded_hotkey) |old| old.destroy();
    self.forwarded_hotkey = forwarded_hotkey;
}

pub fn format(self: *const Hotkey, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    if (fmt.len != 0) {
        std.fmt.invalidFmtError(fmt, self);
    }
    try writer.print("Hotkey{{", .{});
    try writer.print("\n  flags: {}", .{self.flags});
    try writer.print("\n  key: {}", .{self.key});
    try writer.print("\n  process_names: {{", .{});
    {
        for (self.process_names.items) |name| {
            try writer.print("\n    {s}", .{name});
        }
    }
    try writer.print("\n  }}", .{});
    try writer.print("\n  wildcard_command: {?s}", .{self.wildcard_command});
    try writer.print("\n  mode_list: {{", .{});
    {
        var it = self.mode_list.iterator();
        while (it.next()) |kv| {
            try writer.print("\n    {s}", .{kv.key_ptr.*.name});
        }
    }
    try writer.print("\n  }}", .{});
    try writer.print("\n  commands: {{", .{});
    {
        for (self.commands.items) |cmd| {
            try writer.print("\n    {s}", .{cmd});
        }
    }
    try writer.print("\n  }}", .{});
    if (self.forwarded_hotkey) |hotkey| {
        try writer.print("\n  forwarded_hotkey: ", .{});
        try utils.indentPrint(self.allocator, writer, 2, "{}", hotkey);
    }
    try writer.print("\n}}", .{});
}

pub fn add_process_name(self: *Hotkey, process_name: []const u8) !void {
    const owned = try self.allocator.dupe(u8, process_name);
    try self.process_names.append(owned);
}

pub fn add_command(self: *Hotkey, command: []const u8) !void {
    const owned = try self.allocator.dupe(u8, command);
    try self.commands.append(owned);
}

pub fn add_mode(self: *Hotkey, mode: *Mode) !void {
    try self.mode_list.put(mode, {});
}

test "hotkey map" {
    const alloc = std.testing.allocator;
    var m = HotkeyMap.init(alloc);
    defer m.deinit();

    var key1 = try Hotkey.create(alloc);
    defer key1.destroy();
    key1.flags = 0x1;
    key1.key = 0x2;
    try key1.add_process_name("notepad.exe");
    std.debug.print("{}\n", .{key1});

    var key2 = try Hotkey.create(alloc);
    key2.flags = 0x1;
    key2.key = 0x2;
    defer key2.destroy();
    std.debug.print("{}\n", .{key2});

    var key1d = try Hotkey.create(alloc);
    defer key1d.destroy();
    key1d.flags = 0x2;
    key1d.key = 0x2;
    try key1d.add_process_name("notepad.exe");
    std.debug.print("{}\n", .{key1d});

    try m.put(key1, {});
    try m.put(key2, {});
    try m.put(key1d, {});
    try std.testing.expectEqual(2, m.count());
}

test "format hotkey" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc);
    defer hotkey.destroy();

    hotkey.flags = 0x1;
    hotkey.key = 0x2;
    try hotkey.add_process_name("some process_name");
    try hotkey.add_command("some command");
    var mode = try Mode.init(alloc, "default");
    defer mode.deinit();
    // std.debug.print("{}\n", .{mode});
    try hotkey.add_mode(&mode);
    try hotkey.set_wilecard_command("some wildcard_command");
    hotkey.forwarded_hotkey = try Hotkey.create(alloc);

    const string = try std.fmt.allocPrint(alloc, "{}", .{hotkey});
    defer alloc.free(string);

    std.debug.print("{s}\n", .{string});
}
