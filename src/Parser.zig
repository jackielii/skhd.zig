const std = @import("std");
const c = @import("c.zig").c;
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;
const Hotkey = @import("Hotkey.zig");
const assert = std.debug.assert;
const Mode = @import("Mode.zig");
const Mappings = @import("Mappings.zig");
const Keycodes = @import("Keycodes.zig");
const utils = @import("utils.zig");
const ModifierFlag = @import("Keycodes.zig").ModifierFlag;
const ParseError = @import("ParseError.zig").ParseError;

const Parser = @This();
const log = std.log.scoped(.parser);

const LoadDirective = struct {
    filename: []const u8,
    token: Token,
};

allocator: std.mem.Allocator,
tokenizer: Tokenizer = undefined,
content: []const u8 = undefined,
previous_token: ?Token = undefined,
next_token: ?Token = undefined,
keycodes: Keycodes = undefined,
load_directives: std.ArrayListUnmanaged(LoadDirective) = .{},
current_file_path: ?[]const u8 = null,
error_info: ?ParseError = null,
process_groups: std.StringHashMapUnmanaged([][]const u8) = .empty,
command_defs: std.StringHashMapUnmanaged(CommandDef) = .empty,

pub const CommandDef = struct {
    pub const Part = union(enum) {
        text: []const u8,
        placeholder: u8, // placeholder number (1-based)

        pub fn deinit(self: Part, allocator: std.mem.Allocator) void {
            switch (self) {
                .text => |text| allocator.free(text),
                .placeholder => {},
            }
        }
    };

    parts: []Part,
    max_placeholder: u8, // Highest placeholder number seen (0 if none)

    pub fn deinit(self: *CommandDef, allocator: std.mem.Allocator) void {
        for (self.parts) |part| part.deinit(allocator);
        allocator.free(self.parts);
        self.* = undefined;
    }
};

pub fn deinit(self: *Parser) void {
    self.keycodes.deinit();
    for (self.load_directives.items) |directive| {
        self.allocator.free(directive.filename);
    }
    self.load_directives.deinit(self.allocator);
    if (self.error_info) |*error_info| {
        error_info.deinit();
    }

    // Free process groups
    {
        var it = self.process_groups.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            for (kv.value_ptr.*) |process_name| {
                self.allocator.free(process_name);
            }
            self.allocator.free(kv.value_ptr.*);
        }
        self.process_groups.deinit(self.allocator);
    }

    // Free command definitions
    {
        var it = self.command_defs.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            kv.value_ptr.*.deinit(self.allocator);
        }
        self.command_defs.deinit(self.allocator);
    }

    self.* = undefined;
}

pub fn clearError(self: *Parser) void {
    if (self.error_info) |*error_info| {
        error_info.deinit();
        self.error_info = null;
    }
}

pub fn init(allocator: std.mem.Allocator) !Parser {
    // const f = try std.fs.cwd().openFile(filename, .{});
    // defer f.close();
    // const content = try f.readToEndAlloc(allocator, 1 << 24); // max size 16MB
    return Parser{ .allocator = allocator, .previous_token = null, .next_token = null, .keycodes = try Keycodes.init(allocator), .load_directives = .{} };
}

pub fn parse(self: *Parser, mappings: *Mappings, content: []const u8) !void {
    try self.parseWithPath(mappings, content, null);
}

pub fn parseWithPath(self: *Parser, mappings: *Mappings, content: []const u8, file_path: ?[]const u8) !void {
    self.content = content;
    self.tokenizer = try Tokenizer.init(content);
    self.current_file_path = file_path;

    // Create default mode if it doesn't exist
    if (!mappings.mode_map.contains("default")) {
        const default_mode = try Mode.init(mappings.allocator, "default");
        const key = try mappings.allocator.dupe(u8, "default");
        try mappings.mode_map.put(mappings.allocator, key, default_mode);
    }

    _ = self.advance();
    while (self.peek()) |token| {
        switch (token.type) {
            .Token_Identifier, .Token_Modifier, .Token_Literal, .Token_Key_Hex, .Token_Key, .Token_Activate => {
                self.parse_hotkey(mappings) catch |err| {
                    if (self.error_info == null) {
                        self.error_info = try ParseError.fromToken(self.allocator, token, "Failed to parse hotkey", self.current_file_path);
                    }
                    return err;
                };
            },
            .Token_Decl => {
                self.parse_mode_decl(mappings) catch |err| {
                    if (self.error_info == null) {
                        self.error_info = try ParseError.fromToken(self.allocator, token, "Failed to parse mode declaration", self.current_file_path);
                    }
                    return err;
                };
            },
            .Token_Option => {
                self.parse_option(mappings) catch |err| {
                    if (self.error_info == null) {
                        self.error_info = try ParseError.fromToken(self.allocator, token, "Failed to parse option", self.current_file_path);
                    }
                    return err;
                };
            },
            else => {
                const msg = try std.fmt.allocPrint(self.allocator, "Unexpected token type: {s}, text: '{s}'", .{ @tagName(token.type), token.text });
                defer self.allocator.free(msg);
                self.error_info = try ParseError.fromToken(self.allocator, token, msg, self.current_file_path);
                return error.ParseErrorOccurred;
            },
        }
    }
}

fn peek(self: *Parser) ?Token {
    return self.next_token;
}

fn previous(self: *Parser) Token {
    return self.previous_token orelse @panic("No previous token");
}

/// advance token stream
fn advance(self: *Parser) void {
    self.previous_token = self.next_token;
    self.next_token = self.tokenizer.get_token();
}

/// peek next token and check if it's the expected type
fn peek_check(self: *Parser, typ: Tokenizer.TokenType) bool {
    const token = self.peek() orelse return false;
    return token.type == typ;
}

/// match next token and move over it
fn match(self: *Parser, typ: Tokenizer.TokenType) bool {
    if (self.peek_check(typ)) {
        self.advance();
        return true;
    }
    return false;
}

/// Process escape sequences in a string, replacing \\ with \ and \" with "
fn processStringOwned(self: *Parser, str: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(self.allocator);

    var i: usize = 0;
    while (i < str.len) {
        if (i + 1 < str.len and str[i] == '\\') {
            if (str[i + 1] == '\\' or str[i + 1] == '"') {
                // Skip the backslash and append the next character
                try result.append(self.allocator, str[i + 1]);
                i += 2;
                continue;
            }
        }
        try result.append(self.allocator, str[i]);
        i += 1;
    }

    // Always return owned slice
    return try result.toOwnedSlice(self.allocator);
}

/// Helper function to handle errors from add_process_* methods with context
fn handleProcessError(self: *Parser, err: anyerror, process_name: []const u8, operation: []const u8) !void {
    const msg = switch (err) {
        error.ProcessCommandAlreadyExists => blk: {
            if (std.mem.eql(u8, process_name, "*")) {
                break :blk try std.fmt.allocPrint(self.allocator, "Wildcard binding already has a different {s}. Each hotkey can only have one wildcard action", .{operation});
            } else {
                break :blk try std.fmt.allocPrint(self.allocator, "Process '{s}' already has a different {s} for this hotkey. Each process can only have one action per hotkey", .{ process_name, operation });
            }
        },
        error.WildcardCommandAlreadyExists => try std.fmt.allocPrint(self.allocator, "This hotkey already has a wildcard {s}. Only one wildcard action is allowed per hotkey", .{operation}),
        else => return err,
    };
    defer self.allocator.free(msg);

    const token = self.previous();
    self.error_info = try ParseError.fromToken(self.allocator, token, msg, self.current_file_path);
    return error.ParseErrorOccurred;
}

fn parse_hotkey(self: *Parser, mappings: *Mappings) !void {
    var hotkey = try Hotkey.create(self.allocator);
    errdefer hotkey.destroy();

    if (self.match(.Token_Identifier)) {
        try self.parse_mode(mappings, hotkey);
    }

    if (hotkey.mode_list.count() > 0) {
        if (!self.match(.Token_Insert)) {
            const token = self.peek() orelse self.previous();
            self.error_info = try ParseError.fromToken(self.allocator, token, "Expected '<' after mode identifier", self.current_file_path);
            return error.ParseErrorOccurred;
        }
    } else {
        const default_mode = mappings.get_mode_or_create_default("default") catch |err| {
            const msg = try std.fmt.allocPrint(self.allocator, "Failed to get or create default mode: {s}", .{@errorName(err)});
            defer self.allocator.free(msg);
            const token = self.peek() orelse self.previous();
            self.error_info = try ParseError.fromToken(self.allocator, token, msg, self.current_file_path);
            return error.ParseErrorOccurred;
        } orelse unreachable;
        hotkey.add_mode(default_mode) catch |err| {
            const msg = try std.fmt.allocPrint(self.allocator, "Failed to add default mode to hotkey: {s}", .{@errorName(err)});
            defer self.allocator.free(msg);
            const token = self.peek() orelse self.previous();
            self.error_info = try ParseError.fromToken(self.allocator, token, msg, self.current_file_path);
            return error.ParseErrorOccurred;
        };
    }

    const found_modifier = self.match(.Token_Modifier);
    if (found_modifier) {
        hotkey.flags = try self.parse_modifier();
    }

    if (found_modifier) {
        if (!self.match(.Token_Dash)) {
            const token = self.peek() orelse self.previous();
            self.error_info = try ParseError.fromToken(self.allocator, token, "Expected '-' after modifier", self.current_file_path);
            return error.ParseErrorOccurred;
        }
    }

    if (self.match(.Token_Key)) {
        hotkey.key = try self.parse_key();
    } else if (self.match(.Token_Key_Hex)) {
        hotkey.key = try self.parse_key_hex();
    } else if (self.match(.Token_Literal)) {
        const keypress = try self.parse_key_literal();
        hotkey.flags = hotkey.flags.merge(keypress.flags);
        hotkey.key = keypress.key;
    } else {
        const token = self.peek() orelse self.previous();
        self.error_info = try ParseError.fromToken(self.allocator, token, "Expected key, key hex, or literal", self.current_file_path);
        return error.ParseErrorOccurred;
    }

    if (self.match(.Token_Arrow)) {
        hotkey.flags = hotkey.flags.merge(.{ .passthrough = true });
    }

    if (self.match(.Token_Activate)) {
        const mode_name = self.previous().text;

        // Check if there's a command after the mode activation
        if (self.match(.Token_Command)) {
            const result = try self.parse_command();
            defer if (result.owns_memory) self.allocator.free(result.command);
            hotkey.add_process_activation("*", mode_name, result.command) catch |err| {
                try self.handleProcessError(err, "*", "mode activation");
            };
        } else {
            hotkey.add_process_activation("*", mode_name, null) catch |err| {
                try self.handleProcessError(err, "*", "mode activation");
            };
        }
    } else if (self.match(.Token_Forward)) {
        const keypress = try self.parse_keypress();
        hotkey.add_process_forward("*", keypress) catch |err| {
            try self.handleProcessError(err, "*", "key forward");
        };
    } else if (self.match(.Token_Command)) {
        const result = try self.parse_command();
        defer if (result.owns_memory) self.allocator.free(result.command);
        hotkey.add_process_command("*", result.command) catch |err| {
            try self.handleProcessError(err, "*", "command");
        };
    } else if (self.match(.Token_Unbound)) {
        // Simple unbound action: <keysym> ~
        hotkey.add_process_unbound("*") catch |err| {
            try self.handleProcessError(err, "*", "unbound action");
        };
    } else if (self.match(.Token_BeginList)) {
        try self.parse_proc_list(mappings, hotkey);
    }

    mappings.add_hotkey(hotkey) catch |err| {
        if (err == error.DuplicateHotkeyInMode) {
            // Format the hotkey for the error message
            var buf: [256]u8 = undefined;
            const key_str = try Keycodes.formatKeyPressBuffer(&buf, hotkey.flags, hotkey.key);

            // Get the mode(s) where we're trying to add this hotkey
            var mode_names = std.ArrayListUnmanaged(u8){};
            defer mode_names.deinit(self.allocator);

            var it = hotkey.mode_list.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try mode_names.appendSlice(self.allocator, ", ");
                try mode_names.appendSlice(self.allocator, entry.key_ptr.*.name);
                first = false;
            }

            const msg = try std.fmt.allocPrint(self.allocator, "Duplicate hotkey '{s}' already exists in mode '{s}'", .{ key_str, mode_names.items });
            defer self.allocator.free(msg);

            // Use the key token for error location
            const key_token = self.previous();
            self.error_info = try ParseError.fromToken(self.allocator, key_token, msg, self.current_file_path);

            return error.ParseErrorOccurred;
        }
        return err;
    };
}

fn parse_mode(self: *Parser, mappings: *Mappings, hotkey: *Hotkey) !void {
    const token: Token = self.previous();
    assert(token.type == .Token_Identifier);

    const name = token.text;
    const mode = mappings.get_mode_or_create_default(name) catch |err| {
        const msg = try std.fmt.allocPrint(self.allocator, "Failed to get or create mode '{s}': {s}", .{ name, @errorName(err) });
        defer self.allocator.free(msg);
        self.error_info = try ParseError.fromToken(self.allocator, token, msg, self.current_file_path);
        return error.ParseErrorOccurred;
    } orelse {
        const msg = try std.fmt.allocPrint(self.allocator, "Mode '{s}' not found. Did you forget to declare it with '::{s}'?", .{ name, name });
        defer self.allocator.free(msg);
        self.error_info = try ParseError.fromToken(self.allocator, token, msg, self.current_file_path);
        return error.ParseErrorOccurred;
    };
    hotkey.add_mode(mode) catch |err| {
        const msg = try std.fmt.allocPrint(self.allocator, "Failed to add mode '{s}' to hotkey: {s}", .{ name, @errorName(err) });
        defer self.allocator.free(msg);
        self.error_info = try ParseError.fromToken(self.allocator, token, msg, self.current_file_path);
        return error.ParseErrorOccurred;
    };
    if (self.match(.Token_Comma)) {
        if (self.match(.Token_Identifier)) {
            try self.parse_mode(mappings, hotkey);
        } else {
            const error_token = self.peek() orelse self.previous();
            self.error_info = try ParseError.fromToken(self.allocator, error_token, "Expected mode identifier after comma", self.current_file_path);
            return error.ParseErrorOccurred;
        }
    }
}

fn parse_modifier(self: *Parser) !ModifierFlag {
    const token = self.previous();
    var flags = ModifierFlag{};

    if (ModifierFlag.get(token.text)) |modifier_flags_value| {
        flags = flags.merge(modifier_flags_value);
    } else {
        const msg = try std.fmt.allocPrint(self.allocator, "Unknown modifier '{s}'", .{token.text});
        defer self.allocator.free(msg);
        self.error_info = try ParseError.fromToken(self.allocator, token, msg, self.current_file_path);
        return error.ParseErrorOccurred;
    }

    if (self.match(.Token_Plus)) {
        if (self.match(.Token_Modifier)) {
            flags = flags.merge(try self.parse_modifier());
        } else {
            const error_token = self.peek() orelse self.previous();
            self.error_info = try ParseError.fromToken(self.allocator, error_token, "Expected modifier after '+'", self.current_file_path);
            return error.ParseErrorOccurred;
        }
    }
    return flags;
}

fn parse_key(self: *Parser) !u32 {
    const token = self.previous();
    const key = token.text;
    const keycode = self.keycodes.get_keycode(key) catch |err| {
        if (err == error.@"Key not found") {
            const msg = try std.fmt.allocPrint(self.allocator, "Unknown key '{s}'", .{token.text});
            defer self.allocator.free(msg);
            self.error_info = try ParseError.fromToken(self.allocator, token, msg, self.current_file_path);
            return error.ParseErrorOccurred;
        }
        return err;
    };
    return keycode;
}

fn parse_key_hex(self: *Parser) !u32 {
    const token = self.previous();
    const key = token.text;

    const code = std.fmt.parseInt(u32, key, 16) catch {
        const msg = try std.fmt.allocPrint(self.allocator, "Invalid hex keycode '0x{s}'. Expected a valid hexadecimal number (e.g., '0x24' for return key)", .{token.text});
        defer self.allocator.free(msg);
        self.error_info = try ParseError.fromToken(self.allocator, token, msg, self.current_file_path);
        return error.ParseErrorOccurred;
    };
    return code;
}

const literal_keycode_str = @import("Keycodes.zig").literal_keycode_str;
const literal_keycode_value = @import("Keycodes.zig").literal_keycode_value;

fn parse_key_literal(self: *Parser) !Hotkey.KeyPress {
    const token = self.previous();
    const key = token.text;
    var flags = ModifierFlag{};
    var keycode: u32 = 0;

    for (literal_keycode_str, 0..) |literal_key, i| {
        if (std.mem.eql(u8, key, literal_key)) {
            if (i > Keycodes.KEY_HAS_IMPLICIT_FN_MOD and i < Keycodes.KEY_HAS_IMPLICIT_NX_MOD) {
                // flags |= @intFromEnum(consts.hotkey_flag.Hotkey_Flag_Fn);
                flags = flags.merge(.{ .@"fn" = true });
            } else if (i >= Keycodes.KEY_HAS_IMPLICIT_NX_MOD) {
                // flags |= @intFromEnum(consts.hotkey_flag.Hotkey_Flag_NX);
                flags = flags.merge(.{ .nx = true });
            }
            keycode = literal_keycode_value[i];
            break;
        }
    } else {
        const msg = try std.fmt.allocPrint(self.allocator, "Unknown literal key '{s}'", .{token.text});
        defer self.allocator.free(msg);
        self.error_info = try ParseError.fromToken(self.allocator, token, msg, self.current_file_path);
        return error.ParseErrorOccurred;
    }

    return Hotkey.KeyPress{ .flags = flags, .key = keycode };
}

fn parse_keypress(self: *Parser) !Hotkey.KeyPress {
    var flags: ModifierFlag = .{};
    var keycode: u32 = 0;
    var found_modifier = false;
    if (self.match(.Token_Modifier)) {
        flags = try self.parse_modifier();
        found_modifier = true;
    }

    if (found_modifier and !self.match(.Token_Dash)) {
        const token = self.peek() orelse self.previous();
        self.error_info = try ParseError.fromToken(self.allocator, token, "Expected '-' after modifier", self.current_file_path);
        // Error already set in self.error_info
        return error.ParseErrorOccurred;
    }

    if (self.match(.Token_Key)) {
        keycode = try self.parse_key();
    } else if (self.match(.Token_Key_Hex)) {
        keycode = try self.parse_key_hex();
    } else if (self.match(.Token_Literal)) {
        const keypress = try self.parse_key_literal();
        flags = flags.merge(keypress.flags);
        keycode = keypress.key;
    } else {
        const token = self.peek() orelse self.previous();
        self.error_info = try ParseError.fromToken(self.allocator, token, "Expected key, key hex, or literal", self.current_file_path);
        return error.ParseErrorOccurred;
    }

    return Hotkey.KeyPress{ .flags = flags, .key = keycode };
}

fn parse_proc_list(self: *Parser, mappings: *Mappings, hotkey: *Hotkey) !void {
    // std.debug.print("parse_proc_list: entering\n", .{});
    if (self.match(.Token_String)) {
        const name_token = self.previous();
        const process_name = try self.processStringOwned(name_token.text);
        defer self.allocator.free(process_name);
        if (self.match(.Token_Command)) {
            const result = try self.parse_command();
            defer if (result.owns_memory) self.allocator.free(result.command);
            hotkey.add_process_command(process_name, result.command) catch |err| {
                try self.handleProcessError(err, process_name, "command");
            };
        } else if (self.match(.Token_Forward)) {
            const keypress = try self.parse_keypress();
            hotkey.add_process_forward(process_name, keypress) catch |err| {
                try self.handleProcessError(err, process_name, "key forward");
            };
        } else if (self.match(.Token_Unbound)) {
            hotkey.add_process_unbound(process_name) catch |err| {
                try self.handleProcessError(err, process_name, "unbound action");
            };
        } else if (self.match(.Token_Activate)) {
            // Process-specific mode activation
            const mode_name = self.previous().text;
            if (self.match(.Token_Command)) {
                const result = try self.parse_command();
                defer if (result.owns_memory) self.allocator.free(result.command);
                hotkey.add_process_activation(process_name, mode_name, result.command) catch |err| {
                    try self.handleProcessError(err, process_name, "mode activation");
                };
            } else {
                hotkey.add_process_activation(process_name, mode_name, null) catch |err| {
                    try self.handleProcessError(err, process_name, "mode activation");
                };
            }
        } else {
            const token = self.peek() orelse self.previous();
            self.error_info = try ParseError.fromToken(self.allocator, token, "Expected command ':', forward '|', unbound '~', or mode activation ';' after process name", self.current_file_path);
            return error.ParseErrorOccurred;
        }
        try self.parse_proc_list(mappings, hotkey);
    } else if (self.peek_check(.Token_Reference)) {
        // Handle @group_name reference (command references aren't allowed here)
        _ = self.advance();
        const ref_token = self.previous();
        const ref_name = ref_token.text;

        // Check if it's incorrectly followed by parenthesis (command invocation syntax)
        if (self.peek_check(.Token_BeginTuple)) {
            // This is a syntax error - command invocations aren't allowed as process list entries
            const msg = try std.fmt.allocPrint(self.allocator, "Command invocation '@{s}(...)' not allowed here. Process list entries must be process names, wildcards, or process groups", .{ref_name});
            defer self.allocator.free(msg);
            self.error_info = try ParseError.fromToken(self.allocator, ref_token, msg, self.current_file_path);
            return error.ParseErrorOccurred;
        }

        if (self.process_groups.get(ref_name)) |processes| {
            // It's a process group - now parse the action (command, forward, or unbound)
            if (self.match(.Token_Command)) {
                // Apply same command to all processes in the group
                const result = try self.parse_command();
                defer if (result.owns_memory) self.allocator.free(result.command);
                for (processes) |process_name| {
                    hotkey.add_process_command(process_name, result.command) catch |err| {
                        try self.handleProcessError(err, process_name, "command");
                    };
                }
            } else if (self.match(.Token_Forward)) {
                const forward_key = try self.parse_keypress();
                for (processes) |process_name| {
                    hotkey.add_process_forward(process_name, forward_key) catch |err| {
                        try self.handleProcessError(err, process_name, "key forward");
                    };
                }
            } else if (self.match(.Token_Unbound)) {
                for (processes) |process_name| {
                    hotkey.add_process_unbound(process_name) catch |err| {
                        try self.handleProcessError(err, process_name, "unbound action");
                    };
                }
            } else if (self.match(.Token_Activate)) {
                // Process group mode activation
                const mode_name = self.previous().text;

                // Check if there's a command after the mode activation
                var activation_command: ?[]const u8 = null;
                var did_own_command = false;
                if (self.match(.Token_Command)) {
                    const result = try self.parse_command();
                    activation_command = result.command;
                    did_own_command = result.owns_memory;
                }
                defer if (did_own_command and activation_command != null) {
                    self.allocator.free(activation_command.?);
                };

                // Apply activation to all processes in the group
                for (processes) |process_name| {
                    hotkey.add_process_activation(process_name, mode_name, activation_command) catch |err| {
                        try self.handleProcessError(err, process_name, "mode activation");
                    };
                }
            } else {
                const err_token = self.peek() orelse self.previous();
                self.error_info = try ParseError.fromToken(self.allocator, err_token, "Expected command ':', forward '|', unbound '~', or mode activation ';' after process group", self.current_file_path);
                return error.ParseErrorOccurred;
            }
        } else {
            const msg = try std.fmt.allocPrint(self.allocator, "Undefined process group '@{s}'", .{ref_name});
            defer self.allocator.free(msg);
            self.error_info = try ParseError.fromToken(self.allocator, ref_token, msg, self.current_file_path);
            return error.ParseErrorOccurred;
        }
        try self.parse_proc_list(mappings, hotkey);
    } else if (self.match(.Token_Wildcard)) {
        if (self.match(.Token_Command)) {
            const result = try self.parse_command();
            defer if (result.owns_memory) self.allocator.free(result.command);
            hotkey.add_process_command("*", result.command) catch |err| {
                try self.handleProcessError(err, "*", "command");
            };
        } else if (self.match(.Token_Forward)) {
            const keypress = try self.parse_keypress();
            hotkey.add_process_forward("*", keypress) catch |err| {
                try self.handleProcessError(err, "*", "key forward");
            };
        } else if (self.match(.Token_Unbound)) {
            hotkey.add_process_unbound("*") catch |err| {
                try self.handleProcessError(err, "*", "unbound action");
            };
        } else if (self.match(.Token_Activate)) {
            // Wildcard mode activation
            const mode_name = self.previous().text;
            if (self.match(.Token_Command)) {
                const result = try self.parse_command();
                defer if (result.owns_memory) self.allocator.free(result.command);
                hotkey.add_process_activation("*", mode_name, result.command) catch |err| {
                    try self.handleProcessError(err, "*", "mode activation");
                };
            } else {
                hotkey.add_process_activation("*", mode_name, null) catch |err| {
                    try self.handleProcessError(err, "*", "mode activation");
                };
            }
        } else {
            const token = self.peek() orelse self.previous();
            self.error_info = try ParseError.fromToken(self.allocator, token, "Expected command ':', forward '|', unbound '~', or mode activation ';' after wildcard", self.current_file_path);
            return error.ParseErrorOccurred;
        }
        try self.parse_proc_list(mappings, hotkey);
    } else if (self.match(.Token_EndList)) {
        if (hotkey.mappings.count() == 0) {
            const token = self.previous();
            self.error_info = try ParseError.fromToken(self.allocator, token, "Empty process list", self.current_file_path);
            return error.ParseErrorOccurred;
        }
    } else {
        const token = self.peek() orelse self.previous();
        self.error_info = try ParseError.fromToken(self.allocator, token, "Expected process name, wildcard '*' or ']'", self.current_file_path);
        return error.ParseErrorOccurred;
    }
}

fn parse_mode_decl(self: *Parser, mappings: *Mappings) !void {
    assert(self.match(.Token_Decl));
    if (!self.match(.Token_Identifier)) {
        const token = self.peek() orelse self.previous();
        self.error_info = try ParseError.fromToken(self.allocator, token, "Expected mode name after '::'", self.current_file_path);
        return error.ParseErrorOccurred;
    }
    const token = self.previous();
    const mode_name = token.text;
    var mode = try Mode.init(self.allocator, mode_name);
    errdefer mode.deinit();

    if (self.match(.Token_Capture)) {
        mode.capture = true;
    }

    if (self.match(.Token_Command)) {
        const result = try self.parse_command();
        defer if (result.owns_memory) self.allocator.free(result.command);
        try mode.set_command(result.command);
    }

    if (mappings.get_mode_or_create_default(mode_name) catch |err| {
        const msg = try std.fmt.allocPrint(self.allocator, "Failed to get or create mode '{s}': {s}", .{ mode_name, @errorName(err) });
        defer self.allocator.free(msg);
        self.error_info = try ParseError.fromToken(self.allocator, self.previous(), msg, self.current_file_path);
        return error.ParseErrorOccurred;
    }) |existing_mode| {
        if (std.mem.eql(u8, existing_mode.name, "default")) {
            existing_mode.initialized = false;
            existing_mode.capture = mode.capture;
            if (mode.command) |cmd| try existing_mode.set_command(cmd);
            mode.deinit(); // Clean up since we're not using this mode
        } else if (std.mem.eql(u8, existing_mode.name, mode_name)) {
            const msg = try std.fmt.allocPrint(self.allocator, "Mode '{s}' already exists", .{mode_name});
            defer self.allocator.free(msg);
            self.error_info = try ParseError.fromToken(self.allocator, self.previous(), msg, self.current_file_path);
            return error.ParseErrorOccurred;
        }
    } else {
        mappings.put_mode(mode) catch |err| {
            const msg = try std.fmt.allocPrint(self.allocator, "Failed to create mode '{s}': {s}", .{ mode_name, @errorName(err) });
            defer self.allocator.free(msg);
            self.error_info = try ParseError.fromToken(self.allocator, self.previous(), msg, self.current_file_path);
            return error.ParseErrorOccurred;
        };
    }
}

/// Parse a command token, handling both regular commands and command references
/// Returns the parsed command (caller owns memory if it's a reference)
/// Throws error if command is empty without a reference
fn parse_command(self: *Parser) !struct { command: []const u8, owns_memory: bool } {
    const cmd_token = self.previous();
    if (cmd_token.text.len == 0) {
        if (self.peek_check(.Token_Reference)) {
            // Empty command followed by reference
            const command = try self.parse_command_reference();
            return .{ .command = command, .owns_memory = true };
        } else {
            // Empty command with no reference is an error
            const err_token = self.peek() orelse cmd_token;
            self.error_info = try ParseError.fromToken(self.allocator, err_token, "Expected command text or command reference after ':'", self.current_file_path);
            return error.ParseErrorOccurred;
        }
    } else {
        // Regular command
        return .{ .command = cmd_token.text, .owns_memory = false };
    }
}

fn parse_command_reference(self: *Parser) ![]const u8 {
    // We expect a Token_Reference
    if (!self.match(.Token_Reference)) {
        const token = self.peek() orelse self.previous();
        self.error_info = try ParseError.fromToken(self.allocator, token, "Expected command reference", self.current_file_path);
        return error.ParseErrorOccurred;
    }

    const ref_token = self.previous();
    const command_name = ref_token.text;

    // Look up the command definition
    const cmd_def = self.command_defs.get(command_name) orelse {
        // Command not found - report error
        const msg = try std.fmt.allocPrint(self.allocator, "Command '@{s}' not found. Did you forget to define it with '.define {s} : ...'?", .{ command_name, command_name });
        defer self.allocator.free(msg);
        self.error_info = try ParseError.fromToken(self.allocator, ref_token, msg, self.current_file_path);
        return error.ParseErrorOccurred;
    };

    // Check for opening parenthesis
    if (self.match(.Token_BeginTuple)) {
        // Parse arguments
        var args = std.ArrayListUnmanaged([]const u8){};
        defer args.deinit(self.allocator);
        defer for (args.items) |arg| {
            self.allocator.free(arg);
        };

        while (true) {
            if (self.match(.Token_EndTuple)) {
                break;
            }

            if (self.match(.Token_String)) {
                const arg_token = self.previous();
                const processed_arg = try self.processStringOwned(arg_token.text);
                try args.append(self.allocator, processed_arg);

                // Check for comma or closing paren
                if (self.peek_check(.Token_EndTuple)) {
                    continue;
                } else if (!self.match(.Token_Comma)) {
                    const token = self.peek() orelse self.previous();
                    const msg = try std.fmt.allocPrint(self.allocator, "Expected ',' or ')' after argument in command '@{s}'", .{command_name});
                    defer self.allocator.free(msg);
                    self.error_info = try ParseError.fromToken(self.allocator, token, msg, self.current_file_path);
                    return error.ParseErrorOccurred;
                }
            } else {
                const token = self.peek() orelse self.previous();
                const msg = try std.fmt.allocPrint(self.allocator, "Command arguments must be enclosed in double quotes in '@{s}'", .{command_name});
                defer self.allocator.free(msg);
                self.error_info = try ParseError.fromToken(self.allocator, token, msg, self.current_file_path);
                return error.ParseErrorOccurred;
            }
        }

        // Validate argument count
        if (args.items.len != cmd_def.max_placeholder) {
            const msg = if (cmd_def.max_placeholder == 0)
                try std.fmt.allocPrint(self.allocator, "Command '@{s}' expects no arguments but {d} provided", .{ command_name, args.items.len })
            else if (args.items.len < cmd_def.max_placeholder)
                try std.fmt.allocPrint(self.allocator, "Command '@{s}' expects {d} arguments but only {d} provided", .{ command_name, cmd_def.max_placeholder, args.items.len })
            else
                try std.fmt.allocPrint(self.allocator, "Command '@{s}' expects {d} arguments but {d} provided", .{ command_name, cmd_def.max_placeholder, args.items.len });
            defer self.allocator.free(msg);

            self.error_info = try ParseError.fromToken(self.allocator, ref_token, msg, self.current_file_path);
            return error.ParseErrorOccurred;
        }

        // Expand the template using pre-parsed parts
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(self.allocator);

        for (cmd_def.parts) |part| {
            switch (part) {
                .text => |text| try result.appendSlice(self.allocator, text),
                .placeholder => |num| {
                    if (num <= args.items.len) {
                        try result.appendSlice(self.allocator, args.items[num - 1]);
                    }
                    // Note: placeholders > args.len are silently ignored
                },
            }
        }

        return try result.toOwnedSlice(self.allocator);
    } else if (cmd_def.max_placeholder > 0) {
        // Error: command expects arguments but none provided
        const msg = try std.fmt.allocPrint(self.allocator, "Command '@{s}' expects {d} arguments but none provided", .{ command_name, cmd_def.max_placeholder });
        defer self.allocator.free(msg);

        self.error_info = try ParseError.fromToken(self.allocator, ref_token, msg, self.current_file_path);
        return error.ParseErrorOccurred;
    } else {
        // No arguments needed, build from parts
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(self.allocator);

        for (cmd_def.parts) |part| {
            switch (part) {
                .text => |text| try result.appendSlice(self.allocator, text),
                .placeholder => {}, // Should not have placeholders if max_placeholder is 0
            }
        }

        return try result.toOwnedSlice(self.allocator);
    }
}

fn parseCommandTemplate(self: *Parser, template: []const u8, token: Token) !CommandDef {
    var parts = std.ArrayListUnmanaged(CommandDef.Part){};
    errdefer {
        for (parts.items) |part| {
            part.deinit(self.allocator);
        }
        parts.deinit(self.allocator);
    }

    var max_placeholder: u8 = 0;
    var pos: usize = 0;

    while (pos < template.len) {
        // Look for placeholder start
        if (pos + 3 < template.len and template[pos] == '{' and template[pos + 1] == '{') {
            // Find the end
            var j = pos + 2;
            while (j < template.len and template[j] != '}') : (j += 1) {}

            if (j + 1 < template.len and template[j] == '}' and template[j + 1] == '}') {
                // Found a placeholder
                const num_str = template[pos + 2 .. j];
                if (num_str.len == 0) {
                    const msg = try std.fmt.allocPrint(self.allocator, "Invalid placeholder '{{{{}}}}' in command template. Placeholders must be numbers like {{{{1}}}}, {{{{2}}}}, etc.", .{});
                    defer self.allocator.free(msg);
                    self.error_info = try ParseError.fromToken(self.allocator, token, msg, self.current_file_path);
                    return error.ParseErrorOccurred;
                }

                const num = std.fmt.parseInt(u8, num_str, 10) catch {
                    const msg = try std.fmt.allocPrint(self.allocator, "Invalid placeholder '{{{{{s}}}}}' in command template. Placeholders must be numbers like {{{{1}}}}, {{{{2}}}}, etc.", .{num_str});
                    defer self.allocator.free(msg);
                    self.error_info = try ParseError.fromToken(self.allocator, token, msg, self.current_file_path);
                    return error.ParseErrorOccurred;
                };

                if (num == 0) {
                    const msg = try std.fmt.allocPrint(self.allocator, "Invalid placeholder '{{{{0}}}}' in command template. Placeholders must start from 1.", .{});
                    defer self.allocator.free(msg);
                    self.error_info = try ParseError.fromToken(self.allocator, token, msg, self.current_file_path);
                    return error.ParseErrorOccurred;
                }

                try parts.append(self.allocator, .{ .placeholder = num });
                if (num > max_placeholder) {
                    max_placeholder = num;
                }
                pos = j + 2;
                continue;
            }
        }

        // Not a placeholder, find next placeholder or end
        var end = pos + 1;
        while (end < template.len) : (end += 1) {
            if (end + 1 < template.len and template[end] == '{' and template[end + 1] == '{') {
                break;
            }
        }

        // Add text part
        const text = try self.allocator.dupe(u8, template[pos..end]);
        try parts.append(self.allocator, .{ .text = text });
        pos = end;
    }

    return CommandDef{
        .parts = try parts.toOwnedSlice(self.allocator),
        .max_placeholder = max_placeholder,
    };
}

fn parse_option(self: *Parser, mappings: *Mappings) !void {
    assert(self.match(.Token_Option));
    const option = self.previous().text;

    if (std.mem.eql(u8, option, "define")) {
        // Parse name after define
        if (!self.match(.Token_Identifier)) {
            const token = self.peek() orelse self.previous();
            self.error_info = try ParseError.fromToken(self.allocator, token, "Expected name after 'define'", self.current_file_path);
            return error.ParseErrorOccurred;
        }

        const name = self.previous().text;

        // Check if this is a command definition or process group
        if (self.match(.Token_Command)) {
            // Command definition: define name : command
            const command_token = self.previous();
            const command_template = command_token.text;

            // Parse template into parts
            var parsed = try self.parseCommandTemplate(command_template, command_token);
            errdefer parsed.deinit(self.allocator);

            if (self.command_defs.contains(name)) {
                self.error_info = try ParseError.fromToken(self.allocator, command_token, "Command already defined", self.current_file_path);
                return error.CommandAlreadyDefined;
            }

            const owned_name = try self.allocator.dupe(u8, name);
            try self.command_defs.put(self.allocator, owned_name, parsed);
        } else if (self.match(.Token_BeginList)) {
            // Process group definition: define name ["app1", "app2"]
            var process_list = std.ArrayListUnmanaged([]const u8){};
            errdefer {
                for (process_list.items) |process| self.allocator.free(process);
                process_list.deinit(self.allocator);
            }

            while (self.match(.Token_String)) {
                const process_name = try self.processStringOwned(self.previous().text);
                try process_list.append(self.allocator, process_name);

                // Skip optional comma
                _ = self.match(.Token_Comma);
            }

            if (!self.match(.Token_EndList)) {
                const token = self.peek() orelse self.previous();
                self.error_info = try ParseError.fromToken(self.allocator, token, "Expected ']' to close process list", self.current_file_path);
                return error.ParseErrorOccurred;
            }

            if (self.process_groups.contains(name)) {
                self.error_info = try ParseError.fromToken(self.allocator, self.previous(), "Process group already defined", self.current_file_path);
                return error.ProcessGroupAlreadyDefined;
            }

            const owned_name = try self.allocator.dupe(u8, name);
            const owned_processes = try process_list.toOwnedSlice(self.allocator);
            try self.process_groups.put(self.allocator, owned_name, owned_processes);
        } else {
            const token = self.peek() orelse self.previous();
            self.error_info = try ParseError.fromToken(self.allocator, token, "Expected ':' for command definition or '[' for process group after name", self.current_file_path);
            return error.ParseErrorOccurred;
        }
    } else if (std.mem.eql(u8, option, "load")) {
        if (self.match(.Token_String)) {
            const filename_token = self.previous();
            const filename = try self.processStringOwned(filename_token.text);
            try self.load_directives.append(self.allocator, LoadDirective{
                .filename = filename,
                .token = filename_token,
            });
        } else {
            const token = self.peek() orelse self.previous();
            self.error_info = try ParseError.fromToken(self.allocator, token, "Expected filename after 'load'", self.current_file_path);
            return error.ParseErrorOccurred;
        }
    } else if (std.mem.eql(u8, option, "blacklist")) {
        if (self.match(.Token_BeginList)) {
            while (self.match(.Token_String)) {
                const token = self.previous();
                const app_name = try self.processStringOwned(token.text);
                defer self.allocator.free(app_name);
                mappings.add_blacklist(app_name) catch |err| {
                    const msg = try std.fmt.allocPrint(self.allocator, "Failed to add '{s}' to blacklist: {s}", .{ app_name, @errorName(err) });
                    defer self.allocator.free(msg);
                    self.error_info = try ParseError.fromToken(self.allocator, token, msg, self.current_file_path);
                    return error.ParseErrorOccurred;
                };
            }
            if (!self.match(.Token_EndList)) {
                const token = self.peek() orelse self.previous();
                self.error_info = try ParseError.fromToken(self.allocator, token, "Expected ']' to close blacklist", self.current_file_path);
                return error.ParseErrorOccurred;
            }
        } else {
            const token = self.peek() orelse self.previous();
            self.error_info = try ParseError.fromToken(self.allocator, token, "Expected '[' after 'blacklist'", self.current_file_path);
            return error.ParseErrorOccurred;
        }
    } else if (std.mem.eql(u8, option, "shell") or std.mem.eql(u8, option, "SHELL")) {
        if (self.match(.Token_String)) {
            const shell_path = try self.processStringOwned(self.previous().text);
            defer self.allocator.free(shell_path);
            mappings.set_shell(shell_path) catch |err| {
                const msg = try std.fmt.allocPrint(self.allocator, "Failed to set shell to '{s}': {s}", .{ shell_path, @errorName(err) });
                defer self.allocator.free(msg);
                self.error_info = try ParseError.fromToken(self.allocator, self.previous(), msg, self.current_file_path);
                return error.ParseErrorOccurred;
            };
        } else {
            const token = self.peek() orelse self.previous();
            self.error_info = try ParseError.fromToken(self.allocator, token, "Expected shell path after 'shell'", self.current_file_path);
            return error.ParseErrorOccurred;
        }
    } else {
        const msg = try std.fmt.allocPrint(self.allocator, "Unknown option '{s}'. Valid options are: define, load, blacklist, shell", .{option});
        defer self.allocator.free(msg);
        self.error_info = try ParseError.fromToken(self.allocator, self.previous(), msg, self.current_file_path);
        return error.ParseErrorOccurred;
    }
}

pub fn processLoadDirectives(self: *Parser, mappings: *Mappings) !void {
    // Process each load directive
    for (self.load_directives.items) |directive| {
        const resolved_path = try self.resolveLoadPath(directive.filename);
        defer self.allocator.free(resolved_path);

        // Read the file content
        const content = std.fs.cwd().readFileAlloc(self.allocator, resolved_path, 1 << 20) catch {
            // Report error with line info from the .load directive
            const msg = try std.fmt.allocPrint(self.allocator, "Could not open included file '{s}'", .{resolved_path});
            defer self.allocator.free(msg);
            self.error_info = try ParseError.fromToken(self.allocator, directive.token, msg, self.current_file_path);
            return error.ParseErrorOccurred;
        };
        defer self.allocator.free(content);

        // Add the resolved path to the loaded files list
        // Resolve to absolute path for hotloader
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs_path = std.fs.cwd().realpath(resolved_path, &path_buf) catch |err| {
            const msg = try std.fmt.allocPrint(self.allocator, "Failed to resolve path '{s}': {s}", .{ resolved_path, @errorName(err) });
            defer self.allocator.free(msg);
            self.error_info = try ParseError.fromToken(self.allocator, directive.token, msg, self.current_file_path);
            return error.ParseErrorOccurred;
        };
        const duped_path = try self.allocator.dupe(u8, abs_path);
        try mappings.loaded_files.append(self.allocator, duped_path);

        // Create a new parser for the included file
        var included_parser = try Parser.init(self.allocator);
        defer included_parser.deinit();

        // Parse the included file
        try included_parser.parseWithPath(mappings, content, resolved_path);

        // Recursively process any load directives in the included file
        try included_parser.processLoadDirectives(mappings);
    }
}

fn resolveLoadPath(self: *Parser, filename: []const u8) ![]const u8 {
    // If the path is absolute, return it as-is
    if (std.fs.path.isAbsolute(filename)) {
        return try self.allocator.dupe(u8, filename);
    }

    // If we have a current file path, resolve relative to its directory
    if (self.current_file_path) |current_path| {
        const dir_path = std.fs.path.dirname(current_path) orelse ".";
        return try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, filename });
    }

    // Otherwise, treat as relative to current working directory
    return try self.allocator.dupe(u8, filename);
}

test "init" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();
}

test "Parse" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    try parser.parse(&mappings,
        \\cmd + shift - h [
        \\    "notepad.exe": echo "notepad"
        \\    "chrome.exe": echo "chrome"
        \\    "firefox.exe" | cmd + shift - h
        \\    *: ~
        \\]
    );

    // Verify the hotkey was created
    try std.testing.expect(mappings.mode_map.get("default").?.hotkey_map.count() == 1);
}

test "Parse mode decl" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    try parser.parse(&mappings, ":: mode : command");
    // print("{s}\n", .{mappings});
}

test "Parse mode decl capture" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    try parser.parse(&mappings, ":: mode @: command");
    // print("{s}\n", .{mappings});
}

test "double mode free" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    try parser.parse(&mappings,
        \\ ::game
        \\ ::work
        \\ game, work < ctrl + shift - h: echo
    );
    // print("{s}\n", .{mappings});
}

test "load directive" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Parse main content with .load directive
    const main_content =
        \\.load "testdata/test_included.skhdrc"
        \\cmd - m : echo 'from main file'
    ;

    try parser.parse(&mappings, main_content);
    try parser.processLoadDirectives(&mappings);

    // Check that both hotkeys were loaded
    try std.testing.expect(mappings.mode_map.get("default").?.hotkey_map.count() >= 2);
}

test "load directive with cross-file mode reference" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Parse main content with mode definition and .load directive
    const main_content =
        \\:: mymode
        \\.load "testdata/test_included_mode.skhdrc"
        \\cmd - m : echo 'from main file'
    ;

    try parser.parse(&mappings, main_content);
    try parser.processLoadDirectives(&mappings);

    // Check that mode exists and has the hotkey from included file
    try std.testing.expect(mappings.mode_map.contains("mymode"));
    const mode = mappings.mode_map.get("mymode").?;
    try std.testing.expect(mode.hotkey_map.count() > 0);
}

test "nested load directives" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Parse main content that loads nested1
    const main_content =
        \\.load "testdata/test_nested1.skhdrc"
        \\cmd - m : echo 'from main'
    ;

    try parser.parse(&mappings, main_content);
    try parser.processLoadDirectives(&mappings);

    // Check that all three hotkeys were loaded
    try std.testing.expect(mappings.mode_map.get("default").?.hotkey_map.count() >= 3);
}

test "load directive with relative paths" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Parse main content that loads the loader from testdata directory
    const main_content =
        \\.load "testdata/loader.skhdrc"
        \\cmd - m : echo 'from main'
    ;

    try parser.parseWithPath(&mappings, main_content, "test.skhdrc");
    try parser.processLoadDirectives(&mappings);

    // Check that all hotkeys were loaded (main + loader + sub)
    try std.testing.expect(mappings.mode_map.get("default").?.hotkey_map.count() >= 3);
}

test "shell directive" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Test default shell (should be from $SHELL env or /bin/bash)
    const default_shell = mappings.shell;
    try std.testing.expect(default_shell.len > 0);

    // Parse config with .shell directive
    const content =
        \\.shell "/bin/zsh"
        \\cmd - t : echo "test"
    ;
    try parser.parse(&mappings, content);

    // Verify shell was updated
    try std.testing.expectEqualStrings("/bin/zsh", mappings.shell);
}

test "shell directive with spaces" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Parse config with .shell directive containing spaces
    const content =
        \\.shell "/usr/local/bin/fish"
        \\cmd - f : echo "fish shell"
    ;
    try parser.parse(&mappings, content);

    // Verify shell was updated
    try std.testing.expectEqualStrings("/usr/local/bin/fish", mappings.shell);
}

test "shell directive error handling" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Test missing shell path
    const content = ".shell";
    try std.testing.expectError(error.ParseErrorOccurred, parser.parse(&mappings, content));
}

test "command definition without placeholders" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Define a simple command
    const content =
        \\.define focus_recent : yabai -m window --focus recent || yabai -m space --focus recent
        \\cmd - tab : @focus_recent
    ;
    try parser.parse(&mappings, content);

    // Verify command was defined
    try std.testing.expect(parser.command_defs.contains("focus_recent"));

    // Verify hotkey was created with expanded command
    try std.testing.expect(mappings.mode_map.get("default").?.hotkey_map.count() == 1);

    // Verify command expanded correctly
    const ctx = Hotkey.KeyboardLookupContext{};
    const keypress = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = 0x30 }; // tab key
    const hotkey = mappings.mode_map.get("default").?.hotkey_map.getKeyAdapted(keypress, ctx).?;
    const cmd = hotkey.find_command_for_process("").?;
    try std.testing.expectEqualSlices(u8, "yabai -m window --focus recent || yabai -m space --focus recent", cmd.command);
}

test "command definition with single placeholder" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Define a command with one placeholder
    const content =
        \\.define yabai_focus : yabai -m window --focus {{1}} || yabai -m display --focus {{1}}
        \\lcmd - h : @yabai_focus("west")
        \\lcmd - j : @yabai_focus("south")
    ;
    try parser.parse(&mappings, content);

    // Verify command was defined with correct max_placeholder
    try std.testing.expect(parser.command_defs.contains("yabai_focus"));
    const cmd_def = parser.command_defs.get("yabai_focus").?;
    try std.testing.expectEqual(@as(u8, 1), cmd_def.max_placeholder);

    // Verify hotkeys were created
    try std.testing.expect(mappings.mode_map.get("default").?.hotkey_map.count() == 2);

    // Verify hotkeys expand to correct commands
    const ctx = Hotkey.KeyboardLookupContext{};
    const keypress1 = Hotkey.KeyPress{ .flags = .{ .lcmd = true }, .key = c.kVK_ANSI_H };
    const hotkey1 = mappings.mode_map.get("default").?.hotkey_map.getKeyAdapted(keypress1, ctx).?;
    const cmd1 = hotkey1.find_command_for_process("").?;
    try std.testing.expectEqualSlices(u8, "yabai -m window --focus west || yabai -m display --focus west", cmd1.command);
    const keypress2 = Hotkey.KeyPress{ .flags = .{ .lcmd = true }, .key = c.kVK_ANSI_J };
    const hotkey2 = mappings.mode_map.get("default").?.hotkey_map.getKeyAdapted(keypress2, ctx).?;
    const cmd2 = hotkey2.find_command_for_process("").?;
    try std.testing.expectEqualSlices(u8, "yabai -m window --focus south || yabai -m display --focus south", cmd2.command);
}

test "command definition with multiple placeholders" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Define a command with multiple placeholders
    const content =
        \\.define window_action : yabai -m window --{{1}} {{2}} || yabai -m display --{{1}} {{2}}
        \\cmd + shift - h : @window_action("swap", "west")
        \\cmd + shift - j : @window_action("swap", "south")
    ;
    try parser.parse(&mappings, content);

    // Verify command was defined with correct max_placeholder
    try std.testing.expect(parser.command_defs.contains("window_action"));
    const cmd_def = parser.command_defs.get("window_action").?;
    try std.testing.expectEqual(@as(u8, 2), cmd_def.max_placeholder);

    // Verify hotkeys were created
    try std.testing.expect(mappings.mode_map.get("default").?.hotkey_map.count() == 2);

    // Verify commands expanded correctly
    const ctx = Hotkey.KeyboardLookupContext{};
    const keypress1 = Hotkey.KeyPress{ .flags = .{ .cmd = true, .shift = true }, .key = c.kVK_ANSI_H };
    const hotkey1 = mappings.mode_map.get("default").?.hotkey_map.getKeyAdapted(keypress1, ctx).?;
    const cmd1 = hotkey1.find_command_for_process("").?;
    try std.testing.expectEqualSlices(u8, "yabai -m window --swap west || yabai -m display --swap west", cmd1.command);

    const keypress2 = Hotkey.KeyPress{ .flags = .{ .cmd = true, .shift = true }, .key = c.kVK_ANSI_J };
    const hotkey2 = mappings.mode_map.get("default").?.hotkey_map.getKeyAdapted(keypress2, ctx).?;
    const cmd2 = hotkey2.find_command_for_process("").?;
    try std.testing.expectEqualSlices(u8, "yabai -m window --swap south || yabai -m display --swap south", cmd2.command);
}

test "command definition with repeated placeholders" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Define a command where same placeholder appears multiple times
    const content =
        \\.define notify : osascript -e 'display notification "{{1}}" with title "{{1}}"'
        \\cmd - n : @notify("Test Message")
    ;
    try parser.parse(&mappings, content);

    // Verify command was defined
    try std.testing.expect(parser.command_defs.contains("notify"));

    // Verify hotkey was created
    try std.testing.expect(mappings.mode_map.get("default").?.hotkey_map.count() == 1);

    // Verify placeholder replaced correctly in both locations
    const ctx = Hotkey.KeyboardLookupContext{};
    const keypress = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = c.kVK_ANSI_N };
    const hotkey = mappings.mode_map.get("default").?.hotkey_map.getKeyAdapted(keypress, ctx).?;
    const cmd = hotkey.find_command_for_process("").?;
    try std.testing.expectEqualSlices(u8, "osascript -e 'display notification \"Test Message\" with title \"Test Message\"'", cmd.command);
}

test "command definition error: wrong argument count" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Define a command expecting 2 arguments but provide only 1
    const content =
        \\.define window_action : yabai -m window --{{1}} {{2}}
        \\cmd - h : @window_action("swap")
    ;
    // Should fail with ParseError
    try std.testing.expectError(error.ParseErrorOccurred, parser.parse(&mappings, content));

    // Verify error message
    const error_info = parser.error_info.?;
    try std.testing.expect(std.mem.containsAtLeast(u8, error_info.message, 1, "expects 2 arguments but only 1 provided"));
}

test "command definition error: missing arguments" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Define a command expecting arguments but provide none
    const content =
        \\.define yabai_focus : yabai -m window --focus {{1}}
        \\cmd - h : @yabai_focus
    ;
    // Should fail with ParseError
    try std.testing.expectError(error.ParseErrorOccurred, parser.parse(&mappings, content));

    // Verify error message
    const error_info = parser.error_info.?;
    try std.testing.expect(std.mem.containsAtLeast(u8, error_info.message, 1, "expects 1 arguments but none provided"));
}

test "command definition error: too many arguments" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Define a command expecting 1 argument but provide 2
    const content =
        \\.define yabai_focus : yabai -m window --focus {{1}}
        \\cmd - h : @yabai_focus("west", "extra")
    ;

    // Should fail with ParseError
    try std.testing.expectError(error.ParseErrorOccurred, parser.parse(&mappings, content));

    // Verify error message
    const error_info = parser.error_info.?;
    try std.testing.expect(std.mem.containsAtLeast(u8, error_info.message, 1, "expects 1 arguments but 2 provided"));
}

test "command definition error: undefined command" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Try to use undefined command
    const content =
        \\cmd - h : @undefined_command("arg")
    ;

    // Should fail with ParseError
    try std.testing.expectError(error.ParseErrorOccurred, parser.parse(&mappings, content));

    // Verify error message
    const error_info = parser.error_info.?;
    try std.testing.expect(std.mem.containsAtLeast(u8, error_info.message, 1, "Command '@undefined_command' not found"));
    try std.testing.expect(std.mem.containsAtLeast(u8, error_info.message, 1, ".define undefined_command"));
}

test "command definition error: unquoted arguments" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Define a command and try to use with unquoted arguments
    const content =
        \\.define toggle : open -a "{{1}}"
        \\cmd - h : @toggle(Firefox)
    ;

    // Should fail with ParseError
    try std.testing.expectError(error.ParseErrorOccurred, parser.parse(&mappings, content));

    // Verify error message
    const error_info = parser.error_info.?;
    try std.testing.expect(std.mem.containsAtLeast(u8, error_info.message, 1, "must be enclosed in double quotes"));
}

test "command definition with escape sequences" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Define command and use with escaped quotes
    const content =
        \\.define notify : osascript -e 'display notification "{{2}}" with title "{{1}}"'
        \\cmd - n : @notify("Test", "Message with \"quotes\"")
    ;
    try parser.parse(&mappings, content);

    // Verify command was defined and hotkey created
    try std.testing.expect(parser.command_defs.contains("notify"));
    try std.testing.expect(mappings.mode_map.get("default").?.hotkey_map.count() == 1);

    // Verify escape sequences are processed correctly
    const ctx = Hotkey.KeyboardLookupContext{};
    const keypress = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = c.kVK_ANSI_N };
    const hotkey = mappings.mode_map.get("default").?.hotkey_map.getKeyAdapted(keypress, ctx).?;
    const cmd = hotkey.find_command_for_process("").?;
    try std.testing.expectEqualSlices(u8, "osascript -e 'display notification \"Message with \"quotes\"\" with title \"Test\"'", cmd.command);
}

test "command definition with comma-separated arguments" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Test with optional commas between arguments
    const content =
        \\.define resize_win : yabai -m window --resize {{1}}:{{2}}:{{3}}
        \\cmd + ctrl + shift - k : @resize_win("top", "0", "-10")
        \\cmd + ctrl + shift - j : @resize_win("bottom","0","10")
    ;
    try parser.parse(&mappings, content);

    // Verify command was defined and hotkeys created
    try std.testing.expect(parser.command_defs.contains("resize_win"));
    try std.testing.expect(mappings.mode_map.get("default").?.hotkey_map.count() == 2);

    // Verify commands expanded correctly
    const ctx = Hotkey.KeyboardLookupContext{};
    const keypress1 = Hotkey.KeyPress{ .flags = .{ .cmd = true, .control = true, .shift = true }, .key = c.kVK_ANSI_K };
    const hotkey1 = mappings.mode_map.get("default").?.hotkey_map.getKeyAdapted(keypress1, ctx).?;
    const cmd1 = hotkey1.find_command_for_process("").?;
    try std.testing.expectEqualSlices(u8, "yabai -m window --resize top:0:-10", cmd1.command);

    const keypress2 = Hotkey.KeyPress{ .flags = .{ .cmd = true, .control = true, .shift = true }, .key = c.kVK_ANSI_J };
    const hotkey2 = mappings.mode_map.get("default").?.hotkey_map.getKeyAdapted(keypress2, ctx).?;
    const cmd2 = hotkey2.find_command_for_process("").?;
    try std.testing.expectEqualSlices(u8, "yabai -m window --resize bottom:0:10", cmd2.command);
}

test "command definition with whitespace handling" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Test whitespace in arguments and around parentheses
    const content =
        \\.define toggle_app : yabai -m window --toggle {{1}} || open -a "{{1}}"
        \\ralt - m : @toggle_app(  "YT Music"  )
        \\ralt - n : @toggle_app("Notes")
    ;
    try parser.parse(&mappings, content);

    // Verify command was defined and hotkeys created
    try std.testing.expect(parser.command_defs.contains("toggle_app"));
    try std.testing.expect(mappings.mode_map.get("default").?.hotkey_map.count() == 2);

    // Verify whitespace is trimmed from arguments
    const ctx = Hotkey.KeyboardLookupContext{};
    const keypress1 = Hotkey.KeyPress{ .flags = .{ .ralt = true }, .key = c.kVK_ANSI_M };
    const hotkey1 = mappings.mode_map.get("default").?.hotkey_map.getKeyAdapted(keypress1, ctx).?;
    const cmd1 = hotkey1.find_command_for_process("").?;
    try std.testing.expectEqualSlices(u8, "yabai -m window --toggle YT Music || open -a \"YT Music\"", cmd1.command);
}

test "command definition complex placeholders" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Test non-sequential placeholders and highest placeholder detection
    const content =
        \\.define complex : echo {{3}} {{1}} {{3}} {{2}}
        \\cmd - c : @complex("first", "second", "third")
    ;
    try parser.parse(&mappings, content);

    // Verify max_placeholder is correctly detected as 3
    const cmd_def = parser.command_defs.get("complex").?;
    try std.testing.expectEqual(@as(u8, 3), cmd_def.max_placeholder);

    // Verify placeholders expanded in correct order
    const ctx = Hotkey.KeyboardLookupContext{};
    const keypress = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = c.kVK_ANSI_C };
    const hotkey = mappings.mode_map.get("default").?.hotkey_map.getKeyAdapted(keypress, ctx).?;
    const cmd = hotkey.find_command_for_process("").?;
    try std.testing.expectEqualSlices(u8, "echo third first third second", cmd.command);
}

test "process group in hotkey with command expansion" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Test command expansion within process lists
    const content =
        \\.define toggle : open -a "{{1}}"
        \\cmd - a [
        \\    "firefox" : @toggle("Firefox")
        \\    "chrome" : @toggle("Google Chrome")
        \\]
    ;
    try parser.parse(&mappings, content);

    // Verify command was defined and hotkey created
    try std.testing.expect(parser.command_defs.contains("toggle"));
    try std.testing.expect(mappings.mode_map.get("default").?.hotkey_map.count() == 1);

    // Verify commands expanded for different processes
    const ctx = Hotkey.KeyboardLookupContext{};
    const keypress = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = c.kVK_ANSI_A };
    const hotkey = mappings.mode_map.get("default").?.hotkey_map.getKeyAdapted(keypress, ctx).?;

    const firefox_cmd = hotkey.find_command_for_process("firefox").?;
    try std.testing.expectEqualSlices(u8, "open -a \"Firefox\"", firefox_cmd.command);

    const chrome_cmd = hotkey.find_command_for_process("chrome").?;
    try std.testing.expectEqualSlices(u8, "open -a \"Google Chrome\"", chrome_cmd.command);
}

test "error on command invocation in process list" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Try to use command invocation as process list entry - should fail
    const content =
        \\.define toggle : open -a "{{1}}"
        \\cmd - a [
        \\    @toggle("Firefox") : echo "This should fail"
        \\]
    ;

    // Should fail with ParseError
    try std.testing.expectError(error.ParseErrorOccurred, parser.parse(&mappings, content));

    // Verify error message
    const error_info = parser.error_info.?;
    try std.testing.expect(std.mem.containsAtLeast(u8, error_info.message, 1, "Command invocation"));
    try std.testing.expect(std.mem.containsAtLeast(u8, error_info.message, 1, "not allowed here"));
}

test "error on undefined process group in process list" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Try to use undefined process group - should fail
    const content =
        \\.define toggle : open -a "{{1}}"
        \\cmd - a [
        \\    @toggle : echo "This should fail"
        \\]
    ;

    // Should fail with ParseError
    try std.testing.expectError(error.ParseErrorOccurred, parser.parse(&mappings, content));

    // Verify error message
    const error_info = parser.error_info.?;
    try std.testing.expect(std.mem.containsAtLeast(u8, error_info.message, 1, "Undefined process group"));
    try std.testing.expect(std.mem.containsAtLeast(u8, error_info.message, 1, "@toggle"));
}

test "valid process group in process list" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Define process group and use it correctly
    const content =
        \\.define browsers ["Firefox", "Chrome", "Safari"]
        \\cmd - b [
        \\    @browsers : echo "Browser hotkey"
        \\    * : echo "Default"
        \\]
    ;

    try parser.parse(&mappings, content);

    // Should parse successfully
    try std.testing.expect(mappings.mode_map.get("default").?.hotkey_map.count() == 1);

    // Verify commands are set for all browsers
    const ctx = Hotkey.KeyboardLookupContext{};
    const keypress = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = c.kVK_ANSI_B };
    const hotkey = mappings.mode_map.get("default").?.hotkey_map.getKeyAdapted(keypress, ctx).?;

    const firefox_cmd = hotkey.find_command_for_process("Firefox").?;
    try std.testing.expectEqualSlices(u8, "echo \"Browser hotkey\"", firefox_cmd.command);

    const chrome_cmd = hotkey.find_command_for_process("Chrome").?;
    try std.testing.expectEqualSlices(u8, "echo \"Browser hotkey\"", chrome_cmd.command);

    const safari_cmd = hotkey.find_command_for_process("Safari").?;
    try std.testing.expectEqualSlices(u8, "echo \"Browser hotkey\"", safari_cmd.command);

    const default_cmd = hotkey.find_command_for_process("other_app").?;
    try std.testing.expectEqualSlices(u8, "echo \"Default\"", default_cmd.command);
}

test "invalid placeholder in command definition" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // Test various invalid placeholders
    const test_cases = .{
        .{ .content = ".define bad : echo {{a}}", .expected_error = "Invalid placeholder '{{a}}'" },
        .{ .content = ".define bad : echo {{}}", .expected_error = "Invalid placeholder '{{}}'" },
        .{ .content = ".define bad : echo {{0}}", .expected_error = "Invalid placeholder '{{0}}'" },
        .{ .content = ".define bad : echo {{1a}}", .expected_error = "Invalid placeholder '{{1a}}'" },
        .{ .content = ".define bad : echo {{-1}}", .expected_error = "Invalid placeholder '{{-1}}'" },
    };

    inline for (test_cases) |test_case| {
        parser.clearError();

        // Should fail with ParseError
        const result = parser.parse(&mappings, test_case.content);
        try std.testing.expectError(error.ParseErrorOccurred, result);

        // Verify error message contains expected text
        const error_info = parser.error_info.?;
        try std.testing.expect(std.mem.containsAtLeast(u8, error_info.message, 1, test_case.expected_error));
    }
}

test "duplicate command definition returns error" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // First add a command definition
    const content1 = ".define test_cmd : echo first";
    try parser.parse(&mappings, content1);

    // Verify it was added
    try std.testing.expect(parser.command_defs.contains("test_cmd"));

    // Now try to add a duplicate
    const content2 = ".define test_cmd : echo second";
    const result = parser.parse(&mappings, content2);
    try std.testing.expectError(error.CommandAlreadyDefined, result);

    // Verify the original is still there
    try std.testing.expect(parser.command_defs.contains("test_cmd"));
}

test "duplicate process group definition returns error" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = try Mappings.init(alloc);
    defer mappings.deinit();

    // First add a process group
    const content1 = ".define browsers [\"firefox\", \"chrome\"]";
    try parser.parse(&mappings, content1);

    // Verify it was added
    try std.testing.expect(parser.process_groups.contains("browsers"));

    // Now try to add a duplicate
    const content2 = ".define browsers [\"safari\", \"edge\"]";
    const result = parser.parse(&mappings, content2);
    try std.testing.expectError(error.ProcessGroupAlreadyDefined, result);

    // Verify the original is still there
    try std.testing.expect(parser.process_groups.contains("browsers"));
}
