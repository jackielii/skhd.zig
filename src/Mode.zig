// struct mode
// {
//     char *name;
//     char *command;
//     bool capture;
//     bool initialized;
//     struct table hotkey_map;
// };
const std = @import("std");
const Hotkey = @import("Hotkey.zig");
const utils = @import("utils.zig");

const Mode = @This();
const log = std.log.scoped(.mode);

allocator: std.mem.Allocator,
name: []const u8,
command: ?[:0]const u8 = null,
capture: bool = false,
initialized: bool = false,
hotkey_map: Hotkey.HotkeyMap = .empty,

pub fn init(allocator: std.mem.Allocator, name: []const u8) !Mode {
    return Mode{
        .allocator = allocator,
        .name = try allocator.dupe(u8, name),
        .capture = false,
        .initialized = true,
    };
}

pub fn deinit(self: *Mode) void {
    self.allocator.free(self.name);
    if (self.command) |cmd| self.allocator.free(cmd);
    self.hotkey_map.deinit(self.allocator);
    self.* = undefined;
}

pub fn set_command(self: *Mode, command: []const u8) !void {
    if (self.command) |cmd| self.allocator.free(cmd);
    self.command = try self.allocator.dupeZ(u8, command);
}

pub fn format(self: Mode, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("Mode{");
    try writer.print("\n  name: {s}", .{self.name});
    try writer.print("\n  command: {?s}", .{self.command});
    try writer.print("\n  capture: {}", .{self.capture});
    try writer.print("\n  initialized: {}", .{self.initialized});
    try writer.writeAll("\n  hotkey_map: {\n");
    {
        var it = self.hotkey_map.iterator();
        while (it.next()) |kv| {
            utils.indentPrint(self.allocator, writer, "    ", "{f}", kv.key_ptr.*) catch return error.WriteFailed;
        }
    }
    try writer.writeAll("\n  }");
    try writer.writeAll("\n}");
}

pub fn add_hotkey(self: *Mode, hotkey: *Hotkey) !void {
    // Config-time duplicates are about overlapping triggers in the same
    // mode. Commands/process mappings are payload, not part of the lookup
    // key; users express process-specific variants inside one hotkey's
    // process list.
    var it = self.hotkey_map.iterator();
    while (it.next()) |entry| {
        if (Hotkey.triggersOverlap(entry.key_ptr.*, hotkey)) {
            return error.DuplicateHotkeyInMode;
        }
    }

    try self.hotkey_map.put(self.allocator, hotkey, {});
}

test "init" {
    const alloc = std.testing.allocator;
    var mode = try Mode.init(alloc, "default");
    defer mode.deinit();

    var key = try Hotkey.create(alloc);
    defer key.destroy();
    try key.add_process_command("notepad.exe", "echo notepad");
    try key.add_mode(&mode);
    try mode.add_hotkey(key);

    // const string = try std.fmt.allocPrint(alloc, "{}", .{mode});
    // defer alloc.free(string);
    // std.debug.print("{s}\n", .{string});
}
