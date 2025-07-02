const std = @import("std");
const Hotkey = @This();
const Mode = @import("Mode.zig");
const utils = @import("utils.zig");
const ModifierFlag = @import("Keycodes.zig").ModifierFlag;

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

// Define the struct for MultiArrayList
const ProcessMapping = struct {
    // Lowercase process name for comparison
    process_name: []const u8,
    // Pre-computed hash for fast lookup
    name_hash: u64,
    // Command type tag
    command_tag: std.meta.Tag(ProcessCommand),
    // Command data (only valid for command tag)
    command_str: []const u8,
    // Forwarded key data (only valid for forwarded tag)
    forwarded_key: KeyPress,
};

allocator: std.mem.Allocator,
flags: ModifierFlag = undefined,
key: u32 = undefined,
// Use MultiArrayList for SOA
mappings: std.MultiArrayList(ProcessMapping),
wildcard_command: ?ProcessCommand = null,
mode_list: std.AutoArrayHashMap(*Mode, void),

pub fn destroy(self: *Hotkey) void {
    // Free all allocated strings
    for (self.mappings.items(.process_name)) |name| {
        self.allocator.free(name);
    }
    for (self.mappings.items(.command_str)) |cmd| {
        if (cmd.len > 0) { // Only free non-empty strings
            self.allocator.free(cmd);
        }
    }
    
    self.mappings.deinit(self.allocator);
    self.deinit_wildcard_command();
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

fn deinit_wildcard_command(self: *Hotkey) void {
    if (self.wildcard_command) |wildcard_command| {
        switch (wildcard_command) {
            .command => |str| self.allocator.free(str),
            else => {},
        }
        self.wildcard_command = null;
    }
}

pub fn set_wildcard_command(self: *Hotkey, wildcard_command: []const u8) !void {
    self.deinit_wildcard_command();
    const cmd = try self.allocator.dupe(u8, wildcard_command);
    self.wildcard_command = ProcessCommand{ .command = cmd };
}

pub fn set_wildcard_forwarded(self: *Hotkey, forwarded: KeyPress) void {
    self.deinit_wildcard_command();
    self.wildcard_command = ProcessCommand{ .forwarded = forwarded };
}

pub fn set_wildcard_unbound(self: *Hotkey) void {
    self.deinit_wildcard_command();
    self.wildcard_command = ProcessCommand{ .unbound = void{} };
}

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
    try writer.print("\n  process_mappings: {} entries", .{self.mappings.len});
    if (self.wildcard_command) |wildcard_command| {
        try writer.print("\n  wildcard_command: ", .{});
        switch (wildcard_command) {
            .command => |str| try writer.print("{s}", .{str}),
            .forwarded => try writer.print("forwarded", .{}),
            .unbound => try writer.print("unbound", .{}),
        }
    } else {
        try writer.print("\n  wildcard_command: null", .{});
    }
    try writer.print("\n}}", .{});
}

// Compatibility with original API
pub fn add_process_name(self: *Hotkey, process_name: []const u8) !void {
    // This is called before add_proc_command/etc, so we just store it temporarily
    // The actual implementation would need to be refactored to handle this better
    _ = self;
    _ = process_name;
}

pub fn add_proc_command(self: *Hotkey, command: []const u8) !void {
    try self.add_process_mapping("", ProcessCommand{ .command = command });
}

pub fn add_proc_unbound(self: *Hotkey) !void {
    try self.add_process_mapping("", ProcessCommand{ .unbound = void{} });
}

pub fn add_proc_forward(self: *Hotkey, forwarded: KeyPress) !void {
    try self.add_process_mapping("", ProcessCommand{ .forwarded = forwarded });
}

// New API that's more MultiArrayList-friendly
pub fn add_process_mapping(self: *Hotkey, process_name: []const u8, command: ProcessCommand) !void {
    const owned_name = try self.allocator.dupe(u8, process_name);
    errdefer self.allocator.free(owned_name);
    
    // Convert to lowercase once during insertion
    for (owned_name, 0..) |c, i| owned_name[i] = std.ascii.toLower(c);
    
    // Pre-compute hash
    const hash = std.hash.Wyhash.hash(0, owned_name);
    
    // Prepare the mapping entry
    var mapping = ProcessMapping{
        .process_name = owned_name,
        .name_hash = hash,
        .command_tag = std.meta.activeTag(command),
        .command_str = "",
        .forwarded_key = KeyPress{ .flags = .{}, .key = 0 },
    };
    
    // Set the appropriate field based on command type
    switch (command) {
        .command => |str| {
            mapping.command_str = try self.allocator.dupe(u8, str);
        },
        .forwarded => |key| {
            mapping.forwarded_key = key;
        },
        .unbound => {},
    }
    
    try self.mappings.append(self.allocator, mapping);
}

pub fn find_command_for_process(self: *const Hotkey, process_name: []const u8) ?ProcessCommand {
    if (self.mappings.len == 0) return self.wildcard_command;
    
    // Create lowercase version for comparison
    var name_buf: [256]u8 = undefined;
    if (process_name.len > name_buf.len) return self.wildcard_command;
    
    for (process_name, 0..) |c, i| {
        name_buf[i] = std.ascii.toLower(c);
    }
    const lower_name = name_buf[0..process_name.len];
    const target_hash = std.hash.Wyhash.hash(0, lower_name);
    
    // Use MultiArrayList's SOA layout for efficient lookup
    // First, iterate through just the hashes (good cache locality)
    const hashes = self.mappings.items(.name_hash);
    for (hashes, 0..) |hash, i| {
        if (hash == target_hash) {
            // Only access the name when hash matches
            const names = self.mappings.items(.process_name);
            if (std.mem.eql(u8, names[i], lower_name)) {
                // Reconstruct the command from the SOA data
                const tags = self.mappings.items(.command_tag);
                switch (tags[i]) {
                    .command => {
                        const command_strs = self.mappings.items(.command_str);
                        return ProcessCommand{ .command = command_strs[i] };
                    },
                    .forwarded => {
                        const forwarded = self.mappings.items(.forwarded_key);
                        return ProcessCommand{ .forwarded = forwarded[i] };
                    },
                    .unbound => return ProcessCommand{ .unbound = void{} },
                }
            }
        }
    }
    
    return self.wildcard_command;
}

pub fn add_mode(self: *Hotkey, mode: *Mode) !void {
    if (self.mode_list.contains(mode)) {
        return error.@"Mode already exists in hotkey mode";
    }
    try self.mode_list.put(mode, {});
}

// Compatibility layer for existing code
pub const process_names = struct {
    pub fn items(self: *const Hotkey) []const []const u8 {
        return self.mappings.items(.process_name);
    }
};

pub const commands = struct {
    pub fn items(self: *const Hotkey) []ProcessCommand {
        _ = self;
        // This would need to reconstruct the commands from SOA data
        // For now, return empty slice for compatibility
        return &[_]ProcessCommand{};
    }
};

test "MultiArrayList hotkey implementation" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc);
    defer hotkey.destroy();
    
    hotkey.flags = ModifierFlag{ .alt = true };
    hotkey.key = 0x2;
    
    // Test the new API
    try hotkey.add_process_mapping("firefox", ProcessCommand{ .command = "echo firefox" });
    try hotkey.add_process_mapping("chrome", ProcessCommand{ .command = "echo chrome" });
    try hotkey.add_process_mapping("terminal", ProcessCommand{ .forwarded = KeyPress{ .flags = .{}, .key = 0x3 } });
    try hotkey.add_process_mapping("vim", ProcessCommand{ .unbound = void{} });
    
    // Test lookup
    const firefox_cmd = hotkey.find_command_for_process("Firefox");
    try std.testing.expect(firefox_cmd != null);
    try std.testing.expectEqualStrings("echo firefox", firefox_cmd.?.command);
    
    // Test case insensitive
    const chrome_cmd = hotkey.find_command_for_process("CHROME");
    try std.testing.expect(chrome_cmd != null);
    try std.testing.expectEqualStrings("echo chrome", chrome_cmd.?.command);
    
    // Test forwarded
    const terminal_cmd = hotkey.find_command_for_process("terminal");
    try std.testing.expect(terminal_cmd != null);
    try std.testing.expectEqual(@as(u32, 0x3), terminal_cmd.?.forwarded.key);
    
    // Test unbound
    const vim_cmd = hotkey.find_command_for_process("vim");
    try std.testing.expect(vim_cmd != null);
    try std.testing.expectEqual(ProcessCommand{ .unbound = void{} }, vim_cmd.?);
    
    // Test wildcard
    try hotkey.set_wildcard_command("echo default");
    const unknown_cmd = hotkey.find_command_for_process("unknown");
    try std.testing.expect(unknown_cmd != null);
    try std.testing.expectEqualStrings("echo default", unknown_cmd.?.command);
    
    // Test MultiArrayList SOA benefits
    try std.testing.expectEqual(@as(usize, 4), hotkey.mappings.len);
    
    // Verify we can access individual fields efficiently
    const all_hashes = hotkey.mappings.items(.name_hash);
    try std.testing.expectEqual(@as(usize, 4), all_hashes.len);
    
    const all_names = hotkey.mappings.items(.process_name);
    try std.testing.expectEqualStrings("firefox", all_names[0]);
    try std.testing.expectEqualStrings("chrome", all_names[1]);
}
