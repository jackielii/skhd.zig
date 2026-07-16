const std = @import("std");
const Hotkey = @import("Hotkey.zig");

const Sequence = @This();

allocator: std.mem.Allocator,
chords: []Hotkey.KeyPress,
action: *Hotkey,

pub fn create(
    allocator: std.mem.Allocator,
    chords: []const Hotkey.KeyPress,
    action: *Hotkey,
) !*Sequence {
    if (chords.len < 2) return error.SequenceTooShort;
    const self = try allocator.create(Sequence);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .chords = try allocator.dupe(Hotkey.KeyPress, chords),
        .action = action,
    };
    return self;
}

pub fn destroy(self: *Sequence) void {
    self.allocator.free(self.chords);
    self.action.destroy();
    self.allocator.destroy(self);
}

pub fn matchesStep(self: *const Sequence, index: usize, eventkey: Hotkey.KeyPress) bool {
    if (index >= self.chords.len) return false;
    const chord = self.chords[index];
    return chord.key == eventkey.key and Hotkey.hotkeyFlagsMatch(chord.flags, eventkey.flags);
}

pub fn chordOverlapsHotkey(chord: Hotkey.KeyPress, hotkey: *const Hotkey) bool {
    if (chord.key != hotkey.chords[0].key) return false;
    return Hotkey.hotkeyFlagsMatch(chord.flags, hotkey.chords[0].flags) or
        Hotkey.hotkeyFlagsMatch(hotkey.chords[0].flags, chord.flags);
}

pub fn onePrefixesOther(a: *const Sequence, b: *const Sequence) bool {
    const common_len = @min(a.chords.len, b.chords.len);
    for (a.chords[0..common_len], b.chords[0..common_len]) |a_chord, b_chord| {
        if (a_chord.key != b_chord.key) return false;
        if (!(Hotkey.hotkeyFlagsMatch(a_chord.flags, b_chord.flags) or
            Hotkey.hotkeyFlagsMatch(b_chord.flags, a_chord.flags))) return false;
    }
    return true;
}

pub const MatchResult = union(enum) {
    none,
    pending,
    complete: *Sequence,
    mismatch,
};

pub const Matcher = struct {
    allocator: ?std.mem.Allocator = null,
    candidates: std.ArrayListUnmanaged(*Sequence) = .empty,
    next_index: usize = 0,
    process_name: []const u8 = "",

    pub fn start(
        self: *Matcher,
        allocator: std.mem.Allocator,
        sequences: []const *Sequence,
        eventkey: Hotkey.KeyPress,
        process_name: []const u8,
    ) !MatchResult {
        self.cancel(allocator);
        self.allocator = allocator;
        errdefer self.cancelStored();
        for (sequences) |sequence| {
            if (sequence.action.find_command_for_process(process_name) == null) continue;
            if (!sequence.matchesStep(0, eventkey)) continue;
            try self.candidates.append(allocator, sequence);
        }
        if (self.candidates.items.len == 0) {
            self.cancel(allocator);
            return .none;
        }
        self.process_name = try allocator.dupe(u8, process_name);
        self.next_index = 1;
        return .pending;
    }

    pub fn feed(self: *Matcher, eventkey: Hotkey.KeyPress, process_name: []const u8) MatchResult {
        if (self.allocator == null or !std.ascii.eqlIgnoreCase(self.process_name, process_name)) {
            self.cancelStored();
            return .mismatch;
        }

        var write: usize = 0;
        var completed: ?*Sequence = null;
        for (self.candidates.items) |sequence| {
            if (!sequence.matchesStep(self.next_index, eventkey)) continue;
            if (self.next_index + 1 == sequence.chords.len) {
                completed = sequence;
            } else {
                self.candidates.items[write] = sequence;
                write += 1;
            }
        }
        self.candidates.items.len = write;
        if (completed) |sequence| {
            self.cancelStored();
            return .{ .complete = sequence };
        }
        if (write == 0) {
            self.cancelStored();
            return .mismatch;
        }
        self.next_index += 1;
        return .pending;
    }

    pub fn cancel(self: *Matcher, allocator: std.mem.Allocator) void {
        if (self.allocator == null) self.allocator = allocator;
        self.cancelStored();
    }

    fn cancelStored(self: *Matcher) void {
        const allocator = self.allocator orelse return;
        if (self.process_name.len > 0) allocator.free(self.process_name);
        self.candidates.deinit(allocator);
        self.* = .{};
    }
};

test "sequence owns chords and matches complete steps" {
    const chords = [_]Hotkey.KeyPress{
        .{ .flags = .{ .cmd = true }, .key = 0x0C },
        .{ .flags = .{ .cmd = true }, .key = 0x0C },
    };
    var action = try Hotkey.create(std.testing.allocator, &.{.{ .flags = .{}, .key = 0 }});
    errdefer action.destroy();
    var sequence = try Sequence.create(std.testing.allocator, &chords, action);
    defer sequence.destroy();

    try std.testing.expect(sequence.matchesStep(0, chords[0]));
    try std.testing.expect(!sequence.matchesStep(1, .{ .flags = .{}, .key = 0x0C }));
}

test "matcher filters by process and narrows a shared prefix" {
    const alloc = std.testing.allocator;
    const prefix = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = 0x28 };
    const comment = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = 0x08 };
    const uncomment = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = 0x20 };

    var comment_action = try Hotkey.create(alloc, &.{.{ .flags = .{}, .key = 0 }});
    errdefer comment_action.destroy();
    try comment_action.add_process_command("Code", "comment");
    var comment_sequence = try Sequence.create(alloc, &.{ prefix, comment }, comment_action);
    defer comment_sequence.destroy();

    var uncomment_action = try Hotkey.create(alloc, &.{.{ .flags = .{}, .key = 0 }});
    errdefer uncomment_action.destroy();
    try uncomment_action.add_process_command("Code", "uncomment");
    var uncomment_sequence = try Sequence.create(alloc, &.{ prefix, uncomment }, uncomment_action);
    defer uncomment_sequence.destroy();

    var matcher: Matcher = .{};
    defer matcher.cancel(alloc);
    const sequences = [_]*Sequence{ comment_sequence, uncomment_sequence };

    try std.testing.expectEqual(MatchResult.none, try matcher.start(alloc, &sequences, prefix, "Terminal"));
    try std.testing.expectEqual(MatchResult.pending, try matcher.start(alloc, &sequences, prefix, "Code"));
    const completed = matcher.feed(comment, "Code");
    try std.testing.expect(completed == .complete);
    try std.testing.expectEqual(comment_sequence, completed.complete);
}

test "matcher reports mismatch and process change" {
    const alloc = std.testing.allocator;
    const first = Hotkey.KeyPress{ .flags = .{ .cmd = true }, .key = 0x0C };
    var action = try Hotkey.create(alloc, &.{.{ .flags = .{}, .key = 0 }});
    errdefer action.destroy();
    try action.add_process_command("Protected App", "quit");
    var sequence = try Sequence.create(alloc, &.{ first, first }, action);
    defer sequence.destroy();
    const sequences = [_]*Sequence{sequence};

    var matcher: Matcher = .{};
    defer matcher.cancel(alloc);
    try std.testing.expectEqual(MatchResult.pending, try matcher.start(alloc, &sequences, first, "Protected App"));
    try std.testing.expectEqual(MatchResult.mismatch, matcher.feed(first, "Other App"));
}
