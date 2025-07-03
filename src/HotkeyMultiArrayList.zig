const std = @import("std");
const Hotkey = @This();
const Mode = @import("Mode.zig");
const utils = @import("utils.zig");
const ModifierFlag = @import("Keycodes.zig").ModifierFlag;
const log = std.log.scoped(.@"hotkey_multi_array_list");

allocator: std.mem.Allocator,
flags: ModifierFlag = undefined,
key: u32 = undefined,
mappings: ProcessMappings,
mode_list: std.AutoArrayHashMap(*Mode, void),

pub fn destroy(self: *Hotkey) void {
    self.mappings.deinit();
    self.mode_list.deinit();
    self.allocator.destroy(self);
}

pub fn create(allocator: std.mem.Allocator) !*Hotkey {
    const hotkey = try allocator.create(Hotkey);
    hotkey.* = .{
        .allocator = allocator,
        .flags = ModifierFlag{},
        .key = 0,
        .mappings = .{ .allocator = allocator },
        .mode_list = .init(allocator),
    };
    return hotkey;
}

pub const HotkeyMap = std.ArrayHashMapUnmanaged(*Hotkey, void, struct {
    pub fn hash(self: @This(), key: *Hotkey) u32 {
        _ = self;
        // Like original skhd, only hash by key code to allow modifier matching during lookup
        return key.key;
    }
    pub fn eql(self: @This(), a: *Hotkey, b: *Hotkey, _: anytype) bool {
        _ = self;
        return Hotkey.eql(a, b);
    }
}, false);

pub const KeyPress = struct {
    flags: ModifierFlag,
    key: u32,
};

pub fn eql(a: *Hotkey, b: *Hotkey) bool {
    // Implement left/right modifier comparison logic like original skhd
    // Note: This is for HashMap equality check, both are from config
    return compareLRMod(a.flags, b.flags, .alt) and
        compareLRMod(a.flags, b.flags, .cmd) and
        compareLRMod(a.flags, b.flags, .control) and
        compareLRMod(a.flags, b.flags, .shift) and
        a.flags.@"fn" == b.flags.@"fn" and
        a.flags.nx == b.flags.nx and
        a.key == b.key;
}

fn compareLRMod(a: ModifierFlag, b: ModifierFlag, comptime mod: enum { alt, cmd, control, shift }) bool {
    const general_field = switch (mod) {
        .alt => "alt",
        .cmd => "cmd",
        .control => "control",
        .shift => "shift",
    };
    const left_field = switch (mod) {
        .alt => "lalt",
        .cmd => "lcmd",
        .control => "lcontrol",
        .shift => "lshift",
    };
    const right_field = switch (mod) {
        .alt => "ralt",
        .cmd => "rcmd",
        .control => "rcontrol",
        .shift => "rshift",
    };

    const a_general = @field(a, general_field);
    const a_left = @field(a, left_field);
    const a_right = @field(a, right_field);

    const b_general = @field(b, general_field);
    const b_left = @field(b, left_field);
    const b_right = @field(b, right_field);

    // For HashMap equality, we need exact match
    // Both hotkeys are from config, so exact comparison is correct
    return a_general == b_general and a_left == b_left and a_right == b_right;
}

pub const ProcessCommand = union(enum) {
    command: []const u8,
    forwarded: KeyPress,
    unbound: void,
};

// Define the struct that MultiArrayList will manage
const ProcessMapping = struct {
    // Store lowercase process names for fast comparison
    process_name: []const u8,
    // Pre-computed hash for even faster comparison
    name_hash: u64,
    // Command aligned with process name
    command: ProcessCommand,
};

// Use MultiArrayList for SOA storage
const ProcessMappings = struct {
    allocator: std.mem.Allocator,
    list: std.MultiArrayList(ProcessMapping) = .{},

    pub fn deinit(self: *ProcessMappings) void {
        // Free all process names
        const names = self.list.items(.process_name);
        for (names) |name| {
            self.allocator.free(name);
        }

        // Free all command strings
        const commands = self.list.items(.command);
        for (commands) |cmd| {
            switch (cmd) {
                .command => |str| self.allocator.free(str),
                else => {},
            }
        }

        self.list.deinit(self.allocator);
    }

    pub fn add(self: *ProcessMappings, process_name: []const u8, command: ProcessCommand) !void {
        const owned_name = try self.allocator.dupe(u8, process_name);
        errdefer self.allocator.free(owned_name);

        // Convert to lowercase once during insertion
        for (owned_name, 0..) |c, i| owned_name[i] = std.ascii.toLower(c);

        // Pre-compute hash
        const hash = std.hash.Wyhash.hash(0, owned_name);

        // Clone command if needed
        const owned_cmd = switch (command) {
            .command => |str| blk: {
                const owned_str = try self.allocator.dupe(u8, str);
                break :blk ProcessCommand{ .command = owned_str };
            },
            else => command,
        };

        try self.list.append(self.allocator, .{
            .process_name = owned_name,
            .name_hash = hash,
            .command = owned_cmd,
        });
    }

    pub fn findCommand(self: *const ProcessMappings, process_name: []const u8) ?ProcessCommand {
        if (self.list.len == 0) return null;

        // Create lowercase version for comparison
        var name_buf: [256]u8 = undefined;
        if (process_name.len > name_buf.len) return null;

        for (process_name, 0..) |c, i| {
            name_buf[i] = std.ascii.toLower(c);
        }
        const lower_name = name_buf[0..process_name.len];
        const target_hash = std.hash.Wyhash.hash(0, lower_name);

        // Fast path: check hashes first
        // This is where MultiArrayList shines - we can access just the hashes
        const hashes = self.list.items(.name_hash);
        const names = self.list.items(.process_name);
        const commands = self.list.items(.command);

        for (hashes, 0..) |hash, i| {
            if (hash == target_hash) {
                // Verify actual string only on hash match
                if (std.mem.eql(u8, names[i], lower_name)) {
                    return commands[i];
                }
            }
        }
        return null;
    }

    // Utility function to demonstrate field-specific iteration
    pub const CommandStats = struct { commands: usize, forwarded: usize, unbound: usize };

    pub fn countCommandTypes(self: *const ProcessMappings) CommandStats {
        var result = CommandStats{ .commands = 0, .forwarded = 0, .unbound = 0 };

        // MultiArrayList allows efficient access to just the command field
        const commands = self.list.items(.command);
        for (commands) |cmd| {
            switch (cmd) {
                .command => result.commands += 1,
                .forwarded => result.forwarded += 1,
                .unbound => result.unbound += 1,
            }
        }

        return result;
    }

    // Demonstrate using slice() for multi-field access
    pub fn findAllForwardedKeys(self: *const ProcessMappings, allocator: std.mem.Allocator) ![]KeyPress {
        var forwarded = std.ArrayList(KeyPress).init(allocator);
        defer forwarded.deinit();

        // Get a slice view that allows coordinated access to multiple fields
        const slice = self.list.slice();

        for (0..self.list.len) |i| {
            switch (slice.items(.command)[i]) {
                .forwarded => |key_press| try forwarded.append(key_press),
                else => {},
            }
        }

        return try forwarded.toOwnedSlice();
    }
};

pub fn format(self: *const Hotkey, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    _ = fmt;
    try writer.print("Hotkey{{", .{});
    try writer.print("\n  mode_list: {{", .{});
    {
        var it = self.mode_list.iterator();
        while (it.next()) |kv| {
            try writer.print("{s},", .{kv.key_ptr.*.name});
        }
    }
    try writer.print("}}", .{});
    try writer.print("\n  flags: {}", .{self.flags});
    try writer.print("\n  key: {}", .{self.key});
    try writer.print("\n  process_mappings: {} entries", .{self.mappings.list.len});

    // Show command type distribution
    const stats = self.mappings.countCommandTypes();
    try writer.print("\n    commands: {}, forwarded: {}, unbound: {}", .{ stats.commands, stats.forwarded, stats.unbound });
    try writer.print("\n}}", .{});
}

// API that's more SOA-friendly
pub fn add_process_mapping(self: *Hotkey, process_name: []const u8, command: ProcessCommand) !void {
    try self.mappings.add(process_name, command);
}

pub fn find_command_for_process(self: *const Hotkey, process_name: []const u8) ?ProcessCommand {
    // First try to find exact match
    if (self.mappings.findCommand(process_name)) |cmd| {
        return cmd;
    }
    // If no exact match, look for wildcard "*"
    return self.mappings.findCommand("*");
}

pub fn add_mode(self: *Hotkey, mode: *Mode) !void {
    if (self.mode_list.contains(mode)) {
        return error.@"Mode already exists in hotkey mode";
    }
    try self.mode_list.put(mode, {});
}

// Additional utility methods that leverage MultiArrayList features
pub fn getProcessNames(self: *const Hotkey) []const []const u8 {
    return self.mappings.list.items(.process_name);
}

pub fn getCommands(self: *const Hotkey) []const ProcessCommand {
    return self.mappings.list.items(.command);
}

test "MultiArrayList hotkey implementation" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc);
    defer hotkey.destroy();

    hotkey.flags = ModifierFlag{ .alt = true };
    hotkey.key = 0x2;

    // Test the new API
    try hotkey.add_process_mapping("firefox", ProcessCommand{ .command = "echo firefox" });
    try hotkey.add_process_mapping("chrome", ProcessCommand{ .command = "echo chrome" });
    try hotkey.add_process_mapping("terminal", ProcessCommand{ .forwarded = KeyPress{ .flags = .{}, .key = 0x24 } });

    // Test lookup
    const firefox_cmd = hotkey.find_command_for_process("Firefox");
    try std.testing.expect(firefox_cmd != null);
    try std.testing.expectEqualStrings("echo firefox", firefox_cmd.?.command);

    // Test case insensitive
    const chrome_cmd = hotkey.find_command_for_process("CHROME");
    try std.testing.expect(chrome_cmd != null);
    try std.testing.expectEqualStrings("echo chrome", chrome_cmd.?.command);

    // Test wildcard using unified API
    try hotkey.add_process_mapping("*", ProcessCommand{ .command = "echo default" });
    const unknown_cmd = hotkey.find_command_for_process("unknown");
    try std.testing.expect(unknown_cmd != null);
    try std.testing.expectEqualStrings("echo default", unknown_cmd.?.command);

    // Test command type counting
    const stats = hotkey.mappings.countCommandTypes();
    try std.testing.expectEqual(@as(usize, 3), stats.commands); // firefox, chrome, and wildcard
    try std.testing.expectEqual(@as(usize, 1), stats.forwarded);
    try std.testing.expectEqual(@as(usize, 0), stats.unbound);

    // Test field access
    const names = hotkey.getProcessNames();
    try std.testing.expectEqual(@as(usize, 4), names.len); // firefox, chrome, terminal, *
}

test "MultiArrayList performance characteristics" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc);
    defer hotkey.destroy();

    // Add many mappings
    for (0..100) |i| {
        const name = try std.fmt.allocPrint(alloc, "process_{}", .{i});
        defer alloc.free(name);
        const cmd = try std.fmt.allocPrint(alloc, "echo process_{}", .{i});
        defer alloc.free(cmd);

        try hotkey.add_process_mapping(name, ProcessCommand{ .command = cmd });
    }

    // The benefit of MultiArrayList is that we can iterate over just the fields we need
    // This improves cache performance when we only need to access specific fields

    // Example: Count processes starting with "process_1"
    var count: usize = 0;
    const names = hotkey.getProcessNames();
    for (names) |name| {
        if (std.mem.startsWith(u8, name, "process_1")) {
            count += 1;
        }
    }

    // Should match process_1, process_10-19 (11 total)
    try std.testing.expectEqual(@as(usize, 11), count);
}
