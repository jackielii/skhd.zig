const std = @import("std");
const Tokenizer = @import("./Tokenizer.zig");
const Token = Tokenizer.Token;
const Hotkey = @import("./Hotkey.zig");
const print = std.debug.print;
const assert = std.debug.assert;
const Mode = @import("./Mode.zig");
const Mappings = @import("./Mappings.zig");
const KeycodeTable = @import("./KeycodeTable.zig");
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

// managed:
// filename: []const u8,
content: []const u8 = undefined,
load_directives: []LoadDirective = undefined,
tokenizer: Tokenizer = undefined,
previous_token: ?Token = undefined,
next_token: ?Token = undefined,
keycodes: KeycodeTable = undefined,

pub fn deinit(self: *Parser) void {
    // self.allocator.free(self.filename);
    // self.allocator.free(self.content);
    self.keycodes.deinit();
    self.* = undefined;
}

pub fn init(allocator: std.mem.Allocator) Parser {
    // const f = try std.fs.cwd().openFile(filename, .{});
    // defer f.close();
    // const content = try f.readToEndAlloc(allocator, 1 << 24); // max size 16MB
    return Parser{
        .allocator = allocator,
        // .mappings = &mappings,
        // .filename = allocator.dupe(u8, filename),
        // .content = content,
        // .tokenizer = tokenizer,
        // .keycodes = try KeycodeTable.init(allocator),
    };
}

pub fn parse(self: *Parser, mappings: *Mappings, content: []const u8) !void {
    self.content = content;
    self.tokenizer = try Tokenizer.init(content);
    self.keycodes = try KeycodeTable.init(self.allocator);
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

    print("hotkey :: #{d} {{\n", .{self.next_token.?.line});

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
        try self.parse_key_literal(hotkey);
    } else {
        return error.@"Expected key, key hex or literal";
    }

    if (self.match(.Token_Forward)) {
        hotkey.flags |= @intFromEnum(consts.hotkey_flag.Hotkey_Flag_Passthrough);
    }

    if (self.match(.Token_Forward)) {
        print("\tforward: {{\n", .{});
        const forwarded = try self.parse_keypress();
        hotkey.forwarded = forwarded;
        utils.indentPrint(self.alloc, forwarded, "{}", forwarded);
        print("\t}}\n", .{});
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
    print("\tmode: '{s}'\n", .{name});

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
    print("\tkey: '{s}' (0x{x:0>2})\n", .{ key, keycode });
    return keycode;
}

fn parse_key_hex(self: *Parser) !u32 {
    const token = self.previous();
    const key = token.text;

    const code = try std.fmt.parseInt(u32, key, 16);
    return code;
}

const literal_keycode_str = @import("./consts.zig").literal_keycode_str;

fn parse_key_literal(self: *Parser, hotkey: *Hotkey) !void {
    const token = self.previous();
    const key = token.text;

    for (literal_keycode_str, 0..) |literal_key, i| {
        if (std.mem.eql(u8, key, literal_key)) {
            if (i > consts.KEY_HAS_IMPLICIT_FN_MOD and i < consts.KEY_HAS_IMPLICIT_NX_MOD) {
                hotkey.flags |= @intFromEnum(consts.hotkey_flag.Hotkey_Flag_Fn);
            } else if (i >= consts.KEY_HAS_IMPLICIT_NX_MOD) {
                hotkey.flags |= @intFromEnum(consts.hotkey_flag.Hotkey_Flag_NX);
            }
            hotkey.key = try self.keycodes.get_keycode(literal_key);
            return;
        }
    }
}

test "init" {
    const alloc = std.testing.allocator;
    var parser = Parser.init(alloc);
    defer parser.deinit();
}

test "Parse" {
    const alloc = std.testing.allocator;
    var parser = Parser.init(alloc);
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
    try parser.parse(&mappings, "default < ctrl + shift - b:");
}
