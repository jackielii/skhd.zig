const std = @import("std");
const zbench = @import("zbench");
const Skhd = @import("skhd.zig");
const Hotkey = @import("Hotkey.zig");
const c = @import("c.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

// Global context for benchmarks
var g_skhd: ?*Skhd = null;
var g_esc_key: Hotkey.KeyPress = undefined;

// Linear search benchmark
fn benchLinearSearch(allocator: std.mem.Allocator) void {
    _ = allocator;
    const skhd = g_skhd orelse return;
    const mode = skhd.current_mode orelse return;
    _ = skhd.findHotkeyLinear(mode, g_esc_key);
}

// HashMap lookup benchmark
fn benchHashMapLookup(allocator: std.mem.Allocator) void {
    _ = allocator;
    const skhd = g_skhd orelse return;
    const mode = skhd.current_mode orelse return;
    _ = skhd.findHotkeyHashMap(mode, g_esc_key);
}

// Process name lookup benchmark (system call)
fn benchProcessNameLookup(allocator: std.mem.Allocator) void {
    _ = allocator;
    var buffer: [128]u8 = undefined;
    _ = getCurrentProcessNameBuf(&buffer) catch {};
}

// Cached process name lookup benchmark
fn benchCachedProcessName(allocator: std.mem.Allocator) void {
    _ = allocator;
    const skhd = g_skhd orelse return;
    _ = skhd.carbon_event.getProcessName();
}

// Double lookup benchmark (simulating current hot path)
fn benchDoubleLookup(allocator: std.mem.Allocator) void {
    _ = allocator;
    const skhd = g_skhd orelse return;
    const mode = skhd.current_mode orelse return;
    
    // First lookup (forward)
    _ = skhd.findHotkeyInMode(mode, g_esc_key);
    
    // Second lookup (exec)
    _ = skhd.findHotkeyInMode(mode, g_esc_key);
}

// Single lookup benchmark (optimized path)
fn benchSingleLookup(allocator: std.mem.Allocator) void {
    _ = allocator;
    const skhd = g_skhd orelse return;
    const mode = skhd.current_mode orelse return;
    
    // Single lookup
    _ = skhd.findHotkeyInMode(mode, g_esc_key);
}

// Copy the getCurrentProcessNameBuf function for benchmarking
fn getCurrentProcessNameBuf(buffer: []u8) ![]const u8 {
    var psn: c.ProcessSerialNumber = undefined;
    
    const status = c.GetFrontProcess(&psn);
    if (status != c.noErr) {
        const unknown = "unknown";
        @memcpy(buffer[0..unknown.len], unknown);
        return buffer[0..unknown.len];
    }
    
    var process_name_ref: c.CFStringRef = undefined;
    const copy_status = c.CopyProcessName(&psn, &process_name_ref);
    if (copy_status != c.noErr) {
        const unknown = "unknown";
        @memcpy(buffer[0..unknown.len], unknown);
        return buffer[0..unknown.len];
    }
    defer c.CFRelease(process_name_ref);
    
    const success = c.CFStringGetCString(process_name_ref, buffer.ptr, @intCast(buffer.len), c.kCFStringEncodingUTF8);
    if (success == 0) {
        const unknown = "unknown";
        @memcpy(buffer[0..unknown.len], unknown);
        return buffer[0..unknown.len];
    }
    
    const c_string_len = std.mem.len(@as([*:0]const u8, @ptrCast(buffer.ptr)));
    const process_name = buffer[0..c_string_len];
    
    for (process_name) |*char| {
        char.* = std.ascii.toLower(char.*);
    }
    
    // Clean invisible Unicode characters that some apps (like WhatsApp) have
    return cleanInvisibleChars(process_name);
}

/// Remove invisible Unicode characters from the beginning of a string
/// This handles cases like WhatsApp which has U+200E (LEFT-TO-RIGHT MARK) in its process name
fn cleanInvisibleChars(name: []const u8) []const u8 {
    // Common invisible Unicode characters as UTF-8 byte sequences
    const ltr_mark = "\u{200E}"; // LEFT-TO-RIGHT MARK
    const rtl_mark = "\u{200F}"; // RIGHT-TO-LEFT MARK
    const zwsp = "\u{200B}"; // ZERO WIDTH SPACE
    const zwnj = "\u{200C}"; // ZERO WIDTH NON-JOINER
    const zwj = "\u{200D}"; // ZERO WIDTH JOINER
    const bom = "\u{FEFF}"; // ZERO WIDTH NO-BREAK SPACE (BOM)

    var result = name;

    // Keep removing invisible chars from the start until we find a visible char
    while (result.len > 0) {
        if (std.mem.startsWith(u8, result, ltr_mark)) {
            result = result[ltr_mark.len..];
        } else if (std.mem.startsWith(u8, result, rtl_mark)) {
            result = result[rtl_mark.len..];
        } else if (std.mem.startsWith(u8, result, zwsp)) {
            result = result[zwsp.len..];
        } else if (std.mem.startsWith(u8, result, zwnj)) {
            result = result[zwnj.len..];
        } else if (std.mem.startsWith(u8, result, zwj)) {
            result = result[zwj.len..];
        } else if (std.mem.startsWith(u8, result, bom)) {
            result = result[bom.len..];
        } else {
            break;
        }
    }

    return result;
}

pub fn main() !void {
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    
    std.debug.print("\n=== Benchmarking skhd hot path ===\n\n", .{});
    
    // Load the actual user config
    const config_path = "/Users/jackieli/.config/skhd/skhdrc";
    
    // Initialize skhd with profiling disabled
    var skhd = try Skhd.init(allocator, config_path, .service, false);
    defer skhd.deinit();
    
    // Set global context
    g_skhd = &skhd;
    g_esc_key = Hotkey.KeyPress{
        .key = 0x35, // ESC keycode
        .flags = .{},
    };
    
    // Print configuration info
    var hotkey_count: usize = 0;
    if (skhd.current_mode) |mode| {
        hotkey_count = mode.hotkey_map.count();
    }
    std.debug.print("Current mode has {} hotkeys\n\n", .{hotkey_count});
    
    // Create benchmark suite
    var bench = zbench.Benchmark.init(allocator, .{});
    defer bench.deinit();
    
    // Add benchmarks
    try bench.add("Linear Search (ESC key)", benchLinearSearch, .{});
    try bench.add("HashMap Lookup (ESC key)", benchHashMapLookup, .{});
    try bench.add("Double Lookup (current)", benchDoubleLookup, .{});
    try bench.add("Single Lookup (optimized)", benchSingleLookup, .{});
    try bench.add("Process Name Lookup (syscall)", benchProcessNameLookup, .{});
    try bench.add("Process Name Lookup (cached)", benchCachedProcessName, .{});
    
    // Run benchmarks
    try bench.run(std.io.getStdOut().writer());
}