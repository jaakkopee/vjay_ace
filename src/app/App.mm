#include "App.h"
#import  <AppKit/AppKit.h>  // NSScreen for display positions
#include <iostream>
#include <fstream>
#include <csignal>

// ── Signal handling: save state on Ctrl-C / kill ─────────────────────────────
static App* g_sigApp = nullptr;
static void appSigHandler(int) {
    if (g_sigApp) g_sigApp->saveState();
    std::_Exit(0);
}

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
    // ── Register signal handlers so Ctrl-C saves state before exit ───────
    g_sigApp = this;
    std::signal(SIGINT,  appSigHandler);
    std::signal(SIGTERM, appSigHandler);

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

    // ── Audio capture ─────────────────────────────────────────────────
    if (!audio_.start())
        std::cerr << "[App] Audio capture unavailable (no mic/line-in?)\n";

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
    if (currentScene_ >= 0) refreshKnobParamNames();

    return true;
}

// ── Callbacks ─────────────────────────────────────────────────────────────────

void App::wireCallbacks() {
    midi_.onKnob = [this](int k, float v, KnobMode m){ onKnob(k, v, m); };
    midi_.onSceneSelect = [this](int idx){ onSceneSelect(idx); };
    midi_.onModeChange = [this](KnobMode m){
        if (rKeyHeld_ || zKeyHeld_ || oKeyHeld_ || gKeyHeld_ || pKeyHeld_ || fKeyHeld_ || cKeyHeld_) return;  // modifier key overrides; ignore while held
        knobMode_ = m;
        controlWin_.setKnobMode(m);
        static const char* opNames[]   = {"Opac L0", "-", "Opac L1", "-", "Opac L2", "-"};
        static const char* gainNames[] = {"Gain 0", "-", "Gain 1", "-", "Gain 2", "-"};
        if (m == KnobMode::LayerLevel) {
            for (int i = 0; i < NUM_KNOBS; ++i)
                controlWin_.setKnobParamName(i, opNames[i]);
        } else if (m == KnobMode::FxAudio) {
            for (int i = 0; i < NUM_KNOBS; ++i)
                controlWin_.setKnobParamName(i, gainNames[i]);
        } else {
            refreshKnobParamNames();
        }
        refreshKnobDisplay();
    };
    controlWin_.onKnobDrag = [this](int knob, float v){ onKnobDrag(knob, v); };

    // ── Shared helper: update display after a modifier key press/release ──
    auto refreshModifierDisplay = [this]() {
        static const char* rotNames[]   = {"Rot L0",    "-", "Rot L1",    "-", "Rot L2",    "-"};
        static const char* zoomNames[]  = {"Zoom L0",   "-", "Zoom L1",   "-", "Zoom L2",   "-"};
        static const char* opNames[]    = {"Opac L0",   "-", "Opac L1",   "-", "Opac L2",   "-"};
        static const char* gainNames[]  = {"Gain 0",    "-", "Gain 1",    "-", "Gain 2",    "-"};
        static const char* panNames[]   = {"Pan0 X", "Pan0 Y", "Pan1 X", "Pan1 Y", "Pan2 X", "Pan2 Y"};
        static const char* xfadeNames[]  = {"ImgFd 0",   "-", "ImgFd 1",   "-", "ImgFd 2",   "-"};
        static const char* scnFdNames[]  = {"ScnFd 0",   "-", "ScnFd 1",   "-", "ScnFd 2",   "-"};
        if (fKeyHeld_) {
            // F key overrides: show image-load crossfade speed mode
            controlWin_.setKnobMode(KnobMode::FxParam); // reuse any label; will be overridden below
            for (int i = 0; i < NUM_KNOBS; ++i) controlWin_.setKnobParamName(i, xfadeNames[i]);
            refreshKnobDisplay();
            return;
        }
        if (cKeyHeld_) {
            // C key overrides: show scene-change crossfade speed mode
            controlWin_.setKnobMode(KnobMode::FxParam);
            for (int i = 0; i < NUM_KNOBS; ++i) controlWin_.setKnobParamName(i, scnFdNames[i]);
            refreshKnobDisplay();
            return;
        }
        KnobMode eff = effectiveMode();
        controlWin_.setKnobMode(eff);
        if (eff == KnobMode::ImgRotate) {
            for (int i = 0; i < NUM_KNOBS; ++i) controlWin_.setKnobParamName(i, rotNames[i]);
        } else if (eff == KnobMode::ImgZoom) {
            for (int i = 0; i < NUM_KNOBS; ++i) controlWin_.setKnobParamName(i, zoomNames[i]);
        } else if (eff == KnobMode::LayerLevel) {
            for (int i = 0; i < NUM_KNOBS; ++i) controlWin_.setKnobParamName(i, opNames[i]);
        } else if (eff == KnobMode::FxAudio) {
            for (int i = 0; i < NUM_KNOBS; ++i) controlWin_.setKnobParamName(i, gainNames[i]);
        } else if (eff == KnobMode::ImgPan) {
            for (int i = 0; i < NUM_KNOBS; ++i) controlWin_.setKnobParamName(i, panNames[i]);
        } else {
            refreshKnobParamNames();
        }
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
    controlWin_.onOKey = [this, refreshModifierDisplay](bool pressed) {
        if (pressed == oKeyHeld_) return;
        oKeyHeld_ = pressed;
        refreshModifierDisplay();
    };
    controlWin_.onGKey = [this, refreshModifierDisplay](bool pressed) {
        if (pressed == gKeyHeld_) return;
        gKeyHeld_ = pressed;
        refreshModifierDisplay();
    };
    controlWin_.onPKey = [this, refreshModifierDisplay](bool pressed) {
        if (pressed == pKeyHeld_) return;
        pKeyHeld_ = pressed;
        refreshModifierDisplay();
    };
    controlWin_.onFKey = [this, refreshModifierDisplay](bool pressed) {
        if (pressed == fKeyHeld_) return;
        fKeyHeld_ = pressed;
        refreshModifierDisplay();
    };
    controlWin_.onCKey = [this, refreshModifierDisplay](bool pressed) {
        if (pressed == cKeyHeld_) return;
        cKeyHeld_ = pressed;
        refreshModifierDisplay();
    };
    controlWin_.onBKey = [this](bool bypassed) {
        audioBypassed_ = bypassed;
        // Zero out bands in compositor immediately when bypass toggles on
        if (bypassed) {
            const float zeros[8] = {};
            compositor_.setAudioBands(zeros, 8, 0.0f);
        }
    };
    mediaPickerWin_.onFileSelected = [this](int slot, const std::string& path){
        onImageSelected(slot, path);
    };
}

// ── Engine helper: apply one knob value to the right engine target ────────────

void App::applyKnob(int knobIdx, float v, KnobMode mode) {
    switch (mode) {
        case KnobMode::LayerLevel:
            if (knobIdx % 2 == 0 && knobIdx / 2 < NUM_FX_LAYERS) {
                int slot    = knobIdx / 2;     // 0→1, 2→3, 4→5
                int fxLayer = slot * 2 + 1;
                layers_.setOpacity(fxLayer, v);
                compositor_.setLayerOpacity(fxLayer, v);
            }
            break;
        case KnobMode::FxAudio:
            if (knobIdx % 2 == 0 && knobIdx / 2 < NUM_FX_LAYERS)
                compositor_.setAudioGain(knobIdx / 2, v * 8.0f);  // 0.0–8.0x gain (stronger response)
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
            if (knobIdx % 2 == 0 && knobIdx / 2 < NUM_SRC_LAYERS)
                compositor_.setLayerRotation(knobIdx / 2, v * 2.0f * 3.14159265f);
            break;
        case KnobMode::ImgZoom:
            if (knobIdx % 2 == 0 && knobIdx / 2 < NUM_SRC_LAYERS)
                compositor_.setLayerZoom(knobIdx / 2, std::pow(4.0f, v - 0.5f));
            break;
        case KnobMode::ImgPan: {
            int slot = knobIdx / 2;  // knob pair: 0/1→slot0, 2/3→slot1, 4/5→slot2
            bool isY = (knobIdx % 2 == 1);
            if (slot < NUM_SRC_LAYERS) {
                float offset = (v - 0.5f) * 2.0f;  // −1.0 (left/up) .. +1.0 (right/down)
                if (isY) compositor_.setLayerPanY(slot, offset);
                else     compositor_.setLayerPanX(slot, offset);
            }
            break;
        }
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

// ── Update knob param name labels from active scene's FX patches ──────────────

void App::refreshKnobParamNames() {
    if (currentScene_ < 0) return;
    const Scene& sc = SCENES[currentScene_];
    // Knobs 0-1 → FX slot 0, knobs 2-3 → FX slot 1, knobs 4-5 → FX slot 2
    for (int slot = 0; slot < NUM_FX_LAYERS; ++slot) {
        FxPatchId patch = sc.fx[slot];
        std::string prefix = std::string(fxPatchName(patch)) + " ";
        controlWin_.setKnobParamName(slot * 2,     prefix + fxParamName(patch, 0));
        controlWin_.setKnobParamName(slot * 2 + 1, prefix + fxParamName(patch, 1));
    }
}

// ── Sync all 6 knob arc widgets for the current mode ─────────────────────────

void App::refreshKnobDisplay() {
    if (currentScene_ < 0) return;

    // F key mode: show image-load crossfade speed values for even knobs, 0 for odd.
    if (fKeyHeld_) {
        for (int k = 0; k < NUM_KNOBS; ++k) {
            if (k % 2 == 1) { controlWin_.setKnobValue(k, 0); continue; }
            int slot = k / 2;
            controlWin_.setKnobValue(k, static_cast<int>(crossfadeSpeedNorm_[slot] * 127.0f));
        }
        return;
    }

    // C key mode: show scene-change crossfade speed values for even knobs, 0 for odd.
    if (cKeyHeld_) {
        for (int k = 0; k < NUM_KNOBS; ++k) {
            if (k % 2 == 1) { controlWin_.setKnobValue(k, 0); continue; }
            int slot = k / 2;
            controlWin_.setKnobValue(k, static_cast<int>(sceneCrossfadeSpeedNorm_[slot] * 127.0f));
        }
        return;
    }

    KnobMode eff = effectiveMode();
    int mi = static_cast<int>(eff);
    const SceneState& s = scenes_[currentScene_];
    // For rotate/zoom/opacity: knobs 0,2,4 active; knobs 1,3,5 inactive.
    // For pan: all 6 active. For others: all 6 active.
    const bool evenOnlyMode = (eff == KnobMode::ImgRotate  ||
                               eff == KnobMode::ImgZoom    ||
                               eff == KnobMode::LayerLevel ||
                               eff == KnobMode::FxAudio);
    for (int k = 0; k < NUM_KNOBS; ++k) {
        // Odd knobs are inactive in single-param-per-layer modes.
        if (evenOnlyMode && k % 2 == 1) {
            controlWin_.setKnobValue(k, 0);
            continue;
        }
        float v = s.knobs[mi][k];
        // If this knob hasn't been set in this scene yet, show physical position.
        float display = (v >= 0.0f) ? v : (evenOnlyMode ? 0.0f : knobLastPhys_[k]);
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
        KnobMode eff = (rKeyHeld_ || zKeyHeld_ || oKeyHeld_ || gKeyHeld_ || pKeyHeld_ || fKeyHeld_ || cKeyHeld_) ? effectiveMod : mode;

    // F key intercept: set image-load crossfade speed for the even knob's slot, don't store in scene.
    if (fKeyHeld_) {
        if (knobIdx % 2 == 0 && knobIdx / 2 < NUM_SRC_LAYERS) {
            int slot = knobIdx / 2;
            crossfadeSpeedNorm_[slot] = normValue;
            compositor_.setCrossfadeSpeed(slot, 0.1f + normValue * 7.9f); // 0.1–8.0 s
            controlWin_.setKnobValue(knobIdx, static_cast<int>(normValue * 127.0f));
        }
        return;
    }

    // C key intercept: set scene-change crossfade speed for the even knob's slot.
    if (cKeyHeld_) {
        if (knobIdx % 2 == 0 && knobIdx / 2 < NUM_SRC_LAYERS) {
            int slot = knobIdx / 2;
            sceneCrossfadeSpeedNorm_[slot] = normValue;
            controlWin_.setKnobValue(knobIdx, static_cast<int>(normValue * 127.0f));
        }
        return;
    }
    int    mi   = static_cast<int>(eff);
    float& soft = scenes_[currentScene_].knobs[mi][knobIdx];

    // ── Pickup / catch-up ────────────────────────────────────────────────
    // soft == -1.0f → first touch in this scene: apply immediately.
    // Otherwise the physical pot must sweep through the stored value first.
    // Opacity is a performance control; apply immediately without pickup lock.
    // Other modes keep pickup to avoid value jumps on scene recall.
    if (eff != KnobMode::LayerLevel && soft >= 0.0f) {
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
        if (!path.empty()) {
            // Capture current frame and set scene-change crossfade speed before loading new image.
            compositor_.setCrossfadeSpeed(slot, 0.1f + sceneCrossfadeSpeedNorm_[slot] * 7.9f);
            compositor_.beginCrossfade(slot);
            layers_.loadMedia(slot * 2, path);
        }
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
    // 4. Update knob param name labels to reflect the new scene's FX patches.
    refreshKnobParamNames();
    // Persist the new currentScene_ immediately so a crash won't revert it.
    saveState();
}

// ── GUI knob drag ─────────────────────────────────────────────────────────────

void App::onKnobDrag(int knobIdx, float normValue) {
    if (currentScene_ < 0) return;

    // F key intercept: set image-load crossfade speed, don't store in scene.
    if (fKeyHeld_) {
        if (knobIdx % 2 == 0 && knobIdx / 2 < NUM_SRC_LAYERS) {
            int slot = knobIdx / 2;
            crossfadeSpeedNorm_[slot] = normValue;
            compositor_.setCrossfadeSpeed(slot, 0.1f + normValue * 7.9f); // 0.1–8.0 s
        }
        controlWin_.setKnobValue(knobIdx, static_cast<int>(normValue * 127.0f));
        return;
    }

    // C key intercept: set scene-change crossfade speed, don't store in scene.
    if (cKeyHeld_) {
        if (knobIdx % 2 == 0 && knobIdx / 2 < NUM_SRC_LAYERS) {
            int slot = knobIdx / 2;
            sceneCrossfadeSpeedNorm_[slot] = normValue;
        }
        controlWin_.setKnobValue(knobIdx, static_cast<int>(normValue * 127.0f));
        return;
    }

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
    if (currentScene_ >= 0) {
        scenes_[currentScene_].imgPaths[slotIdx] = path;
    } else {
        // No scene active yet — store in every scene that has no image for this slot
        // so the image persists regardless of which scene is selected first.
        for (auto& s : scenes_)
            if (s.imgPaths[slotIdx].empty())
                s.imgPaths[slotIdx] = path;
    }
    compositor_.beginCrossfade(slotIdx);  // capture current frame before new image uploads
    layers_.loadMedia(slotIdx * 2, path);
    saveState();  // persist immediately — don't rely on clean exit
}

// ── State persistence ─────────────────────────────────────────────────────────

std::string App::statePath() {
    const char* home = getenv("HOME");
    return home ? std::string(home) + "/.vjay_ace_state" : "/tmp/vjay_ace_state";
}

void App::saveState() const {
    // Write to a temp file first, then atomically rename so a crash mid-write
    // can never leave the state file truncated/corrupt.
    const std::string tmp = statePath() + ".tmp";
    {
        std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
        if (!f) { std::cerr << "[App] Could not open temp state file for writing\n"; return; }
        // Write magic + version for future-proofing
        const uint32_t magic = 0x56414345; // 'VACE'
        const uint32_t ver   = 7;
        f.write(reinterpret_cast<const char*>(&magic), 4);
        f.write(reinterpret_cast<const char*>(&ver),   4);
        // Write all 16 scene states (knobs + image paths)
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
        if (!f) { std::cerr << "[App] State write error — temp file may be incomplete\n"; return; }
    } // ofstream closes + flushes here
    if (std::rename(tmp.c_str(), statePath().c_str()) != 0) {
        std::cerr << "[App] Could not rename temp state file to " << statePath() << "\n";
        return;
    }
    std::cout << "[App] State saved (scene=" << currentScene_ << ")\n";
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
    // v6: 16 scenes (added 2 LIF scenes; O/G keys replace C2/C#2 mode-latch)
    // v7: 6 modes (added ImgPan)
    const bool isV3 = (ver == 3);
    const bool isV4 = (ver == 4);
    const bool isV5 = (ver == 5);
    const bool isV6 = (ver == 6);
    const bool isV7 = (ver == 7);
    if (!isV3 && !isV4 && !isV5 && !isV6 && !isV7) {
        std::cerr << "[App] Ignoring incompatible state file\n";
        return;
    }
    // Older saves have 14 scenes; v6+ has 16. Read only what was saved.
    const int savedSceneCount = (isV6 || isV7) ? NUM_SCENES : 14;
    for (int si = 0; si < savedSceneCount && si < NUM_SCENES; ++si) {
        auto& s = scenes_[si];
        // v3=3 modes, v4=4, v5/v6=5, v7=6
        int savedModes = isV3 ? 3 : isV4 ? 4 : (isV5 || isV6) ? 5 : SceneState::NMODES;
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
    if (f.read(reinterpret_cast<char*>(&savedScene), sizeof(int))) {
        if (savedScene >= 0 && savedScene < NUM_SCENES)
            currentScene_ = savedScene;
        else
            std::cerr << "[App] Ignoring out-of-range savedScene=" << savedScene << "\n";
    }

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

    // ── Audio poll: read latest bands and push to compositor + meter ─────
    if (!audioBypassed_ && audio_.isRunning()) {
        auto bands = audio_.bands();
        float rms  = audio_.rms();
        compositor_.setAudioBands(bands.data(), static_cast<int>(bands.size()), rms);
        controlWin_.setAudioBands(bands.data(), static_cast<int>(bands.size()), rms);
    } else {
        const float zeros[8] = {};
        compositor_.setAudioBands(zeros, 8, 0.0f);
        controlWin_.setAudioBands(zeros, 8, 0.0f);
    }

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
