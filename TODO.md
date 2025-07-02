# TODO - Future Features and Improvements

This file tracks features and improvements that are not yet implemented but could be added in future versions.

## Performance Optimizations

### Critical Performance Issues
- [ ] **High CPU usage investigation**: Current implementation uses ~1.6% CPU vs original's ~0.6% during repeated key presses
  - Profile event handler callback overhead
  - Investigate allocator usage in hot path
  - Check for unnecessary string operations
  - Optimize process name retrieval caching
  - Review HashMap lookup performance

### Memory and CPU Optimizations
- [x] **SOA for process map**: Convert process mapping from array-of-structures to structure-of-arrays for better cache locality
- [x] **Profiling infrastructure**: Add timing/profiling infrastructure with `-P` flag support
- [ ] **Memory usage optimization**: Reduce memory footprint for hotkey storage and lookup
- [ ] **Hash table optimization**: Further optimize HashMap implementation for O(1) hotkey lookup in all cases

### Event Processing
- [ ] **Event batching**: Batch multiple events together to reduce processing overhead
- [ ] **Hot path optimization**: Further optimize the event processing hot path
- [ ] **SIMD optimizations**: Use SIMD instructions for string matching where applicable

## System Integration Features

### File System Integration
- [ ] **FSEvents-based file watching**: Replace current hotloading with FSEvents API for better performance
- [ ] **Watch included files**: Automatically watch files included via `.load` directives
- [ ] **Symlink resolution**: Handle symlinked configuration files properly
- [ ] **Config validation**: Add comprehensive config file validation with suggestions

### macOS Integration
- [ ] **Application switching detection**: Detect when user switches between applications
- [ ] **Keyboard layout change handling**: Adapt to keyboard layout changes dynamically
- [ ] **Secure keyboard entry detection**: Detect and handle secure input fields
- [ ] **Accessibility permission checks**: Automatically check and prompt for accessibility permissions
- [ ] **macOS notification support**: Show notifications for mode changes and errors
- [ ] **Carbon application event handling**: Handle legacy Carbon app events
- [ ] **Locale-aware keycode mapping**: Support for different keyboard layouts and locales

## Advanced Input Handling

### Mouse Support
- [ ] **Mouse button support**: Add support for left, right, middle, and extra mouse buttons
- [ ] **Mouse event handling**: Support mouse clicks, drag, and scroll events in hotkeys
- [ ] **Mouse gesture recognition**: Basic mouse gesture support for hotkey triggers

### Extended Key Support
- [ ] **Media key event handling**: Improve media key handling (play, pause, next, previous)
- [ ] **Custom key definitions**: Allow users to define custom key mappings
- [ ] **Keycode discovery mode**: Interactive mode to discover keycodes for unusual keys

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

### Advanced Configuration
- [ ] **Configuration templates**: Predefined configuration templates for common use cases
- [ ] **Configuration validation**: Advanced validation with helpful error messages and suggestions
- [ ] **Live configuration editing**: Hot-edit configuration with immediate feedback
- [ ] **Configuration export/import**: Export and import configuration profiles

### Syntax Extensions
- [x] **Process group variables**: Define reusable process groups with `.define` directive and `@group_name` references
- [ ] **Wildcard/regex pattern support**: Support regex or glob patterns in process names (e.g., `"*term*"`, `"^(kitty|wezterm)$"`)
- [ ] **Negation syntax**: Apply hotkeys to all apps except specified ones (e.g., `! ["kitty", "wezterm"]`)
- [ ] **Template/macro system**: Define reusable hotkey templates with parameters
- [ ] **Inheritance/extension**: Allow hotkeys to inherit or extend other definitions
- [ ] **Multi-key definition**: Define multiple keys sharing the same process map in one declaration
- [ ] **Regular expressions in process matching**: Use regex patterns for process name matching
- [ ] **Conditional hotkeys**: Hotkeys that activate based on system state (time, app state, etc.)
- [ ] **Variable substitution**: Environment variable substitution in commands
- [ ] **Command pipelines**: Support for complex command pipelines and scripting

## User Interface and Experience

### GUI Components
- [ ] **System tray integration**: macOS menu bar integration for status and control
- [ ] **Configuration GUI**: Graphical configuration editor
- [ ] **Visual feedback**: On-screen display for mode changes and hotkey execution
- [ ] **Hotkey visualizer**: Show active hotkeys and their bindings

### Documentation and Help
- [ ] **Interactive help system**: Built-in help and documentation browser
- [ ] **Configuration wizard**: Step-by-step configuration setup wizard
- [ ] **Hotkey conflict detection**: Detect and warn about conflicting hotkey definitions
- [ ] **Usage analytics**: Optional usage tracking to help users optimize their workflows

## Platform and Compatibility

### Platform Support
- [ ] **macOS version compatibility**: Ensure compatibility across different macOS versions
- [ ] **Apple Silicon optimization**: Optimize for Apple Silicon Macs
- [ ] **Universal binary**: Build universal binaries for Intel and Apple Silicon

### Integration Features
- [ ] **Shell integration**: Better integration with popular shells (zsh, fish, etc.)
- [ ] **Terminal multiplexer support**: Special handling for tmux, screen, etc.
- [ ] **IDE integration**: Plugins or integration with popular IDEs and editors

## Architecture Improvements

### Code Organization
- [ ] **Plugin system**: Allow third-party plugins to extend functionality
- [ ] **API for external tools**: Provide API for external tools to interact with skhd
- [ ] **Configuration DSL improvements**: Extend the configuration language with more features
- [ ] **Multi-language bindings**: Provide bindings for other programming languages

### Error Handling and Logging
- [ ] **Structured logging**: JSON/structured log output for better parsing
- [ ] **Log rotation**: Automatic log file rotation and cleanup
- [ ] **Remote logging**: Send logs to remote logging services
- [ ] **Error recovery**: Better error recovery and graceful degradation

## Testing and Quality Assurance

### Missing Test Coverage
- [ ] **Media key tests**: Add tests for `sound_up`, `sound_down`, `mute`, `brightness_up`, `brightness_down`
- [ ] **Hex keycode tests**: Add tests for hexadecimal keycode format (e.g., `0x32`)
- [ ] **Function key modifier tests**: Add tests for `fn` modifier combinations
- [ ] **Complex multi-line commands**: Test commands that span multiple lines with backslash continuation
- [ ] **Edge case process names**: Test process names with special characters, Unicode, etc.

### Testing Infrastructure
- [ ] **Integration tests**: Comprehensive integration test suite
- [ ] **Performance benchmarks**: Automated performance testing and regression detection
- [ ] **Fuzzing**: Fuzz testing for configuration parsing and event handling
- [ ] **Continuous integration**: Set up CI/CD pipeline for automated testing

### Quality Improvements
- [ ] **Static analysis**: Integrate static analysis tools for code quality
- [ ] **Memory leak detection**: Automated memory leak detection in tests
- [ ] **Security audit**: Regular security audits and vulnerability assessments
- [ ] **Documentation coverage**: Ensure all features are properly documented

## Community and Ecosystem

### Distribution
- [ ] **Package managers**: Support for Homebrew, MacPorts, etc.
- [ ] **Automatic updates**: Built-in update mechanism
- [ ] **Release automation**: Automated release process with proper versioning

### Community Features
- [ ] **Configuration sharing**: Platform for sharing configuration files
- [ ] **Community plugins**: Repository for community-contributed plugins
- [ ] **Migration tools**: Tools to migrate from original skhd to skhd.zig

---

## Implementation Priority

### High Priority (Performance & Stability)
1. **Performance profiling and optimization**: Implement comprehensive profiling to identify why our implementation uses ~1.6% CPU vs original's ~0.6%
   - Add `-P` / `--profile` flag support
   - Integrate with modern profiling tools (Tracy, Spall, or custom timing)
   - Profile hot path (event handling, hotkey lookup, process name retrieval)
   - Identify and optimize CPU-intensive operations
2. FSEvents-based file watching
3. Memory usage optimization
4. Better error handling and recovery

### Medium Priority (User Experience)
1. Configuration validation and helpful error messages
2. System tray integration
3. Accessibility permission checks
4. Mouse support

### Low Priority (Nice to Have)
1. GUI configuration editor
2. Plugin system
3. Multi-language bindings
4. Community features

---

*This list is not exhaustive and will be updated as new requirements and ideas emerge. Contributions are welcome for any of these features.*
