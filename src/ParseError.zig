const std = @import("std");
const Token = @import("Tokenizer.zig").Token;

pub const ParseError = struct {
    allocator: std.mem.Allocator,
    message: []const u8,
    line: usize,
    column: usize,
    file_path: ?[]const u8,
    token_text: ?[]const u8,

    pub fn format(self: ParseError, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (self.file_path) |path| {
            try writer.print("{s}:", .{path});
        }
        try writer.print("{d}:{d}: error: {s}", .{ self.line, self.column, self.message });
        if (self.token_text) |text| {
            try writer.print(" near '{s}'", .{text});
        }
    }

    pub fn deinit(self: *ParseError) void {
        self.allocator.free(self.message);
    }

    pub fn fromToken(allocator: std.mem.Allocator, token: Token, message: []const u8, file_path: ?[]const u8) !ParseError {
        const msg_copy = try allocator.dupe(u8, message);
        return ParseError{
            .allocator = allocator,
            .message = msg_copy,
            .line = token.line,
            .column = token.cursor,
            .file_path = file_path,
            .token_text = token.text,
        };
    }

    pub fn fromPosition(allocator: std.mem.Allocator, line: usize, column: usize, message: []const u8, file_path: ?[]const u8) !ParseError {
        const msg_copy = try allocator.dupe(u8, message);
        return ParseError{
            .allocator = allocator,
            .message = msg_copy,
            .line = line,
            .column = column,
            .file_path = file_path,
            .token_text = null,
        };
    }
};

pub const ParseErrorContext = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayList(ParseError),

    pub fn init(allocator: std.mem.Allocator) ParseErrorContext {
        return ParseErrorContext{
            .allocator = allocator,
            .errors = std.ArrayList(ParseError).init(allocator),
        };
    }

    pub fn deinit(self: *ParseErrorContext) void {
        self.errors.deinit();
    }

    pub fn addError(self: *ParseErrorContext, err: ParseError) !void {
        try self.errors.append(err);
    }

    pub fn printErrors(self: *ParseErrorContext, writer: anytype) !void {
        for (self.errors.items) |err| {
            try writer.print("{}\n", .{err});
        }
    }
};
