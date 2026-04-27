# SKHD in Zig

Simple Hotkey Daemon for macOS, ported from [skhd](https://github.com/koekeishiya/skhd) to Zig.

This implementation is **fully compatible with the original skhd configuration format** - your existing `.skhdrc` files will work without modification. Additionally, it includes new features like process groups and command definitions (`.define`) for cleaner configs, key forwarding/remapping, and improved error reporting.

📋 [View Changelog](CHANGELOG.md)

## Installation

### Homebrew

The easiest way to install skhd.zig:

```bash
brew install jackielii/tap/skhd-zig
```

> Upgrading from 0.0.17 or earlier? See [docs/UPGRADING.md](docs/UPGRADING.md). The 0.0.18 release switches to an `.app` bundle to keep accessibility permissions working on macOS Tahoe; one-time re-grant is required.

### Pre-built Binaries

Apple Silicon only (Intel builds paused as of v0.0.19; build from source for Intel):

- `skhd-arm64-macos.tar.gz` (contains `skhd.app`)

Extract and install:

```bash
tar -xzf skhd-arm64-macos.tar.gz
mv skhd.app /Applications/
# Optional: expose the CLI on your PATH
sudo ln -sfn /Applications/skhd.app/Contents/MacOS/skhd /usr/local/bin/skhd
```

Then grant accessibility (see [Granting Accessibility](#granting-accessibility) below).

### Development Builds from GitHub Actions

If you need builds with different optimization levels (Debug, ReleaseSafe, ReleaseFast, ReleaseSmall), you can download them directly from GitHub Actions:

1. Go to the [CI workflow](https://github.com/jackielii/skhd.zig/actions/workflows/ci.yml?query=branch%3Amain) in Actions tab. Filter by branch `main`.
2. Click on the latest successful run
3. Scroll down to the "Artifacts" section
4. Download the build artifact for your desired optimization level:
   - `skhd-Debug` - Debug build with full debugging symbols
   - `skhd-ReleaseSafe` - Release build with safety checks and runtime safety
   - `skhd-ReleaseFast` - Optimized for performance (recommended for daily use)
   - `skhd-ReleaseSmall` - Optimized for binary size

### Build from Source

```bash
# Clone the repository
git clone https://github.com/jackielii/skhd.zig
cd skhd.zig

# Build the .app bundle and code-sign it
# (required for Accessibility to persist on macOS Tahoe / Sequoia)
zig build sign-app -Doptimize=ReleaseFast

# Install: symlink the bundle into /Applications, expose the CLI
ln -sfn "$(pwd)/zig-out/skhd.app" /Applications/skhd.app
sudo ln -sfn /Applications/skhd.app/Contents/MacOS/skhd /usr/local/bin/skhd
```

For quick dev iteration without the bundle wrapper, `zig build` still produces a bare binary at `zig-out/bin/skhd`. The `.app` is only needed for the System Settings → Accessibility picker.

The first run of `zig build sign-app` creates a self-signed `skhd-cert` certificate in your login keychain. See [docs/CODE_SIGNING.md](docs/CODE_SIGNING.md) for details and troubleshooting.

### Granting Accessibility

skhd captures keyboard events via macOS Core Graphics, which requires Accessibility permission:

1. Open **System Settings → Privacy & Security → Accessibility**
2. Click **`+`**, navigate to `/Applications/skhd.app`, add it
3. Toggle the entry on
4. Run `skhd --restart-service` (or `skhd --start-service` if not yet running)

You only need to do this once. The bundle's stable identifier (`com.jackielii.skhd`) means TCC entries persist across rebuilds and `brew upgrade`.

## Running as Service

After installation, run skhd as a service for automatic startup:

```bash
# Install and start the service
skhd --install-service
skhd --start-service

# Check if skhd is running properly
skhd --status

# Restart service (useful for restarting after giving accessibility permissions)
skhd --restart-service

# Stop service
skhd --stop-service

# Uninstall service
skhd --uninstall-service
```

The service will:
- Start automatically on login
- Write logs to `~/Library/Logs/skhd.log`
- Use your config from `~/.config/skhd/skhdrc` or `~/.skhdrc`
- Automatically reload on config changes

## Features

### Core Functionality

- **Event capturing**: Uses macOS Core Graphics Event Tap for system-wide keyboard event interception
- **Hotkey mapping**: Maps key combinations to shell commands with full modifier support
- **Process-specific bindings**: Different commands for different applications
- **Key forwarding/remapping**: Remap keys to other key combinations
- **Modal system**: Multi-level modal hotkey system with capture modes
- **Configuration file**: Compatible with original skhd configuration format
- **Hot reloading**: Automatic config reload on file changes

### Additional Features (New in skhd.zig!)

- **Process groups**: Define named groups of applications for cleaner configs
- **Command definitions**: Define reusable commands with placeholders to reduce repetition
- **Key Forwarding**: Forward / remap key binding to another key binding
- **Mode activation with command**: Execute a command when switching modes (e.g., `cmd - w ; window : echo "Window mode"`)

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
- `-P` / `--profile` - Profile event handling (Debug and ReleaseSafe builds only)

### Service Management

- `--install-service` - Install launchd service
- `--uninstall-service` - Remove launchd service
- `--start-service` - Start as service
- `--restart-service` - Restart service
- `--stop-service` - Stop service
- `--status` - Daemon health (PID + event-tap status)
- PID file management (`/tmp/skhd_$USER.pid`)
- Service logging (`~/Library/Logs/skhd.log`)

### Advanced Features

- **Blacklisting**: Exclude applications from hotkey processing
- **Shell customization**: Use custom shell for command execution
- **Left/right modifier distinction**: Support for lcmd, rcmd, lalt, ralt, etc.
- **Special key support**: Function keys, media keys, arrow keys
- **Passthrough mode**: Execute command but still send keypress to application
- **Config includes**: Load additional config files with `.load` directive
- **Comprehensive error reporting**: Detailed error messages with line numbers

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

## Configuration & Usage

### Default Configuration Locations

skhd.zig looks for configuration files in the following order:

1. Path specified with `-c` flag
2. `~/.config/skhd/skhdrc`
3. `~/.skhdrc`

The configuration syntax is fully compatible with the original skhd. See [SYNTAX.md](SYNTAX.md) for the complete syntax reference and grammar.

### Configuration Directives

```bash
# Use custom shell (skips interactive shell overhead)
.shell "/bin/dash"

# Blacklist applications (skip hotkey processing)
.blacklist [
    "dota2"
    "Microsoft Remote Desktop"
    "VMware Fusion"
]

# Load additional config files
.load "~/.config/skhd/extra.skhdrc"

# Define process groups for reuse (New in skhd.zig!)
.define terminal_apps ["kitty", "wezterm", "terminal"]
.define native_apps ["kitty", "wezterm", "chrome", "whatsapp"]
.define browser_apps ["chrome", "safari", "firefox", "edge"]

# Define reusable commands with placeholders (New in skhd.zig!)
.define yabai_focus : yabai -m window --focus {{1}} || yabai -m display --focus {{1}}
.define yabai_swap : yabai -m window --swap {{1}} || (yabai -m window --display {{1}} && yabai -m display --focus {{1}})
.define toggle_app : open -a "{{1}}" || osascript -e 'tell app "{{1}}" to quit'
.define resize_window : yabai -m window --resize {{1}}:{{2}}:{{3}}
.define toggle_scratchpad : yabai -m window --toggle {{1}} || open -a "{{2}}"
```

### Basic Hotkey Syntax

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

### Supported Modifiers

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

### Special Keys

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

### Process-Specific Bindings

```bash
# Different commands for different applications
cmd - n [
    "terminal" : echo "New terminal window"
    "safari"   : echo "New safari window"
    "finder"   : echo "New finder window"
    *          : echo "New window in other apps"
]
```

### Key Forwarding/Remapping

```bash
# Keyboard layout fixes
0xa | 0x32             # UK keyboard § to `
shift - 0xa | shift - 0x32  # shift - § to ~

# Function key navigation (for laptop keyboards)
fn - j | down
fn - k | up
fn - h | left
fn - l | right

# When you have cmd - number for yabai spaces,
# and you still want the cmd - number to work in applications
ctrl - 1 | cmd - 1
ctrl - 2 | cmd - 2
ctrl - 3 | cmd - 3
```

### Passthrough Mode

```bash
# Execute command but still send keypress to application
cmd - p -> : echo "This runs but Cmd+P still goes to app"
```

### Modal Workflow with Visual Indicators

```bash
# Window management mode with anybar visual indicator
# Install anybar: brew install --cask anybar

# Define window management mode for warp/stack operations
# Use anybar to indicate the mode: https://github.com/tonsky/AnyBar
:: winmode @ : echo -n "red" | nc -4u -w0 localhost 1738
:: default : echo -n "hollow" | nc -4u -w0 localhost 1738

# Enter window mode with meh + m (shift + alt + ctrl + m)
meh - w ; winmode
winmode < escape ; default
winmode < meh - w ; default

# Alternative: Enter window mode AND show notification (New in skhd.zig!)
# This executes the command when switching to the mode
# It allows for different commands to execute and switch to another mode
meh - w ; winmode : osascript -e 'display notification "Window mode active" with title "skhd"'
winmode < escape ; default : osascript -e 'display notification "Normal mode" with title "skhd"'

# Focus operations - basic hjkl for focus
winmode < h : yabai -m window --focus west || yabai -m display --focus west
winmode < j : yabai -m window --focus south || yabai -m display --focus south
winmode < k : yabai -m window --focus north || yabai -m display --focus north
winmode < l : yabai -m window --focus east || yabai -m display --focus east

# Move operations - shift + hjkl for moving
winmode < shift - h : yabai -m window --move rel:-80:0
winmode < shift - j : yabai -m window --move rel:0:80
winmode < shift - k : yabai -m window --move rel:0:-80
winmode < shift - l : yabai -m window --move rel:80:0

# Warp operations - alt + shift + hjkl for warping
winmode < alt + shift - h : yabai -m window --warp west
winmode < alt + shift - j : yabai -m window --warp south
winmode < alt + shift - k : yabai -m window --warp north
winmode < alt + shift - l : yabai -m window --warp east

# Stack operations - ctrl + shift + hjkl for stacking
winmode < ctrl + shift - h : yabai -m window --stack west
winmode < ctrl + shift - j : yabai -m window --stack south
winmode < ctrl + shift - k : yabai -m window --stack north
winmode < ctrl + shift - l : yabai -m window --stack east

# Stack management shortcuts
winmode < s : yabai -m window --insert stack  # Toggle stack mode
winmode < u : yabai -m window --toggle float; yabai -m window --toggle float  # Unstack window
winmode < n : yabai -m window --focus stack.next  # Navigate stack next
winmode < p : yabai -m window --focus stack.prev  # Navigate stack prev

# Resize submode
winmode < r ; resize
:: resize @ : echo -n "orange" | nc -4u -w0 localhost 1738
resize < h : yabai -m window --resize left:-20:0
resize < j : yabai -m window --resize bottom:0:20
resize < k : yabai -m window --resize top:0:-20
resize < l : yabai -m window --resize right:20:0
resize < escape ; winmode
```

### Window Management Example

```bash
# Focus windows using command definitions (New in skhd.zig!)
cmd - h : @yabai_focus("west")
cmd - j : @yabai_focus("south")
cmd - k : @yabai_focus("north")
cmd - l : @yabai_focus("east")

# Move/swap windows using command definitions
cmd + shift - h : @yabai_swap("west")
cmd + shift - j : @yabai_swap("south")
cmd + shift - k : @yabai_swap("north")
cmd + shift - l : @yabai_swap("east")

# Resize windows using command definitions
cmd + ctrl - h : @resize_window("left", "-20", "0")
cmd + ctrl - l : @resize_window("right", "20", "0")

# Switch spaces
cmd - 1 : yabai -m space --focus 1
cmd - 2 : yabai -m space --focus 2
```

### Application Launching Example

```bash
# Quick app launching (traditional way)
alt - return : open -a Terminal
alt - b : open -a Safari

# Toggle apps using command definitions (New in skhd.zig!)
alt - f : @toggle_app("Finder")
alt - c : @toggle_app("Visual Studio Code")

# Scratchpad apps with yabai (New in skhd.zig!)
# In yabairc: yabai -m rule --add app="^YouTube Music$" scratchpad=music grid=11:11:1:1:9:9
alt - m : @toggle_scratchpad("music", "YouTube Music")
alt - n : @toggle_scratchpad("notes", "Notes")
```

### Text Editing Enhancements Example

```bash
# Linux-style word navigation and deletion
ctrl - backspace [
    @native_apps ~         # Terminal apps handle natively
    *            | alt - backspace  # Other apps: delete word
]

ctrl - left [
    @native_apps ~         # Terminal apps handle natively
    *            | alt - left       # Other apps: move word left
]

ctrl - right [
    @native_apps ~         # Terminal apps handle natively
    *            | alt - right      # Other apps: move word right
]

# Home/End key behavior (with shift for selection)
home [
    @native_apps ~         # Terminal apps handle natively
    *            | cmd - left       # Other apps: line start
]

shift - home [
    @native_apps ~         # Terminal apps handle natively
    *            | cmd + shift - left  # Other apps: select to line start
]

# Ctrl+Home/End for document navigation
ctrl - home [
    @native_apps ~         # Terminal apps handle natively
    *            | cmd - up         # Other apps: document start
]

ctrl - end [
    @native_apps ~         # Terminal apps handle natively
    *            | cmd - down       # Other apps: document end
]
```


## Device-aware remapping (`.device` + `.remap`)

`.remap` rewrites keys at the HID layer per device. Two forms:

**Colon form** — instant 1:1 swap, applied via `hidutil` (no daemon needed):

```
# Declare the device once, by VendorID/ProductID.
.device builtin { vendor: 0x05AC, product: 0x0342 }

# UK ISO MacBook: make § (top-left) act as the ISO grave key, so it types `.
.remap non_us_backslash [device builtin] : grave
```

**Block form** — tap-hold semantics (caps_lock → tap=escape / hold=ctrl,
space → fn_layer, etc.). Goes through `skhd-grabber` (see below) because
hidutil can't do tap vs. hold.

```
.remap caps_lock [device builtin] {
    tap             : escape
    hold            : lctrl
    timeout         : 120ms
    permissive_hold : on
    retro_tap       : off
}

.remap space [device builtin] {
    tap             : space
    hold            : fn_layer
    timeout         : 200ms
    permissive_hold : on
    retro_tap       : on
}
```

Source/destination names use HID-standard physical-position naming
(layout-independent) — different from the macOS virtual-keycode names
shown by `skhd -o`. Run `skhd --grabber-status` or check
`src/HidKeyMap.zig` for the full list. Common: `a-z`, `0-9`, `caps_lock`,
`escape`, `space`, `return`, `tab`, `backspace`, `lctrl`, `lshift`, `lalt`,
`lcmd` (and `r*` variants), `f1..f20`, `minus`, `equal`, `lbracket`,
`rbracket`, `backslash`, `semicolon`, `quote`, `grave`, `comma`,
`period`, `slash`, `non_us_backslash`.

## skhd-grabber: caps_lock-class tap-hold

macOS's user-level event tap can't see caps_lock or rewrite it cleanly
without LED toggle artifacts. Block-form `.remap` rules go through a
small system daemon (`skhd-grabber`) that runs as root, seizes the
matched keyboard via IOHIDManager, and injects through the Karabiner
DriverKit virtual HID device.

### Install

```bash
# Single command — installs the per-user agent, then prompts to install
# the system grabber if your config has caps_lock-class rules and the
# target device is connected.
skhd --install-service
```

If you want to install the grabber separately (or the prompt didn't fire):

```bash
sudo skhd --install-grabber
```

Diagnostic walk-through of every prerequisite:

```bash
skhd --grabber-status
```

### Dependencies

`skhd-grabber` requires the **Karabiner DriverKit VirtualHIDDevice**
extension to inject HID events:

  https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice

Install the dext, approve it in System Settings → Privacy & Security,
then run `skhd --install-grabber`.

### Mac Studio / external keyboard only

If you share one config across a laptop and a desktop, `.remap`
block-form rules targeting the laptop's built-in keyboard simply
don't fire on the desktop — `--install-service` and the agent both
detect that the target device isn't connected and skip the grabber
entirely on that machine. No need to install the grabber or the dext
on a machine that doesn't need them.

### Caveats

- **Signing**: setting `HIDKeyboardCapsLockDelayOverride` requires an
  Apple Developer ID signature. Unsigned builds fall back to a reactive
  workaround: the grabber reads the OS caps_lock state via
  `CGEventSourceFlagsState` and, when Apple's firmware-level toggle
  fires, injects a vhidd caps_lock toggle to flip it back. Works
  cleanly in practice (no LED flash); see `src/grabber/HidSeize.zig`
  for the rationale.
- **Coexistence**: `skhd-grabber` and Karabiner-Elements both want
  exclusive seize on the same keyboard. If you're running Karabiner-
  Elements, disable its `karabiner_grabber` daemon
  (`sudo launchctl bootout system/org.pqrs.service.daemon.karabiner_grabber`)
  before starting `skhd-grabber`.
- **F-row behavior**: with macOS's "Use F1, F2..." setting **off**
  (default), the grabber translates F1..F12 keyboard events to the
  appropriate Consumer / Apple-Vendor media events (volume,
  brightness, mission control, …) so the F-row stays "media keys"
  under seize.

## Testing and Debugging

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

However, command output will be shown if verbose flag is specified in release builds.

This is a trade-off between convenience and performance:

- **Performance mode** (default): Command output is discarded for faster execution
- **Verbose mode** (`-V`): Command output is preserved, which may add slight overhead but helps with trouble shooting

To debug hotkey events and see detailed logging:

```bash
# Verbose logging for troubleshooting config issues
# Note: In release builds, verbose mode only shows errors and warnings.
# To see debug/info logs, use a debug build:
zig build run -- -V
```

**Performance:** The event loop is allocation-free in release builds, ensuring consistent low-latency hotkey processing.

### Testing Commands

```bash
# Test key combinations and hex code (observe mode)
skhd -o

# Profile event handling (show after CTRL+C)
# Note: Profiling works in Debug and ReleaseSafe builds only
zig build && ./zig-out/bin/skhd -P
# or for production debugging:
zig build -Doptimize=ReleaseSafe && ./zig-out/bin/skhd -P

# Test specific keypress
skhd -k "cmd + shift - t"

# Test text synthesis
skhd -t "hello world"

# Reload config of running instance
skhd -r

# Debug memory allocations with real-time tracking
zig build alloc -- -V
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run tests: `zig build test`
5. Submit a pull request

## License

This project maintains compatibility with the original skhd license.
