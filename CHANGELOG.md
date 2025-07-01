# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.1] - 2025-01-01

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

[Unreleased]: https://github.com/yourusername/skhd.zig/compare/v0.0.1...HEAD
[0.0.1]: https://github.com/yourusername/skhd.zig/releases/tag/v0.0.1