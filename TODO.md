# TODO - Future Features and Improvements

This file tracks features and improvements that are not yet implemented but could be added in future versions.

## Clean up

- [ ] clean up tests by moving the tests tests.zig to their respective zig files and remove tests.zig
- [ ] clean up pub declarations where possible

## Advanced Input Handling

### macOS Integration
- [ ] **Keyboard layout change handling**: Adapt to keyboard layout changes dynamically
- [ ] **Secure keyboard entry detection**: Detect and handle secure input fields
- [ ] **macOS notification support**: Show notifications for mode changes and errors
- [ ] **Locale-aware keycode mapping**: Support for different keyboard layouts and locales

### Mouse Support
- [ ] **Mouse button support**: Add support for left, right, middle, and extra mouse buttons
- [ ] **Mouse event handling**: Support mouse clicks, drag, and scroll events in hotkeys
- [ ] **Mouse gesture recognition**: Basic mouse gesture support for hotkey triggers

## Power Management and System Control

### System Integration
- [ ] **Power management integration**: Integration with macOS power management
- [ ] **Sleep system command**: `iokit_power_management_sleep_system` - Command to put system to sleep
- [ ] **Display control**: Commands to control display brightness, sleep, etc.
- [ ] **Volume and media control**: Direct system volume and media control commands

### Device Detection
- [ ] **Input device detection**: Detect and handle multiple keyboards/input devices
- [ ] **Device-specific mappings**: Different hotkey mappings for different input devices
- [ ] **USB device hotplug**: Handle USB keyboard connect/disconnect events

## Configuration Enhancements

### Syntax Extensions
- [ ] **Negation syntax**: Apply hotkeys to all apps except specified ones (e.g., `! ["kitty", "wezterm"]`)
- [ ] **Conditional hotkeys**: Hotkeys that activate based on system state (time, app state, etc.)

## User Interface and Experience

### Platform Support
- [ ] **Universal binary**: Build universal binaries for Intel and Apple Silicon

## Testing and Quality Assurance

### Testing Infrastructure
- [ ] **Integration tests**: Comprehensive integration test suite
- [ ] **Performance benchmarks**: Automated performance testing and regression detection
- [ ] **Fuzzing**: Fuzz testing for configuration parsing and event handling

## Community and Ecosystem

### Community Features
- [ ] **Configuration sharing**: Platform for sharing configuration files
