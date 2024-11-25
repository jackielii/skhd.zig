const std = @import("std");
const Tokenizer = @import("./Tokenizer.zig");
const Token = Tokenizer.Token;
const Hotkey = @import("./Hotkey.zig");
const print = std.debug.print;
const assert = std.debug.assert;
const Mode = @import("./Mode.zig");
const Mappings = @import("./Mappings.zig");
const Keycodes = @import("./Keycodes.zig");
const consts = @import("./consts.zig");
const utils = @import("./utils.zig");

const Parser = @This();

// const ParserError = error{
//     @"Expect token",
//     @"Mode not found",
//     @"Expected identifier",
//     @"Unexpected token",
//     @"Mode already exists in hotkey mode",
//     @"Expected '<'",
// };

const LoadDirective = struct {
    filename: []const u8,
    token: Token,
};

// struct parser
// {
//     char *file;
//     struct token previous_token;
//     struct token current_token;
//     struct tokenizer tokenizer;
//     struct table *mode_map;
//     struct table *blacklst;
//     struct load_directive *load_directives;
//     bool error;
// };

// unmanaged:
allocator: std.mem.Allocator,
tokenizer: Tokenizer = undefined,
content: []const u8 = undefined,
previous_token: ?Token = undefined,
next_token: ?Token = undefined,
keycodes: Keycodes = undefined,

pub fn deinit(self: *Parser) void {
    // self.allocator.free(self.filename);
    // self.allocator.free(self.content);
    self.keycodes.deinit();
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
    };
}

pub fn parse(self: *Parser, mappings: *Mappings, content: []const u8) !void {
    self.content = content;
    self.tokenizer = try Tokenizer.init(content);

    _ = self.advance();
    while (self.peek()) |token| {
        switch (token.type) {
            .Token_Identifier, .Token_Modifier, .Token_Literal, .Token_Key_Hex, .Token_Key => {
                try self.parse_hotkey(mappings);
            },
            else => {
                unreachable;
            },
        }
        break;
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
    // var found_modifier = false;

    // print("hotkey :: #{d} {{\n", .{self.next_token.?.line});

    if (self.match(.Token_Identifier)) {
        try self.parse_mode(mappings, hotkey);
    }

    if (hotkey.mode_list.count() > 0) {
        if (!self.match(.Token_Insert)) {
            return error.@"Expected '<'";
        }
    } else {
        const default_mode = try mappings.get_mode_or_create_default("default") orelse unreachable;
        try hotkey.mode_list.put(default_mode, {});
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
        hotkey.flags |= keypress.flags;
        hotkey.key = keypress.key;
    } else {
        return error.@"Expected key, key hex, literal or modifier";
    }

    if (self.match(.Token_Forward)) {
        hotkey.flags |= @intFromEnum(consts.hotkey_flag.Hotkey_Flag_Passthrough);
    }

    if (self.match(.Token_Forward)) {
        hotkey.set_wildcard_forwarded(try self.parse_keypress());
    } else if (self.match(.Token_Command)) {
        try hotkey.set_wildcard_command(self.previous().text);
    } else if (self.match(.Token_BeginList)) {
        try self.parse_proc_list(hotkey);
    }

    // switch (true) {
    //     self.match(.Token_Key) => hotkey.key = try self.parse_key(),
    //     self.match(.Token_Key_Hex) => hotkey.key = try self.parse_key_hex(),
    //     self.match(.Token_Literal) => try self.parse_key_literal(hotkey),
    //     else => return error.@"Expected key, key hex or literal",
    // }

    var it = hotkey.mode_list.iterator();
    while (it.next()) |kv| {
        const mode = kv.key_ptr.*;
        try mode.hotkey_map.put(hotkey, {});
    }
}

fn parse_mode(self: *Parser, mappings: *Mappings, hotkey: *Hotkey) !void {
    const token: Token = self.previous();
    assert(token.type == .Token_Identifier);

    const name = token.text;
    const mode = try mappings.get_mode_or_create_default(name) orelse return error.@"Mode not found";

    if (hotkey.mode_list.contains(mode)) {
        return error.@"Mode already exists in hotkey mode";
    }
    try hotkey.mode_list.put(mode, {});
    // print("\tmode: '{s}'\n", .{name});

    // const token1 = self.advance_token() orelse return error.@"Expected token";
    if (self.match(.Token_Comma)) {
        if (self.match(.Token_Identifier)) {
            try self.parse_mode(mappings, hotkey);
        } else {
            return error.@"Expected identifier";
        }
    }
}

const modifier_flags_str = @import("./consts.zig").modifier_flags_str;
const modifier_flags_value = @import("./consts.zig").modifier_flags_value;

fn parse_modifier(self: *Parser) !u32 {
    const token = self.previous();
    var flags: u32 = 0;

    for (modifier_flags_str, 0..) |flag, i| {
        if (std.mem.eql(u8, token.text, flag)) {
            flags |= modifier_flags_value[i];
            break;
        }
    } else {
        return error.@"Unknown modifier";
    }

    if (self.match(.Token_Plus)) {
        if (self.match(.Token_Modifier)) {
            flags |= try self.parse_modifier();
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
    // print("\tkey: '{s}' (0x{x:0>2})\n", .{ key, keycode });
    return keycode;
}

fn parse_key_hex(self: *Parser) !u32 {
    const token = self.previous();
    const key = token.text;

    const code = try std.fmt.parseInt(u32, key, 16);
    return code;
}

const literal_keycode_str = @import("./consts.zig").literal_keycode_str;

fn parse_key_literal(self: *Parser) !Hotkey.KeyPress {
    const token = self.previous();
    const key = token.text;
    var flags: u32 = 0;
    var keycode: u32 = 0;

    for (literal_keycode_str, 0..) |literal_key, i| {
        if (std.mem.eql(u8, key, literal_key)) {
            if (i > consts.KEY_HAS_IMPLICIT_FN_MOD and i < consts.KEY_HAS_IMPLICIT_NX_MOD) {
                flags |= @intFromEnum(consts.hotkey_flag.Hotkey_Flag_Fn);
            } else if (i >= consts.KEY_HAS_IMPLICIT_NX_MOD) {
                flags |= @intFromEnum(consts.hotkey_flag.Hotkey_Flag_NX);
            }
            keycode = try self.keycodes.get_keycode(literal_key);
            break;
        }
    } else {
        return error.@"Unknown literal key";
    }

    return Hotkey.KeyPress{ .flags = flags, .key = keycode };
}

fn parse_keypress(self: *Parser) !Hotkey.KeyPress {
    var flags: u32 = 0;
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
        flags |= keypress.flags;
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

test "init" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();
}

test "Parse" {
    const alloc = std.testing.allocator;
    var parser = try Parser.init(alloc);
    defer parser.deinit();

    var mappings = Mappings.init(alloc);
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
    print("{s}\n", .{mappings});
}
