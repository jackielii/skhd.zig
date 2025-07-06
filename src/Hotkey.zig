const std = @import("std");
const testing = std.testing;
const Hotkey = @This();
const Mode = @import("Mode.zig");
const utils = @import("utils.zig");
const ModifierFlag = @import("Keycodes.zig").ModifierFlag;
const log = std.log.scoped(.hotkey_array_hashmap);

allocator: std.mem.Allocator,
flags: ModifierFlag = undefined,
key: u32 = undefined,
// Use ArrayHashMap for process name -> command mapping
mappings: std.StringArrayHashMapUnmanaged(ProcessCommand),
wildcard_command: ?ProcessCommand = null,
mode_list: std.AutoArrayHashMap(*Mode, void),

pub fn destroy(self: *Hotkey) void {
    // Free all keys (process names)
    var it = self.mappings.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        // Free command strings
        switch (entry.value_ptr.*) {
            .command => |str| self.allocator.free(str),
            else => {},
        }
    }
    self.mappings.deinit(self.allocator);

    // Free wildcard command if any
    if (self.wildcard_command) |cmd| {
        switch (cmd) {
            .command => |str| self.allocator.free(str),
            else => {},
        }
    }

    self.mode_list.deinit();
    self.allocator.destroy(self);
}

pub fn create(allocator: std.mem.Allocator) !*Hotkey {
    const hotkey = try allocator.create(Hotkey);
    hotkey.* = .{
        .allocator = allocator,
        .flags = ModifierFlag{},
        .key = 0,
        .mappings = .{},
        .wildcard_command = null,
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

// Context for looking up hotkeys from keyboard events
// This uses our custom modifier matching logic
pub const KeyboardLookupContext = struct {
    pub fn hash(_: @This(), key: Hotkey.KeyPress) u32 {
        // Must match the hash function used by HotkeyMap for lookup to work
        return key.key;
    }

    pub fn eql(_: @This(), keyboard: Hotkey.KeyPress, config: *Hotkey, _: usize) bool {
        // Match keyboard event against config hotkey
        return config.key == keyboard.key and hotkeyFlagsMatch(config.flags, keyboard.flags);
    }
};

/// Compare hotkey flags, handling left/right modifier logic
/// config = hotkey from config file, keyboard = event from keyboard
pub fn hotkeyFlagsMatch(config: ModifierFlag, keyboard: ModifierFlag) bool {
    // Match logic from original skhd:
    // If config has general modifier (alt), keyboard can have general, left, or right
    // If config has specific modifier (lalt), keyboard must match exactly

    const alt_match = if (config.alt)
        (keyboard.alt or keyboard.lalt or keyboard.ralt)
    else
        (config.lalt == keyboard.lalt and config.ralt == keyboard.ralt and config.alt == keyboard.alt);

    const cmd_match = if (config.cmd)
        (keyboard.cmd or keyboard.lcmd or keyboard.rcmd)
    else
        (config.lcmd == keyboard.lcmd and config.rcmd == keyboard.rcmd and config.cmd == keyboard.cmd);

    const ctrl_match = if (config.control)
        (keyboard.control or keyboard.lcontrol or keyboard.rcontrol)
    else
        (config.lcontrol == keyboard.lcontrol and config.rcontrol == keyboard.rcontrol and config.control == keyboard.control);

    const shift_match = if (config.shift)
        (keyboard.shift or keyboard.lshift or keyboard.rshift)
    else
        (config.lshift == keyboard.lshift and config.rshift == keyboard.rshift and config.shift == keyboard.shift);

    return alt_match and cmd_match and ctrl_match and shift_match and
        config.@"fn" == keyboard.@"fn" and
        config.nx == keyboard.nx;
}

pub const ProcessCommand = union(enum) {
    command: []const u8,
    forwarded: KeyPress,
    unbound: void,
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
    try writer.print("\n  process_mappings: {} entries", .{self.mappings.count()});
    try writer.print("\n}}", .{});
}

pub fn add_process_mapping(self: *Hotkey, process_name: []const u8, command: ProcessCommand) !void {
    // Handle wildcard mappings
    if (std.mem.eql(u8, process_name, "*")) {
        // Free old wildcard command if any
        if (self.wildcard_command) |old_cmd| {
            _ = old_cmd;
            return error.@"Wildcard command already exists";
            // switch (old_cmd) {
            //     .command => |str| self.allocator.free(str),
            //     else => {},
            // }
        }

        // Clone command for wildcard
        self.wildcard_command = switch (command) {
            .command => |str| blk: {
                const owned_str = try self.allocator.dupe(u8, str);
                break :blk ProcessCommand{ .command = owned_str };
            },
            else => command,
        };
        return;
    }

    // Create lowercase version of process name for storage
    const owned_name = try self.allocator.dupe(u8, process_name);
    errdefer self.allocator.free(owned_name);

    for (owned_name, 0..) |c, i| {
        owned_name[i] = std.ascii.toLower(c);
    }

    // Clone command if needed
    const owned_cmd = switch (command) {
        .command => |str| blk: {
            const owned_str = try self.allocator.dupe(u8, str);
            break :blk ProcessCommand{ .command = owned_str };
        },
        else => command,
    };

    // Put into hashmap
    try self.mappings.put(self.allocator, owned_name, owned_cmd);
}

pub fn find_command_for_process(self: *const Hotkey, process_name: []const u8) ?ProcessCommand {
    if (process_name.len == 0 or std.mem.eql(u8, process_name, "*")) {
        return self.wildcard_command;
    }

    // Create lowercase version for lookup
    var name_buf: [256]u8 = undefined;
    if (process_name.len > name_buf.len) return self.wildcard_command;

    for (process_name, 0..) |c, i| {
        name_buf[i] = std.ascii.toLower(c);
    }
    const lower_name = name_buf[0..process_name.len];

    // First try to find exact match
    if (self.mappings.get(lower_name)) |cmd| {
        return cmd;
    }

    // If no exact match, return wildcard
    return self.wildcard_command;
}

pub fn add_mode(self: *Hotkey, mode: *Mode) !void {
    if (self.mode_list.contains(mode)) {
        return error.@"Mode already exists in hotkey mode";
    }
    try self.mode_list.put(mode, {});
}

// Additional utility methods
pub fn getProcessCount(self: *const Hotkey) usize {
    return self.mappings.count();
}

test "ArrayHashMap hotkey implementation" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc);
    defer hotkey.destroy();

    hotkey.flags = ModifierFlag{ .alt = true };
    hotkey.key = 0x2;

    // Test the API
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

    // Test wildcard
    try hotkey.add_process_mapping("*", ProcessCommand{ .command = "echo default" });
    const unknown_cmd = hotkey.find_command_for_process("unknown");
    try std.testing.expect(unknown_cmd != null);
    try std.testing.expectEqualStrings("echo default", unknown_cmd.?.command);

    // Test count
    try std.testing.expectEqual(@as(usize, 3), hotkey.getProcessCount()); // firefox, chrome, terminal (wildcard is separate)
}

test "ArrayHashMap performance characteristics" {
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

    // Test some lookups
    const cmd_50 = hotkey.find_command_for_process("Process_50");
    try std.testing.expect(cmd_50 != null);
    try std.testing.expectEqualStrings("echo process_50", cmd_50.?.command);

    const cmd_99 = hotkey.find_command_for_process("PROCESS_99");
    try std.testing.expect(cmd_99 != null);
    try std.testing.expectEqualStrings("echo process_99", cmd_99.?.command);

    try std.testing.expectEqual(@as(usize, 100), hotkey.getProcessCount());
}

test "hotkeyFlagsMatch behavior" {
    // Test general modifier matching: config has general (alt), keyboard can have general, left, or right
    {
        const config = ModifierFlag{ .alt = true };
        const kb_general = ModifierFlag{ .alt = true };
        const kb_left = ModifierFlag{ .lalt = true };
        const kb_right = ModifierFlag{ .ralt = true };

        try testing.expect(hotkeyFlagsMatch(config, kb_general));
        try testing.expect(hotkeyFlagsMatch(config, kb_left));
        try testing.expect(hotkeyFlagsMatch(config, kb_right));
    }

    // Test specific modifier matching: config has specific (lalt), keyboard must match exactly
    {
        const config = ModifierFlag{ .lalt = true };
        const kb_general = ModifierFlag{ .alt = true };
        const kb_left = ModifierFlag{ .lalt = true };
        const kb_right = ModifierFlag{ .ralt = true };

        try testing.expect(!hotkeyFlagsMatch(config, kb_general));
        try testing.expect(hotkeyFlagsMatch(config, kb_left));
        try testing.expect(!hotkeyFlagsMatch(config, kb_right));
    }

    // Test multiple modifiers
    {
        const config = ModifierFlag{ .cmd = true, .shift = true };
        const kb_match = ModifierFlag{ .lcmd = true, .shift = true };
        const kb_no_match = ModifierFlag{ .lcmd = true }; // Missing shift

        try testing.expect(hotkeyFlagsMatch(config, kb_match));
        try testing.expect(!hotkeyFlagsMatch(config, kb_no_match));
    }
}
