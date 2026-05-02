const std = @import("std");
const builtin = @import("builtin");
const Tracer = @This();

// Simple execution tracer for profiling hot path
// Tracks function calls and execution patterns
// Only active in debug builds, compiled out in release builds

pub const TracerStats = struct {
    // Event handling
    total_key_events: std.atomic.Value(u64) = .init(0),
    key_down_events: std.atomic.Value(u64) = .init(0),
    system_key_events: std.atomic.Value(u64) = .init(0),

    // Process name lookups
    process_name_lookups: std.atomic.Value(u64) = .init(0),
    process_name_cache_hits: std.atomic.Value(u64) = .init(0),

    // Hotkey lookups
    hotkey_lookups: std.atomic.Value(u64) = .init(0),
    hotkey_found: std.atomic.Value(u64) = .init(0),
    hotkey_not_found: std.atomic.Value(u64) = .init(0),
    hotkey_comparisons: std.atomic.Value(u64) = .init(0),

    // Actions taken
    keys_forwarded: std.atomic.Value(u64) = .init(0),
    commands_executed: std.atomic.Value(u64) = .init(0),

    // Early exits
    no_mode_exits: std.atomic.Value(u64) = .init(0),
    blacklisted_exits: std.atomic.Value(u64) = .init(0),
    self_generated_exits: std.atomic.Value(u64) = .init(0),

    // Linear search details
    linear_search_iterations: std.atomic.Value(u64) = .init(0),
    max_linear_search_depth: std.atomic.Value(u64) = .init(0),
};

enabled: bool,
stats: TracerStats = .{},

pub fn init(enabled: bool) Tracer {
    return .{ .enabled = enabled };
}

inline fn add(self: *Tracer, comptime field: []const u8, n: u64) void {
    if (comptime builtin.mode != .Debug and builtin.mode != .ReleaseSafe) return;
    if (!self.enabled) return;
    _ = @field(self.stats, field).fetchAdd(n, .monotonic);
}

// Event tracking
pub fn traceKeyEvent(self: *Tracer) void {
    self.add("total_key_events", 1);
}

pub fn traceKeyDown(self: *Tracer) void {
    self.add("key_down_events", 1);
}

pub fn traceSystemKey(self: *Tracer) void {
    self.add("system_key_events", 1);
}

// Process name tracking
pub fn traceProcessNameLookup(self: *Tracer) void {
    self.add("process_name_lookups", 1);
}

// Hotkey lookup tracking
pub fn traceHotkeyLookup(self: *Tracer) void {
    self.add("hotkey_lookups", 1);
}

pub fn traceHotkeyFound(self: *Tracer, found: bool) void {
    if (found) self.add("hotkey_found", 1) else self.add("hotkey_not_found", 1);
}

pub fn traceHotkeyComparison(self: *Tracer) void {
    self.add("hotkey_comparisons", 1);
}

// Linear search tracking
pub fn traceLinearSearchIterations(self: *Tracer, iterations: u64) void {
    if (comptime builtin.mode != .Debug and builtin.mode != .ReleaseSafe) return;
    if (!self.enabled) return;
    _ = self.stats.linear_search_iterations.fetchAdd(iterations, .monotonic);
    // Bump max_linear_search_depth using a CAS loop. Two tracer threads
    // racing on the max would otherwise let a smaller value win.
    var current = self.stats.max_linear_search_depth.load(.monotonic);
    while (iterations > current) {
        current = self.stats.max_linear_search_depth.cmpxchgWeak(
            current,
            iterations,
            .monotonic,
            .monotonic,
        ) orelse break;
    }
}

// Action tracking
pub fn traceKeyForwarded(self: *Tracer) void {
    self.add("keys_forwarded", 1);
}

pub fn traceCommandExecuted(self: *Tracer) void {
    self.add("commands_executed", 1);
}

// Early exit tracking
pub fn traceNoModeExit(self: *Tracer) void {
    self.add("no_mode_exits", 1);
}

pub fn traceBlacklistedExit(self: *Tracer) void {
    self.add("blacklisted_exits", 1);
}

pub fn traceSelfGeneratedExit(self: *Tracer) void {
    self.add("self_generated_exits", 1);
}

// Print summary statistics
pub fn printSummary(self: *Tracer, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (comptime builtin.mode != .Debug and builtin.mode != .ReleaseSafe) return;
    if (!self.enabled) return;

    const s = &self.stats;
    const total_key_events = s.total_key_events.load(.monotonic);
    const key_down_events = s.key_down_events.load(.monotonic);
    const system_key_events = s.system_key_events.load(.monotonic);
    const process_name_lookups = s.process_name_lookups.load(.monotonic);
    const hotkey_lookups = s.hotkey_lookups.load(.monotonic);
    const hotkey_found = s.hotkey_found.load(.monotonic);
    const hotkey_not_found = s.hotkey_not_found.load(.monotonic);
    const hotkey_comparisons = s.hotkey_comparisons.load(.monotonic);
    const linear_search_iterations = s.linear_search_iterations.load(.monotonic);
    const max_linear_search_depth = s.max_linear_search_depth.load(.monotonic);
    const keys_forwarded = s.keys_forwarded.load(.monotonic);
    const commands_executed = s.commands_executed.load(.monotonic);
    const no_mode_exits = s.no_mode_exits.load(.monotonic);
    const blacklisted_exits = s.blacklisted_exits.load(.monotonic);
    const self_generated_exits = s.self_generated_exits.load(.monotonic);

    try w.print("\n=== SKHD Execution Trace Summary ===\n", .{});
    try w.print("\nEvent Statistics:\n", .{});
    try w.print("  Total key events:     {d}\n", .{total_key_events});
    try w.print("  Key down events:      {d}\n", .{key_down_events});
    try w.print("  System key events:    {d}\n", .{system_key_events});

    try w.print("\nEarly Exits:\n", .{});
    try w.print("  No mode exits:       {d}\n", .{no_mode_exits});
    try w.print("  Blacklisted exits:   {d}\n", .{blacklisted_exits});
    try w.print("  Self-generated exits: {d}\n", .{self_generated_exits});

    try w.print("\nProcess Name Lookups:\n", .{});
    try w.print("  Total lookups:        {d}\n", .{process_name_lookups});
    const lookups_per_event = if (total_key_events > 0)
        @as(f64, @floatFromInt(process_name_lookups)) / @as(f64, @floatFromInt(total_key_events))
    else
        0.0;
    try w.print("  Lookups per event:    {d:.2}\n", .{lookups_per_event});

    try w.print("\nHotkey Lookups:\n", .{});
    try w.print("  Total lookups:        {d}\n", .{hotkey_lookups});
    try w.print("  Hotkeys found:        {d}\n", .{hotkey_found});
    try w.print("  Hotkeys not found:    {d}\n", .{hotkey_not_found});
    try w.print("  Total comparisons:    {d}\n", .{hotkey_comparisons});

    const avg_comparisons = if (hotkey_lookups > 0)
        @as(f64, @floatFromInt(hotkey_comparisons)) / @as(f64, @floatFromInt(hotkey_lookups))
    else
        0.0;
    try w.print("  Avg comparisons/lookup: {d:.2}\n", .{avg_comparisons});

    const avg_iterations = if (hotkey_lookups > 0)
        @as(f64, @floatFromInt(linear_search_iterations)) / @as(f64, @floatFromInt(hotkey_lookups))
    else
        0.0;
    try w.print("  Avg linear iterations: {d:.2}\n", .{avg_iterations});
    try w.print("  Max linear depth:     {d}\n", .{max_linear_search_depth});

    try w.print("\nActions:\n", .{});
    try w.print("  Keys forwarded:       {d}\n", .{keys_forwarded});
    try w.print("  Commands executed:    {d}\n", .{commands_executed});

    // Performance insights
    try w.print("\n=== Performance Insights ===\n", .{});

    const hit_rate = if (hotkey_lookups > 0)
        (@as(f64, @floatFromInt(hotkey_found)) / @as(f64, @floatFromInt(hotkey_lookups))) * 100.0
    else
        0.0;
    try w.print("Hotkey hit rate: {d:.1}%\n", .{hit_rate});

    const wasted_lookups = process_name_lookups -| (total_key_events - no_mode_exits - self_generated_exits);
    if (wasted_lookups > 0) {
        try w.print("Potentially wasted process lookups: {d}\n", .{wasted_lookups});
    }

    try w.print("\n", .{});
}
