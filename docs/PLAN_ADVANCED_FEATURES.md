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

### Layer Tap (LT)

Tap for one key, hold for layer activation:

```bash
# Caps Lock: Tap = Escape, Hold = Control
caps_lock : escape
caps_lock [held] : ctrl

# Space: Tap = Space, Hold = Fn layer
space : space
space [held] -> fn_layer
```

### One Shot Layer (OSL)

Tap to activate layer for next keypress only:

```bash
# Tap F key to activate symbol layer for one key
f [tap] -> symbols [oneshot]

# In symbols mode
:: symbols
a : echo "!"
s : echo "@"
d : echo "#"
```

### Technical Requirements
- Key press/release timing tracking
- State machine for layer management
- Timeout configuration support
- Integration with existing mode system

## Feature 4: Caps Lock Special Handling 🔄

### Research Findings

Based on research at https://claude.ai/public/artifacts/91107587-c58a-46df-8d38-861b5ee9908b:

1. **macOS Caps Lock Behavior**:
   - Has built-in delay (~300ms) to prevent accidental activation
   - Sends special HID usage codes (0x38 and 0x39)
   - Can be remapped at IOKit level using hidutil
   - The delay is handled at the HID driver level

2. **Implementation Strategy: Remap to Unused Key**
   
   Use `hidutil` to remap Caps Lock to an unused key (e.g., F13-F24), then handle that key in skhd:
   
   ```bash
   # Remap Caps Lock (0x39) to F13 (0x68) at system level
   hidutil property --set '{"UserKeyMapping":[{
       "HIDKeyboardModifierMappingSrc":0x700000039,
       "HIDKeyboardModifierMappingDst":0x700000068
   }]}'
   ```
   
   Valid destination keys for remapping:
   - **F13-F24** (0x68-0x73): Ideal - recognized by macOS but unused
   - **International keys** (0x64, 0x65, 0x87-0x8B): Keys not on US keyboards
   - **Media keys**: Different HID usage page (0xFF01000000XX)

3. **Benefits of This Approach**:
   - Bypasses macOS Caps Lock delay entirely
   - Works at HID driver level (affects all apps)
   - No Caps Lock LED toggle
   - CGEventTap sees the remapped key (e.g., F13)
   - Enables tap/hold functionality

4. **Proposed Implementation**:
   
   ```bash
   # In skhd config after remapping Caps Lock to F13
   # Tap F13 = Escape, Hold F13 = Control
   f13 : escape
   f13 [held] : ctrl
   
   # Or use F13 as a hyper key
   f13 - a : open -a "Terminal"
   f13 - s : open -a "Safari"
   ```

5. **Device-Specific Remapping**:
   
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
Device Identification (field 87)
    ↓
keyHandler with device info
    ↓
processHotkey (device + process matching)
    ↓
Timing logic (for LT/OSL)
    ↓
Execute command/forward key
```

### Caps Lock Implementation Flow

```
System Level (hidutil):
  Caps Lock (0x39) → F13 (0x68)
        ↓
skhd Level:
  F13 events → Timing detection
        ↓
  Tap (<200ms) → Send Escape
  Hold (>200ms) → Act as Control
```

### State Management

For timing-based features, we need:
- KeyStateManager to track press/release times
- Timer system for timeouts
- State machine for layer management

## Implementation Roadmap

### Phase 1: Complete Device Filtering ✅ (90% done)
- [x] Parser and data structures
- [x] Device detection
- [ ] Runtime integration
- [ ] Vendor/product ID support

### Phase 2: Mouse Support 🔄
- [ ] Extend event tap for mouse events
- [ ] Add mouse button parsing
- [ ] Test with various mice

### Phase 3: Basic Timing Features 🔄
- [ ] Key state tracking
- [ ] Simple tap/hold detection
- [ ] Basic LT implementation

### Phase 4: Advanced Layers 🔄
- [ ] OSL implementation
- [ ] Layer state management
- [ ] Timeout configuration

### Phase 5: Caps Lock Special 🔄
- [ ] Investigate IOKit remapping
- [ ] Implement chosen approach
- [ ] Handle edge cases

## Testing Strategy

1. **Device Filtering**: Test with multiple keyboards/mice
2. **Timing Features**: Automated tests with simulated delays
3. **Layer Management**: State machine testing
4. **Integration**: Full config file testing

## Open Questions

1. **Timing Precision**: What's acceptable latency for tap/hold detection?
   - Proposal: 200ms default, configurable

2. **Layer Syntax**: Stay close to skhd modes or adopt QMK-style?
   - Proposal: Extend mode system with timing modifiers

3. **Mouse Integration**: Full mouse gesture support or just buttons?
   - Proposal: Start with buttons, consider gestures later

4. **Caps Lock**: Deep remap or work with macOS behavior?
   - Proposal: Start with macOS-compatible approach

## References

- [QMK Layers Documentation](https://docs.qmk.fm/feature_layers)
- [Karabiner-Elements Source](https://github.com/pqrs-org/Karabiner-Elements)
- [IOKit HID Documentation](https://developer.apple.com/documentation/iokit)
- [CGEventTap Reference](https://developer.apple.com/documentation/coregraphics/cgeventref)