const std = @import("std");
const zbench = @import("zbench");
const Skhd = @import("skhd.zig");
const Hotkey = @import("Hotkey.zig");
const HotkeyOriginal = @import("Hotkey.zig");
const c = @import("c.zig").c;
const ModifierFlag = @import("Keycodes.zig").ModifierFlag;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

// Global context for benchmarks
var g_skhd: ?*Skhd = null;
var g_esc_key: Hotkey.KeyPress = undefined;
var g_hotkey_original: ?*HotkeyOriginal = null;

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

// Process mapping benchmarks - Original implementation
fn benchProcessMappingOriginal(allocator: std.mem.Allocator) void {
    _ = allocator;
    const hotkey = g_hotkey_original orelse return;

    // Simulate process lookups
    const test_processes = [_][]const u8{ "firefox", "CHROME", "Visual Studio Code", "Unknown App" };

    for (test_processes) |proc_name| {
        _ = hotkey.find_command_for_process(proc_name);
    }
}

pub fn main() !void {
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    std.debug.print("\n=== Benchmarking skhd hot path ===\n\n", .{});

    // Load the actual user config
    const config_path = "/Users/jackieli/.config/skhd/skhdrc";

    // Initialize skhd with profiling disabled
    var skhd = try Skhd.init(allocator, config_path, false, false);
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

    // Initialize hotkeys for process mapping benchmarks
    {
        // Original implementation
        var hotkey_original = try HotkeyOriginal.create(allocator);
        g_hotkey_original = hotkey_original;

        // Add common process mappings to both implementations
        const common_processes = [_][]const u8{
            "Firefox",            "Google Chrome",    "Safari",  "Terminal", "iTerm2",
            "Visual Studio Code", "Sublime Text",     "Slack",   "Discord",  "Spotify",
            "Mail",               "Calendar",         "Notes",   "Preview",  "Finder",
            "System Preferences", "Activity Monitor", "Console", "Xcode",    "IntelliJ IDEA",
        };

        for (common_processes) |process| {
            const cmd = try std.fmt.allocPrint(allocator, "echo '{s}'", .{process});
            defer allocator.free(cmd);
            try hotkey_original.add_process_command(process, cmd);
        }

        // Set wildcard commands using unified API
        try hotkey_original.add_process_command("*", "echo 'default'");

        std.debug.print("Initialized hotkeys with {} process mappings\n\n", .{common_processes.len});
    }
    defer if (g_hotkey_original) |h| h.destroy();

    // Create benchmark suite
    var bench = zbench.Benchmark.init(allocator, .{});
    defer bench.deinit();

    // Add benchmarks
    try bench.add("Process Name Lookup (syscall)", benchProcessNameLookup, .{});
    try bench.add("Process Name Lookup (cached)", benchCachedProcessName, .{});

    // Add process mapping benchmarks
    try bench.add("Process Mapping (Original)", benchProcessMappingOriginal, .{});

    // Run benchmarks
    try bench.run(std.io.getStdOut().writer());
}
