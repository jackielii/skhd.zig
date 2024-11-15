const std = @import("std");
const print = std.debug.print;
const eql = std.mem.eql;
const unicode = @import("std").unicode;

const modifier_flags_str = [_][]const u8{
    "alt",   "lalt",   "ralt",
    "shift", "lshift", "rshift",
    "cmd",   "lcmd",   "rcmd",
    "ctrl",  "lctrl",  "rctrl",
    "fn",    "hyper",  "meh",
};

const literal_keycode_str = [_][]const u8{
    "return",          "tab",             "space",             "backspace",
    "escape",          "delete",          "home",              "end",
    "pageup",          "pagedown",        "insert",            "left",
    "right",           "up",              "down",              "f1",
    "f2",              "f3",              "f4",                "f5",
    "f6",              "f7",              "f8",                "f9",
    "f10",             "f11",             "f12",               "f13",
    "f14",             "f15",             "f16",               "f17",
    "f18",             "f19",             "f20",               "sound_up",
    "sound_down",      "mute",            "play",              "previous",
    "next",            "rewind",          "fast",              "brightness_up",
    "brightness_down", "illumination_up", "illumination_down",
};

const TokenType = enum {
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

    Token_BeginList,
    Token_EndList,

    Token_Unknown,
    Token_EndOfStream,
};

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
    var tokenizer = try Tokenizer.init(content);
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
    var tokenizer = try Tokenizer.init(content);
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
        \\   hello
        \\world
        \\
    ;
    var tokenizer = try Tokenizer.init(content);
    _ = tokenizer.acceptUntil('\n');
    try expectEqual(9, tokenizer.cursor);
    try expectEqual(1, tokenizer.line);
}

// test "tokenize" {
//     const filename = "/Users/jackieli/.config/skhd/skhdrc";
//     const allocator = std.testing.allocator;
//
//     print("Parsing file: {s}\n", .{filename});
//     const f = try std.fs.cwd().openFile(filename, .{});
//     defer f.close();
//
//     const content = try f.readToEndAlloc(allocator, 1 << 24); // max size 16MB
//     defer allocator.free(content);
//
//     var tokenizer = try Tokenizer.init(content);
//     while (tokenizer.nextRune()) |rune| {
//         print("{s}", .{rune});
//     }
// }

const Token = struct {
    type: TokenType,
    text: []const u8,

    line: usize,
    cursor: usize,
};

const Tokenizer = struct {
    buffer: []const u8,
    pos: usize = 0,
    line: usize = 1,
    cursor: usize = 1,

    // last rune size
    rw: usize = 0,

    const Self = @This();

    pub fn init(buffer: []const u8) !Self {
        if (!unicode.utf8ValidateSlice(buffer)) {
            return error.@"Invalid UTF-8";
        }
        return Self{
            .buffer = buffer,
        };
    }

    // pub fn get_token(self: *Self) Token {}
    //
    // pub fn peek_token(self: *Self) Token {}

    fn peekRune(self: *Self) ?[]const u8 {
        if (self.pos >= self.buffer.len) {
            return null;
        }
        const l: usize = unicode.utf8ByteSequenceLength(self.buffer[self.pos]) catch unreachable;
        return self.buffer[self.pos .. self.pos + l];
    }

    fn moveOver(self: *Self, r: []const u8) void {
        if (r[0] == '\n') {
            self.line += 1;
            self.cursor = 0;
        }
        self.cursor += r.len;
        self.pos += r.len;
    }

    /// Accept consumes the next rune if it's in the valid set.
    /// valid only accepts ASCII characters.
    fn accept(self: *Self, cs: []const u8) bool {
        const r = self.peekRune() orelse return false;
        for (cs) |accepted| {
            if (accepted == r[0]) {
                self.moveOver(r);
                return true;
            }
        }
        return false;
    }

    fn acceptRun(self: *Self, cs: []const u8) ?[]const u8 {
        const start = self.pos;
        while (self.accept(cs)) {}
        const end = self.pos;
        return self.buffer[start..end];
    }

    fn acceptUntil(self: *Self, cs: u8) bool {
        while (true) {
            const r = self.peekRune() orelse return false;
            if (r[0] == cs) {
                return true;
            }
            self.moveOver(r);
        }
    }

    fn skipWhitespace(self: *Self) void {
        self.acceptRun(" \t\n");
    }
};

// struct token
// {
//     enum token_type type;
//     char *text;
//     unsigned length;
//
//     unsigned line;
//     unsigned cursor;
// };
//
// struct tokenizer
// {
//     char *buffer;
//     char *at;
//     unsigned line;
//     unsigned cursor;
// };
//
// void tokenizer_init(struct tokenizer *tokenizer, char *buffer);
// struct token get_token(struct tokenizer *tokenizer);
// struct token peek_token(struct tokenizer tokenizer);
// int token_equals(struct token token, const char *match);
