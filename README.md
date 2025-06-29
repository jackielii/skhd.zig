# SKHD in zig

Simple Hotkey Daemon for macOS, ported from [skhd](https://github.com/koekeishiya/skhd) to zig.

## Completed
- [x] Basic tokenizer and parser
- [x] Event tap creation
- [x] Core data structures (Hotkey, Mode, Mappings)
- [x] Packed structs and unmanaged collections

## TODO

### Core Functionality
- [ ] Complete main entry point with command-line argument parsing
- [ ] Implement actual keyboard event handling in EventTap callback
- [ ] Add hotkey matching and command execution
- [ ] Implement process-specific hotkey support
- [ ] Add actual shell command execution

### Command-Line Features
- [ ] `--version` / `-v` - Display version
- [ ] `--help` - Show usage information
- [ ] `-c` / `--config` - Specify config file location
- [ ] `-o` / `--observe` - Observe mode (echo keycodes)
- [ ] `-k` / `--key` - Synthesize keypress
- [ ] `-t` / `--text` - Synthesize text input
- [ ] `-V` / `--verbose` - Debug output
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
- [ ] `.blacklist` directive for application blacklisting
- [ ] `.shell` directive for custom shell (currently hardcoded)
- [ ] Modal activation commands
- [ ] Capture mode (`@` modifier) for modes
- [ ] Config file error reporting with line numbers

### Hotkey Features
- [ ] Left/right modifier distinction (lcmd, rcmd, etc.)
- [ ] Hyper and Meh modifier support
- [ ] Function key modifier
- [ ] Media key support (brightness, volume, playback)
- [ ] Key forwarding/remapping (`|` operator)
- [ ] Passthrough mode (`->` operator)
- [ ] Wildcard commands (`*` in process lists)
- [ ] Unbound keys (`~` operator)
- [ ] System-defined key events (NX_SYSDEFINED)

### Hotloading
- [ ] FSEvents-based file watching
- [ ] Automatic config reload on changes
- [ ] Watch included files from `.load` directives
- [ ] Symlink resolution

### System Integration
- [ ] Process name detection for active window
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
