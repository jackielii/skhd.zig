const std = @import("std");
const Tokenizer = @import("./Tokenizer.zig");
const Token = Tokenizer.Token;
const Hotkey = @import("./Hotkey.zig");
const print = std.debug.print;
const assert = std.debug.assert;
const Mode = @import("./Mode.zig");
const Mappings = @import("./Mappings.zig");

const Parser = @This();

const ParserError = error{
    @"Expect token",
    @"Expected Identifier",
    @"Mode not found",
    @"Expected identifier",
    @"Mode already exists in hotkey mode",
    @"Expected '<'",
};

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
mappings: *Mappings = undefined,

// managed:
// filename: []const u8,
content: []const u8 = undefined,
load_directives: []LoadDirective = undefined,
tokenizer: Tokenizer = undefined,
previous_token: ?Token = undefined,
next_token: ?Token = undefined,

pub fn deinit(self: *Parser) void {
    // self.allocator.free(self.filename);
    // self.allocator.free(self.content);
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
    };
}

pub fn parse(self: *Parser, mappings: *Mappings, content: []const u8) !void {
    self.mappings = mappings;
    self.content = content;
    self.tokenizer = try Tokenizer.init(content);
    _ = self.advance();

    while (self.peek()) |token| {
        switch (token.type) {
            .Token_Identifier, .Token_Modifier, .Token_Literal, .Token_Key_Hex, .Token_Key => {
                try self.parse_hotkey();
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

fn parse_hotkey(self: *Parser) !void {
    var hotkey = try Hotkey.create(self.allocator);
    errdefer hotkey.destroy();
    // var found_modifier = false;

    print("hotkey :: #{d} {{\n", .{self.next_token.?.line});

    if (self.match(.Token_Identifier)) {
        try self.parse_mode(hotkey);
    }

    if (hotkey.mode_list.count() > 0) {
        if (!self.match(.Token_Insert)) {
            return ParserError.@"Expected '<'";
        }
    } else {
        const default_mode = try self.mappings.get_mode("default") orelse unreachable;
        try hotkey.mode_list.put(default_mode, {});
    }

    var it = hotkey.mode_list.iterator();
    while (it.next()) |kv| {
        const mode = kv.key_ptr.*;
        try mode.hotkey_map.put(hotkey, {});
    }
}

fn parse_mode(self: *Parser, hotkey: *Hotkey) !void {
    const token: Token = self.previous();
    assert(token.type == .Token_Identifier);

    const name = token.text;
    const mode = try self.mappings.get_mode(name) orelse return ParserError.@"Mode not found";

    if (hotkey.mode_list.contains(mode)) {
        return ParserError.@"Mode already exists in hotkey mode";
    }
    try hotkey.mode_list.put(mode, {});
    print("\tmode: '{s}'\n", .{name});

    // const token1 = self.advance_token() orelse return ParserError.@"Expected token";
    if (self.match(.Token_Comma)) {
        if (self.match(.Token_Identifier)) {
            try self.parse_mode(hotkey);
        } else {
            return ParserError.@"Expected identifier";
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

    // try std.testing.expectError(ParserError.@"Mode already exists in hotkey mode", parser.parse(&mappings, "default, default"));
    //
    // try std.testing.expectError(ParserError.@"Mode not found", parser.parse(&mappings, "default, xxx"));
    //
    // const string = try std.fmt.allocPrint(alloc, "{}", .{mappings});
    // defer alloc.free(string);
    //
    // // print("{s}\n", .{string});
    // try std.testing.expectEqual(1, mappings.mode_map.count());

    // var tokenizer = try Tokenizer.init("default <");
    // while (tokenizer.get_token()) |token| {
    //     print("token: {?}\n", .{token});
    // }
    try parser.parse(&mappings, "default <");
}
