const std = @import("std");
const print = std.debug.print;
const eql = std.mem.eql;
const unicode = std.unicode;
const ascii = std.ascii;
const ModifierFlag = @import("Keycodes.zig").ModifierFlag;

// const modifier_flags_str = @import("Keycodes.zig").modifier_flags_str;
const literal_keycode_str = @import("Keycodes.zig").literal_keycode_str;
const log = std.log.scoped(.tokenizer);

const identifier_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_";
const number_chars = "0123456789";
const hex_chars = "0123456789abcdefABCDEF";

pub const TokenType = enum {
    Token_Identifier,
    Token_Activate,

    Token_Command,
    Token_Modifier,
    Token_Literal,
    Token_Key_Hex,
    Token_Key,

    Token_Decl,
    Token_Forward,
    Token_Comma,
    Token_Insert,
    Token_Plus,
    Token_Dash,
    Token_Arrow,
    Token_Capture,
    Token_Unbound,
    Token_Wildcard,
    Token_String,
    Token_Option,
    Token_ProcessGroup,

    Token_BeginList,
    Token_EndList,

    Token_Unknown,
};

pub const Token = struct {
    type: TokenType,
    text: []const u8,

    line: usize,
    cursor: usize,

    pub fn format(self: *const Token, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("Token{{", .{});
        try writer.print("\n  line: {d}", .{self.line});
        try writer.print("\n  cursor: {d}", .{self.cursor});
        try writer.print("\n  type: {any}", .{self.type});
        try writer.print("\n  text: {s}", .{self.text});
        try writer.print("\n}}", .{});
    }
};

buffer: []const u8,
pos: usize = 0,
line: usize = 1,
cursor: usize = 1,

// last rune size
rw: usize = 0,

const Tokenizer = @This();

pub fn init(buffer: []const u8) !Tokenizer {
    if (!unicode.utf8ValidateSlice(buffer)) {
        return error.@"Invalid UTF-8";
    }
    return Tokenizer{
        .buffer = buffer,
    };
}

pub fn get_token(self: *Tokenizer) ?Token {
    self.skipWhitespace();

    var token = Token{
        .line = self.line,
        .cursor = self.cursor,
        .type = .Token_Unknown,
        .text = undefined,
    };

    const r = self.peekRune() orelse return null;
    self.moveOver(r);
    token.text = r;
    switch (r[0]) {
        '+' => token.type = .Token_Plus,
        ',' => token.type = .Token_Comma,
        '<' => token.type = .Token_Insert,
        '@' => {
            // Check if this is a process group reference or capture
            const next = self.peekRune();
            if (next != null and ascii.isAlphabetic(next.?[0])) {
                token.type = .Token_ProcessGroup;
                const start = self.pos - 1; // Include the @
                _ = self.acceptIdentifier();
                token.text = self.buffer[start..self.pos];
            } else {
                token.type = .Token_Capture;
            }
        },
        '~' => token.type = .Token_Unbound,
        '*' => token.type = .Token_Wildcard,
        '[' => token.type = .Token_BeginList,
        ']' => token.type = .Token_EndList,
        '.' => {
            token.type = .Token_Option;
            const start = self.pos - 1; // Include the dot
            _ = self.acceptIdentifier();
            token.text = self.buffer[start..self.pos];
        },
        '"' => {
            token.type = .Token_String;
            // TODO: handle escape characters
            token.text = self.acceptUntil('"');
            self.moveOver("\"");
        },
        '#' => {
            _ = self.acceptUntil('\n');
            token = self.get_token() orelse return null;
        },
        '-' => {
            if (self.accept(">") != null) {
                token.type = .Token_Arrow;
                token.text = "->";
            } else {
                token.type = .Token_Dash;
            }
        },
        ';' => {
            self.skipWhitespace();
            token.type = .Token_Activate;
            token.line = self.line;
            token.cursor = self.cursor;
            token.text = self.acceptIdentifier();
        },
        ':' => {
            if (self.accept(":") != null) {
                token.type = .Token_Decl;
                token.text = "::";
            } else {
                self.skipWhitespace();
                token.line = self.line;
                token.cursor = self.cursor;
                token.type = .Token_Command;
                token.text = self.acceptCommand();
            }
        },
        '|' => {
            self.skipWhitespace();
            token.line = self.line;
            token.cursor = self.cursor;
            token.type = .Token_Forward;
        },
        else => {
            const next = self.peekRune() orelse return null;
            if (r[0] == '0' and next[0] == 'x') {
                self.moveOver(next);
                token.text = self.acceptRun(hex_chars);
                token.type = .Token_Key_Hex;
            } else if (ascii.isDigit(r[0])) {
                token.type = .Token_Key;
            } else if (ascii.isAlphanumeric(r[0])) {
                const start = self.pos - 1; // rewind
                _ = self.acceptIdentifier();
                const end = self.pos;
                token.text = self.buffer[start..end];
                token.type = resolveIdentifierType(token);
            } else {
                token.type = .Token_Unknown;
            }
        },
    }
    return token;
}
//
// pub fn peek_token(self: *Self) Token {}

fn peekRune(self: *Tokenizer) ?[]const u8 {
    if (self.pos >= self.buffer.len) {
        return null;
    }
    const l: usize = unicode.utf8ByteSequenceLength(self.buffer[self.pos]) catch unreachable;
    return self.buffer[self.pos .. self.pos + l];
}

fn moveOver(self: *Tokenizer, r: []const u8) void {
    if (r[0] == '\n') {
        self.line += 1;
        self.cursor = 0;
    }
    self.cursor += r.len;
    self.pos += r.len;
}

/// Accept consumes the next rune if it's in the valid set.
/// valid only accepts ASCII characters.
fn accept(self: *Tokenizer, validSet: []const u8) ?[]const u8 {
    const r = self.peekRune() orelse return null;
    for (validSet) |valid| {
        if (valid == r[0]) {
            self.moveOver(r);
            return r;
        }
    }
    return null;
}

fn acceptRun(self: *Tokenizer, cs: []const u8) []const u8 {
    const start = self.pos;
    while (self.accept(cs)) |_| {}
    const end = self.pos;
    return self.buffer[start..end];
}

fn acceptUntil(self: *Tokenizer, cs: u8) []const u8 {
    const start = self.pos;
    while (self.peekRune()) |r| {
        if (r[0] == cs) {
            break;
        }
        self.moveOver(r);
    }
    return self.buffer[start..self.pos];
}

fn acceptIdentifier(self: *Tokenizer) []const u8 {
    const start = self.pos;
    _ = self.acceptRun(identifier_chars);
    _ = self.acceptRun(identifier_chars ++ number_chars);
    const end = self.pos;
    return self.buffer[start..end];
}

fn acceptCommand(self: *Tokenizer) []const u8 {
    const start = self.pos;
    while (self.peekRune()) |r| {
        self.moveOver(r);
        if (r[0] == '\\') {
            _ = self.accept("\n");
        }
        if (self.accept("\n") != null) {
            break;
        }
    }
    return std.mem.trimRight(u8, self.buffer[start..self.pos], "\n");
}

fn skipWhitespace(self: *Tokenizer) void {
    _ = self.acceptRun(" \t\n");
}

fn resolveIdentifierType(token: Token) TokenType {
    if (token.text.len == 1) {
        return .Token_Key;
    }

    if (ModifierFlag.get(token.text) != null) {
        return .Token_Modifier;
    }

    for (literal_keycode_str) |keycode| {
        if (eql(u8, keycode, token.text)) {
            return .Token_Literal;
        }
    }

    return .Token_Identifier;
}

const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "nextRune" {
    const content =
        \\hello
        \\world
        \\
    ;
    var tokenizer = try init(content);
    var got = std.ArrayList(u8).init(std.testing.allocator);
    defer got.deinit();
    while (tokenizer.peekRune()) |rune| {
        try got.appendSlice(rune);
        tokenizer.pos += rune.len;
    }
    try std.testing.expectEqualStrings(got.items, content);
}

test "acceptRun" {
    const content =
        \\   hello
        \\world
        \\
    ;
    var tokenizer = try init(content);
    _ = tokenizer.acceptRun(" \t");
    try expectEqual(4, tokenizer.cursor);
    try expectEqual(1, tokenizer.line);
    _ = tokenizer.acceptRun("abcdefghijklmnopqrstuvwxyz");
    try expectEqual(9, tokenizer.cursor);
    try expectEqual(1, tokenizer.line);
    _ = tokenizer.acceptRun("\n");
    try expectEqual(1, tokenizer.cursor);
    try expectEqual(2, tokenizer.line);
}

test "acceptUntil" {
    const content =
        \\hello \
        \\world
        \\
    ;
    var tokenizer = try init(content);
    const got = tokenizer.acceptUntil('\n');
    try expectEqual("hello..|".len, tokenizer.cursor);
    try expectEqual(1, tokenizer.line);
    try expectEqualStrings("hello \\", got);
}

test "tokenize" {
    const test_content = "cmd - a : echo test";

    var tokenizer = try init(test_content);

    // Just verify we can tokenize a simple hotkey
    const token1 = tokenizer.get_token();
    try std.testing.expect(token1 != null);
    try std.testing.expectEqual(TokenType.Token_Modifier, token1.?.type);
    try std.testing.expectEqualStrings("cmd", token1.?.text);

    const token2 = tokenizer.get_token();
    try std.testing.expect(token2 != null);
    try std.testing.expectEqual(TokenType.Token_Dash, token2.?.type);

    const token3 = tokenizer.get_token();
    try std.testing.expect(token3 != null);
    try std.testing.expectEqual(TokenType.Token_Key, token3.?.type);
    try std.testing.expectEqualStrings("a", token3.?.text);
}

test "format token" {
    const token = Token{
        .line = 1,
        .cursor = 1,
        .type = .Token_Identifier,
        .text = "hello",
    };
    // Just verify the token was created correctly
    try std.testing.expectEqual(@as(usize, 1), token.line);
    try std.testing.expectEqual(@as(usize, 1), token.cursor);
    try std.testing.expectEqual(TokenType.Token_Identifier, token.type);
    try std.testing.expectEqualStrings("hello", token.text);
}

test "tokenize option" {
    const test_content = ".shell \"/bin/zsh\"";
    var tokenizer = try init(test_content);

    // First token should be .shell
    const token1 = tokenizer.get_token();
    try std.testing.expect(token1 != null);
    try std.testing.expectEqual(TokenType.Token_Option, token1.?.type);
    try std.testing.expectEqualStrings("shell", token1.?.text);

    // Second token should be the string
    const token2 = tokenizer.get_token();
    try std.testing.expect(token2 != null);
    try std.testing.expectEqual(TokenType.Token_String, token2.?.type);
    try std.testing.expectEqualStrings("/bin/zsh", token2.?.text);
}
