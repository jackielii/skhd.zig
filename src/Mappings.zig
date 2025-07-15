const std = @import("std");
const Mode = @import("Mode.zig");
const Hotkey = @import("Hotkey.zig");
const utils = @import("utils.zig");
const log = std.log.scoped(.mappings);

allocator: std.mem.Allocator,
mode_map: std.StringHashMapUnmanaged(Mode) = .empty,
blacklist: std.StringHashMapUnmanaged(void) = .empty,
shell: [:0]const u8,
loaded_files: std.ArrayListUnmanaged([]const u8) = .empty,
// Track all hotkeys for cleanup (hotkeys can belong to multiple modes)
hotkeys: std.ArrayListUnmanaged(*Hotkey) = .empty,

const Mappings = @This();

pub fn init(alloc: std.mem.Allocator) !Mappings {
    const default_shell = "/bin/bash";
    const shell = if (std.posix.getenv("SHELL")) |env|
        try alloc.dupeZ(u8, env)
    else
        try alloc.dupeZ(u8, default_shell);

    return Mappings{
        .shell = shell,
        .allocator = alloc,
    };
}

pub fn deinit(self: *Mappings) void {
    // First destroy all hotkeys (must be done before destroying modes)
    for (self.hotkeys.items) |hotkey| {
        hotkey.destroy();
    }
    self.hotkeys.deinit(self.allocator);

    {
        var it = self.mode_map.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            kv.value_ptr.*.deinit();
        }
        self.mode_map.deinit(self.allocator);
    }
    {
        var it = self.blacklist.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.blacklist.deinit(self.allocator);
    }
    self.allocator.free(self.shell);

    // Free loaded file paths
    for (self.loaded_files.items) |file_path| {
        self.allocator.free(file_path);
    }
    self.loaded_files.deinit(self.allocator);

    self.* = undefined;
}

pub fn add_hotkey(self: *Mappings, hotkey: *Hotkey) !void {
    // First try to add to all modes
    var it = hotkey.mode_list.iterator();
    while (it.next()) |kv| {
        const mode = kv.key_ptr.*;
        try mode.add_hotkey(hotkey);
    }

    // Only track the hotkey after successful addition to all modes
    try self.hotkeys.append(self.allocator, hotkey);
}

pub fn set_shell(self: *Mappings, shell: []const u8) !void {
    self.allocator.free(self.shell);
    self.shell = try self.allocator.dupeZ(u8, shell);
}

pub fn add_blacklist(self: *Mappings, key: []const u8) !void {
    if (self.blacklist.contains(key)) {
        return error.BlacklistEntryAlreadyExists;
    }
    const owned = try self.allocator.dupe(u8, key);
    try self.blacklist.put(self.allocator, owned, void{});
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
        const mode_value = try self.mode_map.getOrPut(self.allocator, key);
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

pub fn get_or_create_mode(self: *Mappings, mode_name: []const u8) !*Mode {
    const key = try self.allocator.dupe(u8, mode_name);
    errdefer self.allocator.free(key);
    const mode_value = try self.mode_map.getOrPut(self.allocator, key);
    if (mode_value.found_existing) {
        defer self.allocator.free(key);
        return mode_value.value_ptr;
    }
    const mode = try Mode.init(self.allocator, key);
    mode_value.value_ptr.* = mode;
    return mode_value.value_ptr;
}

pub fn put_mode(self: *Mappings, mode: Mode) !void {
    if (self.mode_map.contains(mode.name)) {
        return error.ModeAlreadyExists;
    }
    const key = try self.allocator.dupe(u8, mode.name);
    try self.mode_map.put(self.allocator, key, mode);
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
    const mode = try mappings.get_mode_or_create_default("default");
    // Just verify the formatting doesn't crash
    const formatted = try std.fmt.allocPrint(alloc, "{}", .{mappings});
    defer alloc.free(formatted);
    try std.testing.expect(formatted.len > 0);
    try std.testing.expect(mode != null);
}

test "add_blacklist returns error on duplicate" {
    const alloc = std.testing.allocator;
    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // First add should succeed
    try mappings.add_blacklist("firefox");

    // Duplicate should fail
    const result = mappings.add_blacklist("firefox");
    try std.testing.expectError(error.BlacklistEntryAlreadyExists, result);

    // Verify the original entry is still there
    try std.testing.expect(mappings.blacklist.contains("firefox"));
    try std.testing.expectEqual(@as(usize, 1), mappings.blacklist.count());
}

test "put_mode returns error on duplicate" {
    const alloc = std.testing.allocator;
    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Create and add a mode
    const mode1 = try Mode.init(alloc, "test_mode");
    try mappings.put_mode(mode1);

    // Try to add another mode with the same name
    var mode2 = try Mode.init(alloc, "test_mode");
    defer mode2.deinit(); // We need to clean this up since put_mode will fail

    const result = mappings.put_mode(mode2);
    try std.testing.expectError(error.ModeAlreadyExists, result);

    // Verify the original mode is still there
    try std.testing.expect(mappings.mode_map.contains("test_mode"));
    try std.testing.expectEqual(@as(usize, 1), mappings.mode_map.count());
}
