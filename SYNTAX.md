# SKHD Configuration Syntax Reference

This document provides a comprehensive reference for the skhd configuration syntax. The skhd.zig implementation is fully compatible with the original skhd syntax, with additional features.

## Grammar Overview

The configuration syntax follows these formal rules:

```
hotkey       = <mode> '<' <action> | <action>

mode         = 'name of mode' | <mode> ',' <mode>

action       = <trigger> '[' <proc_map_lst> ']'   | <trigger> '->' '[' <proc_map_lst> ']'
               <trigger> ':' <command>            | <trigger> '->' ':' <command>
               <trigger> ';' <mode_activation>    | <trigger> '->' ';' <mode_activation>
               <trigger> '~'

trigger      = <keysym> | <keysym> ',' <keysym> (',' <keysym>)*

keysym       = <mod> '-' <key> | <key>

mod          = 'modifier keyword' | <mod> '+' <mod>

key          = <literal> | <keycode>

literal      = 'single letter or built-in keyword'

keycode      = 'apple keyboard kVK_<Key> values (0x3C)'

proc_map_lst = * <proc_map>

proc_map     = <string> ':' <command>         | <string> '~'   |
               '*'      ':' <command>         | '*'      '~'   |
               <string> ';' <mode_activation> |
               '*'      ';' <mode_activation> |
               '@' <group_name> ':' <command> |
               '@' <group_name> '~'           |
               '@' <group_name> ';' <mode_activation>

string       = '"' 'sequence of characters' '"'

group_name   = 'process group name defined with .define directive'

command      = <shell_command> | <command_reference>

shell_command = command is executed through '$SHELL -c' and
                follows valid shell syntax. if the $SHELL environment
                variable is not set, it will default to '/bin/bash'.
                when bash is used, the ';' delimiter can be specified
                to chain commands.

                to allow a command to extend into multiple lines,
                prepend '\' at the end of the previous line.

                an EOL character signifies the end of the bind.

command_reference = '@' <identifier> |
                    '@' <identifier> '(' <arg_list> ')'

arg_list     = <string> | <string> ',' <arg_list>

mode_activation = <mode> | <mode> ':' <command>

->           = keypress is not consumed by skhd

*            = matches every application not specified in <proc_map_lst>

~            = application is unbound and keypress is forwarded per usual
```

## Hotkey Sequences

A sequence is not a separate construct — **it is a hotkey whose `trigger` has
more than one chord.** Every action form (`:`, `|`, `~`, `->`, `;`, process
lists, process groups, command references, multi-mode declarations) works on
a sequence exactly as it does on a single-chord hotkey:

```skhd
cmd - q, cmd - q : echo "double Cmd-Q"
cmd - k, cmd - c, alt - q : echo "three-chord sequence"
```

Every chord declares its own complete modifiers — nothing is inherited from
the previous chord. Modifiers may be released and re-pressed between chords,
as long as each chord's own modifiers are down when its key goes down.

```
.sequence_timeout 500ms     # default 300ms; also accepts `500` or `1s`
```

Applies between each pair of chords, not to the sequence as a whole. Global,
and must be greater than zero.

### Fallback: a shorter binding under a sequence

Like Vim's `timeoutlen`: a binding can be both a command and the prefix of a
longer one. If the sequence doesn't complete, the shorter one fires.

```
lcmd - k : yabai -m window --focus north
cmd - k, cmd - k [
    "Google Chrome" | cmd - k
]
```

| press | in Chrome | elsewhere |
| --- | --- | --- |
| `Cmd-K` | yabai, after the timeout | yabai, **instantly** |
| `Cmd-K` `Cmd-K` | Chrome's own Cmd-K | — |

Only Chrome waits: the sequence doesn't apply elsewhere, so there's nothing
to wait for. That's how a global binding and an app's native shortcut share
one chord.

Unlike Vim, skhd fires a *declared binding*, never the raw key. So a lone
safety binding still swallows the first press:

```
cmd - q, cmd - q [
    "Protected App" | cmd - q     # nothing shorter -> one Cmd-Q does nothing
]
```

`~` and `->` can't be a fallback — the chord is consumed when the sequence
starts, so there's no keypress left to release. Parse error; use `:` or `|`.

An explicit rule claims its chord in whichever application it applies to. A
chord with no applicable rule for the frontmost application is not consumed,
so a sequence can express an application-specific safety binding while every
other application keeps the operating system's normal behavior for that key:

```skhd
cmd - q, cmd - q [
    "Protected App" : echo "quit Protected App"
]
```

In `Protected App`, the first `cmd-q` starts the sequence. In every other
application this binding does not apply, so the first `cmd-q` is never
consumed and passes straight through to macOS.

**Note:** a `:` command reads to end of line, so the process-list body above
must be written on its own line(s) — `[ "Protected App" : echo "..." ]` on
one line would swallow the closing `]` as part of the shell command and fail
to parse. A `|` forward has no such problem and is fine inline:
`cmd - q, cmd - q [ "Protected App" | cmd - q ]`.

### `->` and `~` apply to the final chord only

Earlier chords in a sequence are always consumed, because when an early
chord arrives it is not yet known whether the sequence will go on to
complete. Delivering it and *also* firing the action on completion would
send the application a keypress the user never triggered. So `->`
(passthrough) and `~` (unbound) only affect the chord that completes the
binding:

```skhd
cmd - k, cmd - c -> : echo "chord 1 is consumed; chord 2 fires and passes through"
cmd - k, cmd - u ~   # chord 1 is consumed; chord 2 is unbound and passes through
```

A single-chord hotkey is its own final chord, so this changes nothing for
ordinary hotkeys.

### The uniqueness rule

Two hotkeys in a mode conflict when the same press could match both:
**identical chord lists always**, and **equal-length overlapping chords**
when their process scopes also overlap. Different lengths never conflict —
the shorter is the longer's [fallback](#fallback-a-shorter-binding-under-a-sequence).

```skhd
# ERROR — identical chords.
cmd - a : echo first
cmd - a : echo second

# ERROR — identical chords. Disjoint apps do NOT help: hotkeys are keyed by
# chords alone, so the second could only be dropped. Use one process list.
cmd - a [
    "Terminal" : echo terminal
]
cmd - a [
    "Firefox" : echo firefox
]

# OK — same key, different modifiers (alt vs lalt), disjoint apps.
alt - a [
    "Terminal" : echo terminal
]
lalt - a [
    "Firefox" : echo firefox
]

# OK — different lengths: `echo now` is the fallback. Cmd-Q in Terminal runs
# it once the timeout expires; twice runs `echo later`.
cmd - q [
    "Terminal" : echo now
]
cmd - q, cmd - q [
    "Terminal" : echo later
]

# OK — shared prefix, disambiguated by the second chord.
cmd - k, cmd - c : echo comment
cmd - k, cmd - u : echo uncomment
```

A bare hotkey (no process list) has wildcard scope, which overlaps every
explicit scope.

An expired or mismatched prefix is never replayed — its consumed key events
stay consumed, which matters for safety bindings like `cmd-q` where delayed
replay could quit an application unexpectedly.

## Mode Activation

Mode activation allows switching between different hotkey modes. The syntax is:

```
mode_activation = <mode> | <mode> ':' <command>
```

- `;` followed by a mode name switches to that mode
- An optional `:` followed by a command executes that command when switching modes

### Examples:
- `cmd - w ; window` - Switch to window mode
- `cmd - w ; window : echo "Window mode"` - Switch to window mode and execute command
- `escape ; default` - Switch back to default mode

Mode activation can be used in:
1. **Global hotkeys**: `cmd - w ; window`
2. **Process-specific bindings**: `"terminal" ; vim_mode`
3. **Process group bindings**: `@browsers ; browser_mode`

## Mode Declaration

Modes are declared using the following syntax:

```
mode_decl = '::' <name> '@' ':' <command> | '::' <name> ':' <command> |
            '::' <name> '@'               | '::' <name>

name      = desired name for this mode

@         = capture keypresses regardless of being bound to an action

command   = command is executed through '$SHELL -c'
```

## Modifiers

### Basic Modifiers
- `cmd` - Command key (⌘)
- `ctrl` - Control key (⌃)
- `alt` - Alt/Option key (⌥)
- `shift` - Shift key (⇧)
- `fn` - Function key

### Left/Right Specific Modifiers
- `lcmd`, `rcmd` - Left/right Command
- `lctrl`, `rctrl` - Left/right Control
- `lalt`, `ralt` - Left/right Alt
- `lshift`, `rshift` - Left/right Shift

### Special Modifier Combinations
- `hyper` - cmd + shift + alt + ctrl
- `meh` - shift + alt + ctrl

## Key Literals

### Navigation Keys
- `left`, `right`, `up`, `down` - Arrow keys
- `home`, `end` - Home/End keys
- `pageup`, `pagedown` - Page Up/Down

### Special Keys
- `return` - Return/Enter key
- `tab` - Tab key
- `space` - Space bar
- `backspace` - Delete/Backspace (kVK_Delete)
- `delete` - Forward Delete (kVK_ForwardDelete)
- `escape` - Escape key
- `backtick` - Backtick/Grave Accent key (`)

### Function Keys
- `f1` through `f20` - Function keys

### Media Keys
- `sound_up`, `sound_down` - Volume controls
- `mute` - Mute key
- `brightness_up`, `brightness_down` - Screen brightness
- `illumination_up`, `illumination_down` - Keyboard backlight
- `play`, `previous`, `next` - Media playback
- `rewind`, `fast` - Media navigation

### Mouse Buttons (New in skhd.zig!)
- `mouse1` - Left button
- `mouse2` - Right button
- `mouse3` - Middle button
- `mouse4` - Back / fourth button
- `mouse5` - Forward / fifth button

Used the same way as keys — combine with modifiers via `-`, or stand alone:

```bash
cmd - mouse1 : echo "cmd-click"
meh - mouse3 : open -a "Mission Control"
mouse4 -> : echo "back button"   # passthrough: still goes to the app
```

Mouse buttons can also be the **target** of a forward, so you can
synthesize a click from a key (e.g. inside a layer):

```bash
fn_layer < enter | mouse1        # in fn_layer, enter = left-click
fn_layer < space | cmd - mouse1  # cmd-click via the layer
```

⚠️ Binding `mouse1` (or any mouse button) **without** a modifier and
**without** `->` consumes every click in non-blacklisted apps and
effectively breaks the trackpad. Pair with a modifier (`cmd - mouse1`)
or use passthrough (`mouse1 -> : ...`) unless you really mean it.
Mouse-up and drag events are not captured (skhd only sees the down
edge); scroll-wheel events aren't bindable either.

## Configuration Directives

Configuration directives follow this syntax:

```
directive = '.shell' <string> |
            '.blacklist' '[' <string_list> ']' |
            '.load' <string> |
            '.sequence_timeout' <duration> |
            '.path' <string> | '.path' '[' <string_list> ']' |
            '.define' <identifier> '[' <string_list> ']' |
            '.define' <identifier> ':' <command_template> |
            '.device' <identifier> '{' <device_attrs> '}' |
            '.remap' <hid_key> <device_clause> ':' <hid_key> |
            '.remap' <hid_key> <device_clause> '{' <taphold_attrs> '}'

device_attrs    = 'vendor:' <hex>  ',' 'product:' <hex>
device_clause   = '[' 'device' <identifier> ']'
taphold_attrs   = ( <taphold_attr> )+
taphold_attr    = 'tap'                ':' <hid_key>
                | 'hold'               ':' <hid_key_or_layer>
                | 'timeout'            ':' <duration>
                | 'permissive_hold'    ':' ('on' | 'off')
                | 'hold_on_other_key_press' ':' ('on' | 'off')
                | 'retro_tap'          ':' ('on' | 'off')
hid_key_or_layer = <hid_key> | <mode_identifier>   // mode = layer hold
duration         = <integer> ('ms' | 's')?   // bare integer = milliseconds.
                                             // The unit must be on the same
                                             // line as the integer.

string_list = <string> | <string> ',' <string_list>
```

### HID key names vs macOS virtual keycodes

`.remap` / `.taphold` / `.device` operate at the **HID layer**, before
macOS translates keys through the active layout. They use HID-standard
**layout-independent physical-position** names (`caps_lock`, `lctrl`,
`non_us_backslash`, `a`–`z`, `0`–`9`, `f1`–`f20`, `minus`, `equal`,
`lbracket`, `rbracket`, `backslash`, `semicolon`, `quote`, `grave`,
`comma`, `period`, `slash`, `space`, `return`, `tab`, `escape`,
`backspace`, etc.) — different from the macOS virtual-keycode names
(`0x32`, `0x29`, etc.) that the regular `cmd - a` hotkey table uses.

Run `skhd --grabber-status` once installed (or check
`src/HidKeyMap.zig`) for the full list. These are the same identifiers
Karabiner-Elements uses, so its [docs](https://karabiner-elements.pqrs.org/docs/help/symbols-and-keycodes/)
work as a cross-reference.

### Shell Configuration
```bash
.shell "/bin/zsh"
```

### Application Blacklist
```bash
.blacklist [
    "loginwindow"
    "screensaver"
    "VMware Fusion"
]
```

### Include Files
```bash
.load "~/.config/skhd/extra.skhdrc"
```

### Extra PATH entries
At startup skhd inherits PATH from the user's login shell (`~/.zprofile`,
`~/.bash_profile`, fish's `config.fish`, etc.) so commands installed by
Homebrew and similar work out of the box. For tools whose location isn't in
the shell's PATH — most commonly version-manager shims like mise/asdf/nvm —
declare the directory with `.path`:

```bash
.path "$HOME/.local/share/mise/shims"
.path "~/.cargo/bin"

# Or list form:
.path [
    "/opt/custom/bin"
    "$HOME/bin"
]
```

`.path` entries are prepended to PATH (declaration order preserved), so they
take precedence over shell-inherited locations. `~` and `$HOME` are
expanded; other `$VAR` forms are not — use absolute paths for everything
else.

### Aliases (New in skhd.zig!)

Give a name to a modifier combination or to a single key. The name is
referenced with a `$` prefix, must start with a letter, and is expanded
at parse time (zero runtime cost).

#### Modifier alias

```bash
.alias $hyper cmd + alt + ctrl + shift
.alias $super cmd + alt

# Use as the modifier prefix of a hotkey
$hyper - h : echo "hyper-h"
$super - return : open -a Terminal.app

# Combine with other modifiers via '+'
$super + shift - h : echo "super+shift+h"

# A modifier alias may reference an earlier modifier alias
.alias $mega $super + shift + ctrl
```

#### Key alias

```bash
.alias $grave 0x32         # Hex keycode (e.g., UK keyboard backtick)
.alias $del   delete       # Literal key (carries any implicit fn/nx flag)

# Use after the dash, or standalone
ctrl - $grave : open -a Notes
$del : echo plain-delete

# A key alias may reference another key alias
.alias $tilde $grave
```

#### Rules

- Aliases must be defined before use; redefinition is an error.
- A **modifier alias** appears in modifier position only (before `-`, or
  chained with `+`). Using it as a key (`ctrl - $hyper`) is an error.
- A **key alias** appears in key position only (after `-`, or standalone).
  Using it as a modifier (`$grave - h`) is an error.
- Combining modifiers into a baked-in keysym (e.g. `.alias $foo cmd - h`)
  is not supported — define the modifier and key parts separately and
  combine them at the use site.

### Process Groups (New in skhd.zig!)
```bash
.define terminal_apps ["kitty", "wezterm", "terminal"]
.define browser_apps ["chrome", "safari", "firefox"]

# Use with @ prefix in proc_map
ctrl - left [
    @terminal_apps ~
    *              | alt - left
]
```

### Command Definitions (New in skhd.zig!)
```bash
# Simple command without placeholders
.define focus_recent : yabai -m window --focus recent

# Command with placeholders
.define yabai_focus : yabai -m window --focus {{1}} || yabai -m display --focus {{1}}
.define window_action : yabai -m window --{{1}} {{2}}

# Use with @ prefix and arguments
cmd - tab : @focus_recent
cmd - h : @yabai_focus("west")
cmd + shift - h : @window_action("swap", "west")
```

### Device Aliases (`.device`)

Declare a USB keyboard once by `vendor`/`product` ID, then reference it
by alias from `.remap` / `.taphold` rules. The alias is a config-local
name — pick anything (`builtin`, `corsair`, `keychron`, …). Find your
keyboard's IDs via System Information → USB, or run any `.remap` rule
with verbose mode to see currently-attached vendor/product pairs in
the log.

```bash
.device builtin { vendor: 0x05AC, product: 0x0342 }
.device keychron { vendor: 0x05AC, product: 0x024F }
```

A config shared between machines targeting different hardware is fine —
rules whose `[device <alias>]` doesn't match a connected device are
silently skipped on that machine. No grabber is installed on a
machine without any matching device.

### Key Remapping (`.remap` colon form)

Instant 1:1 key swap, applied via `hidutil`'s `UserKeyMapping` table.
**No daemon needed** for the colon form — works without installing
skhd-grabber. Original mappings are saved on startup and restored on
shutdown so the keyboard isn't left remapped when skhd exits.

```bash
# UK ISO MacBook: map § (top-left key, HID-named non_us_backslash) to
# the ISO grave key so it types `.
.remap non_us_backslash [device builtin] : grave

# Swap caps_lock with escape on an external keyboard.
.remap caps_lock [device keychron] : escape
```

**Limitations** (use the block form below instead for these cases):
- Cannot map `caps_lock` to a modifier — macOS's kernel layer above
  `hidutil` silently drops `caps_lock → ctrl/shift/alt/cmd`.
- Cannot do tap-hold or layer-hold semantics.

### Tap-Hold Rules (`.remap` block form)

Distinguish tap vs. hold timing on the same physical key, plus layer
holds. Routed through `skhd-grabber` (root LaunchDaemon) — see
[skhd-grabber](README.md#skhd-grabber-caps_lock-class-tap-hold) in the
README for install + permission setup.

```bash
.remap caps_lock [device builtin] {
    tap             : escape
    hold            : lctrl
    timeout         : 120ms
    permissive_hold : on
    retro_tap       : off
}
```

**Attributes** — names, semantics, and defaults all follow
[QMK firmware's tap-hold model](https://github.com/qmk/qmk_firmware/blob/master/docs/tap_hold.md)
(snake_case keywords, same parameter set as a QMK `config.h`).
We deliberately don't use Karabiner-Elements' complex-modifications
JSON dialect — skhd users want a config that reads like the rest of
`.skhdrc`, not a separate verbose camelCase format.

| Attribute | Type | Default | QMK equivalent | Description |
|---|---|---|---|---|
| `tap` | hid_key | required | `LT(layer, kc)` tap behavior | Key emitted on a quick tap (press + release within `timeout`). |
| `hold` | hid_key or mode | required | `LT(layer, kc)` hold behavior | Key emitted while held past `timeout`. A mode identifier here makes it a **layer hold** (see below). |
| `timeout` | duration | `200ms` | [`TAPPING_TERM`](https://github.com/qmk/qmk_firmware/blob/master/docs/tap_hold.md#tapping-term) | How long the source key has to be held to commit the hold action. |
| `permissive_hold` | `on`/`off` | `on` | [`PERMISSIVE_HOLD`](https://github.com/qmk/qmk_firmware/blob/master/docs/tap_hold.md#permissive-hold) | If `on`, a nested down+up of another key while the source is held also commits the hold modifier. Useful for typing Ctrl+A by holding caps for ~50ms then quickly tapping `a`. |
| `hold_on_other_key_press` | `on`/`off` | `off` | [`HOLD_ON_OTHER_KEY_PRESS`](https://github.com/qmk/qmk_firmware/blob/master/docs/tap_hold.md#hold-on-other-key-press) | If `on`, any other key pressed (even without release) while the source is held immediately commits the hold action. Stricter than `permissive_hold`. |
| `retro_tap` | `on`/`off` | `off` | [`RETRO_TAPPING`](https://github.com/qmk/qmk_firmware/blob/master/docs/tap_hold.md#retro-tapping) | If `on`, releasing the source key without committing a hold still emits the tap key. Useful for over-held keys (e.g. holding `space` then releasing without pressing anything else still types a space). |

### Layer Holds

When `hold` references a **mode identifier** instead of a key, the
source key acts as a temporary layer activator: hold to enter the
mode, release to exit. Layer hold rules push IPC messages from grabber
→ agent so the mode change happens on the agent's run loop (where
mode bindings are evaluated).

```bash
# Declare a capture-mode for unbound keys not to leak through.
:: fn_layer @

# Hold space → enter fn_layer; release → back to default.
.remap space [device builtin] {
    tap             : space
    hold            : fn_layer
    timeout         : 200ms
    retro_tap       : on
}

# While the layer is held, number row maps to F-row.
fn_layer < 1 | f1
fn_layer < 2 | f2
fn_layer < tab | alt - tab          # cmd-tab style app switcher
fn_layer < 0x1B | f11               # virtual keycodes also work in layer
```

Layer-hold modes use the same `:: <name> @` declaration syntax as
[regular modes](#mode-declaration) — capture (`@`) decides whether
unbound keys in the layer leak through to the focused app or are
absorbed.

## Syntax Examples

### Basic Hotkey
```bash
cmd - a : echo "Command+A pressed"
```

### Multiple Modifiers
```bash
cmd + shift + alt - x : echo "Complex hotkey"
```

### Process-Specific Bindings
```bash
cmd - n [
    "terminal" : echo "New terminal window"
    "safari"   : echo "New browser window"
    *          : echo "New window in other apps"
]
```

### Key Forwarding
```bash
# Simple forwarding
ctrl - h | left

# Process-specific forwarding
home [
    "kitty"    ~           # Let kitty handle it
    *          | cmd - left # In other apps, send Cmd+Left
]
```

### Modal System
```bash
# Declare mode
:: window : echo "Window mode"

# Enter mode
cmd - w ; window

# Enter mode and execute command
cmd - w ; window : echo "Switching to window mode"

# Commands in mode
window < h : yabai -m window --focus west
window < escape ; default : echo "Returning to default mode"
```

### Process-Specific Mode Activation
Mode activation can also be used in process lists, allowing different applications to trigger different modes:

```bash
# Define terminal and browser app groups
.define terminal_apps ["kitty", "wezterm", "terminal"]
.define browser_apps ["chrome", "safari", "firefox"]

# Different apps switch to different modes with Cmd+M
cmd - m [
    @terminal_apps ; vim_mode : echo "Vim mode for terminals"
    @browser_apps ; browser_mode : echo "Browser mode activated"
    * ; default : echo "Back to default"
]

# Mode activation with command in process list
cmd - e [
    "code" ; edit_mode : osascript -e 'display notification "Edit mode for VS Code"'
    "xcode" ; edit_mode : osascript -e 'display notification "Edit mode for Xcode"'
    * : echo "No special mode for this app"
]
```

### Passthrough Mode
```bash
# Execute command but still send keypress
cmd - p -> : echo "Command runs but Cmd+P goes to app"
```

### Multi-line Commands
```bash
cmd - x : echo "Line 1" ; \
          echo "Line 2" ; \
          echo "Line 3"
```

## Special Syntax Notes

1. **Comments**: Use `#` for comments
2. **Unbinding**: Use `~` to unbind a key in specific applications
3. **Wildcard**: Use `*` to match all applications not explicitly specified
4. **Keycode**: Use hex values like `0x3C` for specific key codes
5. **Mode Capture**: Use `@` after mode name to capture all keypresses

## Common Patterns

### Vim-like Navigation
```bash
# Global navigation
cmd - h : focus west
cmd - j : focus south
cmd - k : focus north
cmd - l : focus east
```

### Application Launching
```bash
alt - return : open -a Terminal
alt - b : open -a Safari
```

### Mode-based Workflows
```bash
:: resize @ : echo "Resize mode"
cmd - r ; resize
resize < h : resize left
resize < l : resize right
resize < escape ; default
```

### Linux-style Text Editing
```bash
# Word movement
ctrl - left [
    @terminal_apps ~
    *              | alt - left
]

# Line start/end
home [
    @native_apps ~
    *            | cmd - left
]
```
