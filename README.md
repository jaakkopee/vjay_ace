# vjay_ace

Real-time GPU VJ compositor for live performance on macOS / Apple Silicon.  
Three source layers, three FX layers, 16 scenes, 6 MIDI knobs.

---

## Requirements

| Dependency | Version |
|---|---|
| macOS | 13+ (Metal 3) |
| Xcode / clang | 15+ |
| CMake | 3.20+ |
| SFML | 3.x |
| TGUI | latest |
| RtMidi | any |
| FFmpeg (libav*) | 6+ |
| OpenCV | 4.x |

All dependencies available via Homebrew on Apple Silicon (`/opt/homebrew`).

```bash
brew install sfml tgui rtmidi ffmpeg opencv cmake
```

### Build

```bash
mkdir build && cd build
cmake ..
make -j$(sysctl -n hw.ncpu)
./vjay_ace
```

---

## Architecture

### Layer topology

```
Layer 0  (source)  ─┐
Layer 1  (FX)      ─┴── FX slot 0 processes layer 0 → composited group 0
Layer 2  (source)  ─┐
Layer 3  (FX)      ─┴── FX slot 1 processes layer 2 → composited group 1
Layer 4  (source)  ─┐
Layer 5  (FX)      ─┴── FX slot 2 processes layer 4 → composited group 2
                           ↓
                   Final Porter-Duff over-blend (bottom → top)
```

- **Source layers (0, 2, 4):** RGBA8 images or video decoded via FFmpeg/OpenCV.  
  Each source is optionally rotated and zoomed on the GPU before FX processing.
- **FX layers (1, 3, 5):** Metal compute kernels run on the source below.  
  FX layer opacity blends the processed result back against the unprocessed source (0 = bypass, 1 = full effect).
- **Output:** 1920 × 1080 RGBA8 composited frame, displayed on the performance window (second screen) and mirrored as a preview in the control window.

### State model

Each of the 14 scenes stores independent knob values per mode. When a scene is selected, stored values are applied immediately. Physical knobs use a **pickup / catch-up** system — a knob has no effect until its physical position crosses the stored value, preventing value jumps.

State is persisted to `~/.vjay_ace_state` on every scene change.

---

## Windows

| Window | Screen | Purpose |
|---|---|---|
| Control | Primary | 6 knob arcs, scene name, mode label, preview |
| Performance | Secondary | Full-screen output |
| Media Picker | Primary (overlay) | Browse `Heikki_stash/` and assign images to slots |

---

## MIDI Mapping

### Knob modes

Hold a mode key to switch all 6 knobs simultaneously. Release to return to FxParam mode.

| Key | Mode | Knobs 0–5 control |
|---|---|---|
| O (held) | **Layer Opacity** | Layers 0–5 opacity (0 = invisible, 1 = full) |
| G (held) | **FX / Audio** | Gain for FX layers 0–2; bandpass frequency 100–8000 Hz |
| *(default)* | **FX Param** | Two params per FX slot (slot 0: knobs 0–1, slot 1: knobs 2–3, slot 2: knobs 4–5) |

**Modifier keys** (held while in FxParam mode):

| Key | Mode | Knobs 0–2 control |
|---|---|---|
| R | **Image Rotate** | Rotation 0–2π for source layers 0, 2, 4 |
| Z | **Image Zoom** | Zoom factor 0.5×–2.0× for source layers 0, 2, 4 |

### Knob CCs

`CC 3 · 9 · 12 · 13 · 14 · 15` → knobs 0–5.

### Scene select

MIDI notes C2–C#3 (36–51) select scenes 0–15.

---

## FX Patches

All effects are Metal compute kernels running at 1920 × 1080.

### Passthrough
Copies input to output unchanged. Used to leave an FX slot inactive.

### Blur
Box blur with parametric kernel size.  
- **P1:** Kernel size (5–15 px)

### Chromatic Aberration
Splits RGB channels horizontally, creating a lens-fringe colour split.  
- **P1:** Pixel offset (0–20 px)

### Hue Cycle
Rotates hue spatially across the image over time.  
- **P1:** Cycle speed  
- **P2:** Time offset (phase)

### Video Glitch
Simplex-noise scanline drift with channel separation and interference bands.  
- **P1:** Displacement strength  
- **P2:** Channel shift amount

### Kaleidoscope
Polar coordinate fold creating a mirrored radial mandala.  
- **P1:** Number of segments (2–12)  
- **P2:** Rotation angle

### Wave Distort
Sinusoidal UV displacement in both axes.  
- **P1:** Amplitude (px)  
- **P2:** Frequency

### Edge Ink
Sobel edge detection overlaid as a coloured ink line.  
- **P1:** Edge threshold  
- **P2:** Edge strength

### Pixelate
Block-average pixelation — great for beat-reactive use.  
- **P1:** Block size (2–64 px)

### Rainbow Shift
Full-spectrum HSV hue rotation travelling as a wave across the image.  
- **P1:** Speed  
- **P2:** Spatial wave scale

### Julia Fractal
Animated Julia set rendered per-pixel and blended with the source.  
`c` slowly rotates in the complex plane over time.  
- **P1:** Real part of `c` (−1 to 1)  
- **P2:** Imaginary part of `c` (−1 to 1)

### Feedback Zoom
Infinite zoom + rotate feedback loop. Each frame the image is slightly zoomed and rotated into itself with a colour tint. Creates tunnel/vortex loops.  
- **P1:** Zoom delta (1.0–1.05 per frame)  
- **P2:** Rotation delta (radians per frame)

### Circle Quilt
Grid of circles whose radii are driven by local image luminance. Dark areas shrink circles; bright areas expand them.  
- **P1:** Grid columns (8–64)  
- **P2:** Radius scale

### CA Glow
Conway-CA-inspired neighbour density map applied as a glow overlay with an animated colour hue.  
- **P1:** Luminance threshold for "live" pixels  
- **P2:** Glow spread radius

### Bitplane Reactor
Wolfram elementary cellular automaton applied row-by-row to the image's luminance bitplane. Each row is the next CA generation of the row above.  
- **P1:** CA rule number (0–255; rule 110 and 30 recommended)  
- **P2:** Luminance threshold

### Mold Trails *(stateless approximation)*
Single-pass GPU approximation of physarum slime-mould diffusion. Each pixel acts as an independent agent depositing and decaying trail.  
Full stateful agent simulation (ping-pong buffer) planned.  
- **P1:** Sensor angle  
- **P2:** Decay rate

### LIF Network
Leaky Integrate-and-Fire neuron network applied to image data. Each pixel is treated as a LIF neuron receiving synaptic input from its neighborhood. The topology parameter smoothly transitions from local excitatory coupling (radius 1 grid — small clusters light up) to an inhibitory-centre / excitatory-surround (Mexican-hat) long-range topology that creates edge-highlighted activation patterns. Audio RMS lowers the firing threshold, making beats trigger broader neuron cascades.  
- **P1:** Firing threshold (0–1; lower = more neurons fire)  
- **P2:** Topology (0 = local excitatory, 1 = inhibitory-surround long-range)

---

## Scenes (C2–C#3)

| # | Note | Name | FX slot 0 | FX slot 1 | FX slot 2 |
|---|---|---|---|---|---|
| 0 | C2 | Pass-Through | Passthrough | Passthrough | Passthrough |
| 1 | C#2 | Kaleidoscope | Kaleidoscope | Hue Cycle | Passthrough |
| 2 | D2 | Rainbow | Rainbow Shift | Rainbow Shift | Rainbow Shift |
| 3 | D#2 | Pixelate | Pixelate | Hue Cycle | Passthrough |
| 4 | E2 | Julia | Julia Fractal | Chroma Aberr | Passthrough |
| 5 | F2 | Glitch Storm | Video Glitch | Wave Distort | Chroma Aberr |
| 6 | F#2 | Feedback Tunnel | Feedback Zoom | Hue Cycle | Passthrough |
| 7 | G2 | Circle Quilt | Circle Quilt | Passthrough | Passthrough |
| 8 | G#2 | CA Glow | CA Glow | CA Glow | Passthrough |
| 9 | A2 | Bitplane | Bitplane Reactor | Passthrough | Hue Cycle |
| 10 | A#2 | Blur Haze | Blur | Blur | Passthrough |
| 11 | B2 | Ink Rainbow | Edge Ink | Rainbow Shift | Passthrough |
| 12 | C3 | Deep Space | Julia Fractal | Feedback Zoom | CA Glow |
| 13 | C#3 | Total Chaos | Video Glitch | Kaleidoscope | Bitplane Reactor |
| 14 | D3 | Neural Glow | LIF Network | Hue Cycle | Passthrough |
| 15 | D#3 | Synapse Storm | LIF Network | Wave Distort | LIF Network |

---

## File Structure

```
src/app/
  App.mm/.h              — Main application, frame loop, MIDI routing, scene management
  MetalCompositor.mm/.h  — GPU pipeline: PSO creation, FX dispatch, composite
  LayerManager.cpp/.h    — Source layer state, VideoDecoder orchestration
  MidiRouter.cpp/.h      — RtMidi wrapper, knob pickup, mode latch
  ControlWindow.cpp/.h   — SFML+TGUI control surface
  PerformanceWindow.cpp/.h — Full-screen SFML output window
  MediaPickerWindow.mm/.h — Stash browser, image slot assignment
  Constants.h            — Layer topology, MIDI map, FX patch enum, Scene array
  FxPatch.cpp            — Placeholder for future stateful FX constructors
  shaders/vjay_shaders.metal — All Metal compute kernels
```

---

## State Persistence

Scene knob values and loaded image paths are saved to `~/.vjay_ace_state` (binary, version-tagged) on every scene change. Deleted automatically on version mismatch to avoid corrupt restores.

---

## Planned

- Stateful MoldTrails with ping-pong agent buffer (100k+ agents)
- Audio analysis (FFTW) → per-band float buffer passed to Metal kernels
- Beat-sync strobe and quantised kaleidoscope segment count
- Additional scenes using the `FeedbackZoom + JuliaFractal` combination at different speeds
