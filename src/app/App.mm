#include "App.h"
#import  <AppKit/AppKit.h>  // NSScreen for display positions
#include <iostream>

// ── helpers ──────────────────────────────────────────────────────────────────

// Returns the origin (top-left in screen coords) of display N (0 = primary).
static sf::Vector2i screenOrigin(int displayIndex) {
    NSArray<NSScreen*>* screens = [NSScreen screens];
    if (displayIndex >= static_cast<int>(screens.count))
        return {0, 0};
    NSRect frame = screens[displayIndex].frame;
    // macOS Y is bottom-up; SFML Y is top-down.
    // Primary screen height for coordinate flip:
    CGFloat primaryH = screens[0].frame.size.height;
    return {
        static_cast<int>(frame.origin.x),
        static_cast<int>(primaryH - frame.origin.y - frame.size.height)
    };
}

static sf::Vector2i screenSize(int displayIndex) {
    NSArray<NSScreen*>* screens = [NSScreen screens];
    if (displayIndex >= static_cast<int>(screens.count))
        return {1920, 1080};
    NSRect frame = screens[displayIndex].frame;
    return {static_cast<int>(frame.size.width), static_cast<int>(frame.size.height)};
}

// ── App ───────────────────────────────────────────────────────────────────────

App::App() = default;
App::~App() = default;

bool App::init() {
    // ── Metal compositor ─────────────────────────────────────────────────
    if (!compositor_.init()) {
        std::cerr << "[App] Metal compositor init failed — GPU unavailable\n";
        // Continue in "software preview" mode (no compositing)
    }

    // ── Windows ──────────────────────────────────────────────────────────
    auto ctrl  = screenOrigin(0);
    auto ctrlS = screenSize(0);
    controlWin_.open(ctrl.x, ctrl.y, ctrlS.x, ctrlS.y);

    auto perf  = screenOrigin(1);   // Second display
    auto perfS = screenSize(1);
    if (perfS.x == 0) {            // Fallback: no second screen — use a window
        perf  = {ctrlS.x / 2, 50};
        perfS = {960, 540};
    }
    perfWin_.open(perf.x, perf.y, perfS.x, perfS.y);

    // Pre-allocate composite texture (SFML side for preview)
    if (!compositeTex_.resize({WORK_W, WORK_H}))
        std::cerr << "[App] Cannot create composite SFML texture\n";

    // ── MIDI ─────────────────────────────────────────────────────────────
    auto ports = midi_.portNames();
    if (!ports.empty()) {
        midi_.openPort(0);
        std::cout << "[App] MIDI opened: " << ports[0] << "\n";
    } else {
        std::cout << "[App] No MIDI ports found\n";
    }

    wireCallbacks();

    // ── Default FX names in control window ───────────────────────────────
    for (int row = 0; row < NUM_FX_LAYERS; ++row) {
        controlWin_.setEffectName(row * 2,     "Src " + std::to_string(row * 2));
        controlWin_.setEffectName(row * 2 + 1, fxPatchName(FxPatchId::None));
    }
    controlWin_.setEffectName(6 - 1, "Src 6");   // last row = top source layer

    return true;
}

// ── Callbacks ─────────────────────────────────────────────────────────────────

void App::wireCallbacks() {
    midi_.onKnob = [this](int k, float v, KnobMode m){ onKnob(k, v, m); };
    midi_.onFxSelect = [this](int slot, FxPatchId p){ onFxSelect(slot, p); };
    midi_.onModeChange = [this](KnobMode m){
        knobMode_ = m;
        controlWin_.setKnobMode(m);
    };

    controlWin_.onKnobDrag = [this](int row, int knob, float v){
        onKnobDrag(row, knob, v);
    };
}

void App::onKnob(int knobIdx, float normValue, KnobMode mode) {
    knobCC_[knobIdx] = static_cast<int>(normValue * 127.0f);

    switch (mode) {
        case KnobMode::LayerLevel:
            // knobs 0–5 → layer opacities for layers 1–6
            if (knobIdx < NUM_LAYERS - 1)
                layers_.setOpacity(knobIdx + 1, normValue);
            break;

        case KnobMode::FxAudio:
            // knobs 0–2 → FX audio gain; knobs 3–5 → bandpass centre freq (100–8000 Hz)
            if (knobIdx < NUM_FX_LAYERS)
                layers_.setAudioGain(knobIdx * 2 + 1, normValue * 2.0f);
            else {
                int slot = knobIdx - NUM_FX_LAYERS;
                float hz = 100.0f + normValue * 7900.0f;
                layers_.setBandpass(slot * 2 + 1, hz);
            }
            break;

        case KnobMode::FxParam:
            // knobs 0,1 → FX slot 0 params; 2,3 → slot 1; 4,5 → slot 2
            {
                int slot  = knobIdx / 2;
                int param = knobIdx % 2;
                if (slot < NUM_FX_LAYERS) {
                    fxPatches_[slot].p[param] = normValue;
                    compositor_.setFxParams(slot,
                                            fxPatches_[slot].p[0],
                                            fxPatches_[slot].p[1]);
                }
            }
            break;
    }

    // Mirror to control window knob display
    // Map knob to "row" = FX slot index (knob 0/1 → row 0, 2/3 → row 1, 4/5 → row 2)
    int displayRow = knobIdx / 2;
    controlWin_.setKnobValue(displayRow, knobIdx, knobCC_[knobIdx]);
}

void App::onFxSelect(int fxSlot, FxPatchId patch) {
    fxPatches_[fxSlot].id = patch;
    compositor_.setFxPatch(fxSlot, patch);
    int layerIdx = fxSlot * 2 + 1; // layer 1, 3, or 5
    layers_.setFxPatch(layerIdx, patch);
    controlWin_.setEffectName(fxSlot * 2 + 1, fxPatchName(patch));
}

void App::onKnobDrag(int layerRow, int knobIdx, float normValue) {
    // Treat mouse drag the same as a MIDI knob in current mode
    onKnob(layerRow * 2 + (knobIdx > 2 ? 1 : 0), normValue, knobMode_);
}

// ── Per-frame ─────────────────────────────────────────────────────────────────

void App::uploadLayers() {
    for (int li = 0; li < NUM_LAYERS; li += 2) {
        const uint8_t* px = layers_.pixelBuffer(li);
        if (px) compositor_.uploadLayerPixels(li, px, WORK_W, WORK_H);
    }
}

void App::syncCompositorState() {
    for (int li = 0; li < NUM_LAYERS; ++li)
        compositor_.setLayerOpacity(li, layers_.state(li).opacity);
    for (int slot = 0; slot < NUM_FX_LAYERS; ++slot) {
        compositor_.setFxPatch(slot, fxPatches_[slot].id);
        compositor_.setFxParams(slot, fxPatches_[slot].p[0], fxPatches_[slot].p[1]);
    }
}

void App::processFrame() {
    midi_.poll();
    layers_.update(60.0f);
    uploadLayers();
    syncCompositorState();

    // GPU composite → CPU readback
    if (compositor_.composite(compositePixels_)) {
        perfWin_.present(compositePixels_);
        compositeTex_.update(compositePixels_.data());
    }
}

// ── Main loop ─────────────────────────────────────────────────────────────────

void App::run() {
    while (controlWin_.isOpen() && perfWin_.isOpen()) {
        if (!controlWin_.handleEvents()) break;
        if (!perfWin_.handleEvents())    break;
        controlWin_.update();
        processFrame();
        controlWin_.render(compositeTex_);
    }
    controlWin_.close();
    perfWin_.close();
}
