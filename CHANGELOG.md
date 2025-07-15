# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.12] - 2025-07-15

### Added
- **Mode activation with optional command execution** - Enhanced mode switching with command execution support
  - New syntax: `keysym ; mode : command` executes command when switching to mode
  - Process-specific mode activation in process lists (e.g., `"terminal" ; vim_mode`)
  - Process group mode activation (e.g., `@browsers ; browser_mode`)
  - Comprehensive test coverage for all activation scenarios
- Added `activation` variant to `ProcessCommand` enum for proper mode activation tracking

### Changed
- Refactored command parsing to eliminate code duplication with helper function `parse_command`
- Removed redundant `flags.activate` field from `ModifierFlag` 
- Updated SYNTAX.md and README.md with comprehensive mode activation documentation

### Fixed
- Fixed mode activation implementation to use dedicated enum variant instead of borrowing command enum
- Improved error handling for empty commands followed by references

## [0.0.11] - 2025-07-13

### Changed
- Optimized command execution by using null-terminated strings throughout, eliminating runtime allocations in exec.zig
- Refactored Hotkey API to have separate methods for each action type (add_process_command, add_process_forward, add_process_unbound)

### Fixed
- Fixed benchmark to use new Hotkey API methods

## [0.0.10] - 2025-07-08

### Fixed
- **Critical bug fix**: Capture mode now respects passthrough and unbound actions
  - Previously, capture mode would consume all keys including those explicitly marked as passthrough (`->`) or unbound (`~`)
  - Now these keys are properly passed through to applications even in capture mode

### Added
- Support for unbound action syntax: `<keysym> ~`
  - Keys marked as unbound are not captured and pass through to applications
  - Compatible with all existing features (modes, process lists, etc.)
- Added `--message` flag to release script for custom tag messages

### Changed
- Refactored hotkey processing to use `HotkeyResult` enum instead of boolean return
  - Clearer distinction between consumed, passthrough, and not_found states
  - Eliminated code duplication between `handleKeyDown` and `handleSystemKey`

### Internal
- Added comprehensive tests for capture mode behavior with passthrough and unbound actions
- Extracted common hotkey result handling into `handleHotkeyResult` helper function
- Updated SYNTAX.md documentation to include unbound action syntax

## [0.0.9] - 2025-07-07

### Fixed

- A subtle but critical bug only happens in release mode due to how memory allocation works with aggressive allocators like `smp_allocator` or `c_allocator`. This bug caused HashMaps to silently point to different objects after destroying an object that was still referenced in the map. This has been fixed by using a array list to track the hotkeys instead of a HashMap, which avoids this issue entirely.

### Added
- Improved duplicate hotkey detection with better error reporting

### Internal
- Added issue template for better bug reporting
- Updated CI workflow configuration
- Include build mode in version string output

## [0.0.8] - 2025-07-06

### Changed
- **Major performance improvement**: Achieved allocation-free event loop
  - Replaced dynamic allocation for process names with fixed-size buffer
  - Zero allocations during runtime after initialization
  - Event loop is now completely allocation-free in release builds
- Refactored hotkey implementation for simplicity and performance
  - Removed HotkeyArrayHashMap and HotkeyMultiArrayList (740+ lines removed)
  - Consolidated hotkey functionality in Hotkey.zig
- Enhanced test coverage with comprehensive duplicate detection tests
- CarbonEvent now uses a pre-allocated buffer for process names to avoid runtime allocations
- Moved VERSION file from src/VERSION to root directory for better visibility
- Code cleanup and formatting improvements across multiple modules

### Fixed
- Fixed cleanup logic when sending SIGINT to the process
- Fixed memory leaks in Hotkey.zig and improved memory management
- **Duplicate definition detection**: Now reports errors instead of silently overwriting duplicate entries in config
- Fixed CI/CD release workflow by replacing deprecated upload-release-asset action with gh CLI

### Internal
- Added TrackingAllocator for monitoring memory allocations during development
- Created new exec.zig module for command execution
- Improved error handling in Parser, Mappings, and Keycodes modules

## [0.0.7] - 2025-07-05

### Fixed
- **Accessibility permission check reliability** - Replaced unreliable event tap creation with `AXIsProcessTrusted()` API
- `--status` command now correctly reports accessibility permission state
- Fixed issue where permissions showed as "not granted" even when properly configured

### Changed
- Permission checking now uses the official macOS API for more accurate results

## [0.0.6] - 2025-07-04

### Added
- **Command definitions feature** with `.define` directive for reusable command templates
  - Support for placeholders (`{{1}}`, `{{2}}`, etc.) in command templates
  - Reference commands with `@command_name("arg1", "arg2")` syntax
  - Reduces configuration duplication and improves maintainability
- Enhanced error handling for command definition parsing with clear error messages

### Changed
- Refactored tokenizer to clean up token text representation
- Optimized command definition storage by moving it directly to Parser
- Updated documentation to include command definition examples

### Fixed
- Command definition parsing now properly handles escaped characters in templates
- Improved error reporting for invalid placeholder syntax

## [0.0.5] - 2025-07-02

### Changed
- Improved service mode execution to always use fork/exec for better reliability
- Refactored hotkey storage to use MultiArrayList for better memory layout and performance
- Updated README to explicitly mention key remapping/forwarding feature

### Added
- MIT License file
- Integrated Homebrew tap update directly into release workflow

### Fixed
- Import statement cleanup for better code organization
- GitHub Actions workflow now directly triggers Homebrew tap updates

## [0.0.4] - 2025-07-02

### Added
- Comprehensive execution tracer with `-P/--profile` flag for performance analysis
- Benchmark suite using zBench for hot path optimization
- Carbon event handler for efficient app switching notifications

### Changed
- **Major performance optimization**: Cache process name lookups (25μs → 21ns)
- **Eliminated double hotkey lookup**: Combined into single `processHotkey` function (169ns → 83ns)
- CPU usage reduced from ~1.2% to ~0.5% (matching original skhd)

### Fixed
- High CPU usage compared to original skhd implementation
- Unnecessary system calls in hot path

## [0.0.3] - 2025-07-01

### Added
- `--start-service` now automatically installs/updates the service plist to ensure it uses the current binary
- `--status` command to check service installation status, running state, and accessibility permissions
- Clear startup message in service mode to confirm skhd is running
- Improved accessibility permission error message with troubleshooting steps for when permissions are "stuck"

### Changed
- Service mode now only logs errors and startup messages, reducing log verbosity
- Removed unnecessary stdout/stderr syncing in logger for better performance

### Fixed
- Service management commands now provide better error messages and guidance
- Homebrew service integration now works more reliably with proper binary path updates

## [0.0.2] - 2025-07-01

### Fixed
- Support for uppercase option names (.SHELL, .BLACKLIST) in configuration files
- Improved error reporting to show parse errors with line numbers during initialization
- Parser now properly handles comma-separated lists in .define directives
- Exit with proper error when config file is not a regular file (e.g., /dev/null)
- Fixed release workflow permissions for uploading artifacts
- Simplified release workflow to build natively for each architecture

## [0.0.1] - 2025-07-01

### Added
- Initial release of skhd.zig - a complete Zig port of skhd
- Full compatibility with original skhd configuration format
- Core features:
  - Event tap creation and keyboard event handling
  - Hotkey mapping with modifier support (cmd, alt, ctrl, shift)
  - Left/right modifier distinction (lcmd, rcmd, etc.)
  - Modal system with mode switching and capture modes
  - Process-specific hotkey bindings
  - Key forwarding/remapping
  - Blacklist support for applications
  - Shell command execution
  - Configuration file loading with `.load` directive
  - Custom shell support with `.shell` directive
- Command-line interface:
  - `-c/--config` - Specify config file
  - `-o/--observe` - Observe mode for testing keys
  - `-V/--verbose` - Verbose output
  - `-k/--key` - Synthesize keypress
  - `-t/--text` - Synthesize text
  - `-r/--reload` - Reload configuration
  - `-h/--no-hotload` - Disable hot reloading
  - `-v/--version` - Show version
- Service management:
  - `--install-service` - Install launchd service
  - `--uninstall-service` - Remove launchd service
  - `--start-service` - Start service
  - `--restart-service` - Restart service
  - `--stop-service` - Stop service
- Enhanced features:
  - **Process group variables** (New!) - Define reusable process groups with `.define` directive
  - Improved error reporting with line numbers and file paths
  - Unicode character handling in process names
  - Fixed key repeating issue with event forwarding
  - Comprehensive test suite
  - CI/CD workflow with GitHub Actions

### Fixed
- Key repeating issue when forwarding events to applications
- Unicode invisible character handling in process names
- Modifier matching logic to properly handle general vs specific modifiers
- Memory management and hot reload stability

### Performance
- Optimized hot path to minimize allocations during key events
- Efficient HashMap-based hotkey lookup
- Stack-based buffers for process name retrieval

[Unreleased]: https://github.com/jackielii/skhd.zig/compare/v0.0.8...HEAD
[0.0.8]: https://github.com/jackielii/skhd.zig/compare/v0.0.7...v0.0.8
[0.0.7]: https://github.com/jackielii/skhd.zig/compare/v0.0.6...v0.0.7
[0.0.6]: https://github.com/jackielii/skhd.zig/compare/v0.0.5...v0.0.6
[0.0.5]: https://github.com/jackielii/skhd.zig/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/jackielii/skhd.zig/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/jackielii/skhd.zig/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/jackielii/skhd.zig/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/jackielii/skhd.zig/releases/tag/v0.0.1
