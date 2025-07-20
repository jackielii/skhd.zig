# Device-Specific Hotkeys Design Document

## Overview

This document outlines the design and implementation plan for adding device-specific hotkey rules to skhd.zig, allowing users to create keyboard shortcuts that only trigger when using specific input devices.

## Research Findings

### macOS API Options

#### 1. CGEvent-based Device Detection

CGEvent provides limited device information through:

```c
// Get keyboard type from event
int64_t keyboardType = CGEventGetIntegerValueField(event, kCGKeyboardEventKeyboardType);

// Alternative: Get keyboard type from event source
CGEventSourceRef evSrc = CGEventCreateSourceFromEvent(event);
if(evSrc) {
    unsigned kbt = (NSUInteger) CGEventSourceGetKeyboardType(evSrc);
    CFRelease(evSrc);
}
```

**Limitations:**
- Only provides keyboard "type" not unique device identifiers
- Values are often undocumented
- Cannot distinguish between multiple keyboards of the same model

#### 2. IOKit HID Manager Approach (Recommended)

IOKit's HID Manager provides full device information:

```c
// Register callback for each device
IOHIDDeviceRegisterInputValueCallback(device, myHIDKeyboardCallback, context);

// In callback, identify device
void myHIDKeyboardCallback(void* context, IOReturn result, void* sender, IOHIDValueRef value) {
    IOHIDDeviceRef device = sender;  // This uniquely identifies the device
    
    // Get device properties
    CFNumberRef vendor = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDVendorIDKey));
    CFNumberRef product = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductIDKey));
    CFStringRef name = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
}
```

**Advantages:**
- Provides unique device identification per session
- Access to vendor ID, product ID, device name
- Can distinguish between multiple identical keyboards
- Works with all HID devices (keyboards, mice, etc.)

### Implementation Architecture

#### Current Event Flow
```
CGEventTap (EventTap.zig)
    ↓
keyHandler (skhd.zig)
    ↓
processHotkey (checks process name)
    ↓
Execute command/forward key
```

#### Proposed Event Flow with Device Support
```
CGEventTap + IOHIDManager (EventTap.zig)
    ↓
keyHandler with device info (skhd.zig)
    ↓
processHotkey (checks process name AND device)
    ↓
Execute command/forward key
```

## Proposed Configuration Syntax

### Device Constraint Syntax
Using angle brackets `<>` to distinguish from process constraints `[]`:

```bash
# Device constraint using device name
cmd - a <device "HHKB-Hybrid"> : echo "HHKB keyboard"
cmd - a <device "Keychron*"> : echo "any Keychron keyboard"

# Device constraint using vendor/product ID (planned)
cmd - a <vendor 0x04fe product 0x0021> : echo "HHKB by ID"
cmd - a <vendor 0x046d> : echo "any Logitech device"

# Combined with process constraints
cmd - a <device "External Keyboard"> [
    "Terminal" : echo "external keyboard in terminal"
    *          : echo "external keyboard elsewhere"
]

# Device aliases using .device directive
.device hhkb = "HHKB-Hybrid"
.device external = ["Keychron K2", "HHKB-Hybrid", "MX Master 2S"]
.device logitech = <vendor:0x046d>

# Using device aliases
cmd - a <@hhkb> : echo "HHKB keyboard"
cmd - a <@external> : echo "any external keyboard"
cmd - a <@logitech> : echo "Logitech device"
```

### Grammar Extension

The grammar for hotkey definitions extends to:
```
hotkey := <modifier>* '-' <key> <device_constraint>? <process_constraint>? ':' <command>
        | <modifier>* '-' <key> <device_constraint>? <process_constraint>? '->' ':' <command>
        | <modifier>* '-' <key> <device_constraint>? <process_constraint>? '~'
        | <modifier>* '-' <key> <device_constraint>? <process_constraint>? '|' <forward_key>

device_constraint := '<' device_spec '>'
device_spec := 'device' <string>
             | 'vendor' <hex> ('product' <hex>)?
             | '@' <identifier>

process_constraint := '[' (<process_list> | <process_wildcard>) ']'

.device directive := '.device' <identifier> '=' (<string> | <device_constraint> | '[' <device_list> ']')
```

## Current Status

### Completed
- ✅ Device detection infrastructure (DeviceManager.zig)
- ✅ HID device enumeration and tracking
- ✅ Device type identification (keyboard/mouse)
- ✅ Two observe modes:
  - `-o`: CGEventTap mode showing all keyboards
  - `-O`: HID mode showing exactly which device sent each key
- ✅ Precise per-device keypress tracking

### Demo
```bash
# Regular observe mode - shows all keyboards but can't identify source
skhd -o
[KbType: 40] [Convolution Rev. 1 | MX Master 2S | HHKB-Hybrid]     a    keycode: 0x+0

# HID observe mode - shows exactly which device sent each key
skhd -O  
[HHKB-Hybrid (0x04fe:0x0021)]     a    HID usage: 0x04
[Convolution Rev. 1 (0xcb10:0x145f)]     a    HID usage: 0x04
```

## Implementation Plan

### Phase 1: Device Detection Infrastructure ✅

1. **DeviceManager.zig** - COMPLETED
   - IOHIDManager for device enumeration
   - Track devices by registry ID
   - Store vendor ID, product ID, device name
   - Support device connection/disconnection events
   - Match CGEvent to IOHIDDevice using field 87 with proximity matching

### Phase 2: Parser Support (NEXT)

1. **Update Tokenizer.zig**
   - Add `TokenType.angle_open` for `<`
   - Add `TokenType.angle_close` for `>`
   - Handle device constraint syntax within angle brackets

2. **Update Parser.zig**
   - Add `.device` directive support
   - Parse device constraints in hotkey definitions
   - Support device aliases similar to process groups
   - Store device constraints in hotkey structures

### Phase 3: Data Structure Updates

1. **Update Hotkey.zig**
   - Add device constraint field
   - Support device name patterns with wildcards
   - Support vendor/product ID matching

2. **Update Mappings.zig**
   - Add device_aliases storage
   - Handle device alias resolution

### Phase 4: Runtime Integration

1. **Update skhd.zig**
   - Integrate DeviceManager into main event loop
   - Pass device info to processHotkey
   - Match hotkeys based on device constraints
   - Handle device hot-plug events

### Phase 5: Testing & Cleanup

1. **Clean up DeviceManager**
   - Remove excessive debug logging
   - Optimize device lookup performance

2. **Add comprehensive tests**
   - Device matching logic
   - Parser support for device syntax
   - Integration tests with device constraints

## Technical Considerations

### Device Identification Strategy

1. **Session-based ID**: Use IOHIDDeviceRef pointer as primary identifier
2. **Persistent properties**: Store vendor ID, product ID, name for matching
3. **Wildcard support**: Allow patterns like "Keychron*" for device names
4. **Fallback behavior**: Process constraints work without device constraints

### Performance Impact

- IOHIDManager adds minimal overhead
- Device lookup can be cached per event
- No allocations in hot path (event processing)

### Security & Permissions

- May require Input Monitoring permission on macOS 10.15+
- Same permissions as current CGEventTap usage
- No additional entitlements needed

## Example Use Cases

### 1. Different Layouts for Different Keyboards
```bash
# Vim navigation on external keyboard only
cmd - h <device:"HHKB*"> : yabai -m window --focus west
cmd - j <device:"HHKB*"> : yabai -m window --focus south
cmd - k <device:"HHKB*"> : yabai -m window --focus north
cmd - l <device:"HHKB*"> : yabai -m window --focus east

# Or using device alias
.device external = ["HHKB-Hybrid", "Keychron K2"]
cmd - h <@external> : yabai -m window --focus west
```

### 2. Device-Specific Modifiers
```bash
# Use caps lock as hyper on specific keyboard
caps <device:"HHKB*"> : echo "hyper pressed"

# Different behavior per device
caps <vendor:0x04fe,product:0x0021> : echo "HHKB caps"
caps <device:"Convolution*"> : echo "Convolution caps"
```

### 3. Testing with Multiple Keyboards
```bash
# Different actions for testing
f1 <device:"HHKB-Hybrid"> : echo "Test from HHKB"
f1 <device:"Convolution Rev. 1"> : echo "Test from Convolution"
f1 <device:"MX Master 2S"> : echo "Test from MX Master"
```

## Open Questions

1. Should device constraints be inheritable in modes?
2. How to handle device disconnection/reconnection?
3. Should we support other HID devices (mice, trackpads)?
4. What's the precedence order: device > process > mode?

## References

- [Apple IOHIDManager Documentation](https://developer.apple.com/documentation/iokit/iohidmanager)
- [CGEvent Documentation](https://developer.apple.com/documentation/coregraphics/cgevent)
- Original skhd source for event handling patterns