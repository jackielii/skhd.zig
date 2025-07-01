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
- [x] Logging facility with `/tmp/skhd_$USER.{out,err}.log`

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
- [x] `-r` / `--reload` - Signal reload to running instance
- [x] `-h` / `--no-hotload` - Disable hotloading

### Service Management
- [x] `--install-service` - Install launchd service
- [x] `--uninstall-service` - Remove launchd service
- [x] `--start-service` - Start as service
- [x] `--restart-service` - Restart service
- [x] `--stop-service` - Stop service
- [x] PID file management (`/tmp/skhd_$USER.pid`)
- [x] Service logging (`/tmp/skhd_$USER.log`)

### Configuration Features
- [x] Default config file resolution (`~/.skhdrc`, `~/.config/skhd/skhdrc`)
- [x] `.load` directive for including other config files
- [x] `.blacklist` directive for application blacklisting
- [x] `.shell` directive for custom shell
- [x] Modal activation commands
- [x] Capture mode (`@` modifier) for modes
- [x] Config file error reporting with line numbers

### Hotkey Features
- [x] Hyper and Meh modifier support
- [x] Function key modifier
- [x] Media key support (brightness, volume, playbook)
- [x] Passthrough mode (`->` operator)
- [x] Wildcard commands (`*` in process lists)
- [x] Unbound keys (`~` operator)
- [x] System-defined key events (NX_SYSDEFINED)

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

### Advanced Features
- [ ] device detection
