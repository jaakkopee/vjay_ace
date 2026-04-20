# VJay Ace — FX Brainstorm (Metal GPU)

Sources surveyed:
- `~/Documents/koodii/MachinaVFX` — C++ effect library with Metal + OpenGL backends, Python/pybind11 bindings
- `~/Documents/koodii/vidmod` — C++/OpenCV VJ app with FFTW audio analysis and a rich set of CPU-side effects

---

## What Metal Already Has (MachinaVFX shaders/ — ready to port direct)

| Kernel file | Kernels inside | Notes |
|---|---|---|
| `simple_effects.metal` | `grayscale`, `invert`, `sepia` | Fully working, per-pixel, trivially fast |
| `brightness_contrast_saturation.metal` | `adjust_brightness`, `adjust_contrast`, `adjust_saturation` | Params via `Params` UBO |
| `box_blur.metal` | `box_blur` | Parametric kernel size, 7× speedup measured |
| `gaussian_blur.metal` | `gaussian_blur_kernel` | Full 2-pass separable; already in Metal |
| `sharpen.metal` | `sharpen` | Unsharp-mask style, cross-pattern kernel |
| `edge_detect.metal` | `edge_detect` | Sobel operator, 7.5× speedup |
| `chromatic_aberration.metal` | `chromatic_aberration` | Horizontal RGB channel split |
| `vignette.metal` | `vignette` | Radial falloff, `strength` param |
| `hsv_operations.metal` | `hsv_shift`, `hue_cycle` | Full RGB↔HSV in shader; position-based hue cycling |
| `video_glitch.metal` | `video_glitch` | Simplex noise scanline drift, channel shift, interference; **most interesting shader in the repo** |

**Takeaway:** 12 production-ready Metal kernels. The `Params` struct (`int_params[16]`, `float_params[16]`) is the established parameter bus — vjay_ace should adopt the same convention.

---

## MachinaVFX CPU Effects That Don't Have Metal Shaders Yet (high-value ports)

These exist as tested C++ and need a `kernel void X(...)` written for them.

### Color
| Effect | Key params | Metal port complexity | VJ interest |
|---|---|---|---|
| `hsv_shift` (full) | hue_shift, sat_mult, val_mult | ★☆☆ trivial — HSV shader base is there | High |
| `color_temperature` | temperature scalar | ★☆☆ | Medium |
| `rainbow_cycle` | cycle_position | ★★☆ | High — psychedelic |
| `psychedelic_colors` | intensity | ★★☆ | High |
| `rgb_modulator` | R, G, B scalars | ★☆☆ | Medium |

### Geometric (all CPU-only, no Metal yet)
| Effect | Key params | Notes |
|---|---|---|
| `kaleidoscope` | segments, rotation | Polar coordinate fold — trivial on GPU, stunning result |
| `mirror_horizontal/vertical` | — | Trivial, very fast |
| `pixelate` | block_size | Block average — great beat-reactive effect |
| `rotate` | angle_degrees | Affine transform, bilinear sample |
| `zoom` | factor, center | Same as rotate: affine + bilinear |

### Distortion (all CPU-only)
| Effect | Key params | Notes |
|---|---|---|
| `wave_distortion` | amplitude, frequency, phase | Sin warp of UV coords — ideal GPU work |
| `ripple_effect` | center, amplitude, wavelength, phase | Radial sin displacement |
| `lens_distortion` | strength, zoom | Barrel/pincushion — simple UV remap |
| `fisheye_effect` | strength | UV remap from polar |
| `swirl_effect` | angle, radius | Rotational UV warp |
| `displacement_map` | displacement_map tex, intensity | Feed a noise texture or audio-driven texture as displacer |
| `noise_distortion` | intensity, scale, seed | Perlin/simplex noise displacement — simplex already in `video_glitch.metal`! |

### Glitch (1 GPU, 7 CPU)
| Effect | GPU? | VJ interest |
|---|---|---|
| `video_glitch` | ✅ Metal | Production-ready |
| `glitch_effect` | — | Block corruption |
| `rgb_shift_glitch` | — | Beat-sync channel split |
| `block_shuffle` | — | Random block rearrangement |
| `scanline` | — | CRT aesthetic |
| `vhs_effect` | — | Analog artifact |
| `datamosh` | — | Needs prev frame — temporal; tricky on GPU |

### Temporal (all CPU)
| Effect | Notes |
|---|---|
| `feedback_transform` | Zoom+rotate into self; GPU version needs double-buffer ping-pong texture |
| `echo_trails` | Frame accumulation, decay — fits well as GPU blend pass |
| `motion_blur` | N-frame blend — GPU multi-texture sample |
| `strobe_effect` | Simply gate output texture |

---

## Vidmod-Unique Effects (not in MachinaVFX — most are complex CPU-only, all prime for Metal porting)

### BitplaneReactor
Extracts bitplanes from the image, runs a **Wolfram elementary cellular automaton** on them, blends back. Audio-reactive via bass energy and beat transient (envelope follower + beat delta). Runs at configurable `sim_scale` (e.g. 0.5×) for perf.

**Metal port idea:** Each thread handles one row. CA step is data-parallel per row (1D automaton). Two-pass: CA step kernel → blend kernel. Audio params arrive via buffer.

### CAGlow
Runs a **multi-state cellular automaton** (up to 6 states) on a downscaled luma image, then Gaussian blurs and composites as a glow layer. The CA neighbourhood mixing is the key variable.

**Metal port idea:** CA step as compute kernel on half/quarter-res texture → Gaussian blur (already have the shader) → blend with alpha. Very parallelizable.

### MoldTrails
Physarum-style **slime mould agent simulation**: N agents (default 4000), each with sensor angle/distance and turn/move speed. Agents deposit trail, trail diffuses and decays per frame. Brightness-weighted spawn from video luminance.

**Metal port idea:** Agents as a structured buffer (`[[buffer(0)]]`). Agent update and trail deposit in one kernel, trail diffuse+decay in a second. This is textbook GPU particle simulation — should run 100k+ agents at 60fps with Metal.

### MoldTrails audio reactivity: `sensor_angle`, `move_speed`, `deposit_amount`, `decay_rate` all mapped to audio bands.

### NeuralCircle / NeuralTile
Grid of "neurons" (circle or tile cells). Each neuron's activation is computed from its pixel brightness, neighbours fold influence via `mode` (vertical/4-way/horizontal), iterated N times per frame. Audio modulates the activation coefficients. Neurons can shift position (`movement` param).

**Metal port idea:** 2D grid → each thread = one neuron. Iteration requires sync between steps but a small iteration count (5) means 5 sequential dispatch calls. The activation function is simple math — very GPU-friendly.

### FractalEffect
**Julia set** rendered on video: `z = z² + c` iteration, with `input_warp` (source image warps the complex-plane coordinates) and `color_source_mix` (colours fractal from source pixels). `cx`/`cy` parameters define the Julia constant; audio deepens `max_iter`.

**Metal port idea:** Each pixel = one thread computing Julia iterations. This is the canonical GPU fractal workload. With Metal the full-res Julia set is trivially real-time. The `input_warp` trick (reading source pixel to perturb UV) is a single texture read per thread.

### EdgeInkEffect
Canny/threshold edge detect → coloured ink overlay, blended. Edge threshold adapted by audio RMS.

**Metal port idea:** Sobel kernel (already in `edge_detect.metal`) → threshold step → tint → blend. Three sequential passes, all pixel-parallel.

### DiffuseEffect
Iterative Gaussian diffuse with audio-scaled kernel size and iteration count — essentially a multi-resolution blur that grows with RMS.

**Metal port idea:** Loop N times over `gaussian_blur_kernel` or `box_blur` with growing kernel. On Metal, chain multiple dispatches or use a persistent texture.

### LightEffect / ShadowEffect
Morphological dilation (Light) / erosion (Shadow) + scaled blend. Audio gain controls the morph coeff.

**Metal port idea:** Min/max filter kernel — sliding window over texture, perfectly parallel.

### CircleQuiltEffect
NxM grid of soft-edged circles, each circle's radius driven by audio band energy at that grid cell's mapped frequency. Creates a frequency-reactive polka-dot field.

**Metal port idea:** Each thread = one circle's pixel. Pass frequency band array in a buffer. Very clean GPU work.

### AudioColorEffect
Maps 8-band FFT to HSV channels in three modes: RGB direct scale, HSV dominant-frequency hue, HSV spectral mapping. Uses FFTW on CPU currently.

**Metal port idea:** FFT stays on CPU (FFTW); pass 8 floats as a small buffer to a `hsv_shift`-derived kernel that does the band→hue mapping on GPU.

### FFTEffect
Applies FFT band magnitudes directly as per-channel brightness multipliers (R, G, B coefficients from bass/mid/treble). Simple but immediate audio→colour coupling.

**Metal port idea:** Three-float buffer → per-pixel multiply. Single kernel pass on existing `adjust_brightness` pattern.

---

## New FX Ideas Enabled by Combining Both Codebases + Metal

### 1. Noise-Warp Feedback Loop
Chain: `simplex noise displacement` (steal noise math from `video_glitch.metal`) → `feedback_transform` (zoom+rotate into displaced result) → `echo_trails` decay. Audio drives warp intensity and zoom speed. Pure Metal ping-pong texture loop.

### 2. Audio-Reactive Kaleidoscope + Hue Cycle
`kaleidoscope` (GPU UV fold) → `hue_cycle` (already in Metal, position-based). Segment count quantized to beat downbeat. Phase offset mapped to BPM clock.

### 3. Julia Glitch
`FractalEffect` Julia render → `video_glitch` simplex scanline drift layered over it. Julia `cx`/`cy` driven by bass/mid; glitch displacement by kick transients. Fully GPU.

### 4. Physarum on Video
`MoldTrails` GPU port: video luma seeds agent positions. Agents trace trails over live video texture. Trail texture composited with additive blend + `hue_cycle` tint. ~100k agents at 60fps on Apple Silicon.

### 5. Wolfram Bitplane Reactor into CA Glow
`BitplaneReactor` → `CAGlow`: bitplane CA output feeds the CA Glow's state texture. Double-CA stack. Both downscaled. Bass drives CA rule selection; treble drives glow blur size.

### 6. Spectral Circle Quilt + Edge Ink
`CircleQuiltEffect` (frequency per cell) composited with `EdgeInkEffect` lines on top. Edge ink threshold cut by RMS so edges only show at high energy. Creates an animated frequency visualizer with ink-line structure.

### 7. Displacement from Audio Waveform Texture
Render audio waveform into a 1D texture (1×N), use it as a 1D displacement map feeding `displacement_map` kernel. Each row shifts horizontally by its corresponding sample value. Audio directly warps video geometry.

### 8. Strobe–Kaleidoscope–Zoom Triplet
Timed strobe gate → during ON phase, zoom + kaleidoscope (segments = 6 or 8 locked to beat). During OFF phase, echo trail decay. BPM-synced. MIDI-triggerable.

---

## Metal Architecture Notes for vjay_ace

- **Texture format:** `MTLPixelFormatRGBA16Float` for HDR chaining; downconvert to `RGBA8Unorm` only for display.
- **Ping-pong textures:** Two `MTLTexture` objects swapped per frame for temporal/feedback effects.
- **Params UBO:** Adopt MachinaVFX's `Params { int_params[16]; float_params[16]; }` — gives 16 int + 16 float slots per effect, accessed via `constant Params& params [[buffer(0)]]`.
- **Audio buffer:** Pass a small `float[]` buffer (8–64 floats: band energies, RMS, BPM phase) as `[[buffer(1)]]` to every kernel that needs audio reactivity.
- **Agent simulation (MoldTrails, NeuralGrid):** `MTLBuffer` for agent structs, read/write in compute kernel. Use `[[threadgroup_memory_barrier]]` between agent update and trail deposit.
- **Effect chain:** `MTLCommandBuffer` with one `MTLComputeCommandEncoder` per effect, ping-ponging textures. Commit per frame.
- **Resolution scaling:** Run simulation effects (CA, Mold, Neural) at 0.25–0.5× res, upscale with bilinear sample; run per-pixel effects at full res.

---

## Priority List for First Implementation Sprint

1. **Kaleidoscope** Metal kernel — immediate visual impact, low complexity
2. **Wave/Ripple distortion** kernels — UV-remap, no temporal state
3. **HSV full shift + rainbow cycle** kernels — color grading backbone
4. **Pixelate** kernel — beat-reactive, trivial
5. **Julia fractal** kernel — GPU showpiece, audio-reactive depth
6. **MoldTrails GPU** — agent simulation, most unique effect in the inventory
7. **Feedback transform** ping-pong — enables infinite zoom/rotate loops
8. **CircleQuiltEffect** GPU — spectral visualizer, clean and audio-reactive
9. **CAGlow** GPU — CA + blur chain
10. **BitplaneReactor** GPU — Wolfram CA per row
