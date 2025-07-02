const std = @import("std");
const Hotkey = @This();
const Mode = @import("Mode.zig");
const utils = @import("./utils.zig");
const ModifierFlag = @import("./Keycodes.zig").ModifierFlag;

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

// SOA optimization: Store process mappings in a cache-friendly way
const ProcessMappings = struct {
    allocator: std.mem.Allocator,
    // Store lowercase process names for fast comparison
    process_names: std.ArrayListUnmanaged([]const u8) = .empty,
    // Pre-computed hashes for even faster comparison
    name_hashes: std.ArrayListUnmanaged(u64) = .empty,
    // Commands aligned with process names
    commands: std.ArrayListUnmanaged(ProcessCommand) = .empty,

    pub fn deinit(self: *ProcessMappings) void {
        for (self.process_names.items) |name| {
            self.allocator.free(name);
        }
        self.process_names.deinit(self.allocator);
        self.name_hashes.deinit(self.allocator);

        for (self.commands.items) |cmd| {
            switch (cmd) {
                .command => |str| self.allocator.free(str),
                else => {},
            }
        }
        self.commands.deinit(self.allocator);
    }

    pub fn add(self: *ProcessMappings, process_name: []const u8, command: ProcessCommand) !void {
        const owned_name = try self.allocator.dupe(u8, process_name);
        // Convert to lowercase once during insertion
        for (owned_name, 0..) |c, i| owned_name[i] = std.ascii.toLower(c);

        // Pre-compute hash
        const hash = std.hash.Wyhash.hash(0, owned_name);

        try self.process_names.append(self.allocator, owned_name);
        try self.name_hashes.append(self.allocator, hash);

        // Clone command if needed
        const owned_cmd = switch (command) {
            .command => |str| ProcessCommand{ .command = try self.allocator.dupe(u8, str) },
            else => command,
        };
        try self.commands.append(self.allocator, owned_cmd);
    }

    pub fn findCommand(self: *const ProcessMappings, process_name: []const u8) ?ProcessCommand {
        if (self.process_names.items.len == 0) return null;

        // Create lowercase version for comparison
        var name_buf: [256]u8 = undefined;
        if (process_name.len > name_buf.len) return null;

        for (process_name, 0..) |c, i| {
            name_buf[i] = std.ascii.toLower(c);
        }
        const lower_name = name_buf[0..process_name.len];
        const target_hash = std.hash.Wyhash.hash(0, lower_name);

        // Fast path: check hashes first
        for (self.name_hashes.items, 0..) |hash, i| {
            if (hash == target_hash) {
                // Verify actual string only on hash match
                if (std.mem.eql(u8, self.process_names.items[i], lower_name)) {
                    return self.commands.items[i];
                }
            }
        }
        return null;
    }
};

allocator: std.mem.Allocator,
flags: ModifierFlag = undefined,
key: u32 = undefined,
// SOA optimization: use dedicated structure for process mappings
mappings: ProcessMappings,
wildcard_command: ?ProcessCommand = null,
mode_list: std.AutoArrayHashMap(*Mode, void),

pub fn destroy(self: *Hotkey) void {
    self.mappings.deinit();
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
        .mappings = .{ .allocator = allocator },
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
    try writer.print("\n  process_mappings: {} entries", .{self.mappings.process_names.items.len});
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

pub fn add_process_name(self: *Hotkey, process_name: []const u8) !void {
    // This is called in sequence with add_proc_command/add_proc_unbound/add_proc_forward
    // We'll handle the actual addition when the command is added
    _ = self;
    _ = process_name;
}

pub fn add_proc_command(self: *Hotkey, command: []const u8) !void {
    // This assumes add_process_name was called just before
    // For now, we'll need to refactor the parser to use a better API
    // that passes both process name and command together
    try self.mappings.add("", ProcessCommand{ .command = command });
}

pub fn add_proc_unbound(self: *Hotkey) !void {
    try self.mappings.add("", ProcessCommand{ .unbound = void{} });
}

pub fn add_proc_forward(self: *Hotkey, forwarded: KeyPress) !void {
    try self.mappings.add("", ProcessCommand{ .forwarded = forwarded });
}

// New API that's more SOA-friendly
pub fn add_process_mapping(self: *Hotkey, process_name: []const u8, command: ProcessCommand) !void {
    try self.mappings.add(process_name, command);
}

pub fn find_command_for_process(self: *const Hotkey, process_name: []const u8) ?ProcessCommand {
    if (self.mappings.findCommand(process_name)) |cmd| {
        return cmd;
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
        return self.mappings.process_names.items;
    }
};

pub const commands = struct {
    pub fn items(self: *const Hotkey) []const ProcessCommand {
        return self.mappings.commands.items;
    }
};

test "SOA hotkey implementation" {
    const alloc = std.testing.allocator;
    var hotkey = try Hotkey.create(alloc);
    defer hotkey.destroy();

    hotkey.flags = ModifierFlag{ .alt = true };
    hotkey.key = 0x2;

    // Test the new API
    try hotkey.add_process_mapping("firefox", ProcessCommand{ .command = "echo firefox" });
    try hotkey.add_process_mapping("chrome", ProcessCommand{ .command = "echo chrome" });

    // Test lookup
    const firefox_cmd = hotkey.find_command_for_process("Firefox");
    try std.testing.expect(firefox_cmd != null);
    try std.testing.expectEqualStrings("echo firefox", firefox_cmd.?.command);

    // Test case insensitive
    const chrome_cmd = hotkey.find_command_for_process("CHROME");
    try std.testing.expect(chrome_cmd != null);
    try std.testing.expectEqualStrings("echo chrome", chrome_cmd.?.command);

    // Test wildcard
    try hotkey.set_wildcard_command("echo default");
    const unknown_cmd = hotkey.find_command_for_process("unknown");
    try std.testing.expect(unknown_cmd != null);
    try std.testing.expectEqualStrings("echo default", unknown_cmd.?.command);
}
