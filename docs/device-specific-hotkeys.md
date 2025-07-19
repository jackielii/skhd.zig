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

### Option 1: Device as Additional Constraint (Recommended)
```bash
# Device constraint in square brackets before process constraint
cmd - a [device:"Apple Internal Keyboard"] : echo "internal keyboard"
cmd - a [vendor:0x05ac,product:0x027e] : echo "specific device by ID"
cmd - a [device:"Keychron*"] : echo "any Keychron keyboard"

# Combined with process constraints
cmd - a [device:"External Keyboard"] [
    "Terminal" : echo "external keyboard in terminal"
    *          : echo "external keyboard elsewhere"
]

# Device groups (similar to process groups)
.define keyboards ["Apple Internal Keyboard", "Keychron K2"]
cmd - a [@keyboards] : echo "from defined keyboards"
```

### Option 2: Device in Process List Syntax
```bash
# Extend existing process list syntax
cmd - a [
    device:"Apple Internal Keyboard" : echo "internal"
    device:"External Keyboard"       : echo "external"
    "Terminal"                       : echo "any keyboard in terminal"
    *                               : echo "fallback"
]
```

### Option 3: Separate Device Modes
```bash
# Define device-specific modes
:: default [device:"Apple Internal Keyboard"]
:: external [device:"External Keyboard"]

# Switch between them
cmd - 1 ; default
cmd - 2 ; external
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

### Phase 1: Device Detection Infrastructure

1. **Create `DeviceManager.zig`**
   - Initialize IOHIDManager
   - Enumerate connected keyboards
   - Cache device information (vendor ID, product ID, name)
   - Provide device lookup by IOHIDDeviceRef

2. **Extend `EventTap.zig`**
   - Add parallel IOHIDManager monitoring
   - Map CGEvents to source device
   - Store device info in event processing

### Phase 2: Data Structure Updates

1. **Update `Hotkey.zig`**
   - Add device constraints to ProcessCommand
   - Support device matching patterns (exact, wildcard, vendor/product)

2. **Update `Mappings.zig`**
   - Add device groups support (like process groups)
   - Store device-specific configuration

### Phase 3: Parser Extensions

1. **Extend `Parser.zig`**
   - Parse device constraints in hotkey definitions
   - Support device groups with `.define`
   - Validate device syntax

2. **Update `Tokenizer.zig`**
   - Add tokens for device-specific syntax
   - Handle device: prefix parsing

### Phase 4: Runtime Integration

1. **Update `skhd.zig`**
   - Pass device info through event processing
   - Match hotkeys based on device constraints
   - Handle device connection/disconnection

### Phase 5: Testing & Documentation

1. **Add comprehensive tests**
   - Device matching logic
   - Parser support for device syntax
   - Integration tests with mock devices

2. **Update documentation**
   - Add device syntax to CLAUDE.md
   - Create examples in README
   - Document device identification methods

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
cmd - h [device:"External*"] : yabai -m window --focus west
cmd - j [device:"External*"] : yabai -m window --focus south
cmd - k [device:"External*"] : yabai -m window --focus north
cmd - l [device:"External*"] : yabai -m window --focus east
```

### 2. Device-Specific Modifiers
```bash
# Use caps lock as hyper on specific keyboard
caps [device:"HHKB*"] : echo "hyper pressed"
```

### 3. Testing with Multiple Keyboards
```bash
# Different actions for testing
f1 [device:"Keyboard 1"] : echo "Test from keyboard 1"
f1 [device:"Keyboard 2"] : echo "Test from keyboard 2"
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