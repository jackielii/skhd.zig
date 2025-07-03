# Command Definitions with .define

This document describes the command definition feature that allows reducing repetition in skhd configuration files.

## Overview

The `.define` directive has been extended to support command definitions with positional placeholders. This allows you to define reusable command templates that can be referenced throughout your configuration.

## Syntax

### Simple Command Definition (No Placeholders)

Define a command without any parameters:

```
.define focus_recent : yabai -m window --focus recent || yabai -m space --focus recent
```

Use it in a hotkey:

```
cmd - tab : @focus_recent
```

### Template Command Definition (With Placeholders)

Define a command template with positional placeholders using `{{n}}` syntax:

```
.define yabai_focus : yabai -m window --focus {{1}} || yabai -m display --focus {{1}}
.define window_action : yabai -m window --{{1}} {{2}} || yabai -m display --{{1}} {{2}}
```

Use it with arguments in double quotes:

```
lcmd - h : @yabai_focus("west")
lcmd - j : @yabai_focus("south")
cmd + shift - h : @window_action("swap", "west")
cmd + shift - j : @window_action("swap", "south")
```

## Rules

1. **Placeholder Numbering**: Placeholders must be numbered starting from 1 (e.g., `{{1}}`, `{{2}}`, etc.)
2. **Argument Quoting**: Arguments must be enclosed in double quotes when calling a command
3. **Argument Count**: The number of arguments must match the highest placeholder number in the template
4. **Multiple Occurrences**: The same placeholder can appear multiple times in a template
5. **Escape Sequences**: Within quoted arguments, use `\"` to include a literal double quote

## Examples

### Window Management

```
# Define reusable yabai commands
.define yabai_focus : yabai -m window --focus {{1}} || yabai -m display --focus {{1}}
.define yabai_move : yabai -m window --swap {{1}} || ( yabai -m window --display {{1}} ; yabai -m display --focus {{1}} )
.define yabai_space : yabai -m window --space {{1}}

# Use in hotkeys
lcmd - h : @yabai_focus("west")
lcmd - l : @yabai_focus("east")
cmd + shift - h : @yabai_move("west")
cmd + shift - 1 : @yabai_space("1")
cmd + shift - 2 : @yabai_space("2")
```

### Application Toggling

```
# Define app toggle command
.define toggle_app : yabai -m window --toggle {{1}} || open -a "{{1}}"

# Use for different applications
ralt - m : @toggle_app("YT Music")
ralt - n : @toggle_app("Notes")
ralt - t : @toggle_app("Microsoft Teams")
```

### Window Resizing

```
# Define resize command with multiple parameters
.define resize_win : yabai -m window --resize {{1}}:{{2}}:{{3}}

# Use with different resize operations
cmd + ctrl + shift - k : @resize_win("top", "0", "-10")
cmd + ctrl + shift - j : @resize_win("bottom", "0", "10")
cmd + ctrl + shift - h : @resize_win("left", "-10", "0")
cmd + ctrl + shift - l : @resize_win("right", "10", "0")
```

### Complex Commands

```
# Define notification command
.define notify : osascript -e 'display notification "{{2}}" with title "{{1}}"'

# Use with different messages
cmd - n : @notify("Reminder", "Time for a break!")
cmd - m : @notify("Meeting", "Team standup in 5 minutes")
```

## Error Messages

- **Undefined Command**: `"@unknown_cmd not defined"`
- **Argument Mismatch**: `"@cmd expects 2 arguments, got 1"`
- **Missing Arguments**: `"@cmd requires arguments but none provided"`
- **No Arguments Expected**: `"@cmd expects no arguments"`

## Disambiguation from Process Groups

The `.define` directive distinguishes between process groups and commands by syntax:

- **Process Groups**: `.define name ["app1", "app2"]` (uses array syntax)
- **Commands**: `.define name : command text` (uses colon syntax)

This ensures backward compatibility with existing process group definitions.