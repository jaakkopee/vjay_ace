#pragma once
#include "Constants.h"
#include "LayerManager.h"
#include "MidiRouter.h"
#include "MetalCompositor.h"
#include "ControlWindow.h"
#include "PerformanceWindow.h"
#include <vector>
#include <memory>

// ── FxPatch (stub base for future per-patch state) ───────────────────────────
// Each FX layer holds one active patch. Parameters come from MIDI knobs.
// This will grow when individual effects need persistent state (e.g. MoldTrails agents).
struct FxPatch {
    FxPatchId id    = FxPatchId::None;
    float     p[2]  = {0.5f, 0.5f}; // param 0 and param 1
    float     audioGain     = 1.0f;
    float     bandpassHz    = 1000.0f;
};

// ── App ───────────────────────────────────────────────────────────────────────
// Top-level orchestrator. Owns all subsystems, wires MIDI → layer state → GPU.

class App {
public:
    App();
    ~App();

    // Initialise all subsystems. Returns false on fatal error.
    bool init();

    // Run the main loop until both windows are closed.
    void run();

private:
    // Subsystems
    LayerManager      layers_;
    MidiRouter        midi_;
    MetalCompositor   compositor_;
    ControlWindow     controlWin_;
    PerformanceWindow perfWin_;

    // Per FX layer (slots 0=layer1, 1=layer3, 2=layer5)
    std::array<FxPatch, NUM_FX_LAYERS> fxPatches_;

    // Current knob mode
    KnobMode knobMode_ = KnobMode::FxParam;

    // Last CC values per knob (0–5)
    std::array<int, 6> knobCC_ = {};

    // Composited pixel output
    std::vector<uint8_t> compositePixels_;
    sf::Texture          compositeTex_;

    // ── Wiring ───────────────────────────────────────────────────────────
    void wireCallbacks();

    // Called by MidiRouter when a knob moves
    void onKnob(int knobIdx, float normValue, KnobMode mode);
    // Called by MidiRouter when a scene pad is hit
    void onSceneSelect(int sceneIdx);
    // Called by ControlWindow when user drags a knob
    void onKnobDrag(int knobIdx, float normValue);

    // ── Per-frame ────────────────────────────────────────────────────────
    void processFrame();
    void uploadLayers();
    void syncCompositorState();
};
