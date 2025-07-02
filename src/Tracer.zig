const std = @import("std");
const Tracer = @This();

// Simple execution tracer for profiling hot path
// Tracks function calls and execution patterns

pub const TracerStats = struct {
    // Event handling
    total_key_events: u64 = 0,
    key_down_events: u64 = 0,
    system_key_events: u64 = 0,

    // Process name lookups
    process_name_lookups: u64 = 0,
    process_name_cache_hits: u64 = 0,

    // Hotkey lookups
    hotkey_lookups: u64 = 0,
    hotkey_found: u64 = 0,
    hotkey_not_found: u64 = 0,
    hotkey_comparisons: u64 = 0,

    // Forwarding
    forward_checks: u64 = 0,
    keys_forwarded: u64 = 0,

    // Execution
    exec_checks: u64 = 0,
    commands_executed: u64 = 0,

    // Early exits
    no_mode_exits: u64 = 0,
    blacklisted_exits: u64 = 0,
    self_generated_exits: u64 = 0,

    // Linear search details
    linear_search_iterations: u64 = 0,
    max_linear_search_depth: u64 = 0,
};

enabled: bool,
stats: TracerStats,
mutex: std.Thread.Mutex,

pub fn init(enabled: bool) Tracer {
    return .{
        .enabled = enabled,
        .stats = .{},
        .mutex = .{},
    };
}

// Event tracking
pub inline fn traceKeyEvent(self: *Tracer) void {
    if (!self.enabled) return;
    self.mutex.lock();
    defer self.mutex.unlock();
    self.stats.total_key_events += 1;
}

pub inline fn traceKeyDown(self: *Tracer) void {
    if (!self.enabled) return;
    self.mutex.lock();
    defer self.mutex.unlock();
    self.stats.key_down_events += 1;
}

pub inline fn traceSystemKey(self: *Tracer) void {
    if (!self.enabled) return;
    self.mutex.lock();
    defer self.mutex.unlock();
    self.stats.system_key_events += 1;
}

// Process name tracking
pub inline fn traceProcessNameLookup(self: *Tracer) void {
    if (!self.enabled) return;
    self.mutex.lock();
    defer self.mutex.unlock();
    self.stats.process_name_lookups += 1;
}

// Hotkey lookup tracking
pub inline fn traceHotkeyLookup(self: *Tracer) void {
    if (!self.enabled) return;
    self.mutex.lock();
    defer self.mutex.unlock();
    self.stats.hotkey_lookups += 1;
}

pub inline fn traceHotkeyFound(self: *Tracer, found: bool) void {
    if (!self.enabled) return;
    self.mutex.lock();
    defer self.mutex.unlock();
    if (found) {
        self.stats.hotkey_found += 1;
    } else {
        self.stats.hotkey_not_found += 1;
    }
}

pub inline fn traceHotkeyComparison(self: *Tracer) void {
    if (!self.enabled) return;
    self.mutex.lock();
    defer self.mutex.unlock();
    self.stats.hotkey_comparisons += 1;
}

// Linear search tracking
pub inline fn traceLinearSearchIterations(self: *Tracer, iterations: u64) void {
    if (!self.enabled) return;
    self.mutex.lock();
    defer self.mutex.unlock();
    self.stats.linear_search_iterations += iterations;
    if (iterations > self.stats.max_linear_search_depth) {
        self.stats.max_linear_search_depth = iterations;
    }
}

// Forwarding tracking
pub inline fn traceForwardCheck(self: *Tracer) void {
    if (!self.enabled) return;
    self.mutex.lock();
    defer self.mutex.unlock();
    self.stats.forward_checks += 1;
}

pub inline fn traceKeyForwarded(self: *Tracer) void {
    if (!self.enabled) return;
    self.mutex.lock();
    defer self.mutex.unlock();
    self.stats.keys_forwarded += 1;
}

// Execution tracking
pub inline fn traceExecCheck(self: *Tracer) void {
    if (!self.enabled) return;
    self.mutex.lock();
    defer self.mutex.unlock();
    self.stats.exec_checks += 1;
}

pub inline fn traceCommandExecuted(self: *Tracer) void {
    if (!self.enabled) return;
    self.mutex.lock();
    defer self.mutex.unlock();
    self.stats.commands_executed += 1;
}

// Early exit tracking
pub inline fn traceNoModeExit(self: *Tracer) void {
    if (!self.enabled) return;
    self.mutex.lock();
    defer self.mutex.unlock();
    self.stats.no_mode_exits += 1;
}

pub inline fn traceBlacklistedExit(self: *Tracer) void {
    if (!self.enabled) return;
    self.mutex.lock();
    defer self.mutex.unlock();
    self.stats.blacklisted_exits += 1;
}

pub inline fn traceSelfGeneratedExit(self: *Tracer) void {
    if (!self.enabled) return;
    self.mutex.lock();
    defer self.mutex.unlock();
    self.stats.self_generated_exits += 1;
}

// Print summary statistics
pub fn printSummary(self: *Tracer, writer: anytype) !void {
    if (!self.enabled) return;

    self.mutex.lock();
    defer self.mutex.unlock();

    const s = &self.stats;

    try writer.print("\n=== SKHD Execution Trace Summary ===\n", .{});
    try writer.print("\nEvent Statistics:\n", .{});
    try writer.print("  Total key events:     {d}\n", .{s.total_key_events});
    try writer.print("  Key down events:      {d}\n", .{s.key_down_events});
    try writer.print("  System key events:    {d}\n", .{s.system_key_events});

    try writer.print("\nEarly Exits:\n", .{});
    try writer.print("  No mode exits:       {d}\n", .{s.no_mode_exits});
    try writer.print("  Blacklisted exits:   {d}\n", .{s.blacklisted_exits});
    try writer.print("  Self-generated exits: {d}\n", .{s.self_generated_exits});

    try writer.print("\nProcess Name Lookups:\n", .{});
    try writer.print("  Total lookups:        {d}\n", .{s.process_name_lookups});
    const lookups_per_event = if (s.total_key_events > 0)
        @as(f64, @floatFromInt(s.process_name_lookups)) / @as(f64, @floatFromInt(s.total_key_events))
    else
        0.0;
    try writer.print("  Lookups per event:    {d:.2}\n", .{lookups_per_event});

    try writer.print("\nHotkey Lookups:\n", .{});
    try writer.print("  Total lookups:        {d}\n", .{s.hotkey_lookups});
    try writer.print("  Hotkeys found:        {d}\n", .{s.hotkey_found});
    try writer.print("  Hotkeys not found:    {d}\n", .{s.hotkey_not_found});
    try writer.print("  Total comparisons:    {d}\n", .{s.hotkey_comparisons});

    const avg_comparisons = if (s.hotkey_lookups > 0)
        @as(f64, @floatFromInt(s.hotkey_comparisons)) / @as(f64, @floatFromInt(s.hotkey_lookups))
    else
        0.0;
    try writer.print("  Avg comparisons/lookup: {d:.2}\n", .{avg_comparisons});

    const avg_iterations = if (s.hotkey_lookups > 0)
        @as(f64, @floatFromInt(s.linear_search_iterations)) / @as(f64, @floatFromInt(s.hotkey_lookups))
    else
        0.0;
    try writer.print("  Avg linear iterations: {d:.2}\n", .{avg_iterations});
    try writer.print("  Max linear depth:     {d}\n", .{s.max_linear_search_depth});

    try writer.print("\nForwarding:\n", .{});
    try writer.print("  Forward checks:       {d}\n", .{s.forward_checks});
    try writer.print("  Keys forwarded:       {d}\n", .{s.keys_forwarded});

    try writer.print("\nExecution:\n", .{});
    try writer.print("  Exec checks:          {d}\n", .{s.exec_checks});
    try writer.print("  Commands executed:    {d}\n", .{s.commands_executed});

    // Performance insights
    try writer.print("\n=== Performance Insights ===\n", .{});

    const hit_rate = if (s.hotkey_lookups > 0)
        (@as(f64, @floatFromInt(s.hotkey_found)) / @as(f64, @floatFromInt(s.hotkey_lookups))) * 100.0
    else
        0.0;
    try writer.print("Hotkey hit rate: {d:.1}%\n", .{hit_rate});

    const wasted_lookups = s.process_name_lookups - (s.total_key_events - s.no_mode_exits - s.self_generated_exits);
    if (wasted_lookups > 0) {
        try writer.print("Potentially wasted process lookups: {d}\n", .{wasted_lookups});
    }

    try writer.print("\n", .{});
}
