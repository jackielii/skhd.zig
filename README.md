# SKHD in Zig

Simple Hotkey Daemon for macOS, ported from [skhd](https://github.com/koekeishiya/skhd) to Zig.

This implementation provides a fully functional hotkey daemon with modal support, process-specific bindings, key forwarding, and comprehensive configuration options that is fully compatible with the original skhd configuration format.

## Features

### Core Functionality
- **Event capturing**: Uses macOS Core Graphics Event Tap for system-wide keyboard event interception
- **Hotkey mapping**: Maps key combinations to shell commands with full modifier support
- **Process-specific bindings**: Different commands for different applications
- **Key forwarding/remapping**: Remap keys to other key combinations
- **Modal system**: Multi-level modal hotkey system with capture modes
- **Configuration file**: Compatible with original skhd configuration format
- **Hot reloading**: Automatic config reload on file changes

### Command-Line Interface
- `--version` / `-v` - Display version information
- `--help` - Show usage information
- `-c` / `--config` - Specify config file location
- `-o` / `--observe` - Observe mode (echo keycodes and modifiers)
- `-V` / `--verbose` - Debug output with detailed logging
- `-k` / `--key` - Synthesize keypress for testing
- `-t` / `--text` - Synthesize text input
- `-r` / `--reload` - Signal reload to running instance
- `-h` / `--no-hotload` - Disable hotloading

### Service Management
- `--install-service` - Install launchd service
- `--uninstall-service` - Remove launchd service
- `--start-service` - Start as service
- `--restart-service` - Restart service
- `--stop-service` - Stop service
- PID file management (`/tmp/skhd_$USER.pid`)
- Service logging (`/tmp/skhd_$USER.log`)

### Advanced Features
- **Blacklisting**: Exclude applications from hotkey processing
- **Shell customization**: Use custom shell for command execution
- **Left/right modifier distinction**: Support for lcmd, rcmd, lalt, ralt, etc.
- **Special key support**: Function keys, media keys, arrow keys
- **Passthrough mode**: Execute command but still send keypress to application
- **Config includes**: Load additional config files with `.load` directive
- **Comprehensive error reporting**: Detailed error messages with line numbers

## Installation

### Build from Source

```bash
# Clone the repository
git clone https://github.com/yourusername/skhd.zig
cd skhd.zig

# Build in release mode
zig build -Doptimize=ReleaseFast

# Install (copy to /usr/local/bin)
sudo cp zig-out/bin/skhd /usr/local/bin/
```

### Build Commands

```bash
# Build the project (creates executable in zig-out/bin/)
zig build

# Build in release mode with optimizations
zig build -Doptimize=ReleaseFast

# Run the application
zig build run

# Run with arguments
zig build run -- -V -c ~/.config/skhd/skhdrc

# Run tests
zig build test
```

## Configuration

### Default Configuration Locations

skhd.zig looks for configuration files in the following order:
1. Path specified with `-c` flag
2. `~/.config/skhd/skhdrc`
3. `~/.skhdrc`

### Configuration Syntax

The configuration syntax is fully compatible with the original skhd. Here's a comprehensive overview:

#### Basic Hotkey Syntax

```bash
# Basic format: modifier - key : command
cmd - a : echo "Command+A pressed"

# Multiple modifiers
cmd + shift - t : open -a Terminal

# Different modifier combinations
ctrl - h : echo "Control+H"
alt - space : echo "Alt+Space"
shift - f1 : echo "Shift+F1"
```

#### Supported Modifiers

```bash
# Basic modifiers
cmd     # Command key
ctrl    # Control key  
alt     # Alt/Option key
shift   # Shift key
fn      # Function key

# Left/right specific modifiers
lcmd, rcmd    # Left/right Command
lctrl, rctrl  # Left/right Control
lalt, ralt    # Left/right Alt
lshift, rshift # Left/right Shift

# Special modifier combinations
hyper   # cmd + shift + alt + ctrl
meh     # shift + alt + ctrl
```

#### Special Keys

```bash
# Navigation keys
cmd - left : echo "Left arrow"
cmd - right : echo "Right arrow"
cmd - up : echo "Up arrow"
cmd - down : echo "Down arrow"

# Special keys
cmd - space : echo "Space"
cmd - return : echo "Return/Enter"
cmd - tab : echo "Tab"
cmd - escape : echo "Escape"
cmd - delete : echo "Delete/Backspace"
cmd - home : echo "Home"
cmd - end : echo "End"
cmd - pageup : echo "Page Up"
cmd - pagedown : echo "Page Down"

# Function keys
cmd - f1 : echo "F1"
cmd - f12 : echo "F12"

# Media keys
sound_up : echo "Volume Up"
sound_down : echo "Volume Down"
mute : echo "Mute"
brightness_up : echo "Brightness Up"
brightness_down : echo "Brightness Down"
```

#### Process-Specific Bindings

```bash
# Different commands for different applications
cmd - n [
    "terminal" : echo "New terminal window"
    "safari"   : echo "New safari window"  
    "finder"   : echo "New finder window"
    *          : echo "New window in other apps"
]

# Unbind keys in specific applications
cmd - q [
    "terminal" ~  # Unbind Cmd+Q in Terminal (key is ignored)
    *          : echo "Quit other applications"
]
```

#### Key Forwarding/Remapping

```bash
# Simple key remapping
ctrl - h | left        # Remap Ctrl+H to Left Arrow
ctrl - j | down        # Remap Ctrl+J to Down Arrow

# Process-specific forwarding
home [
    "kitty"    ~           # Let kitty handle Home key natively
    "terminal" ~           # Let terminal handle Home key natively  
    *          | cmd - left # In other apps, send Cmd+Left instead
]

# Complex forwarding with modifiers
ctrl - backspace [
    "kitty"   ~                # Let kitty handle it
    *         | alt - backspace # In other apps, send Alt+Backspace
]
```

#### Modal System

```bash
# Declare a mode
:: window : echo "Entering window mode"

# Switch to mode
cmd - w ; window

# Commands in mode (no modifiers needed)
window < h : echo "Focus left window"
window < j : echo "Focus down window"  
window < k : echo "Focus up window"
window < l : echo "Focus right window"
window < escape ; default  # Return to default mode

# Mode with capture (@) - captures ALL keypresses
:: vim @ : echo "Vim mode activated"
cmd - v ; vim

# In capture mode, even unbound keys are captured
vim < i : echo "Insert mode"
vim < escape ; default
```

#### Passthrough Mode

```bash
# Execute command but still send keypress to application
cmd - p -> : echo "This runs but Cmd+P still goes to app"
```

#### Configuration Directives

```bash
# Use custom shell
.shell "/bin/zsh"

# Blacklist applications (hotkeys won't work in these apps)
.blacklist [
    "loginwindow"
    "screensaver"
    "VMware Fusion"
]

# Load additional config files
.load "~/.config/skhd/extra.skhdrc"

# Define process groups for reuse (New in skhd.zig!)
.define terminal_apps ["kitty", "wezterm", "terminal"]
.define native_apps ["kitty", "wezterm", "chrome", "whatsapp"]
```

## Usage Examples

### Window Management

```bash
# Focus windows
cmd - h : yabai -m window --focus west
cmd - j : yabai -m window --focus south  
cmd - k : yabai -m window --focus north
cmd - l : yabai -m window --focus east

# Move windows
cmd + shift - h : yabai -m window --swap west
cmd + shift - j : yabai -m window --swap south
cmd + shift - k : yabai -m window --swap north
cmd + shift - l : yabai -m window --swap east

# Switch spaces
cmd - 1 : yabai -m space --focus 1
cmd - 2 : yabai -m space --focus 2
```

### Application Launching

```bash
# Quick app launching
alt - return : open -a Terminal
alt - b : open -a Safari
alt - f : open -a Finder
alt - c : open -a "Visual Studio Code"
```

### Text Editing Enhancements

```bash
# Linux-style editing in macOS
ctrl - left [
    "terminal" ~           # Let terminal handle it
    "kitty" ~             # Let kitty handle it  
    *       | alt - left  # In other apps, word left
]

ctrl - right [
    "terminal" ~           # Let terminal handle it
    "kitty" ~             # Let kitty handle it
    *       | alt - right # In other apps, word right
]

# Home/End key fixes  
home [
    "terminal" ~          # Let terminal handle it
    *          | cmd - left # In other apps, go to line start
]

end [
    "terminal" ~           # Let terminal handle it  
    *          | cmd - right # In other apps, go to line end
]
```

### Using Process Groups (New in skhd.zig!)

```bash
# Define reusable process groups
.define terminal_apps ["kitty", "wezterm", "terminal", "iterm2"]
.define browser_apps ["chrome", "safari", "firefox", "edge"]
.define native_apps ["kitty", "wezterm", "chrome", "whatsapp"]

# Use process groups to reduce duplication
ctrl - backspace [
    @terminal_apps ~       # All terminal apps handle natively
    *              | alt - backspace
]

ctrl - left [
    @terminal_apps ~       # All terminal apps handle natively
    *              | alt - left
]

# Multiple groups can be used
home [
    @native_apps ~         # Native apps handle home key
    *            | cmd - left
]

shift - home [
    @native_apps ~
    @browser_apps ~        # Both native and browser apps
    *             | cmd + shift - left
]
```

### Modal Workflow Example

```bash
# Window management mode
:: window : echo ">>> Window Mode"
cmd - w ; window

window < h : yabai -m window --focus west
window < j : yabai -m window --focus south
window < k : yabai -m window --focus north  
window < l : yabai -m window --focus east

# Resize submode
window < r ; resize
:: resize : echo ">>> Resize Mode"  
resize < h : yabai -m window --resize left:-20:0
resize < l : yabai -m window --resize right:20:0
resize < escape ; window

window < escape ; default
```

## Running as Service

```bash
# Install service (creates ~/Library/LaunchAgents/com.koekeishiya.skhd.plist)
skhd --install-service

# Start service
skhd --start-service

# Restart service (useful after config changes)
skhd --restart-service

# Stop service
skhd --stop-service

# Uninstall service
skhd --uninstall-service
```

## Testing and Debugging

```bash
# Test key combinations (observe mode)
skhd -o

# Verbose logging
skhd -V

# Test specific keypress
skhd -k "cmd + shift - t"

# Test text synthesis
skhd -t "hello world"

# Reload config of running instance
skhd -r
```

## Compatibility

This Zig implementation is fully compatible with original skhd configuration files. You can use your existing `.skhdrc` files without modification.

Key differences from the original:
- Written in Zig for better memory safety and performance
- Improved error reporting with detailed line numbers
- Enhanced logging system
- More robust event handling
- Fixed key repeating issues with event forwarding

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run tests: `zig build test`
5. Submit a pull request

## Publishing & Releases

### Release Process

1. **Update Version**: Run `./scripts/bump-version.sh` to update the version number
2. **Update Changelog**: Edit `CHANGELOG.md` with the changes for the new version
3. **Commit Changes**: Commit both the version and changelog updates
4. **Create Tag**: Create an annotated tag: `git tag -a v0.0.X -m "Release v0.0.X"`
5. **Push**: Push commits and tag: `git push origin main && git push origin v0.0.X`
6. **Create Release**: GitHub Actions will automatically:
   - Build binaries for both architectures
   - Upload artifacts to the release
   - Update the Homebrew tap formula

### GitHub Actions

The project uses GitHub Actions for:
- **CI**: Runs tests on every push and pull request
- **Releases**: Automatically builds and uploads binaries for:
  - ARM64 (Apple Silicon) on `macos-latest`
  - x86_64 (Intel) on `macos-13`
- **Homebrew Updates**: Automatically updates the tap formula (requires `HOMEBREW_TAP_TOKEN` secret)

### Binary Distribution

Pre-built binaries are available for each release:
- `skhd-arm64-macos.tar.gz` - For Apple Silicon Macs (M1/M2/M3)
- `skhd-x86_64-macos.tar.gz` - For Intel Macs

These binaries are automatically built and uploaded to GitHub Releases when a new tag is pushed.

### Homebrew

A Homebrew tap is available for easy installation:
```bash
brew tap jackielii/homebrew-tap
brew install skhd-zig
```

## License

This project maintains compatibility with the original skhd license.
