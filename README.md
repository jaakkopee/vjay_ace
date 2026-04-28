# vjay_ace

`vjay_ace` is a live-performance VJ compositor for macOS on Apple Silicon.

It combines:

- 3 source layers
- 3 GPU FX slots
- 32 scene presets
- live audio analysis
- MIDI scene selection and knob control
- per-scene and global override controls for opacity, audio gain, and crossfade timing

The render path is Metal-based. Control and preview windows use SFML + TGUI.

## What It Does

At runtime, the app:

- loads still images or video into three source slots
- runs one FX patch per slot on the GPU
- composites the processed slots into a single 1920x1080 output
- mirrors that output into a control preview window
- reacts to live audio using RMS plus an 8-band spectrum
- restores scene state, media assignments, and knob values from disk

This is intended for performance use rather than offline rendering.

## Current Feature Set

- 3 source slots with independent media assignment
- 3 FX slots with two parameters per FX
- 32 MIDI-triggered scenes
- per-scene storage for:
  - FX params
  - local opacity
  - local audio gain
  - local image crossfade speed
  - local scene crossfade speed
  - image pan / zoom / rotation
  - media paths
  - LIF topology / neuron count state
- global override modes for:
  - opacity
  - audio gain
  - image crossfade speed
  - scene crossfade speed
- shift lock for staying in global override mode without holding Shift
- live audio input analysis with passthrough monitoring
- feedback-based and neural-style GPU effects

## Platform

This project currently targets:

- macOS
- Apple Silicon / Metal-capable hardware
- CMake-based local builds

## Dependencies

The project uses these libraries and frameworks:

- CMake 3.20+
- SFML 3
- TGUI
- RtMidi
- FFmpeg libraries (`libavcodec`, `libavformat`, `libavutil`, `libswscale`)
- OpenCV 4
- Apple frameworks:
  - Metal
  - MetalKit
  - Foundation
  - AppKit
  - CoreVideo
  - CoreMedia
  - AudioUnit
  - AudioToolbox
  - CoreAudio
  - AVFoundation
  - Accelerate

Homebrew install example:

```bash
brew install cmake sfml tgui rtmidi ffmpeg opencv
```

## Build

From the repository root:

```bash
mkdir -p build
cd build
cmake ..
cmake --build . --target vjay_ace -j$(sysctl -n hw.ncpu)
```

You can also build the MIDI monitor tool:

```bash
cmake --build . --target midi_monitor -j$(sysctl -n hw.ncpu)
```

## Run

From the build directory:

```bash
./vjay_ace
```

The build copies the Metal shader file next to the executable as:

```text
build/vjay_shaders.metal
```

The app expects that file to exist at runtime.

## Windows

The application opens multiple windows:

- Control window: primary display
  - scene name
  - mode label
  - shift-lock indicator
  - 6 knob widgets
  - audio meter
  - composite preview
- Performance window: second display if available
  - full performance output
- Media picker window: primary display overlay
  - browse stash media and assign source images

If no second display is available, the performance output falls back to a regular window.

## Layer Model

The compositor works as three source/FX pairs:

```text
Source 0 -> FX 0
Source 1 -> FX 1
Source 2 -> FX 2
```

In implementation terms:

```text
Layer 0  source
Layer 1  FX for layer 0
Layer 2  source
Layer 3  FX for layer 2
Layer 4  source
Layer 5  FX for layer 4
```

Each source is optionally:

- crossfaded
- rotated
- zoomed
- panned

Then the corresponding FX kernel runs on it, and the three processed groups are alpha-composited into the final frame.

## Audio Analysis

Audio is captured from the default input device and analyzed in real time.

Available analysis data:

- RMS level
- 8-band log-scaled spectrum

Band layout:

1. Sub-bass: 20-60 Hz
2. Bass: 60-250 Hz
3. Lo-mid: 250-500 Hz
4. Mid: 500-2000 Hz
5. Hi-mid: 2000-4000 Hz
6. Presence: 4000-6000 Hz
7. Brilliance: 6000-12000 Hz
8. Air: 12000-20000 Hz

Audio data is injected into FX kernels every frame. Many effects already respond to RMS and selected bands.

## MIDI

### Knobs

The app listens to six knob CCs:

```text
CC 3, 9, 12, 13, 14, 15
```

These map to knob indices 0-5.

### Scene Select

Scenes are selected by MIDI note-on events from:

```text
32 scenes starting at MIDI note 36
```

In code, scene notes start at MIDI note 36 and cover 32 scenes:

- bank A: scene 0-15 = C2 (36) to D#3 (51)
- bank B: scene 16-31 = E3 (52) to G4 (67)

## Keyboard Controls

Keyboard actions are documented in detail in [key_modifiers.md](key_modifiers.md).

Summary:

- `R`: image rotate
- `Z`: image zoom
- `P`: image pan
- `O`: local opacity
- `Shift+O`: global opacity override
- `G`: local audio gain
- `Shift+G`: global audio gain override
- `X`: local image crossfade speed
- `Shift+X`: global image crossfade speed override
- `C`: local scene crossfade speed
- `Shift+C`: global scene crossfade speed override
- `N`: LIF neuron count mode
- `B`: audio bypass toggle
- Shift double-press within 200 ms: toggle Shift Lock

## State Model

Scene state is the main source of truth.

Each scene stores:

- knob values for all control modes
- per-scene image paths
- local crossfade timing
- local opacity values
- local audio gain values
- LIF-related state

Global override values are stored separately for:

- opacity
- audio gain
- image crossfade speed
- scene crossfade speed

Override behavior:

- local values are used by default
- when a global override is changed, it becomes authoritative
- if the local scene value is touched afterward, that scene takes control again

State is persisted to:

```text
~/.vjay_ace_state
```

## Crossfade Behavior

There are two independent crossfade systems:

### Image Crossfade

Used when the source image/video in a slot changes.

- local control: `X`
- global override: `Shift+X`

### Scene Crossfade Timing

Used to define the timing used when changing scenes for pan/zoom transition behavior.

- local control: `C`
- global override: `Shift+C`

Crossfade durations are normalized on the knob side and mapped to approximately:

```text
0.1 to 8.0 seconds
```

## FX Patches

The project currently includes these FX patch IDs:

- Passthrough
- Blur
- Chromatic Aberration
- Hue Cycle
- Video Glitch
- Kaleidoscope
- Wave Distort
- Edge Ink
- Mold Trails
- Fractal
- Pixelate
- Rainbow Shift
- Julia Fractal
- Feedback Zoom
- Circle Quilt
- CA Glow
- Bitplane Reactor
- LIF Modulate
- LIF Replace
- Vignette
- Ripple
- Lens Distort
- Swirl
- RGB Modulate
- Color Temp
- Scanline
- Strobe

### Parameter Map

Each FX exposes up to two parameters.

| FX | Param 1 | Param 2 |
|---|---|---|
| Passthrough | - | - |
| Blur | Kernel Size | - |
| Chromatic Aberration | Offset (px) | - |
| Hue Cycle | Speed | Time Offset |
| Video Glitch | Displace | Chan Shift |
| Kaleidoscope | Segments | Rotation |
| Wave Distort | Amplitude | Frequency |
| Edge Ink | Threshold | Edge Strength |
| Mold Trails | Sensor Angle | Decay |
| Fractal / Julia Fractal | C real | C imag |
| Pixelate | Block Size | - |
| Rainbow Shift | Speed | Wave Scale |
| Feedback Zoom | Zoom Delta | Rotate Delta |
| Circle Quilt | Grid Cols | Radius Scale |
| CA Glow | Threshold | Glow Spread |
| Bitplane Reactor | CA Rule | Threshold |
| LIF Modulate / LIF Replace | Influence | Topology |
| Vignette | Strength | Radius |
| Ripple | Amplitude | Wavelength |
| Lens Distort | Strength | Zoom |
| Swirl | Angle | Radius |
| RGB Modulate | Red Gain | Blue Gain |
| Color Temp | Temperature | Contrast |
| Scanline | Intensity | Density |
| Strobe | Rate | Duty |

## Scene Presets

Current built-in scenes are split into two MIDI banks.

Bank A (C2..D#3, scenes 0-15):

| # | Name | FX 0 | FX 1 | FX 2 |
|---|---|---|---|---|
| 0 | Pass-Through | Passthrough | Passthrough | Passthrough |
| 1 | Kaleidoscope | Kaleidoscope | Hue Cycle | LIF Modulate |
| 2 | Rainbow | Rainbow Shift | Rainbow Shift | Rainbow Shift |
| 3 | Pixelate | Pixelate | Hue Cycle | Passthrough |
| 4 | Julia | Julia Fractal | Chroma Aberr | Passthrough |
| 5 | Glitch Storm | Video Glitch | Wave Distort | Chromatic Aberr |
| 6 | Feedback Tunnel | Feedback Zoom | Hue Cycle | LIF Replace |
| 7 | Circle Quilt | Circle Quilt | Passthrough | Passthrough |
| 8 | CA Glow | CA Glow | CA Glow | Passthrough |
| 9 | Bitplane | Bitplane Reactor | Passthrough | Hue Cycle |
| 10 | Blur Haze | Blur | Blur | Passthrough |
| 11 | Ink Rainbow | Edge Ink | Rainbow Shift | Passthrough |
| 12 | Deep Space | Julia Fractal | Feedback Zoom | CA Glow |
| 13 | Total Chaos | Video Glitch | Kaleidoscope | Bitplane Reactor |
| 14 | Neural Pulse | LIF Modulate | Hue Cycle | Passthrough |
| 15 | Spike Storm | LIF Replace | Kaleidoscope | Video Glitch |

Bank B (E3..G4, scenes 16-31):

| # | Name | FX 0 | FX 1 | FX 2 |
|---|---|---|---|---|
| 16 | Noise Warp Loop | Ripple | Feedback Zoom | Video Glitch |
| 17 | Audio Kaleido Hue | Kaleidoscope | Hue Cycle | RGB Modulate |
| 18 | Julia Glitch | Julia Fractal | Video Glitch | Scanline |
| 19 | Physarum Echo | Scanline | Feedback Zoom | Hue Cycle |
| 20 | Reactor Bloom | Bitplane Reactor | CA Glow | Vignette |
| 21 | Quilt Ink | Circle Quilt | Edge Ink | Color Temp |
| 22 | Waveform Shear | Ripple | Pixelate | Chromatic Aberr |
| 23 | Triplet Strobe | Strobe | Kaleidoscope | Feedback Zoom |
| 24 | Diffuse Bloom | Vignette | CA Glow | Color Temp |
| 25 | Lens Swirl | Lens Distort | Swirl | Feedback Zoom |
| 26 | Neon Contour | Vignette | Edge Ink | CA Glow |
| 27 | Mirror Shatter | Kaleidoscope | Pixelate | Lens Distort |
| 28 | Diffuse Reactor | Bitplane Reactor | Blur | Swirl |
| 29 | Fractal Displacer | Julia Fractal | Lens Distort | Feedback Zoom |
| 30 | Psy Modulator | RGB Modulate | Hue Cycle | Video Glitch |
| 31 | Shadow Morph | Edge Ink | Blur | Strobe |

## Project Structure

Key source files:

```text
src/app/App.mm                      app orchestration, scene logic, control routing
src/app/App.h                       app state structures and interfaces
src/app/MetalCompositor.mm          Metal render and compute pipeline
src/app/MetalCompositor.h           compositor interface and shared shader params
src/app/AudioAnalyzer.mm            live audio capture and analysis
src/app/AudioAnalyzer.h             audio analysis API and band layout
src/app/LayerManager.cpp            source/media layer state management
src/app/VideoDecoder.cpp            video decode path
src/app/MidiRouter.cpp              MIDI input routing
src/app/ControlWindow.cpp           control UI and keyboard handling
src/app/PerformanceWindow.cpp       performance output window
src/app/MediaPickerWindow.mm        media browser and slot assignment UI
src/app/Constants.h                 scene list, FX IDs, MIDI constants
src/app/shaders/vjay_shaders.metal  all Metal kernels
src/midi_monitor/                   standalone MIDI monitor tool
```

## Runtime Notes

- The media picker root is currently wired for the local stash layout used by this project.
- The app saves state aggressively so scene and media changes survive restarts.
- Audio bypass only disables audio injection into FX; it does not disable rendering.
- Shift Lock affects only Shift-based keyboard modifier interpretation in the control window.

## Troubleshooting

### App starts but GPU compositing is missing

Check that:

- Metal is available on the machine
- `build/vjay_shaders.metal` exists
- the shader file compiled successfully during build

### No audio reaction

Check that:

- the app has microphone/input permission if needed
- a valid input device is available
- audio bypass is not enabled
- the relevant FX slot has non-zero audio gain

### Knobs appear to do nothing

Check that:

- the expected modifier key is held
- Shift Lock is not forcing you into a global mode unexpectedly
- your MIDI controller is sending the expected CC numbers

### Scene values seem overridden

This is usually due to a global override mode having been edited recently.
Touch the local scene value again to reclaim control for that scene.

## Development Notes

Useful files while changing behavior:

- [key_modifiers.md](key_modifiers.md): keyboard control reference
- [FX_BrainStorm.md](FX_BrainStorm.md): effect ideas and notes

Useful build command:

```bash
cmake --build build --target vjay_ace -j4
```

## Status

This README is intended to describe the current codebase rather than planned behavior. If controls change again, update [key_modifiers.md](key_modifiers.md) alongside this file.
