# Advanced Features Implementation Plan for skhd.zig

## Executive Summary

This document outlines the advanced features for skhd.zig, building on top of the core hotkey functionality:

1. **Device-specific hotkey filtering** ✅ (Parser completed, runtime integration pending)
2. **Mouse key detection** 🔄 (Planned)
3. **Timing-based features (LT, OSL)** 🔄 (Planned - inspired by QMK)
4. **Caps Lock special handling** 🔄 (Research completed)

## Feature 1: Device-Specific Hotkey Filtering ✅

### Status: Parser Complete, Runtime Integration Pending

Device filtering allows different behavior based on which keyboard/mouse is used (e.g., built-in keyboard vs external HHKB).

### Finalized Syntax

```bash
# Device constraint using device name (space syntax, no colon)
cmd - a <device "HHKB-Hybrid"> : echo "HHKB keyboard"
cmd - a <device "Keychron*"> : echo "any Keychron keyboard"

# Device aliases using .device directive
.device hhkb "HHKB-Hybrid"
.device external ["Keychron K2", "HHKB-Hybrid", "Convolution Rev. 1"]

# Using device aliases
cmd - a <@hhkb> : echo "HHKB keyboard"
cmd - b <@external> : echo "any external keyboard"

# Combined with process constraints
cmd - c <device "External Keyboard"> [
    "Terminal" : echo "external in terminal"
    *          : echo "external elsewhere"
]
```

### Implementation Status

#### ✅ Completed:
- Device detection infrastructure (DeviceManager.zig)
- Parser support for device constraints
- Device alias support with `.device` directive
- Tokenizer support for `<` and `>` brackets
- HID observe mode (`-O` flag) showing exact device per keypress

#### 🔄 Pending:
- Integration with main event loop in skhd.zig
- Device matching logic in processHotkey
- Vendor/product ID syntax support

### Technical Details

- Uses IOHIDManager for device enumeration
- CGEvent field 87 contains device registry ID (with ~22 offset)
- Device matching uses proximity matching (±100 range)

## Feature 2: Mouse Key Detection 🔄

### Planned Implementation

Enable hotkeys to work with mouse buttons:

```bash
# Mouse button hotkeys
mouse1 : echo "left click"
mouse2 : echo "right click"
cmd - mouse1 : echo "cmd + left click"

# Mouse with device constraints
mouse1 <device "MX Master 3"> : echo "MX Master left click"
```

### Technical Approach
- Extend CGEventTap mask to include mouse events
- Add mouse button tokens to Tokenizer
- Map mouse events to hotkey system

## Feature 3: Timing-Based Features (QMK-inspired) 🔄

### Status: Syntax Design Complete, Implementation Pending

We've designed a clear, explicit syntax for tap/hold functionality that avoids operator overloading and uses function-like syntax for clarity.

### Overview

The tap/hold system enables keys to have dual functionality:
- **Tap**: Quick press and release triggers one action
- **Hold**: Pressing and holding triggers a different action

This is particularly useful for:
- Making Control act as Escape when tapped
- Creating "Layer Tap" keys (e.g., Space as both space and layer modifier)
- Optimizing keyboard layouts for ergonomics

### Finalized Syntax

#### Basic Syntax
```skhd
tap(key) | action
hold(key) | action
```

#### Global Timing Configuration
```skhd
# Set global timing defaults
.timing tap_min=50ms tap_max=200ms
```

- `tap_min`: Minimum duration to register as a tap (helps avoid accidental triggers)
- `tap_max`: Maximum duration to still count as a tap (beyond this, it's a hold)

#### Examples

**Control as Escape/Control:**
```skhd
# Control acts as Escape when tapped, Control when held
tap(lctrl) | escape
hold(lctrl) | lctrl
```

**Space as Layer Tap:**
```skhd
# Space key types space when tapped, activates navigation layer when held
tap(space) | space
hold(space) | layer(nav)

.layer nav {
    h | left
    j | down
    k | up
    l | right
    y | home
    u | pagedown
    i | pageup
    o | end
}
```

**Custom Timing:**
```skhd
# Quick tap detection for Control
tap(lctrl, tap_min=50ms, tap_max=150ms) | escape

# No maximum tap duration for Space
tap(space, tap_max=∞) | space

# Custom hold threshold
hold(space, hold_min=200ms) | layer(nav)
```

**With Modifiers:**
```skhd
# Cmd+Space: Return when tapped, symbols layer when held
cmd + tap(space) | return
cmd + hold(space) | layer(symbols)
```

**Device-Specific Bindings:**
```skhd
.device 0x04fe:0x0021 {
    tap(lctrl, tap_max=150ms) | escape
    hold(lctrl) | lctrl
    
    tap(space) | space
    hold(space) | layer(nav)
}
```

### Timing Parameters

#### For `tap()`:
- `tap_min`: Minimum milliseconds for a valid tap (default: from `.timing`)
- `tap_max`: Maximum milliseconds to register as tap (default: from `.timing`)
  - Use `∞` or `inf` for no maximum

#### For `hold()`:
- `hold_min`: Minimum milliseconds before triggering hold action (default: `tap_max + 1ms`)

### Key Design Decisions

1. **Explicit Functions**: `tap()` and `hold()` are clear function calls
2. **Named Parameters**: Optional timing parameters are self-documenting
3. **Consistent Syntax**: Uses `|` for all mappings (like existing key remapping)
4. **Composable**: Works naturally with modifiers and device constraints

### Implementation Notes

1. **Mutual Exclusivity**: When both `tap()` and `hold()` are defined for the same key, only one action fires per key press
2. **Timing Precision**: Times are in milliseconds (ms)
3. **Layer Activation**: `layer()` creates a temporary layer active only while the key is held
4. **Key Repeat**: Hold actions do not auto-repeat by default

### Future Considerations

Potential extensions to the syntax:
- `double_tap(key, interval=300ms) | action` for double-tap detection
- `tap_hold(key) | tap_action | hold_action` as a single-line alternative
- Repeat configuration for held keys

### Working Prototype
We have a **fully functional** timing-based key remapping prototype in `src/timing_test.zig` that demonstrates:
- **Tap Caps Lock** (< 200ms) = Escape
- **Hold Caps Lock** (> 200ms) = Control modifier
- **Double tap Caps Lock** = Original Caps Lock
- **Caps Lock + other key** = Control + that key

### Technical Implementation

#### System Architecture
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

#### Key Components

**KeyRemapper.zig** - Programmatic remapping via hidutil:
```zig
const key_remapper = try KeyRemapper.create(allocator);
defer key_remapper.destroy();

// Automatic setup
if (!try key_remapper.isCapsLockRemapped()) {
    try key_remapper.setKeyMapping(KeyRemapper.KeyMapping.CAPS_TO_F13);
}
```

**Timer-Based Hold Detection**:
```zig
// CFRunLoopTimer fires after 200ms to inject Control
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

### Running the Test
```bash
# Automatic setup and test
zig build timing
```

### Timing Configuration
- **Tap threshold**: 200ms
- **Hold threshold**: > 200ms
- **Double-tap window**: 300ms

### Benefits
- **Bypasses macOS Caps Lock delay** completely
- **Works at system level** - affects all applications
- **No LED issues** - F13 has no LED to toggle
- **Zero latency on hold** - Control injected exactly at 200ms

### Production Integration Path

1. **Create `timing_manager.zig` module**
   - Extract timing logic from test implementation
   - Make it configurable per key
   - Support multiple timing-enabled keys

2. **Extend Parser.zig**
   ```skhd
   # New finalized syntax
   tap(caps_lock) | escape
   hold(caps_lock) | lctrl
   double_tap(caps_lock) | caps_lock
   
   # Custom timing thresholds
   .timing tap_min=50ms tap_max=250ms
   .timing double_tap_window=300ms
   ```

3. **Integration with Hotkey.zig**
   - Add timing configuration to Hotkey struct
   - Support timing modifiers in hotkey matching

### Layer Tap (LT) - Planned Extension

Extend the timing system for layer activation:

```skhd
# Space: Tap = Space, Hold = Nav layer
tap(space) | space
hold(space) | layer(nav)

# Esc: Tap = Esc, Hold = symbols layer
tap(escape) | escape
hold(escape) | layer(symbols)
```

### One Shot Layer (OSL) - Future Work

Tap to activate layer for next keypress only:

```skhd
# Tap F key to activate symbol layer for one key
tap(f) | oneshot(symbols)

# Define symbols layer
.layer symbols {
    a | exclamation
    s | at
    d | hash
}
```

## Feature 4: Caps Lock Special Handling ✅

### Status: Implemented as Part of Timing System

Caps Lock remapping is fully implemented in our timing system, providing tap/hold functionality.

### Implementation Details

1. **macOS Caps Lock Challenge**:
   - Has built-in ~300ms delay to prevent accidental activation
   - Sends special HID usage codes (0x38 and 0x39)
   - The delay is handled at the HID driver level

2. **Solution: Automatic Remapping**
   
   `KeyRemapper.zig` programmatically remaps Caps Lock → F13:
   
   ```zig
   pub const KeyMapping = struct {
       from: u64, // HID usage (0x700000000 | usage)
       to: u64,   // HID usage (0x700000000 | usage)
       
       pub const CAPS_TO_F13 = KeyMapping{
           .from = 0x700000039, // Caps Lock
           .to = 0x700000068,   // F13
       };
   };
   ```
   
   Manual setup (if needed):
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

3. **Benefits Achieved**:
   - ✅ Bypasses macOS Caps Lock delay entirely
   - ✅ Works at HID driver level (affects all apps)
   - ✅ No Caps Lock LED toggle issues
   - ✅ CGEventTap sees F13 events
   - ✅ Full tap/hold functionality

4. **Working Implementation**:
   ```bash
   # Current behavior in timing_test.zig
   # Tap Caps Lock = Escape
   # Hold Caps Lock = Control
   # Double tap = Original Caps Lock
   ```

5. **Device-Specific Remapping** (Future Enhancement):
   ```bash
   # Only remap on specific keyboard
   hidutil property --matching '{"ProductID":0x0021}' --set '{"UserKeyMapping":[{
       "HIDKeyboardModifierMappingSrc":0x700000039,
       "HIDKeyboardModifierMappingDst":0x700000068
   }]}'
   ```

## Architecture Notes

### Event Processing Flow

```
CGEventTap + IOHIDManager
    ↓
Device Identification (field 87 with caching)
    ↓
keyHandler with device info
    ↓
processHotkey (device + process matching)
    ↓
Timing logic (CFRunLoopTimer)
    ↓
Execute command/forward key
```

### DeviceManager Optimizations

#### Field 87 Caching
- CGEvent field 87 contains device registry ID with ~22 offset
- First lookup: O(n) proximity search
- Subsequent lookups: O(1) via HashMap cache
- Automatic offset discovery and recording

```zig
// Optimized lookup
if (self.devices_by_field87.get(field87_value)) |device| {
    return device;  // O(1) lookup
}
// ... learn and cache on first encounter
```

### Timing Implementation Architecture

```
HID Events (IOHIDManager)
    ↓
Precise timestamps (nanosecond)
    ↓
CGEventTap (suppression + injection)
    ↓
CFRunLoopTimer (200ms hold detection)
    ↓
State machine (tap/hold/double-tap)
```

### State Management

**KeyTimingState** - Tracks individual key timing:
```zig
const KeyTimingState = struct {
    is_pressed: bool = false,
    control_injected: bool = false,
    has_been_modified: bool = false,
    timer: ?*c.struct___CFRunLoopTimer = null,
    down_timestamp: i64 = 0,
    tap_count: u32 = 0,
    // ...
};
```

**Key Features**:
- Timer-based hold detection (fires at 200ms)
- Key repeat prevention
- Modifier tracking
- Double-tap detection

## Implementation Roadmap

### Phase 1: Device Filtering ✅ (90% done)
- [x] Parser and data structures
- [x] Device detection with DeviceManager
- [x] Optimize field 87 lookup with caching
- [x] HID observe mode (`-O` flag)
- [ ] Runtime integration in skhd.zig
- [ ] Vendor/product ID support

### Phase 2: Timing Features ✅ (Complete)
- [x] Key state tracking
- [x] Timer-based hold detection (CFRunLoopTimer)
- [x] Tap/hold/double-tap detection
- [x] Programmatic key remapping (KeyRemapper)
- [x] Key repeat prevention
- [x] Automatic cleanup on exit
- [ ] Extract to timing_manager.zig module
- [ ] Parser syntax integration

### Phase 3: Caps Lock Special ✅ (Complete)
- [x] Research macOS behavior
- [x] Implement hidutil remapping
- [x] Full tap/hold functionality
- [x] Bypass macOS delay

### Phase 4: Mouse Support 🔄 (Planned)
- [ ] Extend event tap for mouse events
- [ ] Add mouse button parsing
- [ ] Test with various mice

### Phase 5: Advanced Layers 🔄 (Future)
- [ ] Layer tap (LT) for mode switching
- [ ] One shot layer (OSL)
- [ ] Layer state management

## Testing Strategy

### Completed Testing

1. **Device Filtering**: 
   - ✅ Multiple keyboards detected and identified
   - ✅ CGEvent field 87 mapping verified
   - ✅ HID observe mode shows per-device keypresses

2. **Timing Features**:
   - ✅ Tap/hold detection working at 200ms threshold
   - ✅ Double-tap detection within 300ms window
   - ✅ Key repeat prevention implemented
   - ✅ Timer-based Control injection verified

3. **Caps Lock Remapping**:
   - ✅ Automatic remapping via KeyRemapper
   - ✅ Bypass of macOS delay confirmed
   - ✅ Signal handler cleanup tested

### Pending Testing

1. **Integration Testing**:
   - [ ] Full config file with device constraints
   - [ ] Performance with multiple timing keys
   - [ ] Layer management state machine

2. **Edge Cases**:
   - [ ] Rapid key switching
   - [ ] Multiple devices simultaneously
   - [ ] System sleep/wake behavior

## Resolved Design Decisions

1. **Timing Precision**: 
   - ✅ 200ms tap/hold threshold (configurable)
   - ✅ 300ms double-tap window
   - ✅ Timer-based hold detection for zero latency

2. **Device Syntax**:
   - ✅ Space syntax: `<device "name">` not `<device:"name">`
   - ✅ Device aliases: `.device name "pattern"`

3. **Caps Lock Solution**:
   - ✅ Remap to F13 via hidutil
   - ✅ Full tap/hold functionality achieved
   - ✅ Automatic setup in KeyRemapper.zig

## Remaining Questions

1. **Layer Syntax**: Extend mode system or new syntax?
   - ✅ Decision: Use function syntax `tap()`, `hold()`, `layer()` for clarity

2. **Mouse Integration**: Full gesture support or just buttons?
   - Proposal: Start with buttons, consider gestures later

3. **Performance**: How many timing-enabled keys is reasonable?
   - Current: One key tested, need to benchmark multiple

## References

- [QMK Layers Documentation](https://docs.qmk.fm/feature_layers)
- [Karabiner-Elements Source](https://github.com/pqrs-org/Karabiner-Elements)
- [IOKit HID Documentation](https://developer.apple.com/documentation/iokit)
- [CGEventTap Reference](https://developer.apple.com/documentation/coregraphics/cgeventref)