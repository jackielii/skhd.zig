# Timing-Based Key Remapping Implementation Summary

## Overview

We've successfully implemented a **fully functional** timing-based key remapping system in skhd.zig. The implementation enables advanced key behaviors:
- **Tap Caps Lock** (< 200ms) = Escape
- **Hold Caps Lock** (> 200ms) = Control modifier
- **Double tap Caps Lock** = Original Caps Lock
- **Caps Lock + other key** = Control + that key

## Key Findings

### 1. macOS Caps Lock Challenge
- macOS has a built-in ~300ms delay on Caps Lock to prevent accidental activation
- This delay is implemented at the HID driver level
- Solution: Use `hidutil` to remap Caps Lock to an unused key (F13)

### 2. Implementation Architecture

```
System Level (hidutil):
  Caps Lock (0x39) → F13 (0x68)
        ↓
HID Layer (IOHIDManager):
  Precise timestamps (nanosecond)
  Device identification
        ↓
CGEventTap:
  Event suppression
  Event injection
        ↓
Timing Logic:
  Tap/Hold/Double-tap detection
```

### 3. Complete Working Implementation

Created `src/timing_test.zig` with full functionality:
- **CGEventTap-based timing**: Handles all timing logic in the event tap
- **Key repeat handling**: Ignores repeat DOWN events while holding
- **Timer-based hold detection**: CFRunLoopTimer triggers Control after 200ms
- **Proper state management**: Tracks press/release and Control injection
- **Automatic cleanup**: Signal handler restores Caps Lock on exit
- **Event suppression**: F13 events never reach other applications

## Setup Instructions

### Automatic Setup (Programmatic)

The timing test now **automatically** sets up the Caps Lock → F13 remapping:

```bash
# Just run the test - it handles everything!
zig build timing
```

The test will:
1. Check if Caps Lock is already remapped
2. If not, automatically remap Caps Lock to F13
3. Run the timing tests
4. Display instructions for clearing the mapping when done

### Manual Setup (Optional)

If you prefer to manage mappings manually:

```bash
# Enable remapping
hidutil property --set '{"UserKeyMapping":[{
    "HIDKeyboardModifierMappingSrc":0x700000039,
    "HIDKeyboardModifierMappingDst":0x700000068
}]}'

# Check current mapping
hidutil property --get UserKeyMapping

# Remove mapping (to restore default)
hidutil property --set '{"UserKeyMapping":[]}'
```

## Key Technical Details

### HID Usage Codes
- Caps Lock: 0x39 (full: 0x700000039)
- F13: 0x68 (full: 0x700000068)
- Escape: 0x29 (CGKeyCode: 53)
- Control: 0xE0 (modifier flag)

### Timing Thresholds
- Tap: < 200ms
- Hold: > 200ms
- Double-tap window: 300ms

### Programmatic Key Remapping

We implemented `KeyRemapper.zig` that uses `hidutil` subprocess calls:

```zig
// Automatic remapping
const key_remapper = try KeyRemapper.create(allocator);
defer key_remapper.destroy();

// Check and set mapping
if (!try key_remapper.isCapsLockRemapped()) {
    try key_remapper.setKeyMapping(KeyRemapper.KeyMapping.CAPS_TO_F13);
}

// Clear when done (optional)
try key_remapper.clearKeyMappings();
```

### Key Implementation Details

#### Event Injection
```zig
fn injectKeyEvent(keycode: u16, down: bool) void {
    const event = c.CGEventCreateKeyboardEvent(null, keycode, down);
    defer c.CFRelease(event);
    c.CGEventPost(c.kCGHIDEventTap, event);
}
```

#### Key Repeat Prevention
```zig
if (pressed) {
    // Ignore key repeat - only process the first DOWN
    if (state.is_pressed) {
        return;
    }
    // ... rest of key down handling
}
```

#### Timer-Based Hold Detection
```zig
// Timer fires after 200ms to inject Control
fn holdTimerCallback(timer: c.CFRunLoopTimerRef, info: ?*anyopaque) callconv(.c) void {
    const state = @as(*KeyTimingState, @ptrCast(@alignCast(info)));
    
    if (state.is_pressed and !state.has_been_modified and !state.control_injected) {
        // Inject Control down
        const ctrl_down = c.CGEventCreateKeyboardEvent(null, 0x3B, true);
        defer c.CFRelease(ctrl_down);
        c.CGEventSetFlags(ctrl_down, c.kCGEventFlagMaskControl);
        c.CGEventPost(c.kCGHIDEventTap, ctrl_down);
        
        state.control_injected = true;
    }
}
```

## Production Integration Path

### Current Implementation Status
✅ **Complete working prototype** with:
- Automatic key remapping setup
- Full tap/hold/double-tap detection
- Timer-based Control injection at 200ms
- Proper key repeat handling
- Clean state management
- Automatic cleanup on exit

### Next Steps for Production

1. **Create `timing_manager.zig` module**
   - Extract timing logic from test implementation
   - Make it configurable per key
   - Support multiple timing-enabled keys

2. **Extend Parser.zig**
   ```bash
   # Proposed syntax
   caps_lock : escape                # Default tap behavior
   caps_lock [held] : ctrl          # Hold behavior
   caps_lock [double_tap] : caps_lock # Double tap
   
   # Custom timing thresholds
   .timing tap_threshold 250ms
   .timing double_tap_window 300ms
   ```

3. **Integration with Hotkey.zig**
   - Add timing configuration to Hotkey struct
   - Support timing modifiers in hotkey matching

4. **Remove debug logging**
   - Clean up DeviceManager debug output
   - Make logging configurable

## Next Steps

1. **Implement production-ready timer system**
   - Use dispatch_source for timers
   - Handle edge cases properly

2. **Integrate with skhd main loop**
   - Add timing manager to event processing
   - Extend hotkey matching logic

3. **Add configuration support**
   - Parse timing syntax
   - Store timing options in Hotkey struct

4. **Testing**
   - Unit tests for timing logic
   - Integration tests with real events
   - Performance testing

## Benefits of This Approach

1. **Bypasses macOS Caps Lock delay** completely
2. **Works at system level** - affects all applications
3. **No LED issues** - F13 has no LED to toggle
4. **Flexible** - can be applied to any key
5. **Compatible** - works alongside existing skhd features

## Limitations

1. **Requires hidutil setup** - not automatic
2. **Tap latency** - inherent delay for tap detection
3. **Complexity** - more state management needed

## References

- [hidutil man page](https://ss64.com/osx/hidutil.html)
- [IOHIDValue Documentation](https://developer.apple.com/documentation/iokit/iohidvalue)
- [CGEventTap Documentation](https://developer.apple.com/documentation/coregraphics/cgeventref)