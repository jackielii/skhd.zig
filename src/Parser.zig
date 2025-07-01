const std = @import("std");
const Tokenizer = @import("./Tokenizer.zig");
const Token = Tokenizer.Token;
const Hotkey = @import("./Hotkey.zig");
const print = std.debug.print;
const assert = std.debug.assert;
const Mode = @import("./Mode.zig");
const Mappings = @import("./Mappings.zig");
const Keycodes = @import("./Keycodes.zig");
const utils = @import("./utils.zig");
const ModifierFlag = @import("Keycodes.zig").ModifierFlag;

const Parser = @This();

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

pub fn deinit(self: *Parser) void {
    // self.allocator.free(self.filename);
    // self.allocator.free(self.content);
    self.keycodes.deinit();
    for (self.load_directives.items) |directive| {
        self.allocator.free(directive.filename);
    }
    self.load_directives.deinit();
    self.* = undefined;
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
                return error.@"Unexpected token";
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
    // print("token: {?}\n", .{self.next_token});
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

fn parse_hotkey(self: *Parser, mappings: *Mappings) !void {
    var hotkey = try Hotkey.create(self.allocator);
    errdefer hotkey.destroy();

    if (self.match(.Token_Identifier)) {
        try self.parse_mode(mappings, hotkey);
    }

    if (hotkey.mode_list.count() > 0) {
        if (!self.match(.Token_Insert)) {
            return error.@"Expected '<'";
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
            return error.@"Unexpected token";
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
        return error.@"Expected key, key hex, literal or modifier";
    }

    if (self.match(.Token_Arrow)) {
        hotkey.flags = hotkey.flags.merge(.{ .passthrough = true });
    }

    if (self.match(.Token_Activate)) {
        // Mode activation hotkey - don't add command, just set flag
        hotkey.flags = hotkey.flags.merge(.{ .activate = true });
        const mode_name = self.previous().text;
        // Don't add the target mode to the hotkey's mode list - that's for activation
        // Instead, store it as a command (the mode name to switch to)
        try hotkey.set_wildcard_command(mode_name);
    } else if (self.match(.Token_Forward)) {
        hotkey.set_wildcard_forwarded(try self.parse_keypress());
    } else if (self.match(.Token_Command)) {
        try hotkey.set_wildcard_command(self.previous().text);
    } else if (self.match(.Token_BeginList)) {
        try self.parse_proc_list(hotkey);
    }

    try mappings.add_hotkey(hotkey);
}

fn parse_mode(self: *Parser, mappings: *Mappings, hotkey: *Hotkey) !void {
    const token: Token = self.previous();
    assert(token.type == .Token_Identifier);

    const name = token.text;
    const mode = try mappings.get_mode_or_create_default(name) orelse return error.@"Mode not found";
    try hotkey.add_mode(mode);
    if (self.match(.Token_Comma)) {
        if (self.match(.Token_Identifier)) {
            try self.parse_mode(mappings, hotkey);
        } else {
            return error.@"Expected identifier";
        }
    }
}

fn parse_modifier(self: *Parser) !ModifierFlag {
    const token = self.previous();
    var flags = ModifierFlag{};

    if (ModifierFlag.get(token.text)) |modifier_flags_value| {
        flags = flags.merge(modifier_flags_value);
    } else {
        return error.@"Unknown modifier";
    }

    if (self.match(.Token_Plus)) {
        if (self.match(.Token_Modifier)) {
            flags = flags.merge(try self.parse_modifier());
        } else {
            return error.@"Expected modifier";
        }
    }
    return flags;
}

fn parse_key(self: *Parser) !u32 {
    const token = self.previous();
    const key = token.text;
    const keycode = try self.keycodes.get_keycode(key);
    return keycode;
}

fn parse_key_hex(self: *Parser) !u32 {
    const token = self.previous();
    const key = token.text;

    const code = try std.fmt.parseInt(u32, key, 16);
    return code;
}

const literal_keycode_str = @import("./Keycodes.zig").literal_keycode_str;
const literal_keycode_value = @import("./Keycodes.zig").literal_keycode_value;

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
        return error.@"Unknown literal key";
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
        return error.@"Unexpected token";
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
        return error.@"Expected key, key hex, literal or modifier";
    }

    return Hotkey.KeyPress{ .flags = flags, .key = keycode };
}

fn parse_proc_list(self: *Parser, hotkey: *Hotkey) !void {
    if (self.match(.Token_String)) {
        const name_token = self.previous();
        try hotkey.add_process_name(name_token.text);
        if (self.match(.Token_Command)) {
            try hotkey.add_proc_command(self.previous().text);
        } else if (self.match(.Token_Forward)) {
            try hotkey.add_proc_forward(try self.parse_keypress());
        } else if (self.match(.Token_Unbound)) {
            try hotkey.add_proc_unbound();
        } else {
            return error.@"Expected command ':', forward '|' or unbound '~'";
        }
        try self.parse_proc_list(hotkey);
    } else if (self.match(.Token_Wildcard)) {
        if (self.match(.Token_Command)) {
            try hotkey.set_wildcard_command(self.previous().text);
        } else if (self.match(.Token_Forward)) {
            hotkey.set_wildcard_forwarded(try self.parse_keypress());
        } else if (self.match(.Token_Unbound)) {
            hotkey.set_wildcard_unbound();
        } else {
            return error.@"Expected command ':', forward '|' or unbound '~'";
        }
        try self.parse_proc_list(hotkey);
    } else if (self.match(.Token_EndList)) {
        if (hotkey.process_names.items.len == 0) {
            return error.@"Expected string, wildcard or end list";
        }
    } else {
        return error.@"Expected string, wildcard or end list";
    }
}

fn parse_mode_decl(self: *Parser, mappings: *Mappings) !void {
    assert(self.match(.Token_Decl));
    if (!self.match(.Token_Identifier)) {
        return error.@"Expected identifier";
    }
    const token = self.previous();
    const mode_name = token.text;
    var mode = try Mode.init(self.allocator, mode_name);
    errdefer mode.deinit();

    if (self.match(.Token_Capture)) {
        mode.capture = true;
    }

    if (self.match(.Token_Command)) {
        try mode.set_command(self.previous().text);
    }

    if (try mappings.get_mode_or_create_default(mode_name)) |existing_mode| {
        defer mode.deinit();
        if (std.mem.eql(u8, existing_mode.name, "default")) {
            existing_mode.initialized = false;
            existing_mode.capture = mode.capture;
            if (mode.command) |cmd| try existing_mode.set_command(cmd);
        } else if (std.mem.eql(u8, existing_mode.name, mode_name)) {
            return error.@"Mode already exists";
        }
    } else {
        try mappings.put_mode(mode);
    }
}

fn parse_option(self: *Parser, mappings: *Mappings) !void {
    assert(self.match(.Token_Option));
    const option = self.previous().text;

    if (std.mem.eql(u8, option, "load")) {
        if (self.match(.Token_String)) {
            const filename_token = self.previous();
            const filename = try self.allocator.dupe(u8, filename_token.text);
            try self.load_directives.append(LoadDirective{
                .filename = filename,
                .token = filename_token,
            });
        } else {
            return error.@"Expected filename";
        }
    } else if (std.mem.eql(u8, option, "blacklist")) {
        if (self.match(.Token_BeginList)) {
            while (self.match(.Token_String)) {
                const token = self.previous();
                try mappings.add_blacklist(token.text);
            }
            if (!self.match(.Token_EndList)) {
                return error.@"Expected ']'";
            }
        } else {
            return error.@"Expected '['";
        }
    } else if (std.mem.eql(u8, option, "shell") or std.mem.eql(u8, option, "SHELL")) {
        if (self.match(.Token_String)) {
            try mappings.set_shell(self.previous().text);
        } else {
            return error.@"Expected string";
        }
    } else {
        return error.@"Unknown option";
    }
}

pub fn processLoadDirectives(self: *Parser, mappings: *Mappings) !void {
    // Process each load directive
    for (self.load_directives.items) |directive| {
        const resolved_path = try self.resolveLoadPath(directive.filename);
        defer self.allocator.free(resolved_path);

        // Read the file content
        const content = std.fs.cwd().readFileAlloc(self.allocator, resolved_path, 1 << 20) catch |err| {
            // Report error with line info from the .load directive
            std.debug.print("skhd: could not open file '{s}' from load directive #{d}:{d}\n", .{
                resolved_path,
                directive.token.line,
                directive.token.cursor,
            });
            return err;
        };
        defer self.allocator.free(content);

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

// TODO: This test times out because it prints the entire mappings structure
// test "Parse my skhd.conf" {
//     const alloc = std.testing.allocator;
//     const content = try std.fs.cwd().readFileAlloc(alloc, "/Users/jackieli/.config/skhd/skhdrc", 1 << 16);
//     defer alloc.free(content);

//     var parser = try Parser.init(alloc);
//     defer parser.deinit();

//     var mappings = try Mappings.init(alloc);
//     defer mappings.deinit();

//     try parser.parse(&mappings, content);
//     // print("{s}\n", .{mappings});
// }

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
    try std.testing.expectError(error.@"Expected string", parser.parse(&mappings, content));
}
