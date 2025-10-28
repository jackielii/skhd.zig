# Hyperkey Support in skhd.zig

This document explains how to use hyperkey functionality with skhd.zig.

## What is Hyperkey?

A "hyperkey" is a special modifier key combination that's unlikely to conflict with existing keyboard shortcuts. There are two common definitions:

1. **Standard Hyper**: `Ctrl + Alt + Shift + Cmd` (all modifiers)
2. **Modified Hyper** (used by apps like Hyperkey.app, Karabiner Elements): `Ctrl + Alt + Cmd` (without Shift)

Many users remap their Caps Lock key to act as a hyperkey for easier access to custom shortcuts.

## Using Hyperkey in Your Config

### Built-in `hyper` Modifier

skhd.zig supports the `hyper` keyword which expands to `Ctrl + Alt + Shift + Cmd`:

```bash
# Standard hyper (Ctrl + Alt + Shift + Cmd)
hyper - a : echo "Opening application A"
hyper - b : echo "Opening application B"
```

### Custom Modifier Combinations

You can also define your own modifier combinations using `+`:

```bash
# Hyperkey.app style (Ctrl + Alt + Cmd without Shift)
ctrl + alt + cmd - a : echo "Custom hyperkey"
ctrl + alt + cmd - b : open -a "Firefox"
ctrl + alt + cmd - c : yabai -m window --focus next

# Meh key (Ctrl + Alt + Shift without Cmd)
meh - d : echo "Meh key pressed"

# Or use the built-in meh modifier
ctrl + alt + shift - e : echo "Same as meh"
```

### Chaining Multiple Modifiers

The parser supports chaining multiple modifiers with `+`:

```bash
# Two modifiers
ctrl + alt - a : echo "Ctrl + Alt"
alt + cmd - b : echo "Alt + Cmd"
ctrl + cmd - c : echo "Ctrl + Cmd"

# Three modifiers
ctrl + alt + shift - d : echo "Ctrl + Alt + Shift"
alt + shift + cmd - e : echo "Alt + Shift + Cmd"

# Four modifiers (standard hyper)
ctrl + alt + shift + cmd - f : echo "All modifiers"
```

## Caps Lock as Hyperkey

There are several ways to use Caps Lock as a hyperkey:

### Option 1: External Tools (Current Approach)

Use external apps to remap Caps Lock:

- **[Hyperkey.app](https://hyperkey.app/)**: Simple app that remaps Caps Lock to `Ctrl + Alt + Cmd`
- **[Karabiner-Elements](https://karabiner-elements.pqrs.org/)**: Powerful keyboard customizer with complex remapping rules

Then configure skhd.zig to use the modifier combination:

```bash
# If using Hyperkey.app (sends Ctrl + Alt + Cmd)
ctrl + alt + cmd - a : echo "Hyperkey A"
ctrl + alt + cmd - b : echo "Hyperkey B"
```

### Option 2: Native Support with hidutil (Experimental)

**Note**: This feature is available in the `device-detection` branch and not yet merged into main.

skhd.zig can programmatically remap Caps Lock using macOS's `hidutil` command:

```zig
const KeyRemapper = @import("KeyRemapper.zig");

// Create remapper instance
const remapper = try KeyRemapper.create(allocator);
defer remapper.destroy();

// Remap Caps Lock to F13 (bypasses macOS delay)
try remapper.setKeyMapping(KeyRemapper.KeyMapping.CAPS_TO_F13);
```

Then you can bind F13 in your config:

```bash
# Tap Caps Lock (now F13) for Escape
f13 : skhd --key escape

# Hold Caps Lock (F13) + other keys for hyperkey behavior
# This requires additional timing logic (coming soon)
```

### Option 3: Manual hidutil Setup

You can manually remap Caps Lock to F13 using the terminal:

```bash
# Remap Caps Lock to F13
hidutil property --set '{"UserKeyMapping":[{
    "HIDKeyboardModifierMappingSrc":0x700000039,
    "HIDKeyboardModifierMappingDst":0x700000068
}]}'

# Check current mapping
hidutil property --get UserKeyMapping

# Remove mapping (restore default)
hidutil property --set '{"UserKeyMapping":[]}'
```

Then configure skhd.zig:

```bash
f13 - a : echo "F13 (Caps Lock) + A"
f13 - b : echo "F13 (Caps Lock) + B"
```

## Troubleshooting

### Hyperkey Not Recognized

1. **Check your external tool configuration**: Ensure Hyperkey.app or Karabiner-Elements is running and configured correctly
2. **Test with observe mode**: Run `skhd -o` and press your hyperkey combination to see what modifiers are detected
3. **Verify your config syntax**: Ensure modifiers are separated by `+` and followed by `-` before the key

### Caps Lock Delay

macOS has a built-in ~300ms delay for Caps Lock to prevent accidental activation. Solutions:

- Use an external tool like Hyperkey.app (bypasses the delay)
- Use hidutil to remap to F13 (bypasses the delay)
- Wait for native timing support in skhd.zig (coming in a future release)

### Conflicts with Other Tools

If you're using both skhd.zig and other keyboard customizers:

1. Use the external tool ONLY for Caps Lock remapping
2. Use skhd.zig for all hotkey definitions
3. Avoid defining the same shortcuts in multiple tools

## Future Enhancements

The following features are planned or in development:

### Tap/Hold Behavior (device-detection branch)

```bash
# Tap Caps Lock = Escape
# Hold Caps Lock = Hyper modifier
tap(caps_lock) : escape
hold(caps_lock) : hyper

# Custom timing thresholds
.timing tap_max=200ms hold_min=200ms
```

### Layer Tap (LT)

```bash
# Space: Tap = Space, Hold = Navigation layer
tap(space) : space
hold(space) : layer(nav)

.layer nav {
    h : left
    j : down
    k : up
    l : right
}
```

## Examples

Here's a complete example configuration using hyperkey:

```bash
# Using external Hyperkey.app (Ctrl + Alt + Cmd)
ctrl + alt + cmd - return : open -a "iTerm"
ctrl + alt + cmd - f : open -a "Firefox"
ctrl + alt + cmd - c : open -a "Visual Studio Code"
ctrl + alt + cmd - s : open -a "Slack"

# Window management with yabai
ctrl + alt + cmd - h : yabai -m window --focus west
ctrl + alt + cmd - j : yabai -m window --focus south
ctrl + alt + cmd - k : yabai -m window --focus north
ctrl + alt + cmd - l : yabai -m window --focus east

# Spaces
ctrl + alt + cmd - 1 : yabai -m space --focus 1
ctrl + alt + cmd - 2 : yabai -m space --focus 2
ctrl + alt + cmd - 3 : yabai -m space --focus 3

# Process-specific hotkeys
ctrl + alt + cmd - r [
    "Firefox" : osascript -e 'tell application "Firefox" to activate'
    "Chrome"  : osascript -e 'tell application "Google Chrome" to activate'
    *         : echo "Reload current app"
]
```

## See Also

- [SYNTAX.md](../SYNTAX.md) - Complete syntax reference
- [CLAUDE.md](../CLAUDE.md) - Project overview and build instructions
- [Issue #16](https://github.com/jackielii/skhd.zig/issues/16) - Hyperkey support discussion
