const std = @import("std");
const print = std.debug.print;
const Tokenizer = @import("./Tokenizer.zig");
const Token = Tokenizer.Token;
const Hotkey = @import("./Hotkey.zig");
const debug = std.debug.print;
const assert = std.debug.assert;
const Mode = @import("./Mode.zig");
const Mappings = @import("./Mappings.zig");

const Parser = @This();

const ParserError = error{
    @"Expect token",
    @"Expected Identifier",
    @"Mode not found",
    @"Expected identifier",
    @"Mode already exists",
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
token: ?Token = undefined,

pub fn deinit(self: *Parser) void {
    // self.allocator.free(self.filename);
    // self.allocator.free(self.content);
    self.* = undefined;
}

pub fn init(allocator: std.mem.Allocator) Parser {
    // const f = try std.fs.cwd().openFile(filename, .{});
    // defer f.close();
    // const content = try f.readToEndAlloc(allocator, 1 << 24); // max size 16MB
    var parser = Parser{
        .allocator = allocator,
        // .mappings = &mappings,
        // .filename = allocator.dupe(u8, filename),
        // .content = content,
        // .tokenizer = tokenizer,
    };
    _ = parser.advance_token();
    return parser;
}

pub fn parse(self: *Parser, content: []const u8) !Mappings {
    self.content = content;
    self.tokenizer = try Tokenizer.init(content);

    var mappings = Mappings.init(self.allocator);
    self.mappings = &mappings;

    while (self.token) |token| {
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

    return mappings;
}

fn advance_token(self: *Parser) ?Token {
    self.previous_token = self.token;
    self.token = self.tokenizer.get_token();
    return self.token;
}

fn advance_match_token(self: *Parser, typ: Tokenizer.TokenType) bool {
    if (self.advance_token()) |token| {
        if (token.type == typ) {
            return true;
        }
    }
    return false;
}

fn parse_hotkey(self: *Parser) !void {
    var hotkey = try Hotkey.create(self.allocator);
    errdefer hotkey.destroy();
    // var found_modifier = false;

    const token: Token = self.token orelse return ParserError.@"Expect token";
    debug("hotkey :: #{d} {{\n", .{self.token.?.line});

    if (token.type == .Token_Identifier) {
        try self.parse_mode(hotkey);
    }

    var it = hotkey.mode_list.iterator();
    while (it.next()) |kv| {
        const mode = kv.key_ptr.*;
        try mode.hotkey_map.put(hotkey, {});
    }
}

fn parse_mode(self: *Parser, hotkey: *Hotkey) !void {
    const token: Token = self.token orelse return ParserError.@"Expect token";
    assert(token.type == .Token_Identifier);

    const name = token.text;
    const mode = try self.mappings.get_mode(name) orelse return ParserError.@"Mode not found";

    if (hotkey.mode_list.contains(mode)) {
        return ParserError.@"Mode already exists";
    }
    try hotkey.mode_list.put(mode, {});
    debug("\tmode: '{s}'\n", .{name});
    // const token1 = self.advance_token() orelse return ParserError.@"Expected token";
    if (self.advance_match_token(.Token_Comma)) {
        if (self.advance_match_token(.Token_Identifier)) {
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

    var mappings = parser.parse("default, default, xxxx") catch |err| {
        debug("error: {any}, token: {s}\n", .{ err, std.json.fmt(parser.token, .{ .whitespace = .indent_2 }) });
        return;
    };
    defer mappings.deinit();

    const string = try std.fmt.allocPrint(alloc, "{}", .{mappings});
    defer alloc.free(string);
    debug("mapping: {s}\n", .{string});
}
