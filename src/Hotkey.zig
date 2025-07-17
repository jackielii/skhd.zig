const std = @import("std");
const testing = std.testing;
const Hotkey = @This();
const Mode = @import("Mode.zig");
const utils = @import("utils.zig");
const ModifierFlag = @import("Keycodes.zig").ModifierFlag;
const log = std.log.scoped(.hotkey_array_hashmap);

// Error sets for better type safety
pub const ProcessCommandError = error{
    ProcessCommandAlreadyExists,
    WildcardCommandAlreadyExists,
    OutOfMemory,
};

allocator: std.mem.Allocator,
flags: ModifierFlag = .{},
key: u32 = 0,
wildcard_command: ?ProcessCommand = null,
// Use ArrayHashMap for process name -> command mapping
mappings: std.StringArrayHashMapUnmanaged(ProcessCommand) = .empty,
mode_list: std.AutoArrayHashMapUnmanaged(*Mode, void) = .empty,

pub fn destroy(self: *Hotkey) void {
    var it = self.mappings.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        entry.value_ptr.*.deinit(self.allocator);
    }
    self.mappings.deinit(self.allocator);

    // Free wildcard command if any
    if (self.wildcard_command) |cmd| {
        cmd.deinit(self.allocator);
    }

    self.mode_list.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn create(allocator: std.mem.Allocator) !*Hotkey {
    const hotkey = try allocator.create(Hotkey);
    hotkey.* = .{
        .allocator = allocator,
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
    command: [:0]const u8,
    forwarded: KeyPress,
    unbound: void,
    activation: Activation,

    pub const Activation = struct {
        mode_name: []const u8,
        command: ?[:0]const u8 = null,

        fn eql(self: Activation, other: Activation) bool {
            if (!std.mem.eql(u8, self.mode_name, other.mode_name)) return false;
            if (self.command == null and other.command == null) return true;
            if (self.command != null and other.command != null) {
                return std.mem.eql(u8, self.command.?, other.command.?);
            }
            return false;
        }
    };

    /// Create a command variant with a duplicated null-terminated string
    pub fn initCommand(allocator: std.mem.Allocator, cmd: []const u8) !ProcessCommand {
        return ProcessCommand{ .command = try allocator.dupeZ(u8, cmd) };
    }

    /// Create a forwarded variant
    pub fn initForwarded(key_press: KeyPress) ProcessCommand {
        return ProcessCommand{ .forwarded = key_press };
    }

    /// Create an unbound variant
    pub fn initUnbound() ProcessCommand {
        return ProcessCommand{ .unbound = {} };
    }

    /// Create an activation variant with a duplicated string and optional command
    pub fn initActivation(allocator: std.mem.Allocator, mode_name: []const u8, cmd: ?[]const u8) !ProcessCommand {
        return ProcessCommand{ .activation = .{
            .mode_name = try allocator.dupe(u8, mode_name),
            .command = if (cmd) |c| try allocator.dupeZ(u8, c) else null,
        } };
    }

    /// Free any owned memory
    pub fn deinit(self: ProcessCommand, allocator: std.mem.Allocator) void {
        switch (self) {
            .command => |str| allocator.free(str),
            .activation => |act| {
                allocator.free(act.mode_name);
                if (act.command) |cmd| allocator.free(cmd);
            },
            else => {},
        }
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
    try writer.print("\n  process_mappings: {} entries", .{self.mappings.count()});
    try writer.print("\n}}", .{});
}

pub fn add_process_command(self: *Hotkey, process_name: []const u8, command: []const u8) ProcessCommandError!void {
    const owned_cmd = try ProcessCommand.initCommand(self.allocator, command);
    errdefer owned_cmd.deinit(self.allocator);

    if (std.mem.eql(u8, process_name, "*")) {
        if (self.wildcard_command) |_| {
            return error.WildcardCommandAlreadyExists;
        }

        self.wildcard_command = owned_cmd;
        return;
    }

    const owned_name = try self.toLowercaseOwned(process_name);
    errdefer self.allocator.free(owned_name);

    // Check if we're replacing an existing mapping
    if (self.mappings.get(owned_name)) |existing_cmd| {
        if (std.meta.activeTag(existing_cmd) == ProcessCommand.command and std.mem.eql(u8, existing_cmd.command, owned_cmd.command)) {
            self.allocator.free(owned_name);
            owned_cmd.deinit(self.allocator);
            return;
        }
        return error.ProcessCommandAlreadyExists;
    }

    // Put into hashmap
    try self.mappings.put(self.allocator, owned_name, owned_cmd);
}

fn toLowercaseOwned(self: *Hotkey, process_name: []const u8) ![]const u8 {
    const owned_name = try self.allocator.dupe(u8, process_name);
    for (owned_name, 0..) |c, i| {
        owned_name[i] = std.ascii.toLower(c);
    }
    return owned_name;
}

pub fn add_process_forward(self: *Hotkey, process_name: []const u8, key_press: KeyPress) ProcessCommandError!void {
    const owned_cmd = ProcessCommand.initForwarded(key_press);

    if (std.mem.eql(u8, process_name, "*")) {
        if (self.wildcard_command) |_| {
            return error.WildcardCommandAlreadyExists;
        }

        self.wildcard_command = owned_cmd;
        return;
    }

    const owned_name = try self.toLowercaseOwned(process_name);
    errdefer self.allocator.free(owned_name);

    // Check if we're replacing an existing mapping
    if (self.mappings.get(owned_name)) |existing_cmd| {
        if (std.meta.activeTag(existing_cmd) == ProcessCommand.forwarded and
            std.meta.eql(existing_cmd.forwarded, owned_cmd.forwarded))
        {
            self.allocator.free(owned_name);
            return; // No need to replace if it's the same
        }
        return error.ProcessCommandAlreadyExists;
    }

    // Put into hashmap
    try self.mappings.put(self.allocator, owned_name, owned_cmd);
}

pub fn add_process_unbound(self: *Hotkey, process_name: []const u8) ProcessCommandError!void {
    const owned_cmd = ProcessCommand.initUnbound();

    if (std.mem.eql(u8, process_name, "*")) {
        if (self.wildcard_command) |_| {
            return error.WildcardCommandAlreadyExists;
        }

        self.wildcard_command = owned_cmd;
        return;
    }

    const owned_name = try self.toLowercaseOwned(process_name);
    errdefer self.allocator.free(owned_name);

    // Check if we're replacing an existing mapping
    if (self.mappings.get(owned_name)) |existing_cmd| {
        if (std.meta.activeTag(existing_cmd) == ProcessCommand.unbound) {
            self.allocator.free(owned_name);
            return; // No need to replace if it's already unbound
        }
        return error.ProcessCommandAlreadyExists;
    }

    // Put into hashmap
    try self.mappings.put(self.allocator, owned_name, owned_cmd);
}

pub fn add_process_activation(self: *Hotkey, process_name: []const u8, mode_name: []const u8, cmd: ?[]const u8) ProcessCommandError!void {
    const owned_cmd = try ProcessCommand.initActivation(self.allocator, mode_name, cmd);
    errdefer owned_cmd.deinit(self.allocator);

    if (std.mem.eql(u8, process_name, "*")) {
        if (self.wildcard_command) |_| {
            return error.WildcardCommandAlreadyExists;
        }

        self.wildcard_command = owned_cmd;
        return;
    }

    const owned_name = try self.toLowercaseOwned(process_name);
    errdefer self.allocator.free(owned_name);

    // Check if we're replacing an existing mapping
    if (self.mappings.get(owned_name)) |existing_cmd| {
        if (std.meta.activeTag(existing_cmd) == ProcessCommand.activation and existing_cmd.activation.eql(owned_cmd.activation)) {
            self.allocator.free(owned_name);
            owned_cmd.deinit(self.allocator);
            return; // No need to replace if it's the same
        }
        return error.ProcessCommandAlreadyExists;
    }

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
        return error.ModeAlreadyExistsInHotkey;
    }
    try self.mode_list.put(self.allocator, mode, {});
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
    try hotkey.add_process_command("firefox", "echo firefox");
    try hotkey.add_process_command("chrome", "echo chrome");
    try hotkey.add_process_forward("terminal", KeyPress{ .flags = .{}, .key = 0x24 });

    // Test lookup
    const firefox_cmd = hotkey.find_command_for_process("Firefox");
    try std.testing.expect(firefox_cmd != null);
    try std.testing.expectEqualStrings("echo firefox", firefox_cmd.?.command);

    // Test case insensitive
    const chrome_cmd = hotkey.find_command_for_process("CHROME");
    try std.testing.expect(chrome_cmd != null);
    try std.testing.expectEqualStrings("echo chrome", chrome_cmd.?.command);

    // Test wildcard
    try hotkey.add_process_command("*", "echo default");
    const unknown_cmd = hotkey.find_command_for_process("unknown");
    try std.testing.expect(unknown_cmd != null);
    try std.testing.expectEqualStrings("echo default", unknown_cmd.?.command);

    // Test count
    try std.testing.expectEqual(@as(usize, 3), hotkey.getProcessCount()); // firefox, chrome, terminal (wildcard is separate)
}

test "hotkey initialization" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc);
    defer hotkey.destroy();

    // Test that flags are properly initialized to empty
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(hotkey.flags)));

    // Test that key is properly initialized to 0
    try std.testing.expectEqual(@as(u32, 0), hotkey.key);

    // Test that other fields are properly initialized
    try std.testing.expectEqual(@as(?ProcessCommand, null), hotkey.wildcard_command);
    try std.testing.expectEqual(@as(usize, 0), hotkey.mappings.count());
    try std.testing.expectEqual(@as(usize, 0), hotkey.mode_list.count());
}

test "add_process returns error on duplicate" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc);
    defer hotkey.destroy();

    // First mapping should succeed
    try hotkey.add_process_command("firefox", "echo firefox");

    // Duplicate mapping should fail
    const result = hotkey.add_process_command("firefox", "echo firefox2");
    try std.testing.expectError(error.ProcessCommandAlreadyExists, result);

    // Case insensitive duplicate should also fail
    const result2 = hotkey.add_process_command("FIREFOX", "echo firefox3");
    try std.testing.expectError(error.ProcessCommandAlreadyExists, result2);

    // Original command should still be there
    const cmd = hotkey.find_command_for_process("firefox");
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings("echo firefox", cmd.?.command);

    // Test wildcard duplicate
    try hotkey.add_process_command("*", "echo wildcard");
    const wildcard_result = hotkey.add_process_command("*", "echo wildcard2");
    try std.testing.expectError(error.WildcardCommandAlreadyExists, wildcard_result);

    // Original wildcard should still be there
    const wildcard_cmd = hotkey.find_command_for_process("unknown_process");
    try std.testing.expect(wildcard_cmd != null);
    try std.testing.expectEqualStrings("echo wildcard", wildcard_cmd.?.command);
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

        try hotkey.add_process_command(name, cmd);
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

test "duplicate commands allowed if identical" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc);
    defer hotkey.destroy();

    // Test duplicate command with same content is allowed
    try hotkey.add_process_command("firefox", "echo firefox");
    // Adding the exact same command should succeed silently
    try hotkey.add_process_command("firefox", "echo firefox");

    // Verify only one entry exists
    try std.testing.expectEqual(@as(usize, 1), hotkey.getProcessCount());
    const cmd = hotkey.find_command_for_process("firefox");
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings("echo firefox", cmd.?.command);

    // Test with case-insensitive duplicate
    try hotkey.add_process_command("FIREFOX", "echo firefox");
    try std.testing.expectEqual(@as(usize, 1), hotkey.getProcessCount());

    // But different command should fail
    const result = hotkey.add_process_command("firefox", "echo different");
    try std.testing.expectError(error.ProcessCommandAlreadyExists, result);
}

test "duplicate forwards allowed if identical" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc);
    defer hotkey.destroy();

    const key_press = KeyPress{ .flags = .{ .cmd = true }, .key = 0x24 };

    // First forward should succeed
    try hotkey.add_process_forward("terminal", key_press);
    // Adding the exact same forward should succeed silently
    try hotkey.add_process_forward("terminal", key_press);

    // Verify only one entry exists
    try std.testing.expectEqual(@as(usize, 1), hotkey.getProcessCount());
    const cmd = hotkey.find_command_for_process("terminal");
    try std.testing.expect(cmd != null);
    try std.testing.expect(cmd.? == .forwarded);
    try std.testing.expect(std.meta.eql(cmd.?.forwarded, key_press));

    // Different forward should fail
    const different_key = KeyPress{ .flags = .{ .alt = true }, .key = 0x25 };
    const result = hotkey.add_process_forward("terminal", different_key);
    try std.testing.expectError(error.ProcessCommandAlreadyExists, result);
}

test "duplicate unbound allowed if identical" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc);
    defer hotkey.destroy();

    // First unbound should succeed
    try hotkey.add_process_unbound("notepad");
    // Adding the same unbound should succeed silently
    try hotkey.add_process_unbound("notepad");

    // Verify only one entry exists
    try std.testing.expectEqual(@as(usize, 1), hotkey.getProcessCount());
    const cmd = hotkey.find_command_for_process("notepad");
    try std.testing.expect(cmd != null);
    try std.testing.expect(cmd.? == .unbound);

    // Case insensitive duplicate should also work
    try hotkey.add_process_unbound("NOTEPAD");
    try std.testing.expectEqual(@as(usize, 1), hotkey.getProcessCount());

    // But changing from unbound to command should fail
    const result = hotkey.add_process_command("notepad", "echo notepad");
    try std.testing.expectError(error.ProcessCommandAlreadyExists, result);
}

test "duplicate activation allowed if identical" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc);
    defer hotkey.destroy();

    // Test activation without command
    try hotkey.add_process_activation("vscode", "insert", null);
    try hotkey.add_process_activation("vscode", "insert", null);

    try std.testing.expectEqual(@as(usize, 1), hotkey.getProcessCount());
    const cmd = hotkey.find_command_for_process("vscode");
    try std.testing.expect(cmd != null);
    try std.testing.expect(cmd.? == .activation);
    try std.testing.expectEqualStrings("insert", cmd.?.activation.mode_name);
    try std.testing.expect(cmd.?.activation.command == null);

    // Test activation with command
    try hotkey.add_process_activation("sublime", "visual", "echo visual mode");
    try hotkey.add_process_activation("sublime", "visual", "echo visual mode");

    try std.testing.expectEqual(@as(usize, 2), hotkey.getProcessCount());
    const cmd2 = hotkey.find_command_for_process("sublime");
    try std.testing.expect(cmd2 != null);
    try std.testing.expect(cmd2.? == .activation);
    try std.testing.expectEqualStrings("visual", cmd2.?.activation.mode_name);
    try std.testing.expectEqualStrings("echo visual mode", cmd2.?.activation.command.?);

    // Different mode name should fail
    const result = hotkey.add_process_activation("vscode", "normal", null);
    try std.testing.expectError(error.ProcessCommandAlreadyExists, result);

    // Different command should fail
    const result2 = hotkey.add_process_activation("sublime", "visual", "echo different");
    try std.testing.expectError(error.ProcessCommandAlreadyExists, result2);
}

test "wildcard duplicate handling" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc);
    defer hotkey.destroy();

    // Test wildcard command duplicate
    try hotkey.add_process_command("*", "echo wildcard");
    const result = hotkey.add_process_command("*", "echo wildcard");
    // Wildcard doesn't allow duplicates even if identical
    try std.testing.expectError(error.WildcardCommandAlreadyExists, result);

    // Test wildcard forward
    var hotkey2 = try Hotkey.create(alloc);
    defer hotkey2.destroy();

    const key_press = KeyPress{ .flags = .{}, .key = 0x24 };
    try hotkey2.add_process_forward("*", key_press);
    const result2 = hotkey2.add_process_forward("*", key_press);
    try std.testing.expectError(error.WildcardCommandAlreadyExists, result2);

    // Test wildcard unbound
    var hotkey3 = try Hotkey.create(alloc);
    defer hotkey3.destroy();

    try hotkey3.add_process_unbound("*");
    const result3 = hotkey3.add_process_unbound("*");
    try std.testing.expectError(error.WildcardCommandAlreadyExists, result3);

    // Test wildcard activation
    var hotkey4 = try Hotkey.create(alloc);
    defer hotkey4.destroy();

    try hotkey4.add_process_activation("*", "mode", "cmd");
    const result4 = hotkey4.add_process_activation("*", "mode", "cmd");
    try std.testing.expectError(error.WildcardCommandAlreadyExists, result4);
}

test "mixed duplicate types should fail" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc);
    defer hotkey.destroy();

    // Add a command first
    try hotkey.add_process_command("app", "echo app");

    // Try to add forward for same app - should fail
    const key_press = KeyPress{ .flags = .{}, .key = 0x24 };
    const result1 = hotkey.add_process_forward("app", key_press);
    try std.testing.expectError(error.ProcessCommandAlreadyExists, result1);

    // Try to add unbound for same app - should fail
    const result2 = hotkey.add_process_unbound("app");
    try std.testing.expectError(error.ProcessCommandAlreadyExists, result2);

    // Try to add activation for same app - should fail
    const result3 = hotkey.add_process_activation("app", "mode", null);
    try std.testing.expectError(error.ProcessCommandAlreadyExists, result3);

    // Verify original command is still there
    try std.testing.expectEqual(@as(usize, 1), hotkey.getProcessCount());
    const cmd = hotkey.find_command_for_process("app");
    try std.testing.expect(cmd != null);
    try std.testing.expect(cmd.? == .command);
    try std.testing.expectEqualStrings("echo app", cmd.?.command);
}
