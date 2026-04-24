#pragma once
#include <array>
#include <string>
#include <cstdint>

// ── Resolution ──────────────────────────────────────────────────────────────
// Working resolution for all layers and FX textures.
// Simulation effects (CA, MoldTrails) run at HALF_W x HALF_H and upscale.
inline constexpr int WORK_W = 1920;
inline constexpr int WORK_H = 1080;
inline constexpr int HALF_W = 960;
inline constexpr int HALF_H = 540;

// ── Layer topology ──────────────────────────────────────────────────────────
// 6 layers total (0–5):
//   Even layers (0,2,4) = image/video sources
//   Odd  layers (1,3,5) = FX patches modulating the layer below
inline constexpr int NUM_LAYERS = 6;
inline constexpr int NUM_FX_LAYERS = 3;  // layers 1, 3, 5
inline constexpr int NUM_SRC_LAYERS = 3; // layers 0, 2, 4

inline bool isFxLayer(int idx)  { return idx % 2 == 1 && idx < NUM_LAYERS; }
inline bool isSrcLayer(int idx) { return idx % 2 == 0 && idx < NUM_LAYERS; }

// ── MIDI mapping constants ──────────────────────────────────────────────────
// 6 physical knobs with their specific CC numbers
inline constexpr int NUM_KNOBS = 6;
inline constexpr std::array<int, NUM_KNOBS> KNOB_CCS = {3, 9, 12, 13, 14, 15};

// Returns knob index 0-5 for a given CC, or -1 if not a knob CC.
inline int ccToKnobIndex(int cc) {
    for (int i = 0; i < NUM_KNOBS; ++i)
        if (KNOB_CCS[i] == cc) return i;
    return -1;
}

// FX patch select notes start at C2 = 36 (freed from mode-latch — modes now on O/G keys)
inline constexpr int NOTE_SCENE_BASE = 36;   // C2
inline constexpr int NUM_SCENES      = 16;   // C2 (36) … C#3 (51)

// ── Knob value range ────────────────────────────────────────────────────────
inline constexpr int CC_MIN = 0;
inline constexpr int CC_MAX = 127;
inline float ccToNorm(int cc) { return static_cast<float>(cc) / 127.0f; }

// ── FX parameter slots ──────────────────────────────────────────────────────
// Each FX layer exposes exactly 2 modulatable params
inline constexpr int FX_PARAM_COUNT = 2;

// ── Knob colour mapping (dark blue → bright red via cc value) ───────────────
// Caller interpolates: at cc=0 → {0,0,120}, at cc=127 → {220,20,20}
struct KnobColour { uint8_t r, g, b; };
inline KnobColour ccToKnobColour(int cc) {
    float t = ccToNorm(cc);
    return {
        static_cast<uint8_t>(t * 220),
        0,
        static_cast<uint8_t>((1.0f - t) * 120)
    };
}

// ── FX patch IDs ────────────────────────────────────────────────────────────
enum class FxPatchId : int {
    None           = 0,
    Passthrough    = 1,
    Blur           = 2,
    ChromaticAberr = 3,
    HueCycle       = 4,
    VideoGlitch    = 5,
    Kaleidoscope   = 6,
    WaveDistort    = 7,
    EdgeInk        = 8,
    MoldTrails     = 9,
    Fractal        = 10,
    Pixelate       = 11,
    RainbowShift   = 12,
    JuliaFractal   = 13,
    FeedbackZoom   = 14,
    CircleQuilt    = 15,
    CAGlow         = 16,
    BitplaneReactor= 17,
    LIFModulate    = 18,
    LIFReplace     = 19,
    COUNT
};

inline const char* fxPatchName(FxPatchId id) {
    switch (id) {
        case FxPatchId::None:           return "None";
        case FxPatchId::Passthrough:    return "Passthrough";
        case FxPatchId::Blur:           return "Blur";
        case FxPatchId::ChromaticAberr: return "Chroma Aberr";
        case FxPatchId::HueCycle:       return "Hue Cycle";
        case FxPatchId::VideoGlitch:    return "Video Glitch";
        case FxPatchId::Kaleidoscope:   return "Kaleidoscope";
        case FxPatchId::WaveDistort:    return "Wave Distort";
        case FxPatchId::EdgeInk:        return "Edge Ink";
        case FxPatchId::MoldTrails:     return "Mold Trails";
        case FxPatchId::Fractal:        return "Fractal";
        case FxPatchId::Pixelate:       return "Pixelate";
        case FxPatchId::RainbowShift:   return "Rainbow";
        case FxPatchId::JuliaFractal:   return "Julia";
        case FxPatchId::FeedbackZoom:   return "Feedback Zoom";
        case FxPatchId::CircleQuilt:    return "Circle Quilt";
        case FxPatchId::CAGlow:         return "CA Glow";
        case FxPatchId::BitplaneReactor:return "Bitplane";
        case FxPatchId::LIFModulate:    return "LIF Modulate";
        case FxPatchId::LIFReplace:     return "LIF Replace";
        default:                        return "???";
    }
}

// Returns descriptive label for each of the two knob params of an FX patch.
// paramIdx: 0 = first knob, 1 = second knob.
inline const char* fxParamName(FxPatchId id, int paramIdx) {
    switch (id) {
    case FxPatchId::None:
    case FxPatchId::Passthrough:
      return "-";
        case FxPatchId::Blur:
            return paramIdx == 0 ? "Kernel Size" : "-";
        case FxPatchId::ChromaticAberr:
            return paramIdx == 0 ? "Offset (px)" : "-";
        case FxPatchId::HueCycle:
            return paramIdx == 0 ? "Speed" : "Time Offset";
        case FxPatchId::VideoGlitch:
            return paramIdx == 0 ? "Displace" : "Chan Shift";
        case FxPatchId::Kaleidoscope:
            return paramIdx == 0 ? "Segments" : "Rotation";
        case FxPatchId::WaveDistort:
            return paramIdx == 0 ? "Amplitude" : "Frequency";
        case FxPatchId::EdgeInk:
            return paramIdx == 0 ? "Threshold" : "Edge Strength";
        case FxPatchId::MoldTrails:
            return paramIdx == 0 ? "Sensor Angle" : "Decay";
        case FxPatchId::Fractal:
        case FxPatchId::JuliaFractal:
            return paramIdx == 0 ? "C real" : "C imag";
        case FxPatchId::Pixelate:
            return paramIdx == 0 ? "Block Size" : "-";
        case FxPatchId::RainbowShift:
            return paramIdx == 0 ? "Speed" : "Wave Scale";
        case FxPatchId::FeedbackZoom:
            return paramIdx == 0 ? "Zoom Delta" : "Rotate Delta";
        case FxPatchId::CircleQuilt:
            return paramIdx == 0 ? "Grid Cols" : "Radius Scale";
        case FxPatchId::CAGlow:
            return paramIdx == 0 ? "Threshold" : "Glow Spread";
        case FxPatchId::BitplaneReactor:
            return paramIdx == 0 ? "CA Rule" : "Threshold";
        case FxPatchId::LIFModulate:
        case FxPatchId::LIFReplace:
          return paramIdx == 0 ? "Influence" : "Topology";
        default:
            return paramIdx == 0 ? "P1" : "P2";
    }
}

// ── KnobMode ────────────────────────────────────────────────────────────────
enum class KnobMode {
    LayerLevel,   // O key held: knobs 0-2 → FX layer opacities (layers 1, 3, 5)
    FxAudio,      // G key held: knobs 0-5 → per-FX audio gain
    FxParam,      // default: knobs control active FX patch params 1 & 2 per FX layer
    ImgRotate,    // R key held: knobs 0-2 → rotation (0–2π) for layers 0, 2, 4
    ImgZoom,      // Z key held: knobs 0-2 → zoom factor for layers 0, 2, 4
    ImgPan,       // P key held: knobs 0/1,2/3,4/5 → H/V pan for src layers 0,2,4
};

// ── Per-layer state (plain data, owned by LayerManager) ────────────────────
struct LayerState {
    // Source layers
    std::string mediaPath;   // path to image or video file
    float       opacity = 1.0f;

    // FX layers
    FxPatchId   fxPatch  = FxPatchId::None;
    float       fxParam[FX_PARAM_COUNT] = {0.5f, 0.5f};
    float       audioGain     = 1.0f;

    // Shared
    int         lastCC[6] = {};  // last CC values received for this layer's 6 knobs
};

// ── Scene ──────────────────────────────────────────────────────────────────
// A scene sets all three FX layer patches and their default parameters at once.
// Triggered by MIDI note-on in range D2(38)…D#3(51).
struct Scene {
    const char* name;
    FxPatchId   fx[NUM_FX_LAYERS];                  // patch for slots 0,1,2
    float       params[NUM_FX_LAYERS][FX_PARAM_COUNT]; // p0,p1 for each slot
};

// 14 scene stubs — one per pad D2…D#3
inline constexpr Scene SCENES[NUM_SCENES] = {
    // 00  D2   – bare pass-through, all layers visible
    { "Pass-Through",
      { FxPatchId::Passthrough, FxPatchId::Passthrough, FxPatchId::Passthrough },
      { {0.5f,0.5f}, {0.5f,0.5f}, {0.5f,0.5f} } },

    // 01  D#2  – kaleidoscope + slow hue rotation
    { "Kaleidoscope",
      { FxPatchId::Kaleidoscope, FxPatchId::HueCycle, FxPatchId::LIFModulate },
      { {0.5f,0.2f}, {0.2f,0.5f}, {0.35f,0.0f} } },

    // 02  E2   – rainbow colour wash over all layers
    { "Rainbow",
      { FxPatchId::RainbowShift, FxPatchId::RainbowShift, FxPatchId::RainbowShift },
      { {0.5f,0.5f}, {0.3f,0.7f}, {0.7f,0.3f} } },

    // 03  F2   – beat-ready pixelate on slot 0, hue on others
    { "Pixelate",
      { FxPatchId::Pixelate, FxPatchId::HueCycle, FxPatchId::Passthrough },
      { {0.3f,0.5f}, {0.2f,0.5f}, {0.5f,0.5f} } },

    // 04  F#2  – julia fractal overlay + chromatic on top
    { "Julia",
      { FxPatchId::JuliaFractal, FxPatchId::ChromaticAberr, FxPatchId::Passthrough },
      { {0.6f,0.4f}, {0.5f,0.5f}, {0.5f,0.5f} } },

    // 05  G2   – glitch storm: glitch + wave + chroma
    { "Glitch Storm",
      { FxPatchId::VideoGlitch, FxPatchId::WaveDistort, FxPatchId::ChromaticAberr },
      { {0.6f,0.5f}, {0.4f,0.3f}, {0.5f,0.5f} } },

    // 06  G#2  – feedback zoom loop (infinite tunnel)
    { "Feedback Tunnel",
      { FxPatchId::FeedbackZoom, FxPatchId::HueCycle, FxPatchId::LIFReplace },
      { {0.5f,0.3f}, {0.2f,0.5f}, {0.42f,0.6f} } },

    // 07  A2   – circle quilt spectral visualiser
    { "Circle Quilt",
      { FxPatchId::CircleQuilt, FxPatchId::Passthrough, FxPatchId::Passthrough },
      { {0.5f,0.8f}, {0.5f,0.5f}, {0.5f,0.5f} } },

    // 08  A#2  – CA glow on all layers
    { "CA Glow",
      { FxPatchId::CAGlow, FxPatchId::CAGlow, FxPatchId::Passthrough },
      { {0.4f,0.5f}, {0.6f,0.3f}, {0.5f,0.5f} } },

    // 09  B2   – Wolfram bitplane reactor
    { "Bitplane",
      { FxPatchId::BitplaneReactor, FxPatchId::Passthrough, FxPatchId::HueCycle },
      { {0.72f,0.5f}, {0.5f,0.5f}, {0.3f,0.5f} } },

    // 10  C3   – soft blur haze
    { "Blur Haze",
      { FxPatchId::Blur, FxPatchId::Blur, FxPatchId::Passthrough },
      { {0.3f,0.5f}, {0.2f,0.5f}, {0.5f,0.5f} } },

    // 11  C#3  – edge ink + rainbow
    { "Ink Rainbow",
      { FxPatchId::EdgeInk, FxPatchId::RainbowShift, FxPatchId::Passthrough },
      { {0.4f,0.7f}, {0.5f,0.6f}, {0.5f,0.5f} } },

    // 12  D3   – julia + feedback + CA glow (deep audio-reactive)
    { "Deep Space",
      { FxPatchId::JuliaFractal, FxPatchId::FeedbackZoom, FxPatchId::CAGlow },
      { {0.5f,0.3f}, {0.4f,0.2f}, {0.5f,0.6f} } },

    // 13  D#3  – kitchen sink: everything layered
    { "Total Chaos",
      { FxPatchId::VideoGlitch, FxPatchId::Kaleidoscope, FxPatchId::BitplaneReactor },
      { {0.7f,0.6f}, {0.5f,0.3f}, {0.85f,0.5f} } },

    // 14  E3   – LIF state texture modulates source with hue drift
    { "Neural Pulse",
      { FxPatchId::LIFModulate, FxPatchId::HueCycle, FxPatchId::Passthrough },
      { {0.55f,0.0f}, {0.3f,0.5f}, {0.5f,0.5f} } },

    // 15  F3   – LIF state texture replaces source while chaos layers stack above it
    { "Spike Storm",
      { FxPatchId::LIFReplace, FxPatchId::Kaleidoscope, FxPatchId::VideoGlitch },
      { {0.75f,0.8f}, {0.52f,0.18f}, {0.45f,0.35f} } },
};
