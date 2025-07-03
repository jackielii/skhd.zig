const std = @import("std");
const c = @import("c.zig");
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;
const Hotkey = @import("HotkeyMultiArrayList.zig");
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
load_directives: std.ArrayList(LoadDirective) = undefined,
current_file_path: ?[]const u8 = null,
error_info: ?ParseError = null,

pub fn deinit(self: *Parser) void {
    // self.allocator.free(self.filename);
    // self.allocator.free(self.content);
    self.keycodes.deinit();
    for (self.load_directives.items) |directive| {
        self.allocator.free(directive.filename);
    }
    self.load_directives.deinit();
    if (self.error_info) |*error_info| {
        error_info.deinit();
    }
    self.* = undefined;
}

pub fn getError(self: *const Parser) ?ParseError {
    return self.error_info;
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
    return Parser{
        .allocator = allocator,
        .previous_token = null,
        .next_token = null,
        .keycodes = try Keycodes.init(allocator),
        .load_directives = std.ArrayList(LoadDirective).init(allocator),
    };
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
                try self.parse_hotkey(mappings);
            },
            .Token_Decl => {
                try self.parse_mode_decl(mappings);
            },
            .Token_Option => {
                try self.parse_option(mappings);
            },
            else => {
                self.error_info = try ParseError.fromToken(self.allocator, token, "Unexpected token", self.current_file_path);
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
fn processString(self: *Parser, str: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(self.allocator);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < str.len) {
        if (i + 1 < str.len and str[i] == '\\') {
            if (str[i + 1] == '\\' or str[i + 1] == '"') {
                // Skip the backslash and append the next character
                try result.append(str[i + 1]);
                i += 2;
                continue;
            }
        }
        try result.append(str[i]);
        i += 1;
    }

    // Always return owned slice
    return try result.toOwnedSlice();
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
        const default_mode = try mappings.get_mode_or_create_default("default") orelse unreachable;
        try hotkey.add_mode(default_mode);
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
        // Mode activation hotkey - don't add command, just set flag
        hotkey.flags = hotkey.flags.merge(.{ .activate = true });
        const mode_name = self.previous().text;
        // Don't add the target mode to the hotkey's mode list - that's for activation
        // Instead, store it as a command (the mode name to switch to) with ";" as process name
        try hotkey.add_process_mapping(";", Hotkey.ProcessCommand{ .command = mode_name });
    } else if (self.match(.Token_Forward)) {
        try hotkey.add_process_mapping("*", Hotkey.ProcessCommand{ .forwarded = try self.parse_keypress() });
    } else if (self.match(.Token_Command)) {
        const token = self.previous();
        const command = try self.expandCommand(mappings, token);
        defer self.allocator.free(command);
        try hotkey.add_process_mapping("*", Hotkey.ProcessCommand{ .command = command });
    } else if (self.match(.Token_BeginList)) {
        try self.parse_proc_list(mappings, hotkey);
    }

    try mappings.add_hotkey(hotkey);
}

fn parse_mode(self: *Parser, mappings: *Mappings, hotkey: *Hotkey) !void {
    const token: Token = self.previous();
    assert(token.type == .Token_Identifier);

    const name = token.text;
    const mode = try mappings.get_mode_or_create_default(name) orelse {
        const msg = try std.fmt.allocPrint(self.allocator, "Mode '{s}' not found. Did you forget to declare it with '::{s}'?", .{ name, name });
        defer self.allocator.free(msg);
        self.error_info = try ParseError.fromToken(self.allocator, token, msg, self.current_file_path);
        return error.ParseErrorOccurred;
    };
    try hotkey.add_mode(mode);
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

    const code = try std.fmt.parseInt(u32, key, 16);
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
    if (self.match(.Token_String)) {
        const name_token = self.previous();
        const process_name = try self.processString(name_token.text);
        defer self.allocator.free(process_name);
        if (self.match(.Token_Command)) {
            const token = self.previous();
            const command = try self.expandCommand(mappings, token);
            defer self.allocator.free(command);
            try hotkey.add_process_mapping(process_name, Hotkey.ProcessCommand{ .command = command });
        } else if (self.match(.Token_Forward)) {
            try hotkey.add_process_mapping(process_name, Hotkey.ProcessCommand{ .forwarded = try self.parse_keypress() });
        } else if (self.match(.Token_Unbound)) {
            try hotkey.add_process_mapping(process_name, Hotkey.ProcessCommand{ .unbound = void{} });
        } else {
            const token = self.peek() orelse self.previous();
            self.error_info = try ParseError.fromToken(self.allocator, token, "Expected command ':', forward '|' or unbound '~' after process name", self.current_file_path);
            return error.ParseErrorOccurred;
        }
        try self.parse_proc_list(mappings, hotkey);
    } else if (self.match(.Token_ProcessGroup)) {
        // Handle @group_name reference
        const group_token = self.previous();
        const group_name = group_token.text[1..]; // Skip the @ prefix

        // Look up the process group in mappings
        if (mappings.process_groups.get(group_name)) |processes| {
            // Now parse the action (command, forward, or unbound)
            if (self.match(.Token_Command)) {
                // Apply same command to all processes in the group
                const token = self.previous();
                const command = try self.expandCommand(mappings, token);
                defer self.allocator.free(command);
                for (processes) |process_name| {
                    try hotkey.add_process_mapping(process_name, Hotkey.ProcessCommand{ .command = command });
                }
            } else if (self.match(.Token_Forward)) {
                const forward_key = try self.parse_keypress();
                for (processes) |process_name| {
                    try hotkey.add_process_mapping(process_name, Hotkey.ProcessCommand{ .forwarded = forward_key });
                }
            } else if (self.match(.Token_Unbound)) {
                for (processes) |process_name| {
                    try hotkey.add_process_mapping(process_name, Hotkey.ProcessCommand{ .unbound = void{} });
                }
            } else {
                const token = self.peek() orelse self.previous();
                self.error_info = try ParseError.fromToken(self.allocator, token, "Expected command ':', forward '|' or unbound '~' after process group", self.current_file_path);
                return error.ParseErrorOccurred;
            }
        } else {
            const msg = try std.fmt.allocPrint(self.allocator, "Undefined process group '@{s}'", .{group_name});
            defer self.allocator.free(msg);
            self.error_info = try ParseError.fromToken(self.allocator, group_token, msg, self.current_file_path);
            return error.ParseErrorOccurred;
        }
        try self.parse_proc_list(mappings, hotkey);
    } else if (self.match(.Token_Wildcard)) {
        if (self.match(.Token_Command)) {
            const token = self.previous();
            const command = try self.expandCommand(mappings, token);
            defer self.allocator.free(command);
            try hotkey.add_process_mapping("*", Hotkey.ProcessCommand{ .command = command });
        } else if (self.match(.Token_Forward)) {
            try hotkey.add_process_mapping("*", Hotkey.ProcessCommand{ .forwarded = try self.parse_keypress() });
        } else if (self.match(.Token_Unbound)) {
            try hotkey.add_process_mapping("*", Hotkey.ProcessCommand{ .unbound = {} });
        } else {
            const token = self.peek() orelse self.previous();
            self.error_info = try ParseError.fromToken(self.allocator, token, "Expected command ':', forward '|' or unbound '~' after wildcard", self.current_file_path);
            return error.ParseErrorOccurred;
        }
        try self.parse_proc_list(mappings, hotkey);
    } else if (self.match(.Token_EndList)) {
        if (hotkey.getProcessNames().len == 0) {
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
        const cmd_token = self.previous();
        const command = try self.expandCommand(mappings, cmd_token);
        defer self.allocator.free(command);
        try mode.set_command(command);
    }

    if (try mappings.get_mode_or_create_default(mode_name)) |existing_mode| {
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
        try mappings.put_mode(mode);
    }
}

fn expandCommand(self: *Parser, mappings: *Mappings, command_token: Token) ![]const u8 {
    const command_text = command_token.text;
    // Check if the command starts with @
    if (command_text.len > 0 and command_text[0] == '@') {
        // Find the end of the command name
        var name_end: usize = 1;
        while (name_end < command_text.len and command_text[name_end] != '(') : (name_end += 1) {}

        const command_name = command_text[1..name_end];

        // Look up the command definition
        const cmd_def = mappings.command_defs.get(command_name) orelse {
            // Command not found - return copy of original text
            return try self.allocator.dupe(u8, command_text);
        };

        // Check if arguments are provided
        if (name_end < command_text.len and command_text[name_end] == '(') {
            // Parse arguments
            var args = std.ArrayList([]const u8).init(self.allocator);
            defer args.deinit();
            defer for (args.items) |arg| {
                self.allocator.free(arg);
            };

            var i = name_end + 1;
            while (i < command_text.len and command_text[i] != ')') {
                // Skip whitespace
                while (i < command_text.len and (command_text[i] == ' ' or command_text[i] == '\t')) : (i += 1) {}

                if (i >= command_text.len or command_text[i] == ')') break;

                // Expect opening quote
                if (command_text[i] != '"') {
                    const msg = try std.fmt.allocPrint(self.allocator, 
                        "Command arguments must be enclosed in double quotes. Found '{c}' at position {d} in '{s}'", 
                        .{ command_text[i], i + 1, command_text });
                    defer self.allocator.free(msg);
                    self.error_info = try ParseError.fromToken(self.allocator, command_token, msg, self.current_file_path);
                    return error.ParseErrorOccurred;
                }
                i += 1;

                // Find closing quote
                const arg_start = i;
                while (i < command_text.len and command_text[i] != '"') : (i += 1) {
                    // Skip escaped quotes
                    if (command_text[i] == '\\' and i + 1 < command_text.len and command_text[i + 1] == '"') {
                        i += 1;
                    }
                }

                if (i >= command_text.len) {
                    const msg = try std.fmt.allocPrint(self.allocator, 
                        "Unterminated string in command arguments. Missing closing quote for argument starting at position {d} in '{s}'", 
                        .{ arg_start, command_text });
                    defer self.allocator.free(msg);
                    self.error_info = try ParseError.fromToken(self.allocator, command_token, msg, self.current_file_path);
                    return error.ParseErrorOccurred;
                }

                const raw_arg = command_text[arg_start..i];
                const processed_arg = try self.processString(raw_arg);
                try args.append(processed_arg);
                i += 1; // Skip closing quote

                // Skip whitespace and optional comma
                while (i < command_text.len and (command_text[i] == ' ' or command_text[i] == '\t')) : (i += 1) {}
                if (i < command_text.len and command_text[i] == ',') {
                    i += 1;
                    while (i < command_text.len and (command_text[i] == ' ' or command_text[i] == '\t')) : (i += 1) {}
                }
            }

            // Validate argument count
            if (args.items.len != cmd_def.max_placeholder) {
                // Create error message
                const msg = if (cmd_def.max_placeholder == 0)
                    try std.fmt.allocPrint(self.allocator, "Command '@{s}' expects no arguments but {d} provided", .{ command_name, args.items.len })
                else if (args.items.len < cmd_def.max_placeholder)
                    try std.fmt.allocPrint(self.allocator, "Command '@{s}' expects {d} arguments but only {d} provided", .{ command_name, cmd_def.max_placeholder, args.items.len })
                else
                    try std.fmt.allocPrint(self.allocator, "Command '@{s}' expects {d} arguments but {d} provided", .{ command_name, cmd_def.max_placeholder, args.items.len });
                defer self.allocator.free(msg);

                self.error_info = try ParseError.fromToken(self.allocator, command_token, msg, self.current_file_path);
                return error.ParseErrorOccurred;
            }

            // Expand the template
            var result = std.ArrayList(u8).init(self.allocator);
            errdefer result.deinit();

            i = 0;
            while (i < cmd_def.template.len) {
                if (i + 3 < cmd_def.template.len and
                    cmd_def.template[i] == '{' and cmd_def.template[i + 1] == '{')
                {
                    // Found placeholder start
                    var j = i + 2;
                    var num: u8 = 0;
                    while (j < cmd_def.template.len and cmd_def.template[j] >= '0' and cmd_def.template[j] <= '9') : (j += 1) {
                        num = num * 10 + (cmd_def.template[j] - '0');
                    }
                    if (j + 1 < cmd_def.template.len and
                        cmd_def.template[j] == '}' and cmd_def.template[j + 1] == '}')
                    {
                        // Valid placeholder
                        if (num > 0 and num <= args.items.len) {
                            try result.appendSlice(args.items[num - 1]);
                        }
                        i = j + 2;
                        continue;
                    }
                }
                try result.append(cmd_def.template[i]);
                i += 1;
            }

            // Transfer ownership using toOwnedSlice
            return try result.toOwnedSlice();
        } else if (cmd_def.max_placeholder > 0) {
            // Error: command expects arguments but none provided
            const msg = try std.fmt.allocPrint(self.allocator, "Command '@{s}' expects {d} arguments but none provided", .{ command_name, cmd_def.max_placeholder });
            defer self.allocator.free(msg);

            self.error_info = try ParseError.fromToken(self.allocator, command_token, msg, self.current_file_path);
            return error.ParseErrorOccurred;
        } else {
            // No arguments needed, return a copy of the template
            return try self.allocator.dupe(u8, cmd_def.template);
        }
    }

    // Not a command reference, return a copy
    return try self.allocator.dupe(u8, command_text);
}

fn parse_option(self: *Parser, mappings: *Mappings) !void {
    assert(self.match(.Token_Option));
    const option = self.previous().text;

    if (std.mem.eql(u8, option, ".define")) {
        // Parse name after .define
        if (!self.match(.Token_Identifier)) {
            const token = self.peek() orelse self.previous();
            self.error_info = try ParseError.fromToken(self.allocator, token, "Expected name after '.define'", self.current_file_path);
            return error.ParseErrorOccurred;
        }

        const name = self.previous().text;

        // Check if this is a command definition or process group
        if (self.match(.Token_Command)) {
            // Command definition: .define name : command
            const command_template = self.previous().text;

            // Scan template for placeholders and find max placeholder number
            var max_placeholder: u8 = 0;
            var i: usize = 0;
            while (i < command_template.len - 3) : (i += 1) {
                if (command_template[i] == '{' and command_template[i + 1] == '{') {
                    // Found start of placeholder
                    var j = i + 2;
                    var num: u8 = 0;
                    while (j < command_template.len and command_template[j] >= '0' and command_template[j] <= '9') : (j += 1) {
                        num = num * 10 + (command_template[j] - '0');
                    }
                    if (j + 1 < command_template.len and command_template[j] == '}' and command_template[j + 1] == '}') {
                        // Valid placeholder found
                        if (num > max_placeholder) {
                            max_placeholder = num;
                        }
                        i = j + 1; // Skip past the placeholder
                    }
                }
            }

            try mappings.add_command_def(name, command_template, max_placeholder);
        } else if (self.match(.Token_BeginList)) {
            // Process group definition: .define name ["app1", "app2"]
            var process_list = std.ArrayList([]const u8).init(self.allocator);
            defer process_list.deinit();
            defer for (process_list.items) |process| {
                self.allocator.free(process);
            };

            while (self.match(.Token_String)) {
                const process_name = try self.processString(self.previous().text);
                try process_list.append(process_name);

                // Skip optional comma
                _ = self.match(.Token_Comma);
            }

            if (!self.match(.Token_EndList)) {
                const token = self.peek() orelse self.previous();
                self.error_info = try ParseError.fromToken(self.allocator, token, "Expected ']' to close process list", self.current_file_path);
                return error.ParseErrorOccurred;
            }

            try mappings.add_process_group(name, process_list.items);
        } else {
            const token = self.peek() orelse self.previous();
            self.error_info = try ParseError.fromToken(self.allocator, token, "Expected ':' for command definition or '[' for process group after name", self.current_file_path);
            return error.ParseErrorOccurred;
        }
    } else if (std.mem.eql(u8, option, ".load")) {
        if (self.match(.Token_String)) {
            const filename_token = self.previous();
            const filename = try self.processString(filename_token.text);
            try self.load_directives.append(LoadDirective{
                .filename = filename,
                .token = filename_token,
            });
        } else {
            const token = self.peek() orelse self.previous();
            self.error_info = try ParseError.fromToken(self.allocator, token, "Expected filename after '.load'", self.current_file_path);
            return error.ParseErrorOccurred;
        }
    } else if (std.mem.eql(u8, option, ".blacklist")) {
        if (self.match(.Token_BeginList)) {
            while (self.match(.Token_String)) {
                const token = self.previous();
                const app_name = try self.processString(token.text);
                defer self.allocator.free(app_name);
                try mappings.add_blacklist(app_name);
            }
            if (!self.match(.Token_EndList)) {
                const token = self.peek() orelse self.previous();
                self.error_info = try ParseError.fromToken(self.allocator, token, "Expected ']' to close blacklist", self.current_file_path);
                return error.ParseErrorOccurred;
            }
        } else {
            const token = self.peek() orelse self.previous();
            self.error_info = try ParseError.fromToken(self.allocator, token, "Expected '[' after '.blacklist'", self.current_file_path);
            return error.ParseErrorOccurred;
        }
    } else if (std.mem.eql(u8, option, ".shell") or std.mem.eql(u8, option, ".SHELL")) {
        if (self.match(.Token_String)) {
            const shell_path = try self.processString(self.previous().text);
            defer self.allocator.free(shell_path);
            try mappings.set_shell(shell_path);
        } else {
            const token = self.peek() orelse self.previous();
            self.error_info = try ParseError.fromToken(self.allocator, token, "Expected shell path after '.shell'", self.current_file_path);
            return error.ParseErrorOccurred;
        }
    } else {
        const msg = try std.fmt.allocPrint(self.allocator, "Unknown option '{s}'. Valid options are: .define, .load, .blacklist, .shell", .{option});
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
        const abs_path = try std.fs.cwd().realpath(resolved_path, &path_buf);
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

    // try std.testing.expectError(error.@"Mode already exists in hotkey mode", parser.parse(&mappings, "default, default"));
    //
    // try std.testing.expectError(error.@"Mode not found", parser.parse(&mappings, "default, xxx"));
    //
    // const string = try std.fmt.allocPrint(alloc, "{}", .{mappings});
    // defer alloc.free(string);
    //
    // // print("{s}\n", .{string});
    // try std.testing.expectEqual(1, mappings.mode_map.count());

    // var tokenizer = try Tokenizer.init("ctrl + shift - h :");
    // while (tokenizer.get_token()) |token| {
    //     print("token: {?}\n", .{token});
    // }
    // try parser.parse(&mappings, "default < ctrl + shift - b: echo");
    // print("{s}\n", .{mappings});

    try parser.parse(&mappings,
        \\ cmd + shift - h [
        \\     "notepad.exe": echo
        \\     "chrome.exe": foo
        \\     "firefox.exe" | cmd + shift - h
        \\     *: ~
        \\ ]
    );
    // print("{s}\n", .{mappings});
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
    try std.testing.expect(mappings.hotkey_map.count() >= 2);
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
    try std.testing.expect(mappings.hotkey_map.count() >= 3);
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
    try std.testing.expect(mappings.hotkey_map.count() >= 3);
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
    try std.testing.expect(mappings.command_defs.contains("focus_recent"));

    // Verify hotkey was created with expanded command
    try std.testing.expect(mappings.hotkey_map.count() == 1);

    // Verify command expanded correctly
    const ctx = Hotkey.KeyboardLookupContext{};
    const keypress = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = 0x30 }; // tab key
    const hotkey = mappings.hotkey_map.getKeyAdapted(keypress, ctx).?;
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
    try std.testing.expect(mappings.command_defs.contains("yabai_focus"));
    const cmd_def = mappings.command_defs.get("yabai_focus").?;
    try std.testing.expectEqual(@as(u8, 1), cmd_def.max_placeholder);

    // Verify hotkeys were created
    try std.testing.expect(mappings.hotkey_map.count() == 2);

    // Verify hotkeys expand to correct commands
    const ctx = Hotkey.KeyboardLookupContext{};
    const keypress1 = Hotkey.KeyPress{ .flags = .{ .lcmd = true }, .key = c.kVK_ANSI_H };
    const hotkey1 = mappings.hotkey_map.getKeyAdapted(keypress1, ctx).?;
    const cmd1 = hotkey1.find_command_for_process("").?;
    try std.testing.expectEqualSlices(u8, "yabai -m window --focus west || yabai -m display --focus west", cmd1.command);
    const keypress2 = Hotkey.KeyPress{ .flags = .{ .lcmd = true }, .key = c.kVK_ANSI_J };
    const hotkey2 = mappings.hotkey_map.getKeyAdapted(keypress2, ctx).?;
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
    try std.testing.expect(mappings.command_defs.contains("window_action"));
    const cmd_def = mappings.command_defs.get("window_action").?;
    try std.testing.expectEqual(@as(u8, 2), cmd_def.max_placeholder);

    // Verify hotkeys were created
    try std.testing.expect(mappings.hotkey_map.count() == 2);

    // Verify commands expanded correctly
    const ctx = Hotkey.KeyboardLookupContext{};
    const keypress1 = Hotkey.KeyPress{ .flags = .{ .cmd = true, .shift = true }, .key = c.kVK_ANSI_H };
    const hotkey1 = mappings.hotkey_map.getKeyAdapted(keypress1, ctx).?;
    const cmd1 = hotkey1.find_command_for_process("").?;
    try std.testing.expectEqualSlices(u8, "yabai -m window --swap west || yabai -m display --swap west", cmd1.command);

    const keypress2 = Hotkey.KeyPress{ .flags = .{ .cmd = true, .shift = true }, .key = c.kVK_ANSI_J };
    const hotkey2 = mappings.hotkey_map.getKeyAdapted(keypress2, ctx).?;
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
    try std.testing.expect(mappings.command_defs.contains("notify"));

    // Verify hotkey was created
    try std.testing.expect(mappings.hotkey_map.count() == 1);

    // Verify placeholder replaced correctly in both locations
    const ctx = Hotkey.KeyboardLookupContext{};
    const keypress = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = c.kVK_ANSI_N };
    const hotkey = mappings.hotkey_map.getKeyAdapted(keypress, ctx).?;
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
    const error_info = parser.getError().?;
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
    const error_info = parser.getError().?;
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
    const error_info = parser.getError().?;
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
    try parser.parse(&mappings, content);

    // Should create hotkey with unexpanded command text
    try std.testing.expect(mappings.hotkey_map.count() == 1);

    // Verify command not expanded (returned as-is)
    const ctx = Hotkey.KeyboardLookupContext{};
    const keypress = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = c.kVK_ANSI_H };
    const hotkey = mappings.hotkey_map.getKeyAdapted(keypress, ctx).?;
    const cmd = hotkey.find_command_for_process("").?;
    try std.testing.expectEqualSlices(u8, "@undefined_command(\"arg\")", cmd.command);
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
    const error_info = parser.getError().?;
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
    try std.testing.expect(mappings.command_defs.contains("notify"));
    try std.testing.expect(mappings.hotkey_map.count() == 1);

    // Verify escape sequences are processed correctly
    const ctx = Hotkey.KeyboardLookupContext{};
    const keypress = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = c.kVK_ANSI_N };
    const hotkey = mappings.hotkey_map.getKeyAdapted(keypress, ctx).?;
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
    try std.testing.expect(mappings.command_defs.contains("resize_win"));
    try std.testing.expect(mappings.hotkey_map.count() == 2);

    // Verify commands expanded correctly
    const ctx = Hotkey.KeyboardLookupContext{};
    const keypress1 = Hotkey.KeyPress{ .flags = .{ .cmd = true, .control = true, .shift = true }, .key = c.kVK_ANSI_K };
    const hotkey1 = mappings.hotkey_map.getKeyAdapted(keypress1, ctx).?;
    const cmd1 = hotkey1.find_command_for_process("").?;
    try std.testing.expectEqualSlices(u8, "yabai -m window --resize top:0:-10", cmd1.command);

    const keypress2 = Hotkey.KeyPress{ .flags = .{ .cmd = true, .control = true, .shift = true }, .key = c.kVK_ANSI_J };
    const hotkey2 = mappings.hotkey_map.getKeyAdapted(keypress2, ctx).?;
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
    try std.testing.expect(mappings.command_defs.contains("toggle_app"));
    try std.testing.expect(mappings.hotkey_map.count() == 2);

    // Verify whitespace is trimmed from arguments
    const ctx = Hotkey.KeyboardLookupContext{};
    const keypress1 = Hotkey.KeyPress{ .flags = .{ .ralt = true }, .key = c.kVK_ANSI_M };
    const hotkey1 = mappings.hotkey_map.getKeyAdapted(keypress1, ctx).?;
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
    const cmd_def = mappings.command_defs.get("complex").?;
    try std.testing.expectEqual(@as(u8, 3), cmd_def.max_placeholder);

    // Verify placeholders expanded in correct order
    const ctx = Hotkey.KeyboardLookupContext{};
    const keypress = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = c.kVK_ANSI_C };
    const hotkey = mappings.hotkey_map.getKeyAdapted(keypress, ctx).?;
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
    try std.testing.expect(mappings.command_defs.contains("toggle"));
    try std.testing.expect(mappings.hotkey_map.count() == 1);

    // Verify commands expanded for different processes
    const ctx = Hotkey.KeyboardLookupContext{};
    const keypress = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = c.kVK_ANSI_A };
    const hotkey = mappings.hotkey_map.getKeyAdapted(keypress, ctx).?;

    const firefox_cmd = hotkey.find_command_for_process("firefox").?;
    try std.testing.expectEqualSlices(u8, "open -a \"Firefox\"", firefox_cmd.command);

    const chrome_cmd = hotkey.find_command_for_process("chrome").?;
    try std.testing.expectEqualSlices(u8, "open -a \"Google Chrome\"", chrome_cmd.command);
}
