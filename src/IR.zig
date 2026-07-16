const std = @import("std");

/// Intermediate Representation of parsed config
/// Contains unparsed/unresolved structures - just the raw parsed syntax
pub const IR = struct {
    allocator: std.mem.Allocator,

    /// Raw alias definitions (unparsed text)
    alias_defs: std.StringArrayHashMapUnmanaged(UnresolvedAlias) = .{},

    /// Unparsed hotkey definitions
    hotkey_defs: std.ArrayListUnmanaged(UnresolvedHotkey) = .{},

    /// Mode declarations (just names and capture flag)
    mode_decls: std.StringArrayHashMapUnmanaged(ModeDecl) = .{},

    /// Command template definitions (no aliases to resolve)
    command_defs: std.StringHashMapUnmanaged(CommandDef) = .{},

    /// Process group definitions (no aliases to resolve)
    process_groups: std.StringHashMapUnmanaged(ProcessGroup) = .{},

    /// Blacklist entries
    blacklist: std.ArrayListUnmanaged([]const u8) = .{},

    /// Shell path
    shell: [:0]const u8,

    pub fn init(allocator: std.mem.Allocator) !IR {
        const default_shell = "/bin/bash";
        const shell = if (std.posix.getenv("SHELL")) |env|
            try allocator.dupeZ(u8, env)
        else
            try allocator.dupeZ(u8, default_shell);

        return IR{
            .allocator = allocator,
            .shell = shell,
        };
    }

    pub fn deinit(self: *IR) void {
        // Free alias definitions
        var alias_it = self.alias_defs.iterator();
        while (alias_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.alias_defs.deinit(self.allocator);

        // Free hotkey definitions
        for (self.hotkey_defs.items) |*hotkey| {
            hotkey.deinit(self.allocator);
        }
        self.hotkey_defs.deinit(self.allocator);

        // Free mode declarations
        var mode_it = self.mode_decls.iterator();
        while (mode_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.mode_decls.deinit(self.allocator);

        // Free command definitions
        var cmd_it = self.command_defs.iterator();
        while (cmd_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.command_defs.deinit(self.allocator);

        // Free process groups
        var pg_it = self.process_groups.iterator();
        while (pg_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.process_groups.deinit(self.allocator);

        // Free blacklist
        for (self.blacklist.items) |entry| {
            self.allocator.free(entry);
        }
        self.blacklist.deinit(self.allocator);

        self.allocator.free(self.shell);
        self.* = undefined;
    }
};

/// Unparsed alias definition - stores text representation, not resolved values
pub const UnresolvedAlias = union(enum) {
    /// Modifier alias: ".alias $super cmd + alt" or ".alias $mega $super + shift"
    /// Stores the exact text after the alias name
    modifier: []const u8,

    /// Key alias: ".alias $grave 0x32" or ".alias $exclaim shift - 1"
    /// Stores the exact text after the alias name
    key: []const u8,

    /// Keysym alias: ".alias $nav cmd - h" or ".alias $tilde $super - grave"
    keysym: struct {
        modifier: ?[]const u8, // e.g., "cmd" or "$super" or null
        key: []const u8, // e.g., "h" or "grave" or "$other"
    },

    pub fn deinit(self: *UnresolvedAlias, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .modifier => |text| allocator.free(text),
            .key => |text| allocator.free(text),
            .keysym => |ks| {
                if (ks.modifier) |mod| allocator.free(mod);
                allocator.free(ks.key);
            },
        }
    }
};

/// Unparsed hotkey definition
pub const UnresolvedHotkey = struct {
    /// Mode names this hotkey belongs to
    modes: [][]const u8,

    /// Modifier text (unparsed): "cmd + alt" or "$mega" or null
    modifier: ?[]const u8 = null,

    /// Key text (unparsed): "t" or "$grave" or "0x32" or "'delete'"
    key: []const u8,

    /// Flags
    passthrough: bool = false,

    /// Mode activation
    activate_mode: ?[]const u8 = null,
    activate_command: ?[]const u8 = null,

    /// Wildcard commands/actions
    wildcard_command: ?[]const u8 = null,
    wildcard_forward: ?UnresolvedKeyPress = null,
    wildcard_unbound: bool = false,

    /// Process-specific actions
    process_actions: std.StringHashMapUnmanaged(ProcessAction) = .{},

    /// Source location for error reporting
    line: usize,
    file_path: ?[]const u8 = null,

    pub fn deinit(self: *UnresolvedHotkey, allocator: std.mem.Allocator) void {
        for (self.modes) |mode| allocator.free(mode);
        allocator.free(self.modes);
        if (self.modifier) |mod| allocator.free(mod);
        allocator.free(self.key);
        if (self.activate_mode) |mode| allocator.free(mode);
        if (self.activate_command) |cmd| allocator.free(cmd);
        if (self.wildcard_command) |cmd| allocator.free(cmd);
        if (self.wildcard_forward) |*fwd| fwd.deinit(allocator);

        var it = self.process_actions.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(allocator);
        }
        self.process_actions.deinit(allocator);

        if (self.file_path) |path| allocator.free(path);
        self.* = undefined;
    }
};

/// Unparsed key press for forwards
pub const UnresolvedKeyPress = struct {
    modifier: ?[]const u8,
    key: []const u8,

    pub fn deinit(self: *UnresolvedKeyPress, allocator: std.mem.Allocator) void {
        if (self.modifier) |mod| allocator.free(mod);
        allocator.free(self.key);
    }
};

/// Process-specific action
pub const ProcessAction = union(enum) {
    command: []const u8,
    forward: UnresolvedKeyPress,
    unbound: void,

    pub fn deinit(self: *ProcessAction, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .command => |cmd| allocator.free(cmd),
            .forward => |*fwd| fwd.deinit(allocator),
            .unbound => {},
        }
    }
};

/// Mode declaration
pub const ModeDecl = struct {
    capture: bool,
};

/// Command template definition (from Parser)
/// These don't contain aliases, so can be copied as-is
pub const CommandDef = struct {
    parts: []const []const u8,
    placeholders: []const u8,

    pub fn deinit(self: *CommandDef, allocator: std.mem.Allocator) void {
        for (self.parts) |part| {
            allocator.free(part);
        }
        allocator.free(self.parts);
        allocator.free(self.placeholders);
    }
};

/// Process group definition (from Parser)
/// These don't contain aliases, so can be copied as-is
pub const ProcessGroup = struct {
    processes: [][]const u8,

    pub fn deinit(self: *ProcessGroup, allocator: std.mem.Allocator) void {
        for (self.processes) |process| {
            allocator.free(process);
        }
        allocator.free(self.processes);
    }
};

// ========== TESTS ==========

test "IR init and deinit" {
    const allocator = std.testing.allocator;

    var ir = try IR.init(allocator);
    defer ir.deinit();

    try std.testing.expect(ir.alias_defs.count() == 0);
    try std.testing.expect(ir.hotkey_defs.items.len == 0);
    try std.testing.expect(ir.shell.len > 0);
}

test "IR add alias definition" {
    const allocator = std.testing.allocator;

    var ir = try IR.init(allocator);
    defer ir.deinit();

    const alias_name = try allocator.dupe(u8, "$super");
    const alias_value = UnresolvedAlias{ .modifier = try allocator.dupe(u8, "cmd + alt") };

    try ir.alias_defs.put(ir.allocator, alias_name, alias_value);

    try std.testing.expectEqual(@as(usize, 1), ir.alias_defs.count());

    const retrieved = ir.alias_defs.get("$super").?;
    try std.testing.expectEqualStrings("cmd + alt", retrieved.modifier);
}

test "IR add hotkey definition" {
    const allocator = std.testing.allocator;

    var ir = try IR.init(allocator);
    defer ir.deinit();

    const modes = try allocator.alloc([]const u8, 1);
    modes[0] = try allocator.dupe(u8, "default");

    const hotkey = UnresolvedHotkey{
        .modes = modes,
        .modifier = try allocator.dupe(u8, "cmd"),
        .key = try allocator.dupe(u8, "t"),
        .wildcard_command = try allocator.dupe(u8, "echo test"),
        .line = 1,
    };

    try ir.hotkey_defs.append(ir.allocator, hotkey);

    try std.testing.expectEqual(@as(usize, 1), ir.hotkey_defs.items.len);

    const retrieved = ir.hotkey_defs.items[0];
    try std.testing.expectEqualStrings("cmd", retrieved.modifier.?);
    try std.testing.expectEqualStrings("t", retrieved.key);
}
