# Hotkey Sequences Design

## Goal

Add application-aware, comma-separated hotkey sequences without moving ordinary hotkey behavior into `skhd-grabber` or introducing hidden modes.

The motivating binding requires two `cmd-q` chords within a short interval before quitting:

```skhd
cmd - q, cmd - q : command
```

The grammar should support more than two chords so the same implementation can express sequences such as:

```skhd
cmd - k, cmd - c : command
```

## Scope

- A sequence is two or more complete hotkey chords separated by commas.
- Each chord carries its own modifiers; modifiers are not inherited from the previous chord.
- The default maximum interval between consecutive chords is 300 milliseconds.
- Sequences support the same actions as existing hotkeys: commands, forwarding, unbound actions, mode activation, command references, and process-specific lists.
- Sequence recognition stays in the user-session event-tap process.
- This change does not add configuration for the interval. A configurable interval can be considered separately if real usage requires it.

The first implementation is not a text-editor-style keymap engine. It does not add arbitrary predicates, alternative steps, simultaneous chords, or replay of failed prefixes.

## Architecture

Input continues through the existing layers:

```text
physical keyboard
  -> skhd-grabber HID remap, tap-hold, and layer behavior
  -> virtual HID keyboard
  -> skhd event tap hotkeys, sequences, and application filtering
  -> frontmost application
```

The grabber remains unaware of sequences and applications. It emits the effective keyboard stream after applying HID-level transformations. Sequence matching observes that stream at the event tap, so a remapped key participates using its transformed identity and tap-hold output participates only after the grabber commits it.

No grabber protocol or root-daemon state changes are required.

## Data Model

An ordinary hotkey remains a one-chord binding. A sequence binding stores an ordered slice of complete `Hotkey.KeyPress` values plus the existing action mappings.

Each mode owns its sequence bindings alongside its ordinary hotkey map. The runtime builds a prefix index for the mode so matching a chord narrows an existing candidate set instead of scanning all configured sequences on every event.

The event-tap runtime holds one pending sequence state:

- the current mode,
- the frontmost process identity captured by the first chord,
- the surviving sequence candidates,
- the next chord index,
- and the interval timer.

Only one keyboard sequence can be in progress because physical keyboard events form a single ordered stream.

## Parsing and Validation

The comma token already exists. In a hotkey declaration, a comma after the first complete chord starts another complete chord. Parsing continues until the action delimiter (`:`, `|`, `~`, or `;`) or a process list.

Examples:

```skhd
cmd - q, cmd - q : quit-command
cmd - k, cmd - c [ "Code" : comment-command ]
alt - x, ctrl + shift - y | cmd - z
```

Every step uses the existing modifier and keysym grammar. A missing chord after a comma is a parse error with the comma's source location.

Within one mode, a single-chord binding and a longer sequence may not share the complete single chord as a prefix. For example, these declarations conflict and parsing rejects them:

```skhd
cmd - q : immediate-command
cmd - q, cmd - q : delayed-command
```

Likewise, one complete sequence may not be a prefix of another. Rejecting prefix ambiguity keeps ordinary hotkeys immediate and avoids waiting to discover whether a longer binding will follow.

Different longer sequences may share an incomplete prefix:

```skhd
cmd - k, cmd - c : comment-command
cmd - k, cmd - u : uncomment-command
```

Existing duplicate-binding and process-action collision rules continue to apply to identical sequences.

## Runtime Semantics

When no sequence is pending:

1. Look up the chord in the current mode.
2. If it starts one or more sequences, consume the event, capture the current mode and process identity, retain those candidates, and start the 300ms timer.
3. Otherwise, process it as an ordinary hotkey exactly as today.

When a sequence is pending:

1. Ignore auto-repeat key-down events as sequence steps.
2. Confirm that the current mode and frontmost process still match the captured values.
3. Match the incoming complete chord against the next step of the surviving candidates.
4. Consume a matching chord and narrow the candidate set.
5. If a candidate completes, cancel the timer and execute its existing process-specific action.
6. If candidates remain incomplete, restart the 300ms interval for the next step.

Any non-modifier chord that does not match the next step cancels the sequence. The mismatching event is then processed normally from the root lookup, allowing it to trigger an unrelated ordinary hotkey or start another sequence. This avoids losing unrelated input while still consuming the recognized prefix.

Modifier transitions are not sequence steps. Each configured chord is checked from the modifier flags on its key-down event. Consequently, a sequence may release and press modifiers between steps when its written chords permit that. The motivating `cmd - q, cmd - q` requires `cmd` on both `q` events but does not require proof that the same physical modifier press remained down continuously.

The recognized prefix is never replayed. On timeout or cancellation, its consumed key events remain consumed. This is essential for safety bindings such as `cmd-q`; delayed replay could quit an application unexpectedly.

## Cancellation and Lifecycle

Pending sequence state is cleared when:

- 300ms elapses after the latest matched chord,
- the next non-modifier chord does not match,
- the frontmost process changes,
- the active mode changes,
- configuration is reloaded,
- the event tap is disabled or torn down,
- or skhd shuts down.

Cancellation is idempotent and always invalidates/releases the active run-loop timer before dropping borrowed references to mappings or modes.

Application identity is captured at the first chord and checked at every later chord. The completed action uses that same process-specific binding; a sequence cannot begin in one application and execute against another.

## Timing

Use a one-shot `CFRunLoopTimer`, following the ownership and invalidation pattern already proven by grabber tap-hold timers. The sequence implementation has its own timer and state machine because it runs in the user agent and operates on application-aware chords rather than HID usages.

The interval is measured between matched key-down events. Completing a chord restarts the timer for the next chord. Timer expiry only clears pending state and never executes or replays an action.

## Error Handling

- Invalid or ambiguous declarations fail during parsing with the conflicting sequence and mode identified.
- Timer allocation failure cancels the new sequence prefix and logs an error; it must not allow the consumed prefix through later.
- Command execution and forwarding errors use the existing hotkey action paths.
- Hot reload first cancels pending state, then swaps mappings, preventing references into freed configuration.

## Testing

Parser and mapping tests cover:

- two- and three-chord parsing,
- complete modifiers on every chord,
- all existing action forms,
- process-specific sequence actions,
- malformed commas and missing chords,
- duplicate sequences,
- single-hotkey/sequence prefix conflicts,
- sequence/longer-sequence prefix conflicts,
- and valid shared incomplete prefixes.

A timer-independent sequence matcher unit covers:

- successful completion,
- candidate narrowing across shared prefixes,
- mismatches and root reprocessing,
- auto-repeat suppression,
- process and mode changes,
- and timeout cancellation.

Event-tap integration tests cover consuming prefixes, executing only after completion, ordinary hotkey behavior remaining immediate, and cancellation during hot reload. The full `zig build test` suite remains the completion gate.

## Documentation

Update `SYNTAX.md` with the comma-separated chord grammar, the 300ms default interval, prefix ambiguity rules, and cancellation behavior. Add a concise README example centered on the double-`cmd-q` safety use case.
