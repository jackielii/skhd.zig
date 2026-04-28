# SKHD in Zig

Simple Hotkey Daemon for macOS, ported from [skhd](https://github.com/koekeishiya/skhd) to Zig.

This implementation is **fully compatible with the original skhd configuration format** - your existing `.skhdrc` files will work without modification. Additionally, it includes new features like process groups and command definitions (`.define`) for cleaner configs, key forwarding/remapping, and improved error reporting.

📋 [View Changelog](CHANGELOG.md)

## v0.1.0-alpha — QMK-style keyboard remapping

skhd.zig now ships a system-level **grabber daemon** that enables remapping the user-session event tap can't reach. New directives:

- **`.remap caps_lock [device <alias>] : escape`** — instant 1:1 swap, applied via `hidutil` (no daemon).
- **`.remap key [device <alias>] { tap: …, hold: …, … }`** — tap vs. hold on the same key (e.g. `caps_lock` tapped = escape, held = control). Routed through `skhd-grabber` (root LaunchDaemon) which seizes the keyboard at the IOKit/HID level via Karabiner DriverKit. Required for caps-lock-class rules and modifier-as-hold rules that `hidutil` silently drops.
- **Layer holds** — `hold` can target a skhd mode instead of a key, so holding the source key activates the layer for the duration of the hold (e.g. hold `space` to enter `fn_layer`, where `fn_layer < 1 | f1` rebinds the number row to F-keys).
- **`.device <alias> { vendor: 0x…, product: 0x… }`** — scope rules to a specific keyboard, so one config does the right thing on each machine.

**Install the alpha** (Homebrew formula stays on 0.0.24 until v0.1.0 stable; eager testers download from GitHub releases):

```bash
gh release download v0.1.0-alpha --repo jackielii/skhd.zig --pattern '*-arm64-macos.tar.gz'
tar -xzf skhd-arm64-macos.tar.gz -C /tmp
sudo mv /tmp/skhd.app /Applications/
/Applications/skhd.app/Contents/MacOS/skhd --install-service
```

`--install-service` registers the agent, auto-installs the Karabiner DriverKit pkg if your config has tap-hold rules, prompts for the grabber install via sudo, and pops Accessibility + Input Monitoring dialogs in sequence — one click each.

**Try it out** — drop this into `~/.config/skhd/skhdrc` (replace the vendor/product IDs with your own — find them via `skhd --grabber-status` once installed, or System Information → USB):

```bash
# 1. Declare the keyboard you want to remap.
.device builtin { vendor: 0x05AC, product: 0x0342 }

# 2. caps_lock acts like ctrl when held, escape when tapped.
.remap caps_lock [device builtin] {
    tap             : escape
    hold            : lctrl
    timeout         : 120ms
    permissive_hold : on
}

# 3. Hold space to enter a "function layer", release to exit.
:: fn_layer @
.remap space [device builtin] {
    tap             : space
    hold            : fn_layer
    timeout         : 200ms
    retro_tap       : on
}

# 4. While the layer is held, number row → F-row.
fn_layer < 1 | f1
fn_layer < 2 | f2
fn_layer < 3 | f3
# … etc
```

Save, then `skhd --restart-service`. Tap `caps_lock` → escape. Hold `caps_lock` + `c` → ctrl-c. Hold `space` then press `1` → F1.

**Verify** with `skhd --status` (single command shows the agent, grabber, dext, and TCC state) or `skhd --grabber-status` (drills into the grabber-side dependency chain). **Roll back** with `skhd --uninstall-service` (it prints follow-up `sudo skhd --uninstall-grabber` instructions if anything's still on disk).

**Larger real-world example** — my own `builtin.skhdrc`, which makes a MacBook built-in keyboard behave like a [Keebio Convolution](https://keeb.io/products/convolution-65xt-keyboard) running custom QMK firmware (caps_lock as ctrl/escape, space as fn_layer, fn_layer < hjkl as arrows, number row → F-row under layer, etc.):

- skhd config: <https://gist.github.com/jackielii/9d24095af57ec35df0d46d38bbbe0449>
- QMK source-of-truth keymap it mirrors: <https://github.com/jackielii/qmk_firmware/blob/jackie/keyboards/keebio/convolution/keymaps/jackie/keymap.c>

See [skhd-grabber](#skhd-grabber-caps_lock-class-tap-hold) below for the full architecture, [SYNTAX.md](SYNTAX.md) for the new directive grammar, and the [v0.1.0-alpha CHANGELOG entry](CHANGELOG.md#010-alpha---2026-04-28) for everything that changed.

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
# Single command — installs the per-user agent and, if your config has
# caps_lock-class rules with a connected target device, prompts (Y/n)
# to install the system grabber via sudo. The same prompt also auto-
# downloads + installs the Karabiner DriverKit .pkg if it's missing
# and writes the launchd plist for its userland daemon (the .pkg's
# postinstall is a no-op `killall`, so we wire up launchd ourselves —
# but we skip it cleanly when Karabiner-Elements is already managing
# that label via SMAppService).
skhd --install-service
```

After the grabber install succeeds the agent triggers the **Input
Monitoring** approval dialog. Granting it to `skhd.app` covers the
grabber too: both binaries are signed with the same bundle ID and
the grabber runs from inside `skhd.app/Contents/MacOS/`, so TCC
bundle-keys the grant — one click, both processes covered. No
manual "add `/usr/local/libexec/skhd-grabber` to Input Monitoring"
step.

If the prompt didn't fire (e.g. you added `.remap` rules later) or
you want to install the grabber separately:

```bash
sudo skhd --install-grabber
```

Diagnostic walk-through of every prerequisite (dext, VHIDD daemon,
grabber plist + process, IPC socket):

```bash
skhd --grabber-status
```

### Dependencies

`skhd-grabber` requires the **Karabiner DriverKit VirtualHIDDevice**
extension to inject HID events. The agent's install flow auto-installs
the pinned version (currently v6.14.0; sha-256 verified) the first time
you run `--install-service`, so most users never touch this directly.
If you'd rather install it ahead of time:

```bash
skhd --install-dext     # downloads + installs the pkg, writes the
                        # VHIDD daemon launchd plist (or skips if
                        # Karabiner-Elements is already handling it)
```

Upstream releases: https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice

After install, macOS will prompt you to approve the system extension
in **System Settings → General → Login Items & Extensions → Driver
Extensions**.

### Uninstall

```bash
skhd --uninstall-service       # removes the LaunchAgent
sudo skhd --uninstall-grabber  # removes skhd-grabber + the VHIDD
                               # daemon launchd plist we wrote
```

`--uninstall-service` prints any follow-up commands (the grabber
isn't auto-removed because it's a separate sudo step). For the
Karabiner DriverKit pkg files and the kernel-loaded dext (pqrs's
domain), run their uninstall scripts under
`/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/scripts/uninstall/`,
or toggle the dext off via System Settings → Login Items &
Extensions → Driver Extensions.

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
- **Coexistence with Karabiner-Elements**: KE registers the **same**
  VHIDD daemon launchd label (`org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon`)
  via `SMAppService.daemon`, so we share that piece — `--install-dext`
  detects KE's registration and skips writing our own plist. But the
  *grabber* layer (`karabiner_grabber` for KE, `skhd-grabber` for us)
  still wants exclusive seize on the same keyboard. If you're running
  Karabiner-Elements, disable its grabber
  (`sudo launchctl bootout system/org.pqrs.service.daemon.karabiner_grabber`)
  before starting `skhd-grabber`. `skhd --status` and
  `--install-grabber` flag this conflict when detected.
- **F-row behavior**: with macOS's "Use F1, F2..." setting **off**
  (default), the grabber translates F1..F12 keyboard events to the
  appropriate Consumer / Apple-Vendor media events (volume,
  brightness, mission control, …) so the F-row stays "media keys"
  under seize.

## Built on Karabiner-Elements

This whole feature exists because of **[Karabiner-Elements](https://karabiner-elements.pqrs.org/)** by [Takayama Fumihiko (pqrs.org)](https://pqrs.org/). The architecture, the idea, and the runtime dependency all come from there — skhd.zig is reusing pqrs's lower-level work to plug "QMK-style remapping" into a config format more skhd users already know.

### What Karabiner-Elements does (and we don't)

Karabiner-Elements is the comprehensive keyboard customizer for macOS: a polished GUI, complex modifications, simultaneous keys, parameterized rules, an event viewer, profiles, a giant community library of rule presets, and years of refinement. If you want a turnkey keyboard remapper with a UI, **install Karabiner-Elements** — it's the right tool. skhd.zig's grabber path is intentionally narrower:

- **One config format** — your existing `.skhdrc` plus a few new directives. No JSON, no GUI, no separate rule-set system.
- **Tap-hold + layer holds + 1:1 remaps + device scoping**. That's it. Anything outside that is still standard skhd hotkey territory (event-tap based, no grabber needed).
- **No menu bar app, no preferences pane, no event viewer**. Diagnostics live in `skhd --status` and `skhd --grabber-status`.

If you need anything more sophisticated than the four directives in this README, Karabiner-Elements is unequivocally the better choice.

### What we borrow (with credit)

**From Karabiner — architecture and runtime infrastructure:**

- **[Karabiner-DriverKit-VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice)** — the kernel-side system extension + userland helper daemon that lets us inject synthesized HID events on modern macOS. Apple removed kernel extension support; pqrs's DriverKit replacement is, as far as we know, the only practical route for HID injection on Big Sur and later. We auto-install the pinned version via `skhd --install-dext`, share the launchd registration if Karabiner-Elements is already there, and never modify their code. Apache-2.0 licensed; the .pkg ships under pqrs's signing identity.
- **The architectural pattern** — userland agent talks to a root daemon, which seizes HID via IOHIDManager and injects through DriverKit. Karabiner-Elements pioneered this approach on macOS; skhd-grabber is a smaller config-driven implementation of the same shape.
- **HID-standard key naming** — `caps_lock`, `non_us_backslash`, `lctrl`, etc. (layout-independent physical positions, distinct from the macOS virtual-keycode names skhd uses elsewhere) — Karabiner uses the same identifiers, so cross-referencing their docs for which name maps to which physical key is direct.

**From QMK — tap-hold parameters and defaults:**

We deliberately do *not* use Karabiner's [complex modifications](https://karabiner-elements.pqrs.org/docs/json/complex-modifications-manipulator-definition/) JSON dialect (verbose, camelCase, `to_if_alone` / `to_if_held_down` / etc.). skhd users come from a `.skhdrc` background and want a config that reads like the rest of skhd. We follow **[QMK firmware](https://github.com/qmk/qmk_firmware)**'s tap-hold model instead: snake_case keywords, the same parameter set you'd put in a QMK `config.h`, and the same defaults.

- `timeout` ↔ QMK `TAPPING_TERM` (default 200ms).
- `permissive_hold` ↔ QMK [`PERMISSIVE_HOLD`](https://github.com/qmk/qmk_firmware/blob/master/docs/tap_hold.md#permissive-hold).
- `hold_on_other_key_press` ↔ QMK [`HOLD_ON_OTHER_KEY_PRESS`](https://github.com/qmk/qmk_firmware/blob/master/docs/tap_hold.md#hold-on-other-key-press).
- `retro_tap` ↔ QMK [`RETRO_TAPPING`](https://github.com/qmk/qmk_firmware/blob/master/docs/tap_hold.md#retro-tapping).

If you've configured a custom keyboard in QMK, you already know how every knob in `.taphold` behaves — they're direct ports. **QMK's [`docs/tap_hold.md`](https://github.com/qmk/qmk_firmware/blob/master/docs/tap_hold.md) is the canonical long-form reference** for why each parameter exists and what edge cases it solves; our parser implements the same semantics rule-for-rule.

### Coexistence

skhd-grabber and Karabiner-Elements both want exclusive HID seize on the same keyboard, so running both grabbers at once doesn't work. We coexist at the **DriverKit daemon** layer (we share the same `org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon` registration; if Karabiner-Elements is installed, our `--install-dext` detects its SMAppService registration and skips writing our own plist), but you have to pick **one grabber** at a time. See the Coexistence caveat above for the disable command.

If you're switching from Karabiner-Elements to skhd.zig: keep the dext, keep the daemon, just disable `karabiner_grabber`. If you want to go back the other way: `sudo skhd --uninstall-grabber` and re-enable Karabiner-Elements.

> Thanks again to pqrs and the Karabiner-Elements community. None of this is novel work on our side — we're just packaging a narrow slice in a different config format.

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
