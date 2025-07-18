# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Zig port of skhd (Simple Hotkey Daemon for macOS). The project reimplements the original C-based skhd in Zig, maintaining compatibility with the same config file format and hotkey DSL.

## Build Commands

```bash
# Build the project (creates executable in zig-out/bin/)
zig build

# Build in release mode with optimizations
zig build -Doptimize=ReleaseFast
zig build -Doptimize=ReleaseSmall
zig build -Doptimize=ReleaseSafe

# Run with arguments
zig build run -- [args]

# Run tests
zig build test

# Note: If tests hang, use one of these alternatives:
ZIG_PROGRESS=0 zig build test
```

To run a single test you need to link the frameworks manually:

```bash
zig test -lc -framework Cocoa -framework Carbon src/Hotload.zig
```

It's preferred to use the `zig build test` command as it automatically links the required frameworks.

## Architecture

The codebase follows a modular architecture with clear separation of concerns:

### Core Components

1. **Parser.zig** - Parses skhd configuration files using the DSL syntax
   - Uses Tokenizer for lexical analysis
   - Builds hotkey mappings from config syntax
   - Handles mode declarations and options

2. **Tokenizer.zig** - Lexical analyzer for the configuration DSL
   - Handles UTF-8 text processing
   - Recognizes tokens like modifiers, keys, commands, etc.

3. **EventTap.zig** - macOS event tap interface for capturing keyboard events
   - Wraps Core Graphics event tap APIs
   - Manages event capture and filtering

4. **Hotkey.zig** - Hotkey data structure and management
   - Stores modifier flags and key codes
   - Maps process names to commands
   - Supports wildcard commands and key forwarding

5. **Mode.zig** - Modal hotkey system implementation
   - Each mode has its own hotkey map
   - Supports mode-specific commands and capture behavior

6. **Mappings.zig** - Central registry for all hotkeys and modes
   - Manages global hotkey map and mode map
   - Handles application blacklisting
   - Stores shell configuration for command execution

7. **Keycodes.zig** - Key code and modifier flag definitions
   - Maps between string representations and numeric codes
   - Handles Carbon/Cocoa key constants

8. **CarbonEvent.zig** - Application switching detection
   - Monitors app switch events for process-specific hotkeys
   - Caches process names for performance optimization
   - Reduces lookup overhead from 25μs to 21ns

9. **exec.zig** - Command execution module
   - Implements double-fork technique for proper daemon process creation
   - Ensures child processes are fully detached from parent
   - Prevents zombie processes and terminal output interference

10. **Tracer.zig** - Performance profiling infrastructure
    - Provides execution tracing with `-P/--profile` flag
    - Helps identify performance bottlenecks
    - Available in Debug and ReleaseSafe builds only

### Key Implementation Notes

- The project links against macOS frameworks: Cocoa, Carbon, and CoreServices
- Uses packed structs and unmanaged slices for memory efficiency
- Event handling follows the original skhd's approach but with Zig's safety features
- Config parsing maintains compatibility with the original DSL
- **Performance**: The event loop is allocation-free in release builds
  - Zero allocations during runtime after initialization
  - CPU usage reduced from ~1.2% to ~0.5% (matching original skhd)
  - Process name lookups cached for 25μs → 21ns improvement

## Configuration DSL

The project supports the same configuration syntax as the original skhd, plus additional features:

### Core Syntax
- Hotkey definitions: `mod - key : command`
- Modal system: `:: mode_name` or `:: mode_name @` (capture mode)
- Process-specific bindings: `key [ "app_name" : command ]`
- Key forwarding/remapping: `ctrl - 1 | cmd - 1`
- Passthrough mode: `cmd - p -> : command` (execute command but still send keypress)
- Unbound actions: `cmd - a ~` (key is not captured and passes through to the application)
- String escape sequences: `\"` for quotes, `\\` for backslash, `\n` for newline, `\t` for tab

### Enhanced Features (New in skhd.zig!)
- **Process groups**: `.define group_name ["app1", "app2", "app3"]`
  - Use with `@group_name` in process lists
- **Command definitions**: `.define name : command` with placeholders `{{1}}`, `{{2}}`, etc.
  - Reference with `@name("arg1", "arg2")`
- **Mode activation with command**: `key ; mode : command`
  - Executes command when switching to mode
  - Works in global hotkeys, process lists, and process groups

## Related Codebase

The original C implementation is available at `/Users/jackieli/personal/skhd/` for reference. Key differences:
- Original uses C with manual memory management
- This port uses Zig with explicit allocators and safer memory handling
- Both share the same configuration format and core functionality

My active configuration file is located at `/Users/jackieli/.config/skhd/skhdrc`. Make sure to support all features present in this file.

## Test Infrastructure

The project follows a localized testing strategy:
- **Unit tests**: Write tests for functions in the same file where they are defined (e.g., Parser.zig, Tokenizer.zig, Hotkey.zig)
- **Integration tests**: Use `src/tests.zig` only for tests that span multiple modules or test the interaction between different components
- Use `zig build test` to run all tests (both unit and integration)
- Test configuration files should be placed in the `testdata/` directory
- Follow existing test patterns for consistency

**Important**: Always run `zig build test` after completing any implementation to ensure all tests pass and no regressions are introduced.

## Debugging and Profiling

### Debug vs Release Builds

**Important**: The logging and profiling behavior differs between build modes:

- **ReleaseFast builds** (installed via Homebrew or built with `-Doptimize=ReleaseFast`): 
  - Only show errors and warnings, even with `-V`/`--verbose` flag
  - Profiling (`-P`/`--profile`) is disabled - all tracing code is compiled out for maximum performance
- **ReleaseSafe builds** (built with `-Doptimize=ReleaseSafe`):
  - Show errors, warnings, and info messages with `-V`/`--verbose` flag
  - Profiling (`-P`/`--profile`) is available for production debugging
- **Debug builds** (default `zig build`): 
  - Show all log levels including debug messages with `-V`/`--verbose` flag
  - Profiling (`-P`/`--profile`) is available with full trace details

### Debugging Commands

```bash
# Verbose logging for troubleshooting config issues
zig build run -- -V

# Test key combinations and hex codes (observe mode)
zig build run -- -o

# Profile event handling (Debug/ReleaseSafe only)
zig build && ./zig-out/bin/skhd -P

# Debug memory allocations with real-time tracking
zig build alloc -- -V
```
