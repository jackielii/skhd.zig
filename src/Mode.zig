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
const HotkeyMap = Hotkey.HotkeyMap;
const utils = @import("./utils.zig");

const Mode = @This();

allocator: std.mem.Allocator,
name: []const u8,
command: ?[]const u8 = null,
capture: bool = false,
initialized: bool = false,
hotkey_map: HotkeyMap,

pub fn init(allocator: std.mem.Allocator, name: []const u8) !Mode {
    return Mode{
        .allocator = allocator,
        .name = try allocator.dupe(u8, name),
        .capture = false,
        .initialized = true,
        .hotkey_map = .init(allocator),
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
        self.hotkey_map.deinit();
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
    try self.hotkey_map.put(hotkey, {});
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
