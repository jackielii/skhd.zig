# SKHD Configuration Syntax Reference

This document provides a comprehensive reference for the skhd configuration syntax. The skhd.zig implementation is fully compatible with the original skhd syntax, with additional features.

## Grammar Overview

The configuration syntax follows these formal rules:

```
hotkey       = <mode> '<' <action> | <action>

mode         = 'name of mode' | <mode> ',' <mode>

action       = <keysym> '[' <proc_map_lst> ']' | <keysym> '->' '[' <proc_map_lst> ']'
               <keysym> ':' <command>          | <keysym> '->' ':' <command>
               <keysym> ';' <mode>             | <keysym> '->' ';' <mode>

keysym       = <mod> '-' <key> | <key>

mod          = 'modifier keyword' | <mod> '+' <mod>

key          = <literal> | <keycode>

literal      = 'single letter or built-in keyword'

keycode      = 'apple keyboard kVK_<Key> values (0x3C)'

proc_map_lst = * <proc_map>

proc_map     = <string> ':' <command> | <string>     '~' |
               '*'      ':' <command> | '*'          '~' |
               '@' <group_name> ':' <command> | 
               '@' <group_name> '~'

string       = '"' 'sequence of characters' '"'

group_name   = 'process group name defined with .define directive'

command      = command is executed through '$SHELL -c' and
               follows valid shell syntax. if the $SHELL environment
               variable is not set, it will default to '/bin/bash'.
               when bash is used, the ';' delimiter can be specified
               to chain commands.

               to allow a command to extend into multiple lines,
               prepend '\' at the end of the previous line.

               an EOL character signifies the end of the bind.

->           = keypress is not consumed by skhd

*            = matches every application not specified in <proc_map_lst>

~            = application is unbound and keypress is forwarded per usual
```

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

### Function Keys
- `f1` through `f20` - Function keys

### Media Keys
- `sound_up`, `sound_down` - Volume controls
- `mute` - Mute key
- `brightness_up`, `brightness_down` - Screen brightness
- `illumination_up`, `illumination_down` - Keyboard backlight
- `play`, `previous`, `next` - Media playback
- `rewind`, `fast` - Media navigation

## Configuration Directives

Configuration directives follow this syntax:

```
directive = '.shell' <string> |
            '.blacklist' '[' <string_list> ']' |
            '.load' <string> |
            '.define' <identifier> '[' <string_list> ']'

string_list = <string> | <string> ',' <string_list>
```

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

# Commands in mode
window < h : yabai -m window --focus west
window < escape ; default
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
