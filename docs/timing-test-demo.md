# Timing Test Demo - Caps Lock as Escape/Control

## What the Test Does

The timing test (`zig build timing`) implements a complete tap/hold detection system:

1. **Tap Caps Lock (< 200ms)** → Sends Escape
2. **Hold Caps Lock (> 200ms)** → Acts as Control modifier
3. **Double tap Caps Lock** → Sends original Caps Lock
4. **Caps Lock + another key** → Control + that key

## Key Implementation Features

### Timer-Based Hold Detection

When Caps Lock (remapped to F13) is pressed:
```
[Convolution Rev. 1] F13 DOWN - starting timing
```

After 200ms, if still held:
```
  → Hold threshold reached! Injecting Control DOWN
```

When released:
```
[Convolution Rev. 1] F13 UP - duration: 350ms
  → Releasing Control
```

### Tap Detection

Quick press and release:
```
[Convolution Rev. 1] F13 DOWN - starting timing
[Convolution Rev. 1] F13 UP - duration: 120ms
  → Tap detected! Sending Escape
```

### Modifier Combination

Pressing Caps Lock + A:
```
[Convolution Rev. 1] F13 DOWN - starting timing
Key down: 0 (will check for modified state)
  → F13 used with another key, injecting Control
```

## How It Works

1. **Automatic Remapping**: Uses `KeyRemapper.zig` to programmatically set Caps Lock → F13
2. **Dual Layer Approach**:
   - HID layer for precise timestamps
   - CGEventTap for event suppression and injection
3. **CFRunLoopTimer**: Triggers Control injection after 200ms hold
4. **State Management**: Tracks press/release times and modifier state

## Running the Test

```bash
# Just run - handles everything automatically
zig build timing

# Output:
Timing-based remapping test
===========================

Setting up Caps Lock → F13 remapping...
✓ Caps Lock has been remapped to F13

Test scenarios:
1. Quick tap Caps Lock (< 200ms) → Escape
2. Hold Caps Lock (> 200ms) → Acts as Control
3. Double tap Caps Lock → Original Caps Lock
4. Caps Lock + other key (before 200ms) → Control + key
```

## Technical Details

### Key Components

1. **holdTimerCallback**: Fires after 200ms to inject Control
2. **handleTimingKey**: Main state machine for tap/hold/double-tap
3. **eventTapCallback**: Suppresses F13 and adds Control flag to events

### State Tracking

```zig
const KeyTimingState = struct {
    is_pressed: bool = false,
    control_injected: bool = false,
    has_been_modified: bool = false,
    timer: ?*c.struct___CFRunLoopTimer = null,
    // ...
};
```

## Production Integration

This test implementation provides the foundation for integrating timing-based remapping into skhd:

1. **Configuration Syntax**:
   ```
   caps_lock : escape
   caps_lock [held] : ctrl
   caps_lock [double_tap] : caps_lock
   ```

2. **Module Structure**:
   - `timing_manager.zig` - Core timing logic
   - Integration with `Hotkey.zig`
   - Parser support in `Parser.zig`

## Benefits

- **No macOS Caps Lock Delay**: Bypassed completely via F13 remapping
- **Precise Timing**: HID timestamps for accuracy
- **Flexible**: Can be applied to any key
- **Zero Latency on Hold**: Control is injected exactly at 200ms

## Cleanup

To restore normal Caps Lock:
```bash
hidutil property --set '{"UserKeyMapping":[]}'
```