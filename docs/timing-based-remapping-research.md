# Timing-Based Key Remapping Research

## Overview

This document explores implementing timing-based key remapping (tap vs hold) at the HID layer for skhd.zig, with a focus on creating reliable tap/hold detection for keys like Caps Lock → Escape/Control.

## Key Challenges

1. **Event Timing**: Need precise timing between key down and key up events
2. **Event Suppression**: Must suppress original key events while determining tap/hold
3. **Event Injection**: Need to inject the appropriate key event after timing decision
4. **Edge Cases**: Handle rapid key presses, key holds, and modifier combinations

## Implementation Approaches

### Approach 1: HID Layer with IOHIDManager (Recommended)

Using IOHIDManager callbacks, we can intercept events at the HID layer:

```c
// Pseudocode for HID-level interception
void hidCallback(context, result, sender, value) {
    IOHIDElementRef element = IOHIDValueGetElement(value);
    uint32_t usage = IOHIDElementGetUsage(element);
    int64_t timestamp = IOHIDValueGetTimeStamp(value); // In nanoseconds
    bool pressed = IOHIDValueGetIntegerValue(value) != 0;
    
    if (usage == kHIDUsage_KeyboardF13) { // Remapped caps lock
        if (pressed) {
            // Store timestamp and suppress event
            keyDownTime = timestamp;
            suppressEvent = true;
        } else {
            // Calculate hold duration
            int64_t duration = timestamp - keyDownTime;
            if (duration < TAP_THRESHOLD_NS) {
                // Tap: inject Escape
                injectKey(kHIDUsage_KeyboardEscape);
            } else {
                // Hold: inject Control release
                injectKey(kHIDUsage_KeyboardLeftControl, false);
            }
        }
    }
}
```

**Advantages**:
- Direct access to HID timestamps (nanosecond precision)
- Can suppress events before they reach the system
- Works with hidutil remapping

**Challenges**:
- Need to handle event injection carefully
- Must manage state for multiple keys

### Approach 2: CGEventTap with Timing State

Using CGEventTap to intercept at a higher level:

```zig
const KeyState = struct {
    key_down_time: i64 = 0,
    is_pressed: bool = false,
    has_been_used_as_modifier: bool = false,
    pending_tap: bool = false,
};

fn eventTapCallback(proxy: c.CGEventTapProxy, type: c.CGEventType, event: c.CGEventRef, refcon: ?*anyopaque) callconv(.c) c.CGEventRef {
    const keycode = c.CGEventGetIntegerValueField(event, c.kCGKeyboardEventKeycode);
    const timestamp = c.CGEventGetTimestamp(event); // In Mach absolute time
    
    // Handle F13 (remapped caps lock)
    if (keycode == kVK_F13) {
        if (type == c.kCGEventKeyDown) {
            state.key_down_time = timestamp;
            state.is_pressed = true;
            // Suppress the F13 down event
            return null;
        } else if (type == c.kCGEventKeyUp) {
            const duration_ns = machTimeToNanos(timestamp - state.key_down_time);
            
            if (duration_ns < TAP_THRESHOLD_NS and !state.has_been_used_as_modifier) {
                // Tap: send Escape
                const esc_event = c.CGEventCreateKeyboardEvent(null, kVK_Escape, true);
                c.CGEventPost(c.kCGHIDEventTap, esc_event);
                const esc_up = c.CGEventCreateKeyboardEvent(null, kVK_Escape, false);
                c.CGEventPost(c.kCGHIDEventTap, esc_up);
            }
            
            // Reset state
            state = .{};
            return null;
        }
    }
    
    return event;
}
```

### Approach 3: Hybrid Approach (Most Flexible)

Combine HID detection with CGEventTap injection:

1. Use IOHIDManager for precise timing and device identification
2. Use CGEventTap for event suppression and injection
3. Coordinate between the two using a shared state manager

## Timing Thresholds

Based on research and testing with other implementations:

- **Tap Threshold**: 200-300ms (configurable)
- **Hold Threshold**: >200ms
- **Double Tap Window**: 300ms
- **Repeat Delay**: 500ms (for held keys)

## State Management Requirements

```zig
const TimingConfig = struct {
    tap_threshold_ms: u32 = 200,
    double_tap_window_ms: u32 = 300,
    repeat_delay_ms: u32 = 500,
    repeat_interval_ms: u32 = 30,
};

const KeyTimingState = struct {
    usage_code: u32,
    device_id: u64,
    down_timestamp: i64,
    up_timestamp: i64,
    is_pressed: bool,
    has_been_modified: bool, // Used with other modifiers
    tap_count: u32,
    last_tap_time: i64,
    
    fn shouldTriggerTap(self: *KeyTimingState, current_time: i64, config: TimingConfig) bool {
        if (self.has_been_modified) return false;
        const duration_ms = (current_time - self.down_timestamp) / 1_000_000;
        return duration_ms <= config.tap_threshold_ms;
    }
    
    fn shouldTriggerHold(self: *KeyTimingState, current_time: i64, config: TimingConfig) bool {
        if (!self.is_pressed) return false;
        const duration_ms = (current_time - self.down_timestamp) / 1_000_000;
        return duration_ms > config.tap_threshold_ms;
    }
};
```

## Event Injection Methods

### 1. CGEventPost (High Level)
```zig
fn injectKeyEvent(keycode: u16, down: bool) void {
    const event = c.CGEventCreateKeyboardEvent(null, keycode, down);
    defer c.CFRelease(event);
    c.CGEventPost(c.kCGHIDEventTap, event);
}
```

### 2. IOHIDPostEvent (Low Level)
```c
// Requires IOKit private APIs
IOHIDPostEvent(kIOHIDEventTypeKeyboard, usage, value, options);
```

### 3. Synthetic HID Reports
Generate and inject HID reports directly (most complex but most control).

## Implementation Plan

### Phase 1: Basic Tap/Hold Detection
1. Create timing state manager
2. Implement basic tap/hold detection for F13
3. Test with simple Escape/Control mapping

### Phase 2: Advanced Features
1. Add double-tap detection
2. Implement modifier combination handling
3. Add configurable timing thresholds

### Phase 3: Integration
1. Integrate with skhd's hotkey system
2. Add configuration syntax
3. Implement for multiple keys

## Test Implementation Strategy

Create `src/timing_test.zig` with:
1. Standalone HID monitor
2. Timing state manager
3. Event injection testing
4. Performance measurements

## Configuration Syntax Proposal

```bash
# Basic tap/hold
f13 : escape                    # Default tap behavior
f13 [held] : ctrl              # Hold behavior
f13 [double_tap] : caps_lock   # Double tap

# With timing configuration
.timing tap_threshold 250ms
.timing double_tap_window 300ms

# Complex mappings
space [tap] : space
space [held] -> symbols         # Activate layer
space [double_tap] : _          # Underscore

# Modifier tap/hold
lshift [tap] : (
lshift [held] : lshift
rshift [tap] : )
rshift [held] : rshift
```

## Performance Considerations

1. **Latency**: Tap detection adds inherent latency (tap threshold)
2. **CPU Usage**: Minimal with efficient state management
3. **Memory**: O(n) where n = number of timing-enabled keys

## Security Considerations

1. Event injection requires Accessibility permissions
2. HID access requires Input Monitoring permissions
3. Timing attacks: Ensure consistent timing regardless of action

## References

1. [QMK Tap-Hold Implementation](https://github.com/qmk/qmk_firmware/blob/master/docs/tap_hold.md)
2. [Karabiner-Elements Complex Modifications](https://karabiner-elements.pqrs.org/docs/)
3. [macOS HID Event Timing](https://developer.apple.com/documentation/iokit/iohidvalue)
4. [Mach Absolute Time](https://developer.apple.com/library/archive/technotes/tn2169/_index.html)