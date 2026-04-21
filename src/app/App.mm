#include "App.h"
#import  <AppKit/AppKit.h>  // NSScreen for display positions
#include <iostream>
#include <fstream>

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

    // ── Media picker window — small panel on primary screen ──────────────
    // Position it below or beside the control window
    const std::string stashRoot = []{
        const char* home = getenv("HOME");
        return home ? std::string(home) + "/Documents/koodii/vjay_ace/Heikki_stash" : "";
    }();
    // Open picker as a smaller overlay on the same screen
    mediaPickerWin_.open(ctrl.x + ctrlS.x / 2, ctrl.y,
                         ctrlS.x / 2, ctrlS.y / 2, stashRoot);

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

    // ── Knob pickup state ────────────────────────────────────────────────
    knobLastPhys_.fill(0.5f);

    // ── Scene state objects — reset all to -1 (unvisited) ────────────────
    for (auto& s : scenes_) s.reset();

    wireCallbacks();

    // ── Restore persisted state ──────────────────────────────────────────
    loadState();  // populates scenes_ + applies last-active scene (no-op if first launch)

    // ── Default labels in control window ─────────────────────────────────
    controlWin_.setSceneName("None");
    mediaPickerWin_.setSceneName("None");
    constexpr const char* defaultNames[] = {"FX-1 P1","FX-1 P2","FX-2 P1","FX-2 P2","FX-3 P1","FX-3 P2"};
    for (int i = 0; i < NUM_KNOBS; ++i)
        controlWin_.setKnobParamName(i, defaultNames[i]);
    controlWin_.setKnobMode(knobMode_);
    refreshKnobDisplay();

    return true;
}

// ── Callbacks ─────────────────────────────────────────────────────────────────

void App::wireCallbacks() {
    midi_.onKnob = [this](int k, float v, KnobMode m){ onKnob(k, v, m); };
    midi_.onSceneSelect = [this](int idx){ onSceneSelect(idx); };
    midi_.onModeChange = [this](KnobMode m){
        if (rKeyHeld_ || zKeyHeld_) return;  // modifier key overrides; ignore while held
        knobMode_ = m;
        controlWin_.setKnobMode(m);
        static const char* opNames[]   = {"Layer 1","Layer 2","Layer 3","Layer 4","Layer 5","Layer 6"};
        static const char* gainNames[] = {"Gain 1",  "Gain 2",  "Gain 3",  "Gain 4",  "Gain 5",  "Gain 6"};
        static const char* fxNames[]   = {"FX-1 P1", "FX-1 P2", "FX-2 P1", "FX-2 P2", "FX-3 P1", "FX-3 P2"};
        const char** names = (m == KnobMode::LayerLevel) ? opNames
                           : (m == KnobMode::FxAudio)    ? gainNames : fxNames;
        for (int i = 0; i < NUM_KNOBS; ++i)
            controlWin_.setKnobParamName(i, names[i]);
        refreshKnobDisplay();
    };
    controlWin_.onKnobDrag = [this](int knob, float v){ onKnobDrag(knob, v); };

    // ── Shared helper: update display after a modifier key press/release ──
    auto refreshModifierDisplay = [this]() {
        static const char* rotNames[]  = {"Rot L0", "Rot L2", "Rot L4", "-", "-", "-"};
        static const char* zoomNames[] = {"Zoom L0","Zoom L2","Zoom L4","-","-","-"};
        static const char* opNames[]   = {"Layer 1","Layer 2","Layer 3","Layer 4","Layer 5","Layer 6"};
        static const char* gainNames[] = {"Gain 1", "Gain 2", "Gain 3", "Gain 4", "Gain 5", "Gain 6"};
        static const char* fxNames[]   = {"FX-1 P1","FX-1 P2","FX-2 P1","FX-2 P2","FX-3 P1","FX-3 P2"};
        KnobMode eff = effectiveMode();
        controlWin_.setKnobMode(eff);
        const char** names;
        if      (eff == KnobMode::ImgRotate)  names = rotNames;
        else if (eff == KnobMode::ImgZoom)    names = zoomNames;
        else if (eff == KnobMode::LayerLevel) names = opNames;
        else if (eff == KnobMode::FxAudio)    names = gainNames;
        else                                  names = fxNames;
        for (int i = 0; i < NUM_KNOBS; ++i)
            controlWin_.setKnobParamName(i, names[i]);
        refreshKnobDisplay();
    };

    controlWin_.onRKey = [this, refreshModifierDisplay](bool pressed) {
        if (pressed == rKeyHeld_) return;
        rKeyHeld_ = pressed;
        refreshModifierDisplay();
    };
    controlWin_.onZKey = [this, refreshModifierDisplay](bool pressed) {
        if (pressed == zKeyHeld_) return;
        zKeyHeld_ = pressed;
        refreshModifierDisplay();
    };
    mediaPickerWin_.onFileSelected = [this](int slot, const std::string& path){
        onImageSelected(slot, path);
    };
}

// ── Engine helper: apply one knob value to the right engine target ────────────

void App::applyKnob(int knobIdx, float v, KnobMode mode) {
    switch (mode) {
        case KnobMode::LayerLevel:
            if (knobIdx < NUM_LAYERS - 1)
                layers_.setOpacity(knobIdx + 1, v);
            break;
        case KnobMode::FxAudio:
            if (knobIdx < NUM_FX_LAYERS)
                layers_.setAudioGain(knobIdx * 2 + 1, v * 2.0f);
            else {
                int slot = knobIdx - NUM_FX_LAYERS;
                layers_.setBandpass(slot * 2 + 1, 100.0f + v * 7900.0f);
            }
            break;
        case KnobMode::FxParam: {
            int slot = knobIdx / 2, param = knobIdx % 2;
            if (slot < NUM_FX_LAYERS) {
                fxPatches_[slot].p[param] = v;
                compositor_.setFxParams(slot, fxPatches_[slot].p[0], fxPatches_[slot].p[1]);
            }
            break;
        }
        case KnobMode::ImgRotate:
            if (knobIdx < NUM_SRC_LAYERS)
                compositor_.setLayerRotation(knobIdx, v * 2.0f * 3.14159265f);
            break;
        case KnobMode::ImgZoom:
            if (knobIdx < NUM_SRC_LAYERS)
                // knob 0.5 = 1.0x (no zoom); exponential: 4^(v-0.5) → [0.5x .. 2.0x]
                compositor_.setLayerZoom(knobIdx, std::pow(4.0f, v - 0.5f));
            break;
    }
}

// ── Push all stored values from one scene to the engine ───────────────────────

void App::applySceneToEngine(int idx) {
    const SceneState& s = scenes_[idx];
    for (int mi = 0; mi < SceneState::NMODES; ++mi) {
        auto mode = static_cast<KnobMode>(mi);
        for (int k = 0; k < NUM_KNOBS; ++k) {
            if (s.knobs[mi][k] >= 0.0f)
                applyKnob(k, s.knobs[mi][k], mode);
        }
    }
}

// ── Sync all 6 knob arc widgets for the current mode ─────────────────────────

void App::refreshKnobDisplay() {
    if (currentScene_ < 0) return;
    KnobMode eff = effectiveMode();
    int mi = static_cast<int>(eff);
    const SceneState& s = scenes_[currentScene_];
    const bool modifierMode = (eff == KnobMode::ImgRotate || eff == KnobMode::ImgZoom);
    for (int k = 0; k < NUM_KNOBS; ++k) {
        // In rotate/zoom mode, only knobs 0-2 are active; show 0 for the rest.
        if (modifierMode && k >= NUM_SRC_LAYERS) {
            controlWin_.setKnobValue(k, 0);
            continue;
        }
        float v = s.knobs[mi][k];
        // If this knob hasn't been set in this scene yet, show physical position.
        float display = (v >= 0.0f) ? v : (modifierMode ? 0.0f : knobLastPhys_[k]);
        controlWin_.setKnobValue(k, static_cast<int>(display * 127.0f));
    }
}

// ── MIDI knob handler ─────────────────────────────────────────────────────────

void App::onKnob(int knobIdx, float normValue, KnobMode mode) {
    float prev = knobLastPhys_[knobIdx];
    knobLastPhys_[knobIdx] = normValue;

    // If no scene is active there's nothing to store or apply.
    if (currentScene_ < 0) return;

    // If a modifier key is held, override to its mode
    KnobMode effectiveMod = effectiveMode();
    // Only use MIDI-provided mode when no key is held
    KnobMode eff = (rKeyHeld_ || zKeyHeld_) ? effectiveMod : mode;
    int    mi   = static_cast<int>(eff);
    float& soft = scenes_[currentScene_].knobs[mi][knobIdx];

    // ── Pickup / catch-up ────────────────────────────────────────────────
    // soft == -1.0f → first touch in this scene: apply immediately.
    // Otherwise the physical pot must sweep through the stored value first.
    if (soft >= 0.0f) {
        bool crossed = (prev <= soft && soft <= normValue) ||
                       (normValue <= soft && soft <= prev);
        bool close   = std::abs(normValue - soft) < (3.0f / 127.0f);
        if (!crossed && !close) {
            // Not caught up — show physical position so the arc moves.
            controlWin_.setKnobValue(knobIdx, static_cast<int>(normValue * 127.0f));
            return;
        }
    }

    // Caught up (or first touch): store and apply.
    soft = normValue;
    applyKnob(knobIdx, normValue, eff);
    controlWin_.setKnobValue(knobIdx, static_cast<int>(normValue * 127.0f));
}

// ── Scene select ──────────────────────────────────────────────────────────────

void App::onSceneSelect(int sceneIdx) {
    if (sceneIdx < 0 || sceneIdx >= NUM_SCENES) return;

    currentScene_ = sceneIdx;
    const Scene& sc = SCENES[sceneIdx];

    // 1. Apply the scene's FX patch selection.
    for (int slot = 0; slot < NUM_FX_LAYERS; ++slot) {
        fxPatches_[slot].id = sc.fx[slot];
        compositor_.setFxPatch(slot, sc.fx[slot]);
        layers_.setFxPatch(slot * 2 + 1, sc.fx[slot]);
    }
    controlWin_.setSceneName(sc.name);
    mediaPickerWin_.setSceneName(sc.name);

    // Load this scene's image files into the 3 source layers
    for (int slot = 0; slot < NUM_SRC_LAYERS; ++slot) {
        const std::string& path = scenes_[sceneIdx].imgPaths[slot];
        if (!path.empty())
            layers_.loadMedia(slot * 2, path);
    }
    mediaPickerWin_.setSlotPaths(scenes_[sceneIdx].imgPaths);

    int fxMi = static_cast<int>(KnobMode::FxParam);
    SceneState& s = scenes_[sceneIdx];

    if (!s.hasData(fxMi)) {
        // First visit: seed FxParam knobs from SCENES[] defaults.
        // Applied directly to the engine; scene object stores them so
        // subsequent visits correctly restore them.
        for (int slot = 0; slot < NUM_FX_LAYERS; ++slot) {
            s.knobs[fxMi][slot * 2]     = sc.params[slot][0];
            s.knobs[fxMi][slot * 2 + 1] = sc.params[slot][1];
        }
    }

    // 2. Apply all stored knob values to the engine.
    applySceneToEngine(sceneIdx);

    // 3. Refresh the software knob arcs to show what is actually applied.
    refreshKnobDisplay();
}

// ── GUI knob drag ─────────────────────────────────────────────────────────────

void App::onKnobDrag(int knobIdx, float normValue) {
    if (currentScene_ < 0) return;
    int mi = static_cast<int>(knobMode_);
    // GUI drag bypasses pickup: write directly to scene and sync physical tracker.
    scenes_[currentScene_].knobs[mi][knobIdx] = normValue;
    knobLastPhys_[knobIdx] = normValue;
    applyKnob(knobIdx, normValue, knobMode_);
    controlWin_.setKnobValue(knobIdx, static_cast<int>(normValue * 127.0f));
}

// ── Image selected from media picker ──────────────────────────────────────────

void App::onImageSelected(int slotIdx, const std::string& path) {
    if (slotIdx < 0 || slotIdx >= NUM_SRC_LAYERS) return;
    if (currentScene_ >= 0)
        scenes_[currentScene_].imgPaths[slotIdx] = path;
    layers_.loadMedia(slotIdx * 2, path);
}

// ── State persistence ─────────────────────────────────────────────────────────

std::string App::statePath() {
    const char* home = getenv("HOME");
    return home ? std::string(home) + "/.vjay_ace_state" : "/tmp/vjay_ace_state";
}

void App::saveState() const {
    std::ofstream f(statePath(), std::ios::binary | std::ios::trunc);
    if (!f) { std::cerr << "[App] Could not save state\n"; return; }
    // Write magic + version for future-proofing
    const uint32_t magic = 0x56414345; // 'VACE'
    const uint32_t ver   = 5;
    f.write(reinterpret_cast<const char*>(&magic), 4);
    f.write(reinterpret_cast<const char*>(&ver),   4);
    // Write all 14 scene states (knobs + image paths)
    for (const auto& s : scenes_) {
        for (const auto& row : s.knobs)
            for (float v : row)
                f.write(reinterpret_cast<const char*>(&v), sizeof(float));
        // Write 3 image paths as length-prefixed strings
        for (const auto& p : s.imgPaths) {
            uint32_t len = static_cast<uint32_t>(p.size());
            f.write(reinterpret_cast<const char*>(&len), sizeof(len));
            if (len) f.write(p.data(), len);
        }
    }
    f.write(reinterpret_cast<const char*>(&currentScene_), sizeof(int));
    std::cout << "[App] State saved to " << statePath() << "\n";
}

void App::loadState() {
    std::ifstream f(statePath(), std::ios::binary);
    if (!f) return;
    uint32_t magic = 0, ver = 0;
    if (!f.read(reinterpret_cast<char*>(&magic), 4)) return;
    if (!f.read(reinterpret_cast<char*>(&ver),   4)) return;
    if (magic != 0x56414345) {
        std::cerr << "[App] Ignoring incompatible state file\n";
        return;
    }
    // v3: 3 modes, v4: 4 modes (added ImgRotate), v5: 5 modes (added ImgZoom)
    const bool isV3 = (ver == 3);
    const bool isV4 = (ver == 4);
    const bool isV5 = (ver == 5);
    if (!isV3 && !isV4 && !isV5) {
        std::cerr << "[App] Ignoring incompatible state file\n";
        return;
    }
    for (auto& s : scenes_) {
        int savedModes = isV3 ? 3 : isV4 ? 4 : SceneState::NMODES;
        for (int mi = 0; mi < savedModes; ++mi)
            for (float& v : s.knobs[mi])
                if (!f.read(reinterpret_cast<char*>(&v), sizeof(float))) return;
        // Rows beyond what was saved remain at -1 (default from reset())
        // Read 3 image paths
        for (auto& p : s.imgPaths) {
            uint32_t len = 0;
            if (!f.read(reinterpret_cast<char*>(&len), sizeof(len))) return;
            if (len > 4096) return; // sanity guard
            p.resize(len);
            if (len) { if (!f.read(p.data(), len)) return; }
        }
    }
    int savedScene = -1;
    if (f.read(reinterpret_cast<char*>(&savedScene), sizeof(int)))
        currentScene_ = savedScene;

    // Apply the last-active scene to the engine
    if (currentScene_ >= 0) {
        const Scene& sc = SCENES[currentScene_];
        for (int slot = 0; slot < NUM_FX_LAYERS; ++slot) {
            fxPatches_[slot].id = sc.fx[slot];
            compositor_.setFxPatch(slot, sc.fx[slot]);
            layers_.setFxPatch(slot * 2 + 1, sc.fx[slot]);
        }
        controlWin_.setSceneName(sc.name);
        mediaPickerWin_.setSceneName(sc.name);
        // Load persisted images
        for (int slot = 0; slot < NUM_SRC_LAYERS; ++slot) {
            const std::string& path = scenes_[currentScene_].imgPaths[slot];
            if (!path.empty()) layers_.loadMedia(slot * 2, path);
        }
        mediaPickerWin_.setSlotPaths(scenes_[currentScene_].imgPaths);
        applySceneToEngine(currentScene_);
    }
    std::cout << "[App] State restored from " << statePath() << "\n";
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
    } else {
        perfWin_.clearBlack();
    }
}

// ── Main loop ─────────────────────────────────────────────────────────────────

void App::run() {
    while (controlWin_.isOpen() && perfWin_.isOpen()) {
        if (!controlWin_.handleEvents()) break;
        if (!perfWin_.handleEvents())    break;
        if (mediaPickerWin_.isOpen()) mediaPickerWin_.handleEvents();
        controlWin_.update();
        processFrame();
        controlWin_.render(compositeTex_);
        if (mediaPickerWin_.isOpen()) mediaPickerWin_.render();
    }
    saveState();
    controlWin_.close();
    perfWin_.close();
}
