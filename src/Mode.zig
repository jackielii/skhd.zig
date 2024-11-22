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

const Mode = @This();

allocator: std.mem.Allocator,
name: []const u8,
command: ?[]const u8 = null,
capture: bool,
initialized: bool,
hotkey_map: std.AutoArrayHashMap(*Hotkey, void),

pub fn init(allocator: std.mem.Allocator, name: []const u8) !Mode {
    return Mode{
        .allocator = allocator,
        .name = try allocator.dupe(u8, name),
        // .command = allocator.dupe(command),
        .capture = false,
        .initialized = false,
        .hotkey_map = std.AutoArrayHashMap(*Hotkey, void).init(allocator),
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

pub fn format(self: *const Mode, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    if (fmt.len != 0) {
        std.fmt.invalidFmtError(fmt, self);
    }
    try writer.print("Mode{{", .{});
    try writer.print("\n  name: {s}", .{self.name});
    try writer.print("\n  command: {?s}", .{self.command});
    try writer.print("\n  capture: {}", .{self.capture});
    try writer.print("\n  initialized: {}", .{self.initialized});
    try writer.print("\n  hotkey_map: {{", .{});
    {
        var it = self.hotkey_map.iterator();
        while (it.next()) |kv| {
            const string = try std.fmt.allocPrint(self.allocator, "{}", .{kv.key_ptr.*});
            defer self.allocator.free(string);
            var parts = std.mem.splitScalar(u8, string, '\n');
            while (parts.next()) |part| {
                try writer.print("\n    {s}", .{part});
            }
            // try writer.print("\n    {}", .{kv.key_ptr.*});
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
