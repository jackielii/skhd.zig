const std = @import("std");
const c = @import("c.zig");
const DeviceManager = @import("DeviceManager.zig");
const KeyRemapper = @import("KeyRemapper.zig");

// Global for cleanup
var global_key_remapper: ?*KeyRemapper = null;
var should_cleanup_mapping = false;

// Timing configuration
const TimingConfig = struct {
    tap_threshold_ns: i64 = 200_000_000, // 200ms in nanoseconds
    double_tap_window_ns: i64 = 300_000_000, // 300ms
    repeat_delay_ns: i64 = 500_000_000, // 500ms
    repeat_interval_ns: i64 = 30_000_000, // 30ms
};

// Key state for timing detection
const KeyTimingState = struct {
    usage_code: u32,
    device_ref: c.IOHIDDeviceRef,
    down_timestamp: i64 = 0,
    up_timestamp: i64 = 0,
    is_pressed: bool = false,
    has_been_modified: bool = false,
    control_injected: bool = false,
    tap_count: u32 = 0,
    last_tap_time: i64 = 0,
    timer: ?*c.struct___CFRunLoopTimer = null,
    
    fn reset(self: *KeyTimingState) void {
        self.is_pressed = false;
        self.has_been_modified = false;
        self.control_injected = false;
        self.down_timestamp = 0;
        self.up_timestamp = 0;
        if (self.timer) |timer| {
            c.CFRunLoopTimerInvalidate(timer);
            c.CFRelease(timer);
            self.timer = null;
        }
    }
    
    fn shouldTriggerTap(self: *const KeyTimingState, current_time: i64, config: TimingConfig) bool {
        if (self.has_been_modified) return false;
        const duration = current_time - self.down_timestamp;
        return duration <= config.tap_threshold_ns;
    }
    
    fn shouldTriggerHold(self: *const KeyTimingState, current_time: i64, config: TimingConfig) bool {
        if (!self.is_pressed) return false;
        const duration = current_time - self.down_timestamp;
        return duration > config.tap_threshold_ns;
    }
    
    fn isDoubleTap(self: *const KeyTimingState, current_time: i64, config: TimingConfig) bool {
        const time_since_last = current_time - self.last_tap_time;
        return self.tap_count > 0 and time_since_last <= config.double_tap_window_ns;
    }
};

// Global state
var timing_config = TimingConfig{};
var key_states: std.AutoHashMap(u32, KeyTimingState) = undefined;
var event_tap: c.CFMachPortRef = null;
var run_loop_source: c.CFRunLoopSourceRef = null;
var device_manager: *DeviceManager = undefined;

// Convert Mach absolute time to nanoseconds
fn machTimeToNanos(mach_time: u64) i64 {
    // For simplicity, assume 1:1 ratio (true on most modern Macs)
    // In production, would use mach_timebase_info
    return @intCast(mach_time);
}

// Handle timing key from CGEventTap
fn handleTimingKeyFromCGEvent(state: *KeyTimingState, pressed: bool, timestamp: i64) void {
    if (pressed) {
        // Ignore key repeat - only process the first DOWN
        if (state.is_pressed) {
            return;
        }
        
        // Key down
        state.down_timestamp = timestamp;
        state.is_pressed = true;
        state.has_been_modified = false;
        state.control_injected = false;
        
        std.debug.print("F13 DOWN - starting timing\n", .{});
        
        // Create timer for hold detection
        const delay_ns = timing_config.tap_threshold_ns;
        const delay_seconds = @as(f64, @floatFromInt(delay_ns)) / 1_000_000_000.0;
        
        var timer_context = c.CFRunLoopTimerContext{
            .version = 0,
            .info = state,
            .retain = null,
            .release = null,
            .copyDescription = null,
        };
        
        state.timer = c.CFRunLoopTimerCreate(
            c.kCFAllocatorDefault,
            c.CFAbsoluteTimeGetCurrent() + delay_seconds,
            0, // no repeat
            0, // flags
            0, // order
            holdTimerCallback,
            &timer_context
        );
        
        if (state.timer) |timer| {
            c.CFRunLoopAddTimer(c.CFRunLoopGetCurrent(), timer, c.kCFRunLoopCommonModes);
        }
    } else {
        // Key up - only process if key was actually pressed
        if (!state.is_pressed) {
            return;
        }
        
        state.up_timestamp = timestamp;
        const duration_ns = timestamp - state.down_timestamp;
        const duration_ms = @divTrunc(duration_ns, 1_000_000);
        
        std.debug.print("F13 UP - duration: {}ms\n", .{duration_ms});
        
        // Cancel timer if still pending
        if (state.timer) |timer| {
            c.CFRunLoopTimerInvalidate(timer);
            c.CFRelease(timer);
            state.timer = null;
        }
        
        if (state.control_injected) {
            // Release Control
            std.debug.print("  → Releasing Control\n", .{});
            const ctrl_up = c.CGEventCreateKeyboardEvent(null, 0x3B, false);
            defer c.CFRelease(ctrl_up);
            c.CGEventPost(c.kCGHIDEventTap, ctrl_up);
        } else if (state.shouldTriggerTap(timestamp, timing_config)) {
            // Check for double tap
            if (state.isDoubleTap(timestamp, timing_config)) {
                std.debug.print("  → Double tap detected! Sending Caps Lock\n", .{});
                sendKeyPress(57); // Original caps lock keycode
                state.tap_count = 0;
            } else {
                std.debug.print("  → Tap detected! Sending Escape\n", .{});
                sendKeyPress(53); // Escape keycode
                state.tap_count += 1;
            }
            state.last_tap_time = timestamp;
        } else if (state.has_been_modified) {
            std.debug.print("  → Used as modifier (Control)\n", .{});
        }
        
        state.reset();
    }
}

// Inject a key event
fn injectKeyEvent(keycode: u16, down: bool) void {
    const event = c.CGEventCreateKeyboardEvent(null, keycode, down);
    defer c.CFRelease(event);
    
    // Post to HID event tap
    c.CGEventPost(c.kCGHIDEventTap, event);
}

// Send a complete key press (down + up)
fn sendKeyPress(keycode: u16) void {
    injectKeyEvent(keycode, true);
    // Small delay between down and up
    std.time.sleep(10_000_000); // 10ms
    injectKeyEvent(keycode, false);
}

// HID input callback
fn hidInputCallback(context: ?*anyopaque, result: c.IOReturn, sender: ?*anyopaque, value: c.IOHIDValueRef) callconv(.c) void {
    _ = result;
    _ = context;
    
    const device = @as(c.IOHIDDeviceRef, @ptrCast(sender));
    const element = c.IOHIDValueGetElement(value);
    const usage_page = c.IOHIDElementGetUsagePage(element);
    const usage = c.IOHIDElementGetUsage(element);
    
    // Debug: log F13 events only
    if (usage_page == c.kHIDPage_KeyboardOrKeypad and usage == 0x68) {
        const pressed = c.IOHIDValueGetIntegerValue(value) != 0;
        const device_info = device_manager.getDeviceInfo(device);
        if (device_info) |info| {
            std.debug.print("[HID] [{s}] F13 {s}\n", .{ 
                info.name, 
                if (pressed) "DOWN" else "UP" 
            });
        }
    }
    
    // Only handle keyboard events
    if (usage_page != c.kHIDPage_KeyboardOrKeypad) return;
    
    const pressed = c.IOHIDValueGetIntegerValue(value) != 0;
    const timestamp = @as(i64, @intCast(c.IOHIDValueGetTimeStamp(value))); // nanoseconds since boot
    
    // Get or create key state
    const key_state = key_states.getPtr(usage) orelse blk: {
        key_states.put(usage, KeyTimingState{
            .usage_code = usage,
            .device_ref = device,
        }) catch return;
        break :blk key_states.getPtr(usage).?;
    };
    
    // Handle F13 (0x68) - our remapped Caps Lock
    if (usage == 0x68) {
        handleTimingKey(key_state, pressed, timestamp, device);
    }
    
    // Track modifier usage with timing keys
    if (usage >= 0xE0 and usage <= 0xE7) { // Modifier keys
        // If F13 is pressed and a modifier is used, mark it as modified
        if (key_states.getPtr(0x68)) |f13_state| {
            if (f13_state.is_pressed) {
                f13_state.has_been_modified = true;
            }
        }
    }
}

// Timer callback for hold detection
fn holdTimerCallback(timer: c.CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const state = @as(*KeyTimingState, @ptrCast(@alignCast(info)));
    
    if (state.is_pressed and !state.has_been_modified and !state.control_injected) {
        std.debug.print("  → Hold threshold reached! Injecting Control DOWN\n", .{});
        
        // Inject Control down
        const ctrl_down = c.CGEventCreateKeyboardEvent(null, 0x3B, true); // Left Control keycode
        defer c.CFRelease(ctrl_down);
        c.CGEventSetFlags(ctrl_down, c.kCGEventFlagMaskControl);
        c.CGEventPost(c.kCGHIDEventTap, ctrl_down);
        
        state.control_injected = true;
    }
    
    // Invalidate timer after firing
    if (state.timer) |t| {
        if (t == timer) {
            c.CFRunLoopTimerInvalidate(timer);
            state.timer = null;
        }
    }
}

// Handle timing-based key
fn handleTimingKey(state: *KeyTimingState, pressed: bool, timestamp: i64, device: c.IOHIDDeviceRef) void {
    const device_info = device_manager.getDeviceInfo(device) orelse return;
    
    if (pressed) {
        // Key down
        state.down_timestamp = timestamp;
        state.is_pressed = true;
        state.has_been_modified = false;
        state.control_injected = false;
        
        std.debug.print("[{s}] F13 DOWN - starting timing\n", .{device_info.name});
        
        // Create timer for hold detection
        const delay_ns = timing_config.tap_threshold_ns;
        const delay_seconds = @as(f64, @floatFromInt(delay_ns)) / 1_000_000_000.0;
        
        var timer_context = c.CFRunLoopTimerContext{
            .version = 0,
            .info = state,
            .retain = null,
            .release = null,
            .copyDescription = null,
        };
        
        state.timer = c.CFRunLoopTimerCreate(
            c.kCFAllocatorDefault,
            c.CFAbsoluteTimeGetCurrent() + delay_seconds,
            0, // no repeat
            0, // flags
            0, // order
            holdTimerCallback,
            &timer_context
        );
        
        if (state.timer) |timer| {
            c.CFRunLoopAddTimer(c.CFRunLoopGetCurrent(), timer, c.kCFRunLoopCommonModes);
        }
    } else {
        // Key up
        state.up_timestamp = timestamp;
        const duration_ns = timestamp - state.down_timestamp;
        const duration_ms = @divTrunc(duration_ns, 1_000_000);
        
        std.debug.print("[{s}] F13 UP - duration: {}ms\n", .{ device_info.name, duration_ms });
        
        // Cancel timer if still pending
        if (state.timer) |timer| {
            c.CFRunLoopTimerInvalidate(timer);
            c.CFRelease(timer);
            state.timer = null;
        }
        
        if (state.control_injected) {
            // Release Control
            std.debug.print("  → Releasing Control\n", .{});
            const ctrl_up = c.CGEventCreateKeyboardEvent(null, 0x3B, false);
            defer c.CFRelease(ctrl_up);
            c.CGEventPost(c.kCGHIDEventTap, ctrl_up);
        } else if (state.shouldTriggerTap(timestamp, timing_config)) {
            // Check for double tap
            if (state.isDoubleTap(timestamp, timing_config)) {
                std.debug.print("  → Double tap detected! Sending Caps Lock\n", .{});
                sendKeyPress(0x39); // Original caps lock
                state.tap_count = 0;
            } else {
                std.debug.print("  → Tap detected! Sending Escape\n", .{});
                sendKeyPress(0x35); // Escape
                state.tap_count += 1;
            }
            state.last_tap_time = timestamp;
        } else if (state.has_been_modified) {
            std.debug.print("  → Used as modifier (Control)\n", .{});
        }
        
        state.reset();
    }
}

// CGEventTap callback for suppressing F13 events and monitoring
fn eventTapCallback(proxy: c.CGEventTapProxy, event_type: c.CGEventType, event: c.CGEventRef, refcon: ?*anyopaque) callconv(.c) c.CGEventRef {
    _ = proxy;
    _ = refcon;
    
    if (event_type == c.kCGEventTapDisabledByTimeout or event_type == c.kCGEventTapDisabledByUserInput) {
        // Re-enable the event tap
        c.CGEventTapEnable(event_tap, true);
        return event;
    }
    
    const cg_event_type = c.CGEventGetType(event);
    if (cg_event_type != c.kCGEventKeyDown and cg_event_type != c.kCGEventKeyUp) {
        return event;
    }
    
    const keycode = c.CGEventGetIntegerValueField(event, c.kCGKeyboardEventKeycode);
    
    // Handle F13 events (keycode 105) - our remapped Caps Lock
    if (keycode == 105) {
        const is_down = cg_event_type == c.kCGEventKeyDown;
        const timestamp = c.CGEventGetTimestamp(event); // Mach absolute time
        const timestamp_ns = machTimeToNanos(timestamp);
        
        // Get or create key state for F13
        const key_state = key_states.getPtr(0x68) orelse blk: {
            key_states.put(0x68, KeyTimingState{
                .usage_code = 0x68,
                .device_ref = undefined,
            }) catch return null;
            break :blk key_states.getPtr(0x68).?;
        };
        
        // Handle timing for F13
        handleTimingKeyFromCGEvent(key_state, is_down, timestamp_ns);
        
        // Always suppress F13
        return null;
    }
    
    // Monitor for demonstration
    if (cg_event_type == c.kCGEventKeyDown) {
        std.debug.print("Key down: {} (will check for modified state)\n", .{keycode});
        
        // If F13 is held and another key is pressed, mark F13 as modified
        if (key_states.getPtr(0x68)) |f13_state| {
            if (f13_state.is_pressed) {
                f13_state.has_been_modified = true;
                
                // If Control hasn't been injected yet, inject it now
                if (!f13_state.control_injected) {
                    std.debug.print("  → F13 used with another key, injecting Control\n", .{});
                    const ctrl_down = c.CGEventCreateKeyboardEvent(null, 0x3B, true);
                    defer c.CFRelease(ctrl_down);
                    c.CGEventSetFlags(ctrl_down, c.kCGEventFlagMaskControl);
                    c.CGEventPost(c.kCGHIDEventTap, ctrl_down);
                    f13_state.control_injected = true;
                }
                
                // Add Control flag to this event
                const flags = c.CGEventGetFlags(event) | c.kCGEventFlagMaskControl;
                c.CGEventSetFlags(event, flags);
            }
        }
    }
    
    return event;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Initialize key states
    key_states = std.AutoHashMap(u32, KeyTimingState).init(allocator);
    defer key_states.deinit();
    
    // Initialize device manager
    device_manager = try DeviceManager.create(allocator);
    defer device_manager.destroy();
    
    // Initialize key remapper
    const key_remapper = try KeyRemapper.create(allocator);
    defer key_remapper.destroy();
    global_key_remapper = key_remapper;
    
    // Set up signal handler for cleanup
    var sa = std.posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    
    std.debug.print("Timing-based remapping test\n", .{});
    std.debug.print("===========================\n\n", .{});
    
    // Check if Caps Lock is already remapped
    const already_remapped = try key_remapper.isCapsLockRemapped();
    if (!already_remapped) {
        std.debug.print("Setting up Caps Lock → F13 remapping...\n", .{});
        try key_remapper.setKeyMapping(KeyRemapper.KeyMapping.CAPS_TO_F13);
        std.debug.print("✓ Caps Lock has been remapped to F13\n\n", .{});
        should_cleanup_mapping = true;
    } else {
        std.debug.print("✓ Caps Lock is already remapped\n\n", .{});
        should_cleanup_mapping = false;
    }
    
    std.debug.print("Test scenarios:\n", .{});
    std.debug.print("1. Quick tap Caps Lock (< 200ms) → Escape\n", .{});
    std.debug.print("2. Hold Caps Lock (> 200ms) → Acts as Control\n", .{});
    std.debug.print("3. Double tap Caps Lock → Original Caps Lock\n", .{});
    std.debug.print("4. Caps Lock + other key (before 200ms) → Control + key\n", .{});
    std.debug.print("\nPress Ctrl+C to exit\n", .{});
    if (should_cleanup_mapping) {
        std.debug.print("(Mapping will be automatically cleared on exit)\n\n", .{});
    } else {
        std.debug.print("(Existing mapping will be preserved on exit)\n\n", .{});
    }
    
    // Set up CGEventTap to suppress F13 and monitor events
    const event_mask = (1 << @as(u6, @intCast(c.kCGEventKeyDown))) | 
                       (1 << @as(u6, @intCast(c.kCGEventKeyUp)));
    
    event_tap = c.CGEventTapCreate(
        c.kCGSessionEventTap,
        c.kCGHeadInsertEventTap,
        c.kCGEventTapOptionDefault,
        @intCast(event_mask),
        eventTapCallback,
        null
    );
    
    if (event_tap == null) {
        std.debug.print("Failed to create event tap. Make sure accessibility access is granted.\n", .{});
        return error.EventTapCreateFailed;
    }
    
    run_loop_source = c.CFMachPortCreateRunLoopSource(c.kCFAllocatorDefault, event_tap, 0);
    c.CFRunLoopAddSource(c.CFRunLoopGetCurrent(), run_loop_source, c.kCFRunLoopCommonModes);
    c.CGEventTapEnable(event_tap, true);
    
    // Register HID callbacks
    try device_manager.registerInputCallbacks(hidInputCallback, null);
    
    // Run the event loop
    c.CFRunLoopRun();
    
    // Cleanup
    if (run_loop_source) |source| {
        c.CFRunLoopRemoveSource(c.CFRunLoopGetCurrent(), source, c.kCFRunLoopCommonModes);
        c.CFRelease(source);
    }
    if (event_tap) |tap| {
        c.CGEventTapEnable(tap, false);
        c.CFRelease(tap);
    }
}

test "timing calculations" {
    const config = TimingConfig{};
    var state = KeyTimingState{
        .usage_code = 0x68,
        .device_ref = undefined,
    };
    
    // Test tap detection
    state.down_timestamp = 1000_000_000;
    state.is_pressed = true;
    
    // 100ms later - should be tap
    try std.testing.expect(state.shouldTriggerTap(1100_000_000, config));
    try std.testing.expect(!state.shouldTriggerHold(1100_000_000, config));
    
    // 300ms later - should be hold
    try std.testing.expect(!state.shouldTriggerTap(1300_000_000, config));
    try std.testing.expect(state.shouldTriggerHold(1300_000_000, config));
    
    // Test double tap
    state.last_tap_time = 2000_000_000;
    state.tap_count = 1;
    
    // 200ms later - should be double tap
    try std.testing.expect(state.isDoubleTap(2200_000_000, config));
    
    // 400ms later - should not be double tap
    try std.testing.expect(!state.isDoubleTap(2400_000_000, config));
}

// Signal handler for cleanup
fn signalHandler(sig: c_int) callconv(.c) void {
    _ = sig;
    std.debug.print("\n\nCleaning up...\n", .{});
    
    if (should_cleanup_mapping) {
        if (global_key_remapper) |remapper| {
            remapper.clearKeyMappings() catch |err| {
                std.debug.print("Failed to clear key mappings: {}\n", .{err});
            };
            std.debug.print("✓ Restored Caps Lock to default\n", .{});
        }
    }
    
    std.posix.exit(0);
}