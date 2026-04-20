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
// 7 layers total (0–6):
//   Even layers (0,2,4,6) = image/video sources
//   Odd  layers (1,3,5)   = FX patches modulating the layer below
inline constexpr int NUM_LAYERS = 7;
inline constexpr int NUM_FX_LAYERS = 3;  // layers 1, 3, 5
inline constexpr int NUM_SRC_LAYERS = 4; // layers 0, 2, 4, 6

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

// Special note mappings (channel 1, note numbers)
inline constexpr int NOTE_LAYER_OPACITY_MODE  = 36; // C2  held → 6 knobs = layer opacities
inline constexpr int NOTE_FX_AUDIO_MODE       = 37; // C#2 held → 6 knobs = audio gain

// FX patch select notes start at D2 = 38
inline constexpr int NOTE_SCENE_BASE = 38;   // D2
inline constexpr int NUM_SCENES      = 14;   // D2 (38) … D#3 (51)

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
        default:                        return "???";
    }
}

// ── KnobMode ────────────────────────────────────────────────────────────────
enum class KnobMode {
    LayerLevel,   // C2  held: knobs 0-5 → layer opacities (layers 1-6)
    FxAudio,      // C#2 held: knobs 0-2 → FX audio gain; knobs 3-5 → FX bandpass freq
    FxParam,      // default: knobs control active FX patch params 1 & 2 per FX layer
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
    float       bandpassFreqHz = 1000.0f; // centre frequency of audio bandpass

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

    // 01  D#2  – soft blur over everything
    { "Blur Haze",
      { FxPatchId::Blur, FxPatchId::Blur, FxPatchId::None },
      { {0.3f,0.5f}, {0.2f,0.5f}, {0.5f,0.5f} } },

    // 02  E2   – chromatic aberration on slot 0
    { "Chroma Drift",
      { FxPatchId::ChromaticAberr, FxPatchId::None, FxPatchId::None },
      { {0.6f,0.5f}, {0.5f,0.5f}, {0.5f,0.5f} } },

    // 03  F2   – slow hue rotation on all slots
    { "Hue Wash",
      { FxPatchId::HueCycle, FxPatchId::HueCycle, FxPatchId::HueCycle },
      { {0.2f,0.5f}, {0.5f,0.5f}, {0.8f,0.5f} } },

    // 04  F#2  – glitch on slot 0 only
    { "Glitch Solo",
      { FxPatchId::VideoGlitch, FxPatchId::None, FxPatchId::None },
      { {0.5f,0.4f}, {0.5f,0.5f}, {0.5f,0.5f} } },

    // 05  G2   – heavy glitch on all slots
    { "Full Glitch",
      { FxPatchId::VideoGlitch, FxPatchId::VideoGlitch, FxPatchId::VideoGlitch },
      { {0.7f,0.6f}, {0.5f,0.5f}, {0.3f,0.4f} } },

    // 06  G#2  – kaleidoscope top layer
    { "Kaleidoscope",
      { FxPatchId::None, FxPatchId::None, FxPatchId::Kaleidoscope },
      { {0.5f,0.5f}, {0.5f,0.5f}, {0.5f,0.3f} } },

    // 07  A2   – wave distortion
    { "Wave",
      { FxPatchId::WaveDistort, FxPatchId::None, FxPatchId::None },
      { {0.5f,0.4f}, {0.5f,0.5f}, {0.5f,0.5f} } },

    // 08  A#2  – edge ink / Sobel outline
    { "Ink Outline",
      { FxPatchId::EdgeInk, FxPatchId::None, FxPatchId::None },
      { {0.5f,0.6f}, {0.5f,0.5f}, {0.5f,0.5f} } },

    // 09  B2   – mold trails simulation
    { "Mold Trails",
      { FxPatchId::MoldTrails, FxPatchId::None, FxPatchId::None },
      { {0.5f,0.5f}, {0.5f,0.5f}, {0.5f,0.5f} } },

    // 10  C3   – fractal zoom
    { "Fractal",
      { FxPatchId::Fractal, FxPatchId::None, FxPatchId::None },
      { {0.5f,0.5f}, {0.5f,0.5f}, {0.5f,0.5f} } },

    // 11  C#3  – chroma + hue combo
    { "Prisma",
      { FxPatchId::ChromaticAberr, FxPatchId::HueCycle, FxPatchId::None },
      { {0.6f,0.5f}, {0.3f,0.5f}, {0.5f,0.5f} } },

    // 12  D3   – glitch + wave + ink
    { "Storm",
      { FxPatchId::VideoGlitch, FxPatchId::WaveDistort, FxPatchId::EdgeInk },
      { {0.6f,0.5f}, {0.5f,0.4f}, {0.5f,0.7f} } },

    // 13  D#3  – mold + hue + fractal deep
    { "Deep",
      { FxPatchId::MoldTrails, FxPatchId::HueCycle, FxPatchId::Fractal },
      { {0.5f,0.5f}, {0.4f,0.5f}, {0.5f,0.6f} } },
};
