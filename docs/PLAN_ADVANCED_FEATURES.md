# Advanced Features Implementation Plan for skhd.zig

## Executive Summary

This document outlines the plan to implement advanced Karabiner-Elements features in skhd.zig, specifically:
1. Device-specific hotkey filtering (e.g., different behavior for built-in keyboard vs external HHKB)
2. Dual-function keys with `to_if_alone` functionality (e.g., Caps Lock → Escape when tapped, Control when held)

## Feature 1: Device Filtering

### How Karabiner-Elements Implements Device Filtering

Based on research of the Karabiner-Elements codebase:

1. **Device Identification**:
   - Uses vendor_id and product_id to identify devices
   - Maintains a device_properties_manager that tracks all connected devices
   - Device information is queried from IOKit

2. **Condition System**:
   - Four condition types: `device_if`, `device_unless`, `device_exists_if`, `device_exists_unless`
   - Conditions are evaluated before executing manipulators
   - Located in `src/share/manipulator/conditions/device.hpp`

3. **Configuration Format**:
   ```json
   "conditions": [{
       "type": "device_if",
       "identifiers": [{
           "vendor_id": 1452,
           "product_id": 834,
           "description": "Apple Internal Keyboard"
       }]
   }]
   ```

### Proposed skhd.zig Implementation

1. **Add Device Detection**:
   - Create a new `DeviceManager.zig` module
   - Use IOKit APIs to enumerate HID devices
   - Track vendor_id, product_id for each device

2. **Extend Configuration Syntax**:
   ```
   # Device-specific binding
   ctrl - h [device:1452,834] : echo "Built-in keyboard"
   ctrl - h [device:1278,33] : echo "HHKB keyboard"
   ```

3. **Modify Parser**:
   - Add device condition parsing in `Parser.zig`
   - Store device conditions in `Hotkey` structure

4. **Event Processing**:
   - In `EventTap.zig`, identify source device for each event
   - Match against device conditions before executing commands

## Feature 2: to_if_alone (Dual-Function Keys)

### How Karabiner-Elements Implements to_if_alone

Based on analysis of `src/share/manipulator/manipulators/basic/`:

1. **State Tracking**:
   - `manipulated_original_event` tracks "alone" state
   - Records key down timestamp
   - `alone_` flag set to true on key down

2. **Alone State Interruption**:
   - Flag set to false when:
     - Another key is pressed
     - Mouse wheel is scrolled
   - Handled by `unset_alone_if_needed()` method

3. **Timeout Logic**:
   - Default timeout: 1000ms (configurable)
   - Stored in `basic_to_if_alone_timeout_milliseconds`

4. **Event Processing**:
   - Key down: Send normal `to` events
   - Key up (if alone and within timeout): Send `to_if_alone` events

### Proposed skhd.zig Implementation

1. **Configuration Syntax**:
   ```
   # Caps Lock → Escape (tap) / Control (hold)
   caps_lock : ctrl
   caps_lock [alone] : escape
   
   # Alternative syntax
   caps_lock -> ctrl | escape
   ```

2. **State Management**:
   - Create `DualFunctionKeyManager.zig`
   - Track key press timestamps
   - Monitor for interrupting events

3. **Integration Points**:
   - Modify `EventTap.zig` to track alone state
   - Add timeout handling (use dispatch timers)
   - Inject synthetic events for alone actions

## Architecture Comparison: Virtual Driver vs Event Tap

### Karabiner-Elements: Virtual HID Driver Approach

**Pros**:
- Complete control over event flow
- Can suppress original events reliably
- Lower-level access allows complex manipulations
- Better for system-wide modifications
- Can handle all input types (keyboard, mouse, etc.)

**Cons**:
- Requires kernel extension (security implications)
- More complex installation/permissions
- Higher development complexity
- Potential system stability risks

**Implementation**:
- Uses `pqrs::karabiner::driverkit::virtual_hid_device`
- Intercepts events at driver level
- Posts modified events to virtual device

### skhd: Event Tap Approach

**Pros**:
- Simpler implementation
- No kernel extensions required
- Easier to debug and maintain
- Less invasive to system
- Good enough for most hotkey use cases

**Cons**:
- Limited to CGEventTap capabilities
- Can't suppress all events reliably
- Higher latency than driver approach
- Some edge cases with event ordering

**Current Implementation**:
- Uses CGEventTapCreate
- Processes events at user-space level
- Limited to keyboard events

### Recommendation

For skhd.zig, continue with the Event Tap approach because:
1. Maintains simplicity and compatibility with original skhd
2. Sufficient for hotkey daemon functionality
3. Avoids kernel extension complexity
4. Device filtering and to_if_alone can be implemented with event taps

However, we need to enhance the current implementation:
- Add mouse event monitoring for alone state interruption
- Implement proper event suppression for dual-function keys
- Add timing mechanisms for alone detection

## Implementation Roadmap

### Phase 1: Device Filtering (Foundation)
1. Create DeviceManager module
2. Implement IOKit device enumeration
3. Add device tracking to EventTap
4. Extend Parser for device conditions
5. Update Hotkey structure
6. Add device matching logic
7. Write comprehensive tests

### Phase 2: Basic to_if_alone
1. Create DualFunctionKeyManager
2. Add state tracking for key presses
3. Implement timeout handling
4. Add alone state interruption logic
5. Integrate with EventTap
6. Test with simple use cases

### Phase 3: Advanced Features
1. Add configuration for timeout values
2. Support multiple alone actions
3. Add to_if_held_down support
4. Optimize performance
5. Handle edge cases

### Phase 4: Testing & Polish
1. Comprehensive test suite
2. Performance benchmarking
3. Documentation updates
4. Example configurations

## Open Questions

1. **Configuration Syntax**: Should we maintain compatibility with skhd syntax or adopt Karabiner-style JSON?
   - Proposal: Extend skhd syntax to maintain backwards compatibility

2. **Event Suppression**: How to reliably suppress original events in dual-function scenarios?
   - May need to explore CGEventTapProxy options

3. **Mouse Integration**: Should we monitor mouse events for alone interruption?
   - Yes, for feature parity with Karabiner

4. **Performance**: Will state tracking impact hotkey responsiveness?
   - Need benchmarking, but likely minimal impact

5. **Persistence**: Should device configurations persist across disconnections?
   - Yes, match devices by vendor/product ID

## Next Steps

1. Review and approve this plan
2. Begin Phase 1 implementation with DeviceManager
3. Create test harness for device simulation
4. Iterate based on testing results