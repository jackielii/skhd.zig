const std = @import("std");
const IR = @import("IR.zig");
const Mappings = @import("Mappings.zig");
const Mode = @import("Mode.zig");
const Hotkey = @import("Hotkey.zig");
const ModifierFlag = @import("Keycodes.zig").ModifierFlag;
const Keycodes = @import("Keycodes.zig");

pub const CompileError = error{
    UndefinedAlias,
    CircularAliasReference,
    AliasTooDeep,
    AliasTypeMismatch,
    DuplicateHotkey,
    InvalidModifier,
    InvalidKey,
    UndefinedMode,
    BlacklistEntryAlreadyExists,
    ModeAlreadyExistsInHotkey,
    ProcessCommandAlreadyExists,
    ProcessForwardAlreadyExists,
    ProcessUnboundAlreadyExists,
    WildcardCommandAlreadyExists,
    DuplicateHotkeyInMode,
    OutOfMemory,
};

pub const CompileErrorInfo = struct {
    message: []const u8,
    line: usize,
    file_path: ?[]const u8,

    pub fn deinit(self: *CompileErrorInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.file_path) |path| allocator.free(path);
    }
};

pub const Compiler = struct {
    allocator: std.mem.Allocator,
    keycodes: *Keycodes,
    ir: *IR.IR,
    error_info: ?CompileErrorInfo = null,

    pub fn init(allocator: std.mem.Allocator, keycodes: *Keycodes, ir: *IR.IR) Compiler {
        return .{
            .allocator = allocator,
            .keycodes = keycodes,
            .ir = ir,
        };
    }

    pub fn deinit(self: *Compiler) void {
        if (self.error_info) |*err| {
            err.deinit(self.allocator);
        }
    }

    /// Compile IR into Mappings
    pub fn compile(self: *Compiler, mappings: *Mappings) CompileError!void {
        // Create modes from declarations
        try self.createModes(mappings);

        // Compile all hotkey definitions
        for (self.ir.hotkey_defs.items) |unresolved| {
            self.compileHotkey(unresolved, mappings) catch |err| {
                // If error_info is already set, return the error
                if (self.error_info != null) {
                    return err;
                }
                return err;
            };
        }

        // Set shell
        try mappings.set_shell(self.ir.shell);

        // Add blacklist entries
        for (self.ir.blacklist.items) |entry| {
            try mappings.add_blacklist(entry);
        }

        // Note: command_defs and process_groups stay in IR/Parser
        // They're used during parsing/compilation but not stored in final Mappings
    }

    fn createModes(self: *Compiler, mappings: *Mappings) CompileError!void {
        // Always create default mode
        if (!self.ir.mode_decls.contains("default")) {
            const default_mode = try Mode.init(mappings.allocator, "default");
            const key = try mappings.allocator.dupe(u8, "default");
            try mappings.mode_map.put(mappings.allocator, key, default_mode);
        }

        // Create declared modes
        var it = self.ir.mode_decls.iterator();
        while (it.next()) |entry| {
            const mode_name = entry.key_ptr.*;
            const mode_decl = entry.value_ptr.*;

            const key = try mappings.allocator.dupe(u8, mode_name);
            var mode = try Mode.init(mappings.allocator, mode_name); // Mode.init will dupe internally
            mode.capture = mode_decl.capture;
            try mappings.mode_map.put(mappings.allocator, key, mode);
        }
    }

    fn compileHotkey(self: *Compiler, unresolved: IR.UnresolvedHotkey, mappings: *Mappings) CompileError!void {
        // Create hotkey
        var hotkey = try Hotkey.create(self.allocator);
        errdefer hotkey.destroy();

        // Resolve and set modifier flags
        if (unresolved.modifier) |mod_text| {
            hotkey.flags = try self.resolveModifier(mod_text, unresolved.line, unresolved.file_path);
        }

        // Resolve and set key
        const key_result = try self.resolveKey(unresolved.key, unresolved.line, unresolved.file_path);
        hotkey.key = key_result.key;
        hotkey.flags = hotkey.flags.merge(key_result.flags);

        // Set passthrough flag
        hotkey.flags.passthrough = unresolved.passthrough;

        // Handle mode activation
        if (unresolved.activate_mode) |mode_name| {
            const mode = mappings.mode_map.getPtr(mode_name) orelse {
                return self.setError(
                    try std.fmt.allocPrint(self.allocator, "Undefined mode '{s}'", .{mode_name}),
                    unresolved.line,
                    unresolved.file_path,
                    error.UndefinedMode,
                );
            };
            try hotkey.add_mode(mode);

            if (unresolved.activate_command) |cmd| {
                const cmd_copy = try self.allocator.dupe(u8, cmd);
                try hotkey.add_process_command("*", cmd_copy);
            }
        } else {
            // Add to specified modes
            for (unresolved.modes) |mode_name| {
                const mode = mappings.mode_map.getPtr(mode_name) orelse {
                    return self.setError(
                        try std.fmt.allocPrint(self.allocator, "Undefined mode '{s}'", .{mode_name}),
                        unresolved.line,
                        unresolved.file_path,
                        error.UndefinedMode,
                    );
                };
                try hotkey.add_mode(mode);
            }
        }

        // Set wildcard command
        if (unresolved.wildcard_command) |cmd| {
            const cmd_copy = try self.allocator.dupe(u8, cmd);
            try hotkey.add_process_command("*", cmd_copy);
        }

        // Set wildcard forward
        if (unresolved.wildcard_forward) |fwd| {
            const keypress = try self.resolveKeyPress(fwd, unresolved.line, unresolved.file_path);
            try hotkey.add_process_forward("*", keypress);
        }

        // Set wildcard unbound
        if (unresolved.wildcard_unbound) {
            try hotkey.add_process_unbound("*");
        }

        // Set process-specific actions
        var proc_it = unresolved.process_actions.iterator();
        while (proc_it.next()) |entry| {
            const process_name = entry.key_ptr.*;
            const action = entry.value_ptr.*;

            switch (action) {
                .command => |cmd| {
                    const cmd_copy = try self.allocator.dupe(u8, cmd);
                    try hotkey.add_process_command(process_name, cmd_copy);
                },
                .forward => |fwd| {
                    const keypress = try self.resolveKeyPress(fwd, unresolved.line, unresolved.file_path);
                    try hotkey.add_process_forward(process_name, keypress);
                },
                .unbound => {
                    try hotkey.add_process_unbound(process_name);
                },
            }
        }

        // Add hotkey to mappings
        try mappings.add_hotkey(hotkey);
    }

    /// Resolve modifier text to ModifierFlag
    /// Handles: "cmd + alt", "$mega", "$super + shift", etc.
    fn resolveModifier(self: *Compiler, text: []const u8, line: usize, file_path: ?[]const u8) CompileError!ModifierFlag {
        var visited = std.ArrayList([]const u8).init(self.allocator);
        defer visited.deinit();
        return self.resolveModifierWithVisited(text, &visited, line, file_path);
    }

    fn resolveModifierWithVisited(self: *Compiler, text: []const u8, visited: *std.ArrayList([]const u8), line: usize, file_path: ?[]const u8) CompileError!ModifierFlag {
        var flags: ModifierFlag = .{};

        // Split by " + " and process each part
        var iter = std.mem.splitSequence(u8, text, " + ");
        while (iter.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " ");
            if (trimmed.len == 0) continue;

            if (trimmed[0] == '$') {
                // Alias reference
                const alias_flags = try self.resolveModifierAlias(trimmed, visited, line, file_path);
                flags = flags.merge(alias_flags);
            } else {
                // Built-in modifier
                if (ModifierFlag.get(trimmed)) |mod_flags| {
                    flags = flags.merge(mod_flags);
                } else {
                    return self.setError(
                        try std.fmt.allocPrint(self.allocator, "Unknown modifier '{s}'", .{trimmed}),
                        line,
                        file_path,
                        error.InvalidModifier,
                    );
                }
            }
        }

        return flags;
    }

    fn resolveModifierAlias(self: *Compiler, alias_name: []const u8, visited: *std.ArrayList([]const u8), line: usize, file_path: ?[]const u8) CompileError!ModifierFlag {
        // Check for circular reference
        for (visited.items) |name| {
            if (std.mem.eql(u8, name, alias_name)) {
                return self.setError(
                    try std.fmt.allocPrint(self.allocator, "Circular alias reference: {s}", .{alias_name}),
                    line,
                    file_path,
                    error.CircularAliasReference,
                );
            }
        }

        // Check depth limit
        if (visited.items.len >= 10) {
            return self.setError(
                try std.fmt.allocPrint(self.allocator, "Alias nesting too deep (max 10 levels)", .{}),
                line,
                file_path,
                error.AliasTooDeep,
            );
        }

        try visited.append(alias_name);

        // Look up alias
        const alias = self.ir.alias_defs.get(alias_name) orelse {
            return self.setError(
                try std.fmt.allocPrint(self.allocator, "Undefined alias '{s}'", .{alias_name}),
                line,
                file_path,
                error.UndefinedAlias,
            );
        };

        return switch (alias) {
            .modifier => |text| try self.resolveModifierWithVisited(text, visited, line, file_path),
            .keysym => |ks| if (ks.modifier) |mod|
                try self.resolveModifierWithVisited(mod, visited, line, file_path)
            else
                ModifierFlag{},
            .key => |text| {
                // Key alias like "shift - 1" can provide modifiers
                if (std.mem.indexOf(u8, text, " - ")) |dash_pos| {
                    const mod_part = text[0..dash_pos];
                    return try self.resolveModifierWithVisited(mod_part, visited, line, file_path);
                }
                return ModifierFlag{};
            },
        };
    }

    /// Resolve key text to keycode and implicit flags
    fn resolveKey(self: *Compiler, text: []const u8, line: usize, file_path: ?[]const u8) CompileError!Hotkey.KeyPress {
        if (text[0] == '$') {
            // Alias
            return try self.resolveKeyAlias(text, line, file_path);
        } else if (std.mem.startsWith(u8, text, "0x")) {
            // Hex keycode
            const keycode = std.fmt.parseInt(u32, text[2..], 16) catch {
                return self.setError(
                    try std.fmt.allocPrint(self.allocator, "Invalid hex keycode '{s}'", .{text}),
                    line,
                    file_path,
                    error.InvalidKey,
                );
            };
            return Hotkey.KeyPress{ .flags = .{}, .key = keycode };
        } else if (text[0] == '\'' and text[text.len - 1] == '\'') {
            // Literal key
            const literal_name = text[1 .. text.len - 1];
            return try self.resolveKeyLiteral(literal_name, line, file_path);
        } else {
            // Regular key name
            const keycode = self.keycodes.get_keycode(text) catch {
                return self.setError(
                    try std.fmt.allocPrint(self.allocator, "Unknown key '{s}'", .{text}),
                    line,
                    file_path,
                    error.InvalidKey,
                );
            };
            return Hotkey.KeyPress{ .flags = .{}, .key = keycode };
        }
    }

    fn resolveKeyAlias(self: *Compiler, alias_name: []const u8, line: usize, file_path: ?[]const u8) CompileError!Hotkey.KeyPress {
        var visited = std.ArrayList([]const u8).init(self.allocator);
        defer visited.deinit();
        return try self.resolveKeyAliasInternal(alias_name, &visited, line, file_path);
    }

    fn resolveKeyAliasInternal(self: *Compiler, alias_name: []const u8, visited: *std.ArrayList([]const u8), line: usize, file_path: ?[]const u8) CompileError!Hotkey.KeyPress {
        // Check for circular reference
        for (visited.items) |name| {
            if (std.mem.eql(u8, name, alias_name)) {
                return self.setError(
                    try std.fmt.allocPrint(self.allocator, "Circular alias reference: {s}", .{alias_name}),
                    line,
                    file_path,
                    error.CircularAliasReference,
                );
            }
        }

        if (visited.items.len >= 10) {
            return self.setError(
                try std.fmt.allocPrint(self.allocator, "Alias nesting too deep (max 10 levels)", .{}),
                line,
                file_path,
                error.AliasTooDeep,
            );
        }

        try visited.append(alias_name);

        const alias = self.ir.alias_defs.get(alias_name) orelse {
            return self.setError(
                try std.fmt.allocPrint(self.allocator, "Undefined alias '{s}'", .{alias_name}),
                line,
                file_path,
                error.UndefinedAlias,
            );
        };

        return switch (alias) {
            .key => |text| try self.resolveKey(text, line, file_path),
            .keysym => |ks| {
                var flags: ModifierFlag = .{};
                if (ks.modifier) |mod| {
                    flags = try self.resolveModifier(mod, line, file_path);
                }
                const key_result = try self.resolveKey(ks.key, line, file_path);
                return Hotkey.KeyPress{
                    .flags = flags.merge(key_result.flags),
                    .key = key_result.key,
                };
            },
            .modifier => {
                return self.setError(
                    try std.fmt.allocPrint(self.allocator, "Alias '{s}' is a modifier, not a key", .{alias_name}),
                    line,
                    file_path,
                    error.AliasTypeMismatch,
                );
            },
        };
    }

    fn resolveKeyLiteral(self: *Compiler, literal_name: []const u8, line: usize, file_path: ?[]const u8) CompileError!Hotkey.KeyPress {
        const Keycodes_impl = @import("Keycodes.zig");
        const literal_keycode_str = Keycodes_impl.literal_keycode_str;
        const literal_keycode_value = Keycodes_impl.literal_keycode_value;

        // Find the literal
        for (literal_keycode_str, 0..) |name, i| {
            if (std.mem.eql(u8, name, literal_name)) {
                const value = literal_keycode_value[i];
                const keycode = value & 0xFFFF;
                var flags: ModifierFlag = .{};
                if ((value & (1 << 16)) != 0) flags.@"fn" = true;
                if ((value & (1 << 17)) != 0) flags.@"nx" = true;
                return Hotkey.KeyPress{ .flags = flags, .key = keycode };
            }
        }

        return self.setError(
            try std.fmt.allocPrint(self.allocator, "Unknown literal key '{s}'", .{literal_name}),
            line,
            file_path,
            error.InvalidKey,
        );
    }

    fn resolveKeyPress(self: *Compiler, unresolved: IR.UnresolvedKeyPress, line: usize, file_path: ?[]const u8) CompileError!Hotkey.KeyPress {
        var flags: ModifierFlag = .{};
        if (unresolved.modifier) |mod| {
            flags = try self.resolveModifier(mod, line, file_path);
        }
        const key_result = try self.resolveKey(unresolved.key, line, file_path);
        return Hotkey.KeyPress{
            .flags = flags.merge(key_result.flags),
            .key = key_result.key,
        };
    }

    fn setError(self: *Compiler, message: []const u8, line: usize, file_path: ?[]const u8, err: CompileError) CompileError {
        const path_copy = if (file_path) |path|
            self.allocator.dupe(u8, path) catch return error.OutOfMemory
        else
            null;

        self.error_info = .{
            .message = message,
            .line = line,
            .file_path = path_copy,
        };
        return err;
    }
};

// ========== TESTS ==========

test "compile simple hotkey" {
    const allocator = std.testing.allocator;

    var ir = try IR.IR.init(allocator);
    defer ir.deinit();

    // Add default mode
    try ir.mode_decls.put(allocator, try allocator.dupe(u8, "default"), .{ .capture = false });

    // Add a simple hotkey
    const modes = try allocator.alloc([]const u8, 1);
    modes[0] = try allocator.dupe(u8, "default");

    try ir.hotkey_defs.append(allocator, .{
        .modes = modes,
        .modifier = try allocator.dupe(u8, "cmd"),
        .key = try allocator.dupe(u8, "t"),
        .wildcard_command = try allocator.dupe(u8, "echo test"),
        .line = 1,
    });

    var keycodes = try Keycodes.init(allocator);
    defer keycodes.deinit();

    var compiler = Compiler.init(allocator, &keycodes, &ir);
    defer compiler.deinit();

    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    try compiler.compile(&mappings);

    // Verify hotkey was created
    const default_mode = mappings.mode_map.get("default").?;
    try std.testing.expectEqual(@as(usize, 1), default_mode.hotkey_map.count());
}

test "compile modifier alias resolution" {
    const allocator = std.testing.allocator;

    var ir = try IR.IR.init(allocator);
    defer ir.deinit();

    // Add mode
    try ir.mode_decls.put(allocator, try allocator.dupe(u8, "default"), .{ .capture = false });

    // Add alias definition
    try ir.alias_defs.put(
        allocator,
        try allocator.dupe(u8, "$super"),
        .{ .modifier = try allocator.dupe(u8, "cmd + alt") },
    );

    // Add hotkey using alias
    const modes = try allocator.alloc([]const u8, 1);
    modes[0] = try allocator.dupe(u8, "default");

    try ir.hotkey_defs.append(allocator, .{
        .modes = modes,
        .modifier = try allocator.dupe(u8, "$super"),
        .key = try allocator.dupe(u8, "t"),
        .wildcard_command = try allocator.dupe(u8, "echo test"),
        .line = 2,
    });

    var keycodes = try Keycodes.init(allocator);
    defer keycodes.deinit();

    var compiler = Compiler.init(allocator, &keycodes, &ir);
    defer compiler.deinit();

    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    try compiler.compile(&mappings);

    // Verify alias was resolved correctly
    const default_mode = mappings.mode_map.get("default").?;
    const hotkey = default_mode.hotkey_map.keys()[0];
    try std.testing.expect(hotkey.flags.cmd);
    try std.testing.expect(hotkey.flags.alt);
    try std.testing.expect(!hotkey.flags.shift);
}

test "compile circular alias detection" {
    const allocator = std.testing.allocator;

    var ir = try IR.IR.init(allocator);
    defer ir.deinit();

    // Add mode
    try ir.mode_decls.put(allocator, try allocator.dupe(u8, "default"), .{ .capture = false });

    // Create circular aliases
    try ir.alias_defs.put(
        allocator,
        try allocator.dupe(u8, "$a"),
        .{ .modifier = try allocator.dupe(u8, "$b + shift") },
    );
    try ir.alias_defs.put(
        allocator,
        try allocator.dupe(u8, "$b"),
        .{ .modifier = try allocator.dupe(u8, "$a + ctrl") },
    );

    // Add hotkey using circular alias
    const modes = try allocator.alloc([]const u8, 1);
    modes[0] = try allocator.dupe(u8, "default");

    try ir.hotkey_defs.append(allocator, .{
        .modes = modes,
        .modifier = try allocator.dupe(u8, "$a"),
        .key = try allocator.dupe(u8, "t"),
        .line = 3,
    });

    var keycodes = try Keycodes.init(allocator);
    defer keycodes.deinit();

    var compiler = Compiler.init(allocator, &keycodes, &ir);
    defer compiler.deinit();

    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    // Should fail with circular reference error
    const result = compiler.compile(&mappings);
    try std.testing.expectError(error.CircularAliasReference, result);

    // Check error message
    try std.testing.expect(compiler.error_info != null);
    try std.testing.expect(std.mem.indexOf(u8, compiler.error_info.?.message, "Circular") != null);
}

test "compile undefined alias error" {
    const allocator = std.testing.allocator;

    var ir = try IR.IR.init(allocator);
    defer ir.deinit();

    // Add mode
    try ir.mode_decls.put(allocator, try allocator.dupe(u8, "default"), .{ .capture = false });

    // Add hotkey using undefined alias
    const modes = try allocator.alloc([]const u8, 1);
    modes[0] = try allocator.dupe(u8, "default");

    try ir.hotkey_defs.append(allocator, .{
        .modes = modes,
        .modifier = try allocator.dupe(u8, "$undefined"),
        .key = try allocator.dupe(u8, "t"),
        .line = 1,
    });

    var keycodes = try Keycodes.init(allocator);
    defer keycodes.deinit();

    var compiler = Compiler.init(allocator, &keycodes, &ir);
    defer compiler.deinit();

    var mappings = try Mappings.init(allocator);
    defer mappings.deinit();

    // Should fail with undefined alias error
    const result = compiler.compile(&mappings);
    try std.testing.expectError(error.UndefinedAlias, result);

    // Check error message
    try std.testing.expect(compiler.error_info != null);
    try std.testing.expect(std.mem.indexOf(u8, compiler.error_info.?.message, "$undefined") != null);
}
