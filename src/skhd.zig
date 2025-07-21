const std = @import("std");
const builtin = @import("builtin");

const c = @import("c.zig");
const CarbonEvent = @import("CarbonEvent.zig");
const DeviceManager = @import("DeviceManager.zig");
const EventTap = @import("EventTap.zig");
const forkAndExec = @import("exec.zig").forkAndExec;
const Hotkey = @import("Hotkey.zig");
const Hotload = @import("Hotload.zig");
const Keycodes = @import("Keycodes.zig");
const ModifierFlag = Keycodes.ModifierFlag;
const Mappings = @import("Mappings.zig");
const Mode = @import("Mode.zig");
const Parser = @import("Parser.zig");
const Tracer = @import("Tracer.zig");

// Use scoped logging for skhd module
const log = std.log.scoped(.skhd);
const Skhd = @This();

// Global reference for signal handler
var global_skhd: ?*Skhd = null;

// Result of processing a hotkey
const HotkeyResult = enum {
    consumed, // Hotkey handled, consume the event
    passthrough, // Hotkey found but marked as passthrough/unbound
    not_found, // No matching hotkey
};

allocator: std.mem.Allocator,
mappings: Mappings,
current_mode: ?*Mode = null,
event_tap: EventTap,
config_file: []const u8,
verbose: bool,
hotloader: ?*Hotload = null,
hotload_enabled: bool = false,
tracer: Tracer,
carbon_event: *CarbonEvent,
device_manager: *DeviceManager,

pub fn init(gpa: std.mem.Allocator, config_file: []const u8, verbose: bool, profile: bool) !Skhd {
    log.info("Initializing skhd with config: {s}", .{config_file});

    var mappings = try Mappings.init(gpa);
    errdefer mappings.deinit();

    // Parse configuration file
    var parser = try Parser.init(gpa);
    defer parser.deinit();

    const content = try std.fs.cwd().readFileAlloc(gpa, config_file, 1 << 20); // 1MB max
    defer gpa.free(content);

    parser.parseWithPath(&mappings, content, config_file) catch |err| {
        if (parser.error_info) |parse_err| {
            log.err("skhd: {}", .{parse_err});
        }
        return err;
    };

    // Process any .load directives
    try parser.processLoadDirectives(&mappings);

    // Initialize with default mode if exists
    var current_mode: ?*Mode = null;
    if (mappings.mode_map.getPtr("default")) |default_mode| {
        current_mode = default_mode;
    }

    // Log loaded modes
    var mode_iter = mappings.mode_map.iterator();
    var modes_list = std.ArrayList(u8).init(gpa);
    defer modes_list.deinit();
    while (mode_iter.next()) |entry| {
        try modes_list.writer().print("'{s}' ", .{entry.key_ptr.*});
    }
    log.info("Loaded modes: {s}", .{modes_list.items});

    // Log shell configuration
    log.info("Using shell: {s}", .{mappings.shell});

    // Initialize Carbon event handler for app switching
    var carbon_event = try CarbonEvent.init(gpa);
    errdefer carbon_event.deinit();

    log.info("Initial process: {s}", .{carbon_event.getProcessName()});

    // Initialize Device Manager for device-specific hotkeys
    const device_manager = try DeviceManager.create(gpa);
    errdefer device_manager.destroy();

    // Create event tap with keyboard and system defined events
    const mask: u32 = (1 << c.kCGEventKeyDown) | (1 << c.kCGEventKeyUp) | (1 << c.NX_SYSDEFINED);

    return Skhd{
        .allocator = gpa,
        .mappings = mappings,
        .current_mode = current_mode,
        .event_tap = EventTap{ .mask = mask },
        .config_file = try gpa.dupe(u8, config_file),
        .verbose = verbose,
        .tracer = Tracer.init(profile),
        .carbon_event = carbon_event,
        .device_manager = device_manager,
    };
}

pub fn deinit(self: *Skhd) void {
    // Print tracer summary before cleanup
    if (self.tracer.enabled) {
        const stderr = std.io.getStdErr().writer();
        self.tracer.printSummary(stderr) catch {};
    }

    if (self.hotloader) |hotloader| {
        hotloader.destroy();
    }
    self.device_manager.destroy();
    self.carbon_event.deinit();
    self.event_tap.deinit();
    self.mappings.deinit();
    self.allocator.free(self.config_file);
}

pub fn run(self: *Skhd, enable_hotload: bool) !void {
    // Set up signal handler for config reload
    const usr1_act = std.posix.Sigaction{
        .handler = .{ .handler = handleSigusr1 },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.USR1, &usr1_act, null);

    // Set up signal handler for SIGINT (Ctrl+C) to print trace summary
    const int_act = std.posix.Sigaction{
        .handler = .{ .handler = handleSigint },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &int_act, null);

    // Store a global reference for the signal handler
    global_skhd = self;

    // Check if config file is a regular file
    const stat = std.fs.cwd().statFile(self.config_file) catch |err| {
        log.err("Cannot stat config file {s}: {}", .{ self.config_file, err });
        return err;
    };

    if (stat.kind != .file) {
        log.err("Config file {s} is not a regular file", .{self.config_file});
        return error.InvalidConfigFile;
    }

    // Enable hot reload if requested (must be done before run loop starts)
    if (enable_hotload) {
        try self.enableHotReload();
    }

    // Set up event tap (but don't start run loop yet)
    log.info("Starting event tap", .{});
    self.event_tap.begin(keyHandler, self) catch |err| {
        if (err == error.AccessibilityPermissionDenied) {
            const allocated_path: ?[]u8 = std.fs.selfExePathAlloc(self.allocator) catch null;
            defer if (allocated_path) |path| self.allocator.free(path);
            const exe_path = allocated_path orelse "/opt/homebrew/bin/skhd";

            log.err(
                \\
                \\=====================================================
                \\ACCESSIBILITY PERMISSIONS REQUIRED
                \\=====================================================
                \\skhd requires accessibility permissions to function.
                \\
                \\Please grant accessibility permissions:
                \\1. Open System Settings → Privacy & Security → Accessibility
                \\2. Click the lock to make changes
                \\3. Add this binary: {s}
                \\4. Make sure it's enabled (checkbox checked)
                \\5. Restart skhd
                \\
                \\Troubleshooting:
                \\If skhd is already listed but still not working:
                \\- Remove the existing skhd entry
                \\- Stop the service: skhd --stop-service
                \\- Re-add skhd to the list - Or just restart the service to see the entry added
                \\- Enable the entry and run skhd --restart-service
                \\=====================================================
                \\
            , .{exe_path});
        }
        return err;
    };

    // Call NSApplicationLoad() like the original skhd
    c.NSApplicationLoad();

    // Always log successful event tap creation
    log.info("Event tap created successfully. skhd is now running.", .{});

    // Now start the run loop - this will handle both event tap and FSEvents
    c.CFRunLoopRun();

    // If we get here, the run loop has exited
    log.info("Run loop exited", .{});
}

fn keyHandler(proxy: c.CGEventTapProxy, typ: c.CGEventType, event: c.CGEventRef, user_info: ?*anyopaque) callconv(.c) c.CGEventRef {
    _ = proxy;

    const self = @as(*Skhd, @ptrCast(@alignCast(user_info)));
    self.tracer.traceKeyEvent();

    switch (typ) {
        c.kCGEventTapDisabledByTimeout, c.kCGEventTapDisabledByUserInput => {
            log.info("Restarting event-tap", .{});
            c.CGEventTapEnable(self.event_tap.handle, true);
            return event;
        },
        c.kCGEventKeyDown => {
            self.tracer.traceKeyDown();
            return self.handleKeyDown(event) catch |err| {
                log.err("Error handling key down: {}", .{err});
                return event;
            };
        },
        c.NX_SYSDEFINED => {
            self.tracer.traceSystemKey();
            return self.handleSystemKey(event) catch |err| {
                log.err("Error handling system key: {}", .{err});
                return event;
            };
        },
        else => return event,
    }
}

inline fn handleKeyDown(self: *Skhd, event: c.CGEventRef) !c.CGEventRef {
    if (self.current_mode == null) {
        self.tracer.traceNoModeExit();
        return event;
    }

    // Skip events that we generated ourselves to avoid loops
    const marker = c.CGEventGetIntegerValueField(event, c.kCGEventSourceUserData);
    if (marker == SKHD_EVENT_MARKER) {
        self.tracer.traceSelfGeneratedExit();
        return event;
    }

    // Check if current application is blacklisted (using cached name)
    self.tracer.traceProcessNameLookup();
    const process_name = self.carbon_event.getProcessName();

    if (self.mappings.blacklist.contains(process_name)) {
        self.tracer.traceBlacklistedExit();
        return event;
    }

    const eventkey = createEventKey(event);
    const result = try self.processHotkey(&eventkey, event, process_name);
    return try self.handleHotkeyResult(result, event, eventkey, process_name);
}

/// Process the result of a hotkey lookup and determine what to do with the event
inline fn handleHotkeyResult(self: *Skhd, result: HotkeyResult, event: c.CGEventRef, eventkey: Hotkey.KeyPress, process_name: []const u8) !c.CGEventRef {
    switch (result) {
        .consumed => return @ptrFromInt(0),
        .passthrough => return event,
        .not_found => {
            // Check if current mode has capture enabled
            if (self.current_mode) |mode| {
                if (mode.capture) {
                    // Mode has capture enabled, consume all unmatched keypresses
                    try self.logKeyPress("Capture mode consuming unmatched key: {s}, process name: {s}", eventkey, .{process_name});
                    return @ptrFromInt(0);
                }
            }

            try self.logKeyPress("No matching hotkey found for key: {s}, process name: {s}", eventkey, .{process_name});
            return event;
        },
    }
}

inline fn handleSystemKey(self: *Skhd, event: c.CGEventRef) !c.CGEventRef {
    if (self.current_mode == null) {
        self.tracer.traceNoModeExit();
        return event;
    }

    // Skip events that we generated ourselves to avoid loops
    const marker = c.CGEventGetIntegerValueField(event, c.kCGEventSourceUserData);
    if (marker == SKHD_EVENT_MARKER) {
        self.tracer.traceSelfGeneratedExit();
        return event;
    }

    // Check if current application is blacklisted (using cached name)
    self.tracer.traceProcessNameLookup();
    const process_name = self.carbon_event.getProcessName();

    if (self.mappings.blacklist.contains(process_name)) {
        self.tracer.traceBlacklistedExit();
        return event;
    }

    var eventkey: Hotkey.KeyPress = undefined;
    if (interceptSystemKey(event, &eventkey)) {
        const result = try self.processHotkey(&eventkey, event, process_name);
        return try self.handleHotkeyResult(result, event, eventkey, process_name);
    }

    return event;
}

inline fn createEventKey(event: c.CGEventRef) Hotkey.KeyPress {
    return .{
        .key = @intCast(c.CGEventGetIntegerValueField(event, c.kCGKeyboardEventKeycode)),
        .flags = cgeventFlagsToHotkeyFlags(c.CGEventGetFlags(event)),
    };
}

inline fn cgeventFlagsToHotkeyFlags(event_flags: c.CGEventFlags) ModifierFlag {
    var flags = ModifierFlag{};

    // Implement left/right modifier distinction like original skhd
    // Alt/Option modifiers
    if (event_flags & c.kCGEventFlagMaskAlternate != 0) {
        const left_alt = (event_flags & 0x00000020) != 0; // Event_Mask_LAlt
        const right_alt = (event_flags & 0x00000040) != 0; // Event_Mask_RAlt

        if (left_alt) {
            flags.lalt = true;
        }
        if (right_alt) {
            flags.ralt = true;
        }
        if (!left_alt and !right_alt) {
            flags.alt = true;
        }
    }

    // Shift modifiers
    if (event_flags & c.kCGEventFlagMaskShift != 0) {
        const left_shift = (event_flags & 0x00000002) != 0; // Event_Mask_LShift
        const right_shift = (event_flags & 0x00000004) != 0; // Event_Mask_RShift

        if (left_shift) {
            flags.lshift = true;
        }
        if (right_shift) {
            flags.rshift = true;
        }
        if (!left_shift and !right_shift) {
            flags.shift = true;
        }
    }

    // Command modifiers
    if (event_flags & c.kCGEventFlagMaskCommand != 0) {
        const left_cmd = (event_flags & 0x00000008) != 0; // Event_Mask_LCmd
        const right_cmd = (event_flags & 0x00000010) != 0; // Event_Mask_RCmd

        if (left_cmd) {
            flags.lcmd = true;
        }
        if (right_cmd) {
            flags.rcmd = true;
        }
        if (!left_cmd and !right_cmd) {
            flags.cmd = true;
        }
    }

    // Control modifiers
    if (event_flags & c.kCGEventFlagMaskControl != 0) {
        const left_ctrl = (event_flags & 0x00000001) != 0; // Event_Mask_LControl
        const right_ctrl = (event_flags & 0x00002000) != 0; // Event_Mask_RControl

        if (left_ctrl) {
            flags.lcontrol = true;
        }
        if (right_ctrl) {
            flags.rcontrol = true;
        }
        if (!left_ctrl and !right_ctrl) {
            flags.control = true;
        }
    }

    // Function key modifier
    if (event_flags & c.kCGEventFlagMaskSecondaryFn != 0) {
        flags.@"fn" = true;
    }

    return flags;
}

inline fn interceptSystemKey(event: c.CGEventRef, eventkey: *Hotkey.KeyPress) bool {
    const event_data = c.CGEventCreateData(c.kCFAllocatorDefault, event);
    defer c.CFRelease(event_data);

    const data = c.CFDataGetBytePtr(event_data);
    const key_code = data[129];
    const key_state = data[130];
    const key_stype = data[123];

    const NX_KEYDOWN: u8 = 0x0A;
    const NX_SUBTYPE_AUX_CONTROL_BUTTONS: u8 = 8;

    const result = (key_state == NX_KEYDOWN) and (key_stype == NX_SUBTYPE_AUX_CONTROL_BUTTONS);

    if (result) {
        eventkey.key = key_code;
        eventkey.flags = cgeventFlagsToHotkeyFlags(c.CGEventGetFlags(event));
        eventkey.flags.nx = true;
    }

    return result;
}

// Magic number to mark events generated by us
const SKHD_EVENT_MARKER: i64 = 0x736B6864; // "skhd" in hex

inline fn forwardKey(target_key: Hotkey.KeyPress, _: c.CGEventRef) !void {
    // Create a proper event source for the new event
    const event_source = c.CGEventSourceCreate(c.kCGEventSourceStateHIDSystemState);
    if (event_source == null) return error.FailedToCreateEventSource;
    defer c.CFRelease(event_source);

    // Create key down event
    const key_down = c.CGEventCreateKeyboardEvent(event_source, @intCast(target_key.key), true);
    if (key_down == null) return error.FailedToCreateKeyboardEvent;
    defer c.CFRelease(key_down);

    // Create key up event
    const key_up = c.CGEventCreateKeyboardEvent(event_source, @intCast(target_key.key), false);
    if (key_up == null) return error.FailedToCreateKeyboardEvent;
    defer c.CFRelease(key_up);

    // Set the modifier flags for both events
    const target_flags = hotkeyFlagsToCGEventFlags(target_key.flags);
    c.CGEventSetFlags(key_down, target_flags);
    c.CGEventSetFlags(key_up, target_flags);

    // Mark these events as generated by us to avoid processing them again
    c.CGEventSetIntegerValueField(key_down, c.kCGEventSourceUserData, SKHD_EVENT_MARKER);
    c.CGEventSetIntegerValueField(key_up, c.kCGEventSourceUserData, SKHD_EVENT_MARKER);

    // Post both key down and key up events
    c.CGEventPost(c.kCGSessionEventTap, key_down);
    c.CGEventPost(c.kCGSessionEventTap, key_up);
}

inline fn hotkeyFlagsToCGEventFlags(hotkey_flags: ModifierFlag) c.CGEventFlags {
    var flags: c.CGEventFlags = 0;

    // Handle command modifiers (general, left, right)
    if (hotkey_flags.cmd or hotkey_flags.lcmd or hotkey_flags.rcmd) {
        flags |= c.kCGEventFlagMaskCommand;
        if (hotkey_flags.lcmd) {
            flags |= 0x00000008; // Event_Mask_LCmd
        }
        if (hotkey_flags.rcmd) {
            flags |= 0x00000010; // Event_Mask_RCmd
        }
    }

    // Handle alt modifiers (general, left, right)
    if (hotkey_flags.alt or hotkey_flags.lalt or hotkey_flags.ralt) {
        flags |= c.kCGEventFlagMaskAlternate;
        if (hotkey_flags.lalt) {
            flags |= 0x00000020; // Event_Mask_LAlt
        }
        if (hotkey_flags.ralt) {
            flags |= 0x00000040; // Event_Mask_RAlt
        }
    }

    // Handle control modifiers (general, left, right)
    if (hotkey_flags.control or hotkey_flags.lcontrol or hotkey_flags.rcontrol) {
        flags |= c.kCGEventFlagMaskControl;
        if (hotkey_flags.lcontrol) {
            flags |= 0x00000001; // Event_Mask_LControl
        }
        if (hotkey_flags.rcontrol) {
            flags |= 0x00002000; // Event_Mask_RControl
        }
    }

    // Handle shift modifiers (general, left, right)
    if (hotkey_flags.shift or hotkey_flags.lshift or hotkey_flags.rshift) {
        flags |= c.kCGEventFlagMaskShift;
        if (hotkey_flags.lshift) {
            flags |= 0x00000002; // Event_Mask_LShift
        }
        if (hotkey_flags.rshift) {
            flags |= 0x00000004; // Event_Mask_RShift
        }
    }

    // Function key modifier
    if (hotkey_flags.@"fn") {
        flags |= c.kCGEventFlagMaskSecondaryFn;
    }

    return flags;
}

/// Find a hotkey in the mode that matches the keyboard event
/// Returns the hotkey pointer if found, null otherwise
pub inline fn findHotkeyInMode(self: *Skhd, mode: *const Mode, eventkey: Hotkey.KeyPress) ?*Hotkey {
    // Method 1: HashMap lookup with adapted context (O(1) average case)
    return self.findHotkeyHashMap(mode, eventkey);

    // Method 2: Linear array search (O(n) but potentially faster for small sets)
    // return self.findHotkeyLinear(mode, eventkey);
}

/// HashMap-based lookup using adapted context
pub inline fn findHotkeyHashMap(self: *Skhd, mode: *const Mode, eventkey: Hotkey.KeyPress) ?*Hotkey {
    self.tracer.traceHotkeyLookup();
    const ctx = Hotkey.KeyboardLookupContext{};
    const result = mode.hotkey_map.getKeyAdapted(eventkey, ctx);
    self.tracer.traceHotkeyFound(result != null);
    return result;
}

/// Process a hotkey - single lookup that handles both forwarding and execution
inline fn processHotkey(self: *Skhd, eventkey: *const Hotkey.KeyPress, event: c.CGEventRef, process_name: []const u8) !HotkeyResult {
    const mode = self.current_mode orelse return .not_found;

    self.tracer.traceHotkeyLookup();
    const found_hotkey = self.findHotkeyInMode(mode, eventkey.*);

    if (found_hotkey == null) {
        self.tracer.traceHotkeyFound(false);
        return .not_found;
    }

    try self.logKeyPress("Found hotkey: '{s}' for process: '{s}' in mode '{s}'", eventkey.*, .{ process_name, mode.name });
    self.tracer.traceHotkeyFound(true);
    const hotkey = found_hotkey.?;

    // Check for process-specific command/forward (includes wildcard fallback)
    if (hotkey.find_command_for_process(process_name)) |process_cmd| {
        switch (process_cmd) {
            .forwarded => |target_key| {
                try self.logKeyPress("Forwarding key '{s}' for process {s}", target_key, .{process_name});
                self.tracer.traceKeyForwarded();
                try forwardKey(target_key, event);
                return .consumed;
            },
            .command => |cmd| {
                log.debug("Executing command '{s}' for process {s}", .{ cmd, process_name });
                self.tracer.traceCommandExecuted();
                try forkAndExec(self.mappings.shell, cmd, self.verbose);
                return if (hotkey.flags.passthrough) .passthrough else .consumed;
            },
            .unbound => {
                log.debug("Unbound key for process {s}", .{process_name});
                return .passthrough;
            },
            .activation => |act| {
                // Execute activation command if provided
                if (act.command) |activation_cmd| {
                    log.debug("Executing activation command: {s}", .{activation_cmd});
                    try forkAndExec(self.mappings.shell, activation_cmd, self.verbose);
                }
                log.debug("Activating mode '{s}'", .{act.mode_name});
                self.current_mode = self.mappings.mode_map.getPtr(act.mode_name);
                if (self.current_mode) |_mode| {
                    if (_mode.command) |mode_cmd| {
                        log.debug("Executing mode command: {s}", .{mode_cmd});
                        try forkAndExec(self.mappings.shell, mode_cmd, self.verbose);
                    }
                } else {
                    log.err("Failed to activate mode '{s}': mode not found", .{act.mode_name});
                    log.debug("Resetting to default mode", .{});
                    self.current_mode = self.mappings.mode_map.getPtr("default");
                }

                return .consumed;
            },
        }
    }

    return .not_found;
}

/// Signal handler for SIGUSR1 - reload configuration
fn handleSigusr1(_: c_int) callconv(.C) void {
    if (global_skhd) |skhd| {
        log.info("Received SIGUSR1, reloading configuration", .{});
        skhd.reloadConfig() catch |err| {
            log.err("Failed to reload config: {}", .{err});
        };
    }
}

/// Signal handler for SIGINT - stop the run loop to allow graceful shutdown
fn handleSigint(_: c_int) callconv(.C) void {
    // Stop the run loop to allow graceful shutdown with defer statements
    c.CFRunLoopStop(c.CFRunLoopGetCurrent());
}

/// Reload configuration from file
pub fn reloadConfig(self: *Skhd) !void {
    log.info("Reloading configuration from: {s}", .{self.config_file});

    // Parse new configuration
    var new_mappings = try Mappings.init(self.allocator);
    errdefer new_mappings.deinit();

    var parser = try Parser.init(self.allocator);
    defer parser.deinit();

    const content = try std.fs.cwd().readFileAlloc(self.allocator, self.config_file, 1 << 20);
    defer self.allocator.free(content);

    parser.parseWithPath(&new_mappings, content, self.config_file) catch |err| {
        // Log the parse error with proper formatting
        if (parser.error_info) |parse_err| {
            log.err("skhd: {}", .{parse_err});
        }
        return err;
    };
    try parser.processLoadDirectives(&new_mappings);

    // Swap old mappings with new ones
    self.mappings.deinit();
    self.mappings = new_mappings;

    // Reset to default mode
    if (self.mappings.mode_map.getPtr("default")) |default_mode| {
        self.current_mode = default_mode;
    } else {
        self.current_mode = null;
    }

    // Note: We don't re-enable hot reload here because this function
    // might be called from within the hotload callback. Instead, we'll
    // update the watched files list when hot reload is already enabled.

    log.info("Configuration reloaded successfully", .{});
}

pub fn enableHotReload(self: *Skhd) !void {
    if (self.hotload_enabled) return;

    log.info("Enabling hot reload...", .{});

    // Store self reference for callback
    global_skhd = self;

    // Create hotloader (already heap-allocated by create())
    const hotloader = try Hotload.create(self.allocator, hotloadCallback);

    // Resolve main config file to absolute path for FSEvents
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = try std.fs.cwd().realpath(self.config_file, &path_buf);

    log.info("Watching main config: {s} (resolved to: {s})", .{ self.config_file, abs_path });
    try hotloader.addFile(abs_path);

    // Also watch all loaded files
    for (self.mappings.loaded_files.items) |loaded_file| {
        log.info("Watching loaded file: {s}", .{loaded_file});
        hotloader.addFile(loaded_file) catch |err| {
            log.info("Failed to watch loaded file {s}: {}", .{ loaded_file, err });
        };
    }

    // Start the hotloader
    try hotloader.start();

    self.hotloader = hotloader;
    self.hotload_enabled = true;

    log.info("Hot reload enabled successfully", .{});
}

pub fn disableHotReload(self: *Skhd) void {
    if (!self.hotload_enabled) return;

    if (self.hotloader) |hotloader| {
        hotloader.destroy();
    }

    self.hotloader = null;
    self.hotload_enabled = false;

    log.info("Hot reload disabled", .{});
}

fn hotloadCallback(path: []const u8) void {
    // Follow the original skhd approach - directly reload the config
    if (global_skhd) |skhd| {
        log.info("Config file has been modified: {s} .. reloading config", .{path});
        skhd.reloadConfig() catch |err| {
            log.err("Failed to reload config: {}", .{err});
        };
    } else {
        std.debug.print("ERROR: global_skhd is null in hotloadCallback\n", .{});
    }
}

/// Log a keypress with formatted key string
inline fn logKeyPress(self: *Skhd, comptime fmt: []const u8, key: Hotkey.KeyPress, rest: anytype) !void {
    if (comptime builtin.mode != .Debug and builtin.mode != .ReleaseSafe) return;
    // Only log in interactive mode to avoid allocation in hot path
    if (!self.verbose) return;

    var buf: [256]u8 = undefined;
    const key_str = try Keycodes.formatKeyPressBuffer(&buf, key.flags, key.key);
    log.debug(fmt, .{key_str} ++ rest);
}

// Test helper to create a Skhd instance from a config string
fn createTestSkhdFromConfig(allocator: std.mem.Allocator, config: []const u8) !Skhd {
    // Parse the config
    var mappings = try Mappings.init(allocator);
    errdefer mappings.deinit();

    var parser = try Parser.init(allocator);
    defer parser.deinit();

    try parser.parseWithPath(&mappings, config, "test.conf");

    // Set up default mode if it exists
    var current_mode: ?*Mode = null;
    if (mappings.mode_map.getPtr("default")) |default_mode| {
        current_mode = default_mode;
    }

    // Create carbon event mock
    const carbon_event = try CarbonEvent.init(allocator);
    errdefer carbon_event.deinit();

    // Create device manager mock
    const device_manager = try DeviceManager.create(allocator);
    errdefer device_manager.destroy();

    return Skhd{
        .allocator = allocator,
        .mappings = mappings,
        .current_mode = current_mode,
        .event_tap = EventTap{ .mask = 0 },
        .config_file = try allocator.dupe(u8, "test.conf"),
        .verbose = false,
        .tracer = Tracer.init(false),
        .carbon_event = carbon_event,
        .device_manager = device_manager,
    };
}

test "processHotkey respects passthrough in capture mode" {
    const alloc = std.testing.allocator;

    const config =
        \\:: capture @
        \\capture < cmd - a -> : echo passthrough
        \\capture < cmd - b : echo normal
        \\capture < cmd - c ~
    ;

    var skhd = try createTestSkhdFromConfig(alloc, config);
    defer skhd.deinit();

    // Switch to capture mode
    skhd.current_mode = skhd.mappings.mode_map.getPtr("capture");

    // Create mock event
    const mock_event: c.CGEventRef = @ptrFromInt(0x1234);

    // Test passthrough command
    {
        const keypress = Hotkey.KeyPress{ .key = 0x00, .flags = ModifierFlag{ .cmd = true } }; // Cmd+A
        const result = try skhd.processHotkey(&keypress, mock_event, "test");
        try std.testing.expectEqual(HotkeyResult.passthrough, result);
    }

    // Test normal command
    {
        const keypress = Hotkey.KeyPress{ .key = 0x0B, .flags = ModifierFlag{ .cmd = true } }; // Cmd+B
        const result = try skhd.processHotkey(&keypress, mock_event, "test");
        try std.testing.expectEqual(HotkeyResult.consumed, result);
    }

    // Test unbound action
    {
        const keypress = Hotkey.KeyPress{ .key = 0x08, .flags = ModifierFlag{ .cmd = true } }; // Cmd+C
        const result = try skhd.processHotkey(&keypress, mock_event, "test");
        try std.testing.expectEqual(HotkeyResult.passthrough, result);
    }

    // Test unmatched key (should return not_found, allowing capture mode to consume it)
    {
        const keypress = Hotkey.KeyPress{ .key = 0x02, .flags = ModifierFlag{ .cmd = true } }; // Cmd+D (not defined)
        const result = try skhd.processHotkey(&keypress, mock_event, "test");
        try std.testing.expectEqual(HotkeyResult.not_found, result);
    }
}
