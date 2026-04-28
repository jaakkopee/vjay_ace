# Keyboard Actions

This document lists the keyboard actions currently used by the control window in `vjay_ace`.

## Modifier Modes

These keys temporarily change what the six knobs control while held.

- `R`: image rotation mode
- `Z`: image zoom mode
- `O`: local opacity mode
- `Shift+O`: global opacity override mode
- `G`: local audio gain mode
- `Shift+G`: global audio gain override mode
- `P`: image pan mode
- `X`: local image crossfade speed mode
- `Shift+X`: global image crossfade speed override mode
- `C`: local scene crossfade speed mode
- `Shift+C`: global scene crossfade speed override mode
- `N`: LIF neuron count mode

## Shift Lock

Shift can be latched so Shift-based global modes stay active without holding Shift.

- `Shift` double-press within 200 ms: toggle Shift Lock on/off
- When Shift Lock is on, Shift-based global mappings behave as if Shift is being held
- The control window shows the current state as `Shift Lock: On` or `Shift Lock: Off`

## Audio Control

- `B`: toggle audio bypass on/off

When audio bypass is enabled:

- audio bands sent to the compositor are zeroed
- the audio meter shows bypass state visually

## Notes

- Local/global pairs use the same base letter where possible, with `Shift+key` selecting the global version
- These keyboard actions are polled in the control window and affect knob routing rather than triggering one-shot commands
- Scene selection itself is currently MIDI-driven, not keyboard-driven

## MIDI Scene Notes

Scene triggering is mapped to note-on events:

- scenes 0-15: C2 (36) to D#3 (51)
- scenes 16-31: E3 (52) to G4 (67)

The second scene bank starts at E3 (52).
