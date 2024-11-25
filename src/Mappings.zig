const std = @import("std");
const Mode = @import("./Mode.zig");
const utils = @import("./utils.zig");

allocator: std.mem.Allocator,
mode_map: std.StringHashMap(Mode) = undefined,
blacklist: std.StringHashMap(void) = undefined,
shell: []const u8 = undefined,

const Mappings = @This();

pub fn init(alloc: std.mem.Allocator) !Mappings {
    var shell: []const u8 = "/bin/bash";
    if (std.posix.getenv("SHELL")) |env| {
        shell = try alloc.dupe(u8, env);
    } else {
        shell = try alloc.dupe(u8, shell);
    }
    return Mappings{
        .shell = shell,
        .allocator = alloc,
        .mode_map = std.StringHashMap(Mode).init(alloc),
        .blacklist = std.StringHashMap(void).init(alloc),
    };
}

pub fn deinit(self: *Mappings) void {
    {
        var it = self.mode_map.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            kv.value_ptr.*.deinit();
        }
        self.mode_map.deinit();
    }
    {
        var it = self.blacklist.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.blacklist.deinit();
    }
    self.allocator.free(self.shell);

    self.* = undefined;
}

pub fn set_shell(self: *Mappings, shell: []const u8) !void {
    self.allocator.free(self.shell);
    self.shell = try self.allocator.dupe(u8, shell);
}

pub fn add_blacklist(self: *Mappings, key: []const u8) !void {
    const key_dup = try self.allocator.dupe(u8, key);
    try self.blacklist.put(key_dup, void{});
}

pub fn format(self: *const Mappings, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    // if (fmt.len != 0) {
    //     std.fmt.invalidFmtError(fmt, self);
    // }
    _ = fmt;
    try writer.print("Mappings {{", .{});
    try writer.print("\n  mode_map: {{", .{});
    {
        var it = self.mode_map.iterator();
        while (it.next()) |kv| {
            try utils.indentPrint(self.allocator, writer, "    ", "\n{}", kv.value_ptr.*);
        }
    }
    try writer.print("\n  }}", .{});
    try writer.print("\n  blacklist: {{", .{});
    {
        var it = self.blacklist.keyIterator();
        while (it.next()) |key| {
            try writer.print("\n    {s}", .{key.*});
        }
    }
    try writer.print("\n  }}", .{});
    try writer.print("\n}}", .{});
}

pub fn get_mode_or_create_default(self: *Mappings, mode_name: []const u8) !?*Mode {
    if (std.mem.eql(u8, mode_name, "default")) {
        const key = try self.allocator.dupe(u8, mode_name);
        errdefer self.allocator.free(key);
        const mode_value = try self.mode_map.getOrPut(key);
        if (mode_value.found_existing) {
            defer self.allocator.free(key);
            return mode_value.value_ptr;
        }
        const mode = try Mode.init(self.allocator, key);
        mode_value.value_ptr.* = mode;
        return mode_value.value_ptr;
    }
    return self.mode_map.getPtr(mode_name);
}

test "get_mode default" {
    const alloc = std.testing.allocator;
    var mappings = try Mappings.init(alloc);
    _ = try mappings.get_mode_or_create_default("default");
    _ = try mappings.get_mode_or_create_default("default");
    _ = try mappings.get_mode_or_create_default("xxx");
    _ = try mappings.get_mode_or_create_default("yyy");
    try std.testing.expectEqual(mappings.mode_map.count(), 1);
    defer mappings.deinit();
}

test "format" {
    const alloc = std.testing.allocator;
    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();
    _ = try mappings.get_mode_or_create_default("default");
    std.debug.print("{}\n", .{mappings});
    // try std.json.stringify(mappings, .{ .whitespace = .indent_2 }, string.writer());
}
