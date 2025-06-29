# SKHD in zig

Simple Hotkey Daemon for macOS, ported from [skhd](https://github.com/koekeishiya/skhd) to zig.

This implementation provides a fully functional hotkey daemon with modal support, process-specific bindings, key forwarding, and comprehensive configuration options.

## Completed
- [x] Basic tokenizer and parser
- [x] Event tap creation
- [x] Core data structures (Hotkey, Mode, Mappings)
- [x] Packed structs and unmanaged collections
- [x] Main entry point with command-line argument parsing
- [x] Keyboard event handling in EventTap callback
- [x] Hotkey matching and command execution
- [x] Shell command execution
- [x] Modal system with mode switching (`;` syntax)
- [x] Basic verbose output (`-V`)
- [x] Observe mode (`-o`)
- [x] Config file specification (`-c`)
- [x] Process name detection for active window
- [x] Process-specific hotkey support
- [x] Key forwarding/remapping (`|` operator)
- [x] Left/right modifier distinction (lcmd, rcmd, etc.)
- [x] Key synthesis (-k option) for testing
- [x] Text synthesis (-t option) for text input
- [x] Comprehensive unit tests

## TODO

### Core Functionality

### Command-Line Features
- [x] `--version` / `-v` - Display version
- [x] `--help` - Show usage information
- [x] `-c` / `--config` - Specify config file location
- [x] `-o` / `--observe` - Observe mode (echo keycodes)
- [x] `-V` / `--verbose` - Debug output
- [x] `-k` / `--key` - Synthesize keypress
- [x] `-t` / `--text` - Synthesize text input
- [ ] `-P` / `--profile` - Profiling output
- [ ] `-r` / `--reload` - Signal reload to running instance
- [ ] `-h` / `--no-hotload` - Disable hotloading

### Service Management
- [ ] `--install-service` - Install launchd service
- [ ] `--uninstall-service` - Remove launchd service
- [ ] `--start-service` - Start as service
- [ ] `--restart-service` - Restart service
- [ ] `--stop-service` - Stop service
- [ ] PID file management (`/tmp/skhd_$USER.pid`)
- [ ] Service logging (`/tmp/skhd_$USER.{out,err}.log`)

### Configuration Features
- [ ] Default config file resolution (`~/.skhdrc`, `~/.config/skhd/skhdrc`)
- [ ] `.load` directive for including other config files
- [x] `.blacklist` directive for application blacklisting
- [ ] `.shell` directive for custom shell
- [x] Modal activation commands
- [x] Capture mode (`@` modifier) for modes
- [ ] Config file error reporting with line numbers

### Hotkey Features
- [ ] Hyper and Meh modifier support
- [ ] Function key modifier
- [ ] Media key support (brightness, volume, playbook)
- [x] Passthrough mode (`->` operator)
- [ ] Wildcard commands (`*` in process lists)
- [ ] Unbound keys (`~` operator)
- [ ] System-defined key events (NX_SYSDEFINED)

### Hotloading
- [ ] FSEvents-based file watching
- [ ] Automatic config reload on changes
- [ ] Watch included files from `.load` directives
- [ ] Symlink resolution

### System Integration
- [ ] Application switching detection
- [ ] Keyboard layout change handling
- [ ] Secure keyboard entry detection
- [ ] Accessibility permission checks
- [ ] macOS notification support

### Performance & Architecture
- [ ] Use SOA for process map
- [ ] Implement hash table for O(1) hotkey lookup
- [ ] Add timing/profiling infrastructure
- [ ] Memory usage optimization

### Platform Features
- [ ] Carbon application event handling
- [ ] Locale-aware keycode mapping
- [ ] Media key event handling
- [ ] Mouse button support (left, right, middle, extra buttons)
- [ ] Mouse event handling (clicks, drag, scroll)
- [ ] System power management integration
- [ ] `iokit_power_management_sleep_system` - Put system to sleep command
