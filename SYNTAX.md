# SKHD Configuration Syntax Reference

This document provides a comprehensive reference for the skhd configuration syntax. The skhd.zig implementation is fully compatible with the original skhd syntax, with additional features.

## Grammar Overview

The configuration syntax follows these formal rules:

```
hotkey       = <mode> '<' <action> | <action>

mode         = 'name of mode' | <mode> ',' <mode>

action       = <keysym> '[' <proc_map_lst> ']'   | <keysym> '->' '[' <proc_map_lst> ']'
               <keysym> ':' <command>            | <keysym> '->' ':' <command>
               <keysym> ';' <mode_activation>    | <keysym> '->' ';' <mode_activation>
               <keysym> '~'

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


## Key Aliases

Key aliases allow you to define reusable names for modifiers, keys, and key combinations, making configurations more readable and maintainable.

### Syntax

```
alias_def = '.alias' <alias_name> <alias_value>

alias_name = '$' <identifier>

alias_value = <modifier_combo> |              # Modifier alias
              <key_spec> |                    # Key alias
              <modifier_combo> '-' <key_spec> # Keysym alias

modifier_combo = <modifier> | <modifier> '+' <modifier_combo> | <alias_name>

key_spec = <literal> | <keycode> | <alias_name>
```

### Alias Types

#### 1. Modifier Alias
Defines a modifier combination that can be reused and combined with other modifiers.

```bash
.alias $super cmd + alt
.alias $hyper cmd + alt + ctrl + shift

# Use standalone
$super - h : echo "Super+H"

# Combine with other modifiers (like built-in hyper/meh)
$super + shift - h : echo "Super+Shift+H"
```

#### 2. Key Alias
Defines a key (with optional modifiers baked in) that can be used in key position.

```bash
.alias $grave 0x32                    # Hex keycode
.alias $exclaim shift - 1             # Key with modifier

# Use in key position
ctrl - $grave : echo "Ctrl+Grave"
ctrl - $exclaim : echo "Ctrl+Shift+1"  # Modifiers merge!
```

#### 3. Keysym Alias
Defines a complete key combination (modifier + key) that can be used standalone or with additional modifiers.

```bash
.alias $nav_left cmd - h
.alias $terminal_key cmd + shift - t

# Use standalone (macro expansion)
$nav_left : yabai -m window --focus west

# Add more modifiers
ctrl + $nav_left : yabai -m window --focus west  # Becomes: ctrl+cmd - h
```

### Nesting

Aliases can reference other aliases, and they are fully expanded at parse time:

```bash
# Nested modifiers
.alias $super cmd + alt
.alias $mega $super + shift + ctrl   # Expands to: cmd+alt+shift+ctrl

# Nested keys
.alias $grave 0x32
.alias $tilde shift - $grave         # Expands to: shift - 0x32

# Nested keysyms
.alias $nav_left $super - h          # Expands to: cmd+alt - h
.alias $special_nav ctrl + $nav_left # Expands to: ctrl+cmd+alt - h
```

### Valid Usage Contexts

| Alias Type | Standalone | As Modifier | In Key Position | With + Modifier |
|------------|------------|-------------|-----------------|-----------------|
| Modifier   | ✗          | ✓           | ✗               | ✓               |
| Key        | ✗          | ✗           | ✓               | ✗               |
| Keysym     | ✓          | ✗           | ✗               | ✓               |

### Examples

```bash
# Define aliases
.alias $super cmd + alt
.alias $mega $super + shift + ctrl
.alias $grave 0x32
.alias $tilde shift - $grave
.alias $nav_left $super - h

# Modifier alias - can combine like hyper/meh
$super - t : open -a Terminal.app
$super + shift - t : open -a "New Terminal"

# Key alias - only in key position
ctrl - $grave : open -a Notes.app
$super - $tilde : open -a "System Settings"

# Keysym alias - standalone or with additional modifiers
$nav_left : yabai -m window --focus west
ctrl + $nav_left : yabai -m window --focus west  # Add ctrl
```

### Common Errors

#### Using Wrong Alias Type

```bash
# ✗ WRONG: Key alias as modifier
.alias $grave 0x32
$grave - t : echo "bad"              # Error: $grave is a key, not a modifier

# ✓ CORRECT: Use in key position
ctrl - $grave : echo "good"

# ✗ WRONG: Modifier alias in key position
.alias $hyper cmd + alt
ctrl - $hyper : echo "bad"           # Error: $hyper is a modifier, not a key

# ✓ CORRECT: Use as modifier
$hyper - t : echo "good"

# ✗ WRONG: Modifier alias standalone
.alias $hyper cmd + alt
$hyper : echo "bad"                  # Error: needs a key

# ✓ CORRECT: Add a key
$hyper - t : echo "good"
```

#### Missing $ Prefix

```bash
.alias $hyper cmd + alt
hyper - t : echo "bad"               # Error! Did you mean '$hyper'?
```

#### Circular References

```bash
.alias $a $b + shift                 # Error: $b not defined yet
.alias $b $a + ctrl
```

### Benefits

- **Readability**: Complex modifier combinations get meaningful names
- **Maintainability**: Change definition once, affects all uses
- **Keyboard Layouts**: Abstract away layout-specific hex codes
- **Consistency**: Same modifier combo everywhere
- **Composability**: Combine aliases like built-in hyper/meh

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

## Configuration Directives

Configuration directives follow this syntax:

```
directive = '.shell' <string> |
            '.blacklist' '[' <string_list> ']' |
            '.load' <string> |
            '.define' <identifier> '[' <string_list> ']' |
            '.define' <identifier> ':' <command_template>

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
