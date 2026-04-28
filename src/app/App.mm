#include "App.h"
#import  <AppKit/AppKit.h>  // NSScreen for display positions
#include <iostream>
#include <fstream>
#include <csignal>
#include <filesystem>

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

static bool isLIFPatch(FxPatchId patch) {
    return patch == FxPatchId::LIFModulate || patch == FxPatchId::LIFReplace;
}

static int topologyIndexFromNorm(float value) {
    return std::clamp(static_cast<int>(value * 5.0f), 0, 4);
}

static LIFNetwork::Topology topologyFromIndex(int index) {
    switch (std::clamp(index, 0, 4)) {
        case 0: return LIFNetwork::Topology::Ring;
        case 1: return LIFNetwork::Topology::FullyConnected;
        case 2: return LIFNetwork::Topology::Feedforward;
        case 3: return LIFNetwork::Topology::SparseRandom;
        default: return LIFNetwork::Topology::SmallWorld;
    }
}

int App::lifNeuronCountFromNorm(float v) {
    static constexpr int kCounts[4] = {512, 1024, 2048, 4096};
    int idx = std::clamp(static_cast<int>(v * 4.0f), 0, 3);
    return kCounts[idx];
}

float App::normFromLIFNeuronCount(int neuronCount) {
    if (neuronCount <= 512) return 0.0f;
    if (neuronCount <= 1024) return 1.0f / 3.0f;
    if (neuronCount <= 2048) return 2.0f / 3.0f;
    return 1.0f;
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
        std::error_code ec;

        if (const char* home = getenv("HOME")) {
            const std::string stashCandidate = std::string(home) + "/Documents/koodii/vjay_ace/Heikki_stash";
            if (std::filesystem::exists(stashCandidate, ec) && std::filesystem::is_directory(stashCandidate, ec))
                return stashCandidate;
        }

        NSString* exeDir = [NSBundle mainBundle].executablePath.stringByDeletingLastPathComponent;
        const std::filesystem::path imagesCandidate = std::filesystem::path(exeDir.UTF8String).parent_path() / "images";
        if (std::filesystem::exists(imagesCandidate, ec) && std::filesystem::is_directory(imagesCandidate, ec))
            return imagesCandidate.string();

        return std::string();
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
        if (rKeyHeld_ || zKeyHeld_ || oKeyHeld_ || gKeyHeld_ || pKeyHeld_ || imgXfadeKeyHeld_ || sceneXfadeKeyHeld_ || globalImgXfadeKeyHeld_ || globalSceneXfadeKeyHeld_ || globalOpacityKeyHeld_ || globalAudioGainKeyHeld_ || nKeyHeld_) return;  // modifier key overrides; ignore while held
        knobMode_ = m;
        controlWin_.setKnobMode(m);
        static const char* opNames[]   = {"Opac L0", "-", "Opac L1", "-", "Opac L2", "-"};
        static const char* gOpNames[]  = {"GOpac L0", "-", "GOpac L1", "-", "GOpac L2", "-"};
        static const char* gainNames[] = {"Gain 0", "-", "Gain 1", "-", "Gain 2", "-"};
        static const char* gGainNames[] = {"GGain 0", "-", "GGain 1", "-", "GGain 2", "-"};
        if (m == KnobMode::LayerLevel) {
            const char** names = globalOpacityKeyHeld_ ? gOpNames : opNames;
            for (int i = 0; i < NUM_KNOBS; ++i)
                controlWin_.setKnobParamName(i, names[i]);
        } else if (m == KnobMode::FxAudio) {
            const char** names = globalAudioGainKeyHeld_ ? gGainNames : gainNames;
            for (int i = 0; i < NUM_KNOBS; ++i)
                controlWin_.setKnobParamName(i, names[i]);
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
        static const char* gOpNames[]   = {"GOpac L0",  "-", "GOpac L1",  "-", "GOpac L2",  "-"};
        static const char* gainNames[]  = {"Gain 0",    "-", "Gain 1",    "-", "Gain 2",    "-"};
        static const char* gGainNames[] = {"GGain 0",   "-", "GGain 1",   "-", "GGain 2",   "-"};
        static const char* panNames[]   = {"Pan0 X", "Pan0 Y", "Pan1 X", "Pan1 Y", "Pan2 X", "Pan2 Y"};
        static const char* xfadeNames[]  = {"ImgFd 0",   "-", "ImgFd 1",   "-", "ImgFd 2",   "-"};
        static const char* scnFdNames[]  = {"ScnFd 0",   "-", "ScnFd 1",   "-", "ScnFd 2",   "-"};
        static const char* gImgFdNames[] = {"GImgFd 0",  "-", "GImgFd 1",  "-", "GImgFd 2",  "-"};
        static const char* gScnFdNames[] = {"GScnFd 0",  "-", "GScnFd 1",  "-", "GScnFd 2",  "-"};
        static const char* lifCountNames[] = {"LIF 512-4k", "-", "LIF 512-4k", "-", "LIF 512-4k", "-"};
        if (globalImgXfadeKeyHeld_) {
            // I key overrides: show global image-load crossfade speed mode
            controlWin_.setKnobMode(KnobMode::FxParam);
            for (int i = 0; i < NUM_KNOBS; ++i) controlWin_.setKnobParamName(i, gImgFdNames[i]);
            refreshKnobDisplay();
            return;
        }
        if (globalSceneXfadeKeyHeld_) {
            // S key overrides: show global scene-change crossfade speed mode
            controlWin_.setKnobMode(KnobMode::FxParam);
            for (int i = 0; i < NUM_KNOBS; ++i) controlWin_.setKnobParamName(i, gScnFdNames[i]);
            refreshKnobDisplay();
            return;
        }
        if (globalOpacityKeyHeld_) {
            // L key overrides: show global opacity override mode
            controlWin_.setKnobMode(KnobMode::LayerLevel);
            for (int i = 0; i < NUM_KNOBS; ++i) controlWin_.setKnobParamName(i, gOpNames[i]);
            refreshKnobDisplay();
            return;
        }
        if (globalAudioGainKeyHeld_) {
            // H key overrides: show global audio gain override mode
            controlWin_.setKnobMode(KnobMode::FxAudio);
            for (int i = 0; i < NUM_KNOBS; ++i) controlWin_.setKnobParamName(i, gGainNames[i]);
            refreshKnobDisplay();
            return;
        }
        if (imgXfadeKeyHeld_) {
            // F key overrides: show image-load crossfade speed mode
            controlWin_.setKnobMode(KnobMode::FxParam); // reuse any label; will be overridden below
            for (int i = 0; i < NUM_KNOBS; ++i) controlWin_.setKnobParamName(i, xfadeNames[i]);
            refreshKnobDisplay();
            return;
        }
        if (sceneXfadeKeyHeld_) {
            // C key overrides: show scene-change crossfade speed mode
            controlWin_.setKnobMode(KnobMode::FxParam);
            for (int i = 0; i < NUM_KNOBS; ++i) controlWin_.setKnobParamName(i, scnFdNames[i]);
            refreshKnobDisplay();
            return;
        }
        if (nKeyHeld_) {
            controlWin_.setKnobMode(KnobMode::FxParam);
            for (int i = 0; i < NUM_KNOBS; ++i) controlWin_.setKnobParamName(i, lifCountNames[i]);
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
            const char** names = globalOpacityKeyHeld_ ? gOpNames : opNames;
            for (int i = 0; i < NUM_KNOBS; ++i) controlWin_.setKnobParamName(i, names[i]);
        } else if (eff == KnobMode::FxAudio) {
            const char** names = globalAudioGainKeyHeld_ ? gGainNames : gainNames;
            for (int i = 0; i < NUM_KNOBS; ++i) controlWin_.setKnobParamName(i, names[i]);
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
    controlWin_.onImgXfadeKey = [this, refreshModifierDisplay](bool pressed) {
        if (pressed == imgXfadeKeyHeld_) return;
        imgXfadeKeyHeld_ = pressed;
        refreshModifierDisplay();
    };
    controlWin_.onSceneXfadeKey = [this, refreshModifierDisplay](bool pressed) {
        if (pressed == sceneXfadeKeyHeld_) return;
        sceneXfadeKeyHeld_ = pressed;
        refreshModifierDisplay();
    };
    controlWin_.onGlobalImgXfadeKey = [this, refreshModifierDisplay](bool pressed) {
        if (pressed == globalImgXfadeKeyHeld_) return;
        globalImgXfadeKeyHeld_ = pressed;
        refreshModifierDisplay();
    };
    controlWin_.onGlobalSceneXfadeKey = [this, refreshModifierDisplay](bool pressed) {
        if (pressed == globalSceneXfadeKeyHeld_) return;
        globalSceneXfadeKeyHeld_ = pressed;
        refreshModifierDisplay();
    };
    controlWin_.onGlobalOpacityKey = [this, refreshModifierDisplay](bool pressed) {
        if (pressed == globalOpacityKeyHeld_) return;
        globalOpacityKeyHeld_ = pressed;
        refreshModifierDisplay();
    };
    controlWin_.onGlobalAudioGainKey = [this, refreshModifierDisplay](bool pressed) {
        if (pressed == globalAudioGainKeyHeld_) return;
        globalAudioGainKeyHeld_ = pressed;
        refreshModifierDisplay();
    };
    controlWin_.onNKey = [this, refreshModifierDisplay](bool pressed) {
        if (pressed == nKeyHeld_) return;
        nKeyHeld_ = pressed;
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
                compositor_.setLayerZoom(knobIdx / 2, std::pow(64.0f, v - 0.5f)); // 0.125x .. 8.0x
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

void App::ensureSceneTransformDefaults(int idx) {
    if (idx < 0 || idx >= NUM_SCENES) return;

    SceneState& s = scenes_[idx];
    const int rotateMi = static_cast<int>(KnobMode::ImgRotate);
    const int zoomMi   = static_cast<int>(KnobMode::ImgZoom);
    const int panMi    = static_cast<int>(KnobMode::ImgPan);

    for (int slot = 0; slot < NUM_SRC_LAYERS; ++slot) {
        const int evenKnob = slot * 2;
        if (s.knobs[rotateMi][evenKnob] < 0.0f)
            s.knobs[rotateMi][evenKnob] = 0.0f;
        if (s.knobs[zoomMi][evenKnob] < 0.0f)
            s.knobs[zoomMi][evenKnob] = 0.5f;

        const int xKnob = slot * 2;
        const int yKnob = xKnob + 1;
        if (s.knobs[panMi][xKnob] < 0.0f)
            s.knobs[panMi][xKnob] = 0.5f;
        if (s.knobs[panMi][yKnob] < 0.0f)
            s.knobs[panMi][yKnob] = 0.5f;
    }
}

void App::ensureSceneOpacityDefaults(int idx) {
    if (idx < 0 || idx >= NUM_SCENES) return;

    SceneState& s = scenes_[idx];
    const int layerMi = static_cast<int>(KnobMode::LayerLevel);
    for (int slot = 0; slot < NUM_FX_LAYERS; ++slot) {
        const int knob = slot * 2;
        if (s.knobs[layerMi][knob] < 0.0f)
            s.knobs[layerMi][knob] = 1.0f;
        if (s.opacityVersion[slot] == 0)
            s.opacityVersion[slot] = globalOpacityVersion_[slot];
    }
}

void App::ensureSceneAudioGainDefaults(int idx) {
    if (idx < 0 || idx >= NUM_SCENES) return;

    SceneState& s = scenes_[idx];
    const int gainMi = static_cast<int>(KnobMode::FxAudio);
    for (int slot = 0; slot < NUM_FX_LAYERS; ++slot) {
        const int knob = slot * 2;
        if (s.knobs[gainMi][knob] < 0.0f)
            s.knobs[gainMi][knob] = 0.125f; // compositor gain 1.0x
        if (s.audioGainVersion[slot] == 0)
            s.audioGainVersion[slot] = globalAudioGainVersion_[slot];
    }
}

void App::ensureSceneLIFDefaults(int idx) {
    if (idx < 0 || idx >= NUM_SCENES) return;

    SceneState& s = scenes_[idx];
    const Scene& sc = SCENES[idx];
    if (s.lifNeuronCount <= 0) {
        int lifPatchCount = 0;
        for (FxPatchId patch : sc.fx)
            if (isLIFPatch(patch))
                ++lifPatchCount;
        s.lifNeuronCount = (lifPatchCount >= 2) ? 2048 : 1024;
    }

    if (s.lifTopologyIndex < 0) {
        int fxMi = static_cast<int>(KnobMode::FxParam);
        for (int slot = 0; slot < NUM_FX_LAYERS; ++slot) {
            if (!isLIFPatch(sc.fx[slot])) continue;
            float stored = s.knobs[fxMi][slot * 2 + 1];
            float source = (stored >= 0.0f) ? stored : sc.params[slot][1];
            s.lifTopologyIndex = topologyIndexFromNorm(source);
            break;
        }
        if (s.lifTopologyIndex < 0)
            s.lifTopologyIndex = 0;
    }
}

void App::applySceneCrossfadeSettings(int idx) {
    if (idx < 0 || idx >= NUM_SCENES) return;
    for (int slot = 0; slot < NUM_SRC_LAYERS; ++slot)
        compositor_.setCrossfadeSpeed(slot, 0.1f + effectiveImageCrossfadeNorm(idx, slot) * 7.9f);
}

float App::effectiveImageCrossfadeNorm(int sceneIdx, int slot) const {
    if (sceneIdx < 0 || sceneIdx >= NUM_SCENES || slot < 0 || slot >= NUM_SRC_LAYERS) return 0.1f;
    const SceneState& s = scenes_[sceneIdx];
    if (s.imageCrossfadeVersion[slot] < globalImageCrossfadeVersion_[slot])
        return globalImageCrossfadeNorm_[slot];
    return s.imageCrossfadeSpeedNorm[slot];
}

float App::effectiveSceneCrossfadeNorm(int sceneIdx, int slot) const {
    if (sceneIdx < 0 || sceneIdx >= NUM_SCENES || slot < 0 || slot >= NUM_SRC_LAYERS) return 0.1f;
    const SceneState& s = scenes_[sceneIdx];
    if (s.sceneCrossfadeVersion[slot] < globalSceneCrossfadeVersion_[slot])
        return globalSceneCrossfadeNorm_[slot];
    return s.sceneCrossfadeSpeedNorm[slot];
}

float App::effectiveLayerOpacityNorm(int sceneIdx, int slot) const {
    if (sceneIdx < 0 || sceneIdx >= NUM_SCENES || slot < 0 || slot >= NUM_FX_LAYERS) return 1.0f;
    const SceneState& s = scenes_[sceneIdx];
    if (s.opacityVersion[slot] < globalOpacityVersion_[slot])
        return globalOpacityNorm_[slot];
    const int layerMi = static_cast<int>(KnobMode::LayerLevel);
    const float local = s.knobs[layerMi][slot * 2];
    return (local >= 0.0f) ? local : 1.0f;
}

float App::effectiveAudioGainNorm(int sceneIdx, int slot) const {
    if (sceneIdx < 0 || sceneIdx >= NUM_SCENES || slot < 0 || slot >= NUM_FX_LAYERS) return 0.125f;
    const SceneState& s = scenes_[sceneIdx];
    if (s.audioGainVersion[slot] < globalAudioGainVersion_[slot])
        return globalAudioGainNorm_[slot];
    const int gainMi = static_cast<int>(KnobMode::FxAudio);
    const float local = s.knobs[gainMi][slot * 2];
    return (local >= 0.0f) ? local : 0.125f;
}

void App::setLocalLayerOpacityNorm(int sceneIdx, int slot, float norm) {
    if (sceneIdx < 0 || sceneIdx >= NUM_SCENES || slot < 0 || slot >= NUM_FX_LAYERS) return;
    const int layerMi = static_cast<int>(KnobMode::LayerLevel);
    scenes_[sceneIdx].knobs[layerMi][slot * 2] = norm;
    scenes_[sceneIdx].opacityVersion[slot] = globalOpacityVersion_[slot];
}

void App::setGlobalLayerOpacityNorm(int slot, float norm) {
    if (slot < 0 || slot >= NUM_FX_LAYERS) return;
    globalOpacityNorm_[slot] = norm;
    ++globalOpacityVersion_[slot];
}

void App::setLocalAudioGainNorm(int sceneIdx, int slot, float norm) {
    if (sceneIdx < 0 || sceneIdx >= NUM_SCENES || slot < 0 || slot >= NUM_FX_LAYERS) return;
    const int gainMi = static_cast<int>(KnobMode::FxAudio);
    scenes_[sceneIdx].knobs[gainMi][slot * 2] = norm;
    scenes_[sceneIdx].audioGainVersion[slot] = globalAudioGainVersion_[slot];
}

void App::setGlobalAudioGainNorm(int slot, float norm) {
    if (slot < 0 || slot >= NUM_FX_LAYERS) return;
    globalAudioGainNorm_[slot] = norm;
    ++globalAudioGainVersion_[slot];
}

void App::setLocalImageCrossfadeNorm(int sceneIdx, int slot, float norm) {
    if (sceneIdx < 0 || sceneIdx >= NUM_SCENES || slot < 0 || slot >= NUM_SRC_LAYERS) return;
    scenes_[sceneIdx].imageCrossfadeSpeedNorm[slot] = norm;
    scenes_[sceneIdx].imageCrossfadeVersion[slot] = globalImageCrossfadeVersion_[slot];
}

void App::setLocalSceneCrossfadeNorm(int sceneIdx, int slot, float norm) {
    if (sceneIdx < 0 || sceneIdx >= NUM_SCENES || slot < 0 || slot >= NUM_SRC_LAYERS) return;
    scenes_[sceneIdx].sceneCrossfadeSpeedNorm[slot] = norm;
    scenes_[sceneIdx].sceneCrossfadeVersion[slot] = globalSceneCrossfadeVersion_[slot];
}

void App::setGlobalImageCrossfadeNorm(int slot, float norm) {
    if (slot < 0 || slot >= NUM_SRC_LAYERS) return;
    globalImageCrossfadeNorm_[slot] = norm;
    ++globalImageCrossfadeVersion_[slot];
}

void App::setGlobalSceneCrossfadeNorm(int slot, float norm) {
    if (slot < 0 || slot >= NUM_SRC_LAYERS) return;
    globalSceneCrossfadeNorm_[slot] = norm;
    ++globalSceneCrossfadeVersion_[slot];
}

void App::applySceneToEngine(int idx) {
    ensureSceneTransformDefaults(idx);
    ensureSceneOpacityDefaults(idx);
    ensureSceneAudioGainDefaults(idx);
    ensureSceneLIFDefaults(idx);
    applySceneCrossfadeSettings(idx);
    compositor_.setLIFTopology(topologyFromIndex(scenes_[idx].lifTopologyIndex));
    compositor_.setLIFNeuronCount(scenes_[idx].lifNeuronCount);
    const SceneState& s = scenes_[idx];

    // Layer opacity is scene-local by default and can be globally overridden.
    for (int slot = 0; slot < NUM_FX_LAYERS; ++slot)
        applyKnob(slot * 2, effectiveLayerOpacityNorm(idx, slot), KnobMode::LayerLevel);

    // Audio gain is scene-local by default and can be globally overridden.
    for (int slot = 0; slot < NUM_FX_LAYERS; ++slot)
        applyKnob(slot * 2, effectiveAudioGainNorm(idx, slot), KnobMode::FxAudio);

    for (int mi = 0; mi < SceneState::NMODES; ++mi) {
        if (mi == static_cast<int>(KnobMode::LayerLevel) || mi == static_cast<int>(KnobMode::FxAudio)) continue;
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

    // I key mode: show global image-load crossfade values for even knobs.
    if (globalImgXfadeKeyHeld_) {
        for (int k = 0; k < NUM_KNOBS; ++k) {
            if (k % 2 == 1) { controlWin_.setKnobValue(k, 0); continue; }
            int slot = k / 2;
            controlWin_.setKnobValue(k, static_cast<int>(globalImageCrossfadeNorm_[slot] * 127.0f));
        }
        return;
    }

    // S key mode: show global scene-change crossfade values for even knobs.
    if (globalSceneXfadeKeyHeld_) {
        for (int k = 0; k < NUM_KNOBS; ++k) {
            if (k % 2 == 1) { controlWin_.setKnobValue(k, 0); continue; }
            int slot = k / 2;
            controlWin_.setKnobValue(k, static_cast<int>(globalSceneCrossfadeNorm_[slot] * 127.0f));
        }
        return;
    }

    // L key mode: show global opacity override values for even knobs.
    if (globalOpacityKeyHeld_) {
        for (int k = 0; k < NUM_KNOBS; ++k) {
            if (k % 2 == 1) { controlWin_.setKnobValue(k, 0); continue; }
            int slot = k / 2;
            controlWin_.setKnobValue(k, static_cast<int>(globalOpacityNorm_[slot] * 127.0f));
        }
        return;
    }

    // H key mode: show global audio gain override values for even knobs.
    if (globalAudioGainKeyHeld_) {
        for (int k = 0; k < NUM_KNOBS; ++k) {
            if (k % 2 == 1) { controlWin_.setKnobValue(k, 0); continue; }
            int slot = k / 2;
            controlWin_.setKnobValue(k, static_cast<int>(globalAudioGainNorm_[slot] * 127.0f));
        }
        return;
    }

    // F key mode: show image-load crossfade speed values for even knobs, 0 for odd.
    if (imgXfadeKeyHeld_) {
        for (int k = 0; k < NUM_KNOBS; ++k) {
            if (k % 2 == 1) { controlWin_.setKnobValue(k, 0); continue; }
            int slot = k / 2;
            controlWin_.setKnobValue(k, static_cast<int>(scenes_[currentScene_].imageCrossfadeSpeedNorm[slot] * 127.0f));
        }
        return;
    }

    // C key mode: show scene-change crossfade speed values for even knobs, 0 for odd.
    if (sceneXfadeKeyHeld_) {
        for (int k = 0; k < NUM_KNOBS; ++k) {
            if (k % 2 == 1) { controlWin_.setKnobValue(k, 0); continue; }
            int slot = k / 2;
            controlWin_.setKnobValue(k, static_cast<int>(scenes_[currentScene_].sceneCrossfadeSpeedNorm[slot] * 127.0f));
        }
        return;
    }

    if (nKeyHeld_) {
        float display = normFromLIFNeuronCount(scenes_[currentScene_].lifNeuronCount);
        for (int k = 0; k < NUM_KNOBS; ++k) {
            if (k % 2 == 1) { controlWin_.setKnobValue(k, 0); continue; }
            controlWin_.setKnobValue(k, static_cast<int>(display * 127.0f));
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
        if (eff == KnobMode::LayerLevel && (k % 2 == 0))
            v = effectiveLayerOpacityNorm(currentScene_, k / 2);
        if (eff == KnobMode::FxAudio && (k % 2 == 0))
            v = effectiveAudioGainNorm(currentScene_, k / 2);
        // If this knob hasn't been set in this scene yet, show physical position.
        float display = (v >= 0.0f) ? v : (evenOnlyMode ? 0.0f : knobLastPhys_[k]);
        controlWin_.setKnobValue(k, static_cast<int>(display * 127.0f));
    }
}

// ── MIDI knob handler ─────────────────────────────────────────────────────────

void App::onKnob(int knobIdx, float normValue, KnobMode mode) {
    knobLastPhys_[knobIdx] = normValue;

    // If no scene is active there's nothing to store or apply.
    if (currentScene_ < 0) return;

    // If a modifier key is held, override to its mode
    KnobMode effectiveMod = effectiveMode();
    // Only use MIDI-provided mode when no modifier key is held.
    KnobMode eff = (rKeyHeld_ || zKeyHeld_ || oKeyHeld_ || gKeyHeld_ || pKeyHeld_ || imgXfadeKeyHeld_ || sceneXfadeKeyHeld_ || globalImgXfadeKeyHeld_ || globalSceneXfadeKeyHeld_ || globalOpacityKeyHeld_ || globalAudioGainKeyHeld_ || nKeyHeld_) ? effectiveMod : mode;

    // I key intercept: set global image-load crossfade speed override for the even knob's slot.
    if (globalImgXfadeKeyHeld_) {
        if (knobIdx % 2 == 0 && knobIdx / 2 < NUM_SRC_LAYERS) {
            int slot = knobIdx / 2;
            setGlobalImageCrossfadeNorm(slot, normValue);
            compositor_.setCrossfadeSpeed(slot, 0.1f + normValue * 7.9f); // 0.1–8.0 s
            controlWin_.setKnobValue(knobIdx, static_cast<int>(normValue * 127.0f));
        }
        return;
    }

    // S key intercept: set global scene-change crossfade speed override for the even knob's slot.
    if (globalSceneXfadeKeyHeld_) {
        if (knobIdx % 2 == 0 && knobIdx / 2 < NUM_SRC_LAYERS) {
            int slot = knobIdx / 2;
            setGlobalSceneCrossfadeNorm(slot, normValue);
            controlWin_.setKnobValue(knobIdx, static_cast<int>(normValue * 127.0f));
        }
        return;
    }

    // L key intercept: set global opacity override for the even knob's FX slot.
    if (globalOpacityKeyHeld_) {
        if (knobIdx % 2 == 0 && knobIdx / 2 < NUM_FX_LAYERS) {
            int slot = knobIdx / 2;
            setGlobalLayerOpacityNorm(slot, normValue);
            applyKnob(knobIdx, normValue, KnobMode::LayerLevel);
            controlWin_.setKnobValue(knobIdx, static_cast<int>(normValue * 127.0f));
        }
        return;
    }

    // H key intercept: set global audio gain override for the even knob's FX slot.
    if (globalAudioGainKeyHeld_) {
        if (knobIdx % 2 == 0 && knobIdx / 2 < NUM_FX_LAYERS) {
            int slot = knobIdx / 2;
            setGlobalAudioGainNorm(slot, normValue);
            applyKnob(knobIdx, normValue, KnobMode::FxAudio);
            controlWin_.setKnobValue(knobIdx, static_cast<int>(normValue * 127.0f));
        }
        return;
    }

    // F key intercept: set scene-local image-load crossfade speed for the even knob's slot.
    if (imgXfadeKeyHeld_) {
        if (knobIdx % 2 == 0 && knobIdx / 2 < NUM_SRC_LAYERS) {
            int slot = knobIdx / 2;
            setLocalImageCrossfadeNorm(currentScene_, slot, normValue);
            compositor_.setCrossfadeSpeed(slot, 0.1f + normValue * 7.9f); // 0.1–8.0 s
            controlWin_.setKnobValue(knobIdx, static_cast<int>(normValue * 127.0f));
        }
        return;
    }

    // C key intercept: set scene-local scene-change crossfade speed for the even knob's slot.
    if (sceneXfadeKeyHeld_) {
        if (knobIdx % 2 == 0 && knobIdx / 2 < NUM_SRC_LAYERS) {
            int slot = knobIdx / 2;
            setLocalSceneCrossfadeNorm(currentScene_, slot, normValue);
            controlWin_.setKnobValue(knobIdx, static_cast<int>(normValue * 127.0f));
        }
        return;
    }
    if (nKeyHeld_) {
        if (knobIdx % 2 == 0) {
            scenes_[currentScene_].lifNeuronCount = lifNeuronCountFromNorm(normValue);
            compositor_.setLIFNeuronCount(scenes_[currentScene_].lifNeuronCount);
            refreshKnobDisplay();
        }
        return;
    }
    int    mi   = static_cast<int>(eff);
    float& soft = scenes_[currentScene_].knobs[mi][knobIdx];

    // Immediate mode: always store and apply on every MIDI movement.
    if (eff == KnobMode::LayerLevel && knobIdx % 2 == 0) {
        setLocalLayerOpacityNorm(currentScene_, knobIdx / 2, normValue);
    }
    if (eff == KnobMode::FxAudio && knobIdx % 2 == 0) {
        setLocalAudioGainNorm(currentScene_, knobIdx / 2, normValue);
    }
    soft = normValue;
    if (eff == KnobMode::FxParam && (knobIdx % 2 == 1)) {
        int slot = knobIdx / 2;
        if (slot < NUM_FX_LAYERS && isLIFPatch(SCENES[currentScene_].fx[slot])) {
            scenes_[currentScene_].lifTopologyIndex = topologyIndexFromNorm(normValue);
            compositor_.setLIFTopology(topologyFromIndex(scenes_[currentScene_].lifTopologyIndex));
        }
    }
    applyKnob(knobIdx, normValue, eff);
    controlWin_.setKnobValue(knobIdx, static_cast<int>(normValue * 127.0f));
}

// ── Pan/Zoom animation helpers ────────────────────────────────────────────────

void App::startPanZoomAnimation() {
    // Capture current pan/zoom values as the starting point
    const int panMi = static_cast<int>(KnobMode::ImgPan);
    const int zoomMi = static_cast<int>(KnobMode::ImgZoom);
    
    // Match pan/zoom ramp length to effective scene crossfade duration.
    float avgCrossfadeSpeedNorm = 0.0f;
    for (int slot = 0; slot < NUM_SRC_LAYERS; ++slot)
        avgCrossfadeSpeedNorm += effectiveSceneCrossfadeNorm(currentScene_, slot);
    avgCrossfadeSpeedNorm /= static_cast<float>(NUM_SRC_LAYERS);
    panZoomAnimDuration_ = 0.1f + avgCrossfadeSpeedNorm * 7.9f;  // 0.1–8.0 seconds
    
    for (int slot = 0; slot < NUM_SRC_LAYERS; ++slot) {
        // Current pan values from compositor
        compositor_.getLayerPan(slot, panXFrom_[slot], panYFrom_[slot]);
        panXTo_[slot] = (scenes_[currentScene_].knobs[panMi][slot * 2] - 0.5f) * 2.0f;
        panYTo_[slot] = (scenes_[currentScene_].knobs[panMi][slot * 2 + 1] - 0.5f) * 2.0f;
        
        // Current zoom value from compositor
        zoomFrom_[slot] = compositor_.getLayerZoom(slot);
        float zoomNorm = scenes_[currentScene_].knobs[zoomMi][slot * 2];
        zoomTo_[slot] = zoomNorm >= 0.0f ? std::pow(64.0f, zoomNorm - 0.5f) : 1.0f;
    }
    
    panZoomAnimTime_ = 0.0f;
    panZoomAnimating_ = true;
}

void App::updatePanZoomAnimation(float deltaTime) {
    if (!panZoomAnimating_) return;
    
    panZoomAnimTime_ += deltaTime;
    float progress = panZoomAnimTime_ / panZoomAnimDuration_;
    
    if (progress >= 1.0f) {
        progress = 1.0f;
        panZoomAnimating_ = false;
    }
    
    // Easing: smooth step for a gentle start/end
    float eased = progress * progress * (3.0f - 2.0f * progress);
    
    for (int slot = 0; slot < NUM_SRC_LAYERS; ++slot) {
        float panX = panXFrom_[slot] + (panXTo_[slot] - panXFrom_[slot]) * eased;
        float panY = panYFrom_[slot] + (panYTo_[slot] - panYFrom_[slot]) * eased;
        float zoom = zoomFrom_[slot] + (zoomTo_[slot] - zoomFrom_[slot]) * eased;
        
        compositor_.setLayerPanX(slot, panX);
        compositor_.setLayerPanY(slot, panY);
        compositor_.setLayerZoom(slot, zoom);
    }
}

// ── Scene select ──────────────────────────────────────────────────────────────

void App::onSceneSelect(int sceneIdx) {
    if (sceneIdx < 0 || sceneIdx >= NUM_SCENES) return;

    const int prevScene = currentScene_;
    currentScene_ = sceneIdx;
    const Scene& sc = SCENES[sceneIdx];

    compositor_.resetFeedbackBuffers();

    // 1. Apply the scene's FX patch selection.
    for (int slot = 0; slot < NUM_FX_LAYERS; ++slot) {
        fxPatches_[slot].id = sc.fx[slot];
        compositor_.setFxPatch(slot, sc.fx[slot]);
        layers_.setFxPatch(slot * 2 + 1, sc.fx[slot]);
    }
    controlWin_.setSceneName(sc.name);
    mediaPickerWin_.setSceneName(sc.name);

    // Load this scene's image files into the 3 source layers.
    // Changed paths are crossfaded; unchanged paths are still reloaded to reset playback.
    for (int slot = 0; slot < NUM_SRC_LAYERS; ++slot) {
        const std::string& path = scenes_[sceneIdx].imgPaths[slot];
        const std::string prevPath =
            (prevScene >= 0 && prevScene < NUM_SCENES) ? scenes_[prevScene].imgPaths[slot] : std::string();
        const bool changed = (path != prevPath);
        if (!path.empty()) {
            if (changed) {
                // Scene-triggered image swaps use image-load crossfade (local F or global I override).
                compositor_.setCrossfadeSpeed(slot, 0.1f + effectiveImageCrossfadeNorm(sceneIdx, slot) * 7.9f);
                compositor_.beginCrossfade(slot);
            }
            // Always reload scene media so selecting a scene can reset slot playback,
            // even when the path is unchanged from the previous scene.
            layers_.loadMedia(slot * 2, path);
        }
    }
    mediaPickerWin_.setSlotPaths(scenes_[sceneIdx].imgPaths);

    int fxMi = static_cast<int>(KnobMode::FxParam);
    SceneState& s = scenes_[sceneIdx];

    ensureSceneTransformDefaults(sceneIdx);
    ensureSceneLIFDefaults(sceneIdx);

    if (!s.hasData(fxMi)) {
        // First visit: seed FxParam knobs from SCENES[] defaults.
        // Applied directly to the engine; scene object stores them so
        // subsequent visits correctly restore them.
        for (int slot = 0; slot < NUM_FX_LAYERS; ++slot) {
            s.knobs[fxMi][slot * 2]     = sc.params[slot][0];
            s.knobs[fxMi][slot * 2 + 1] = sc.params[slot][1];
        }
    }

    // 2. Start pan/zoom animation before applying the new scene.
    startPanZoomAnimation();

    // 3. Apply all stored knob values to the engine.
    applySceneToEngine(sceneIdx);

    // 4. Refresh the software knob arcs to show what is actually applied.
    refreshKnobDisplay();
    // 5. Update knob param name labels to reflect the new scene's FX patches.
    refreshKnobParamNames();
    // Persist the new currentScene_ immediately so a crash won't revert it.
    saveState();
}

// ── GUI knob drag ─────────────────────────────────────────────────────────────

void App::onKnobDrag(int knobIdx, float normValue) {
    if (currentScene_ < 0) return;

    // I key intercept: set global image-load crossfade speed override.
    if (globalImgXfadeKeyHeld_) {
        if (knobIdx % 2 == 0 && knobIdx / 2 < NUM_SRC_LAYERS) {
            int slot = knobIdx / 2;
            setGlobalImageCrossfadeNorm(slot, normValue);
            compositor_.setCrossfadeSpeed(slot, 0.1f + normValue * 7.9f); // 0.1–8.0 s
        }
        controlWin_.setKnobValue(knobIdx, static_cast<int>(normValue * 127.0f));
        return;
    }

    // S key intercept: set global scene-change crossfade speed override.
    if (globalSceneXfadeKeyHeld_) {
        if (knobIdx % 2 == 0 && knobIdx / 2 < NUM_SRC_LAYERS) {
            int slot = knobIdx / 2;
            setGlobalSceneCrossfadeNorm(slot, normValue);
        }
        controlWin_.setKnobValue(knobIdx, static_cast<int>(normValue * 127.0f));
        return;
    }

    // L key intercept: set global opacity override.
    if (globalOpacityKeyHeld_) {
        if (knobIdx % 2 == 0 && knobIdx / 2 < NUM_FX_LAYERS) {
            int slot = knobIdx / 2;
            setGlobalLayerOpacityNorm(slot, normValue);
            applyKnob(knobIdx, normValue, KnobMode::LayerLevel);
        }
        controlWin_.setKnobValue(knobIdx, static_cast<int>(normValue * 127.0f));
        return;
    }

    // H key intercept: set global audio gain override.
    if (globalAudioGainKeyHeld_) {
        if (knobIdx % 2 == 0 && knobIdx / 2 < NUM_FX_LAYERS) {
            int slot = knobIdx / 2;
            setGlobalAudioGainNorm(slot, normValue);
            applyKnob(knobIdx, normValue, KnobMode::FxAudio);
        }
        controlWin_.setKnobValue(knobIdx, static_cast<int>(normValue * 127.0f));
        return;
    }

    // F key intercept: set scene-local image-load crossfade speed.
    if (imgXfadeKeyHeld_) {
        if (knobIdx % 2 == 0 && knobIdx / 2 < NUM_SRC_LAYERS) {
            int slot = knobIdx / 2;
            setLocalImageCrossfadeNorm(currentScene_, slot, normValue);
            compositor_.setCrossfadeSpeed(slot, 0.1f + normValue * 7.9f); // 0.1–8.0 s
        }
        controlWin_.setKnobValue(knobIdx, static_cast<int>(normValue * 127.0f));
        return;
    }

    // C key intercept: set scene-local scene-change crossfade speed.
    if (sceneXfadeKeyHeld_) {
        if (knobIdx % 2 == 0 && knobIdx / 2 < NUM_SRC_LAYERS) {
            int slot = knobIdx / 2;
            setLocalSceneCrossfadeNorm(currentScene_, slot, normValue);
        }
        controlWin_.setKnobValue(knobIdx, static_cast<int>(normValue * 127.0f));
        return;
    }

    if (nKeyHeld_) {
        if (knobIdx % 2 == 0) {
            scenes_[currentScene_].lifNeuronCount = lifNeuronCountFromNorm(normValue);
            compositor_.setLIFNeuronCount(scenes_[currentScene_].lifNeuronCount);
            refreshKnobDisplay();
        }
        return;
    }

    int mi = static_cast<int>(knobMode_);
    // GUI drag bypasses pickup: write directly to scene and sync physical tracker.
    if (knobMode_ == KnobMode::LayerLevel && knobIdx % 2 == 0)
        setLocalLayerOpacityNorm(currentScene_, knobIdx / 2, normValue);
    if (knobMode_ == KnobMode::FxAudio && knobIdx % 2 == 0)
        setLocalAudioGainNorm(currentScene_, knobIdx / 2, normValue);
    scenes_[currentScene_].knobs[mi][knobIdx] = normValue;
    if (knobMode_ == KnobMode::FxParam && (knobIdx % 2 == 1)) {
        int slot = knobIdx / 2;
        if (slot < NUM_FX_LAYERS && isLIFPatch(SCENES[currentScene_].fx[slot])) {
            scenes_[currentScene_].lifTopologyIndex = topologyIndexFromNorm(normValue);
            compositor_.setLIFTopology(topologyFromIndex(scenes_[currentScene_].lifTopologyIndex));
        }
    }
    knobLastPhys_[knobIdx] = normValue;
    applyKnob(knobIdx, normValue, knobMode_);
    controlWin_.setKnobValue(knobIdx, static_cast<int>(normValue * 127.0f));
}

// ── Image selected from media picker ──────────────────────────────────────────

void App::onImageSelected(int slotIdx, const std::string& path) {
    if (slotIdx < 0 || slotIdx >= NUM_SRC_LAYERS) return;
    const int layerIdx = slotIdx * 2;
    const bool samePathAsLoaded = (layers_.state(layerIdx).mediaPath == path);

    if (currentScene_ >= 0) {
        scenes_[currentScene_].imgPaths[slotIdx] = path;
        compositor_.setCrossfadeSpeed(slotIdx,
                                      0.1f + effectiveImageCrossfadeNorm(currentScene_, slotIdx) * 7.9f);
    } else {
        // No scene active yet — store in every scene that has no image for this slot
        // so the image persists regardless of which scene is selected first.
        for (auto& s : scenes_)
            if (s.imgPaths[slotIdx].empty())
                s.imgPaths[slotIdx] = path;
    }
    // Reloading the exact same file should reset playback in that slot.
    // Only use visual crossfade when the incoming path differs.
    if (!samePathAsLoaded)
        compositor_.beginCrossfade(slotIdx);  // capture current frame before new image uploads

    layers_.loadMedia(layerIdx, path);
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
        const uint32_t ver   = 10;
        f.write(reinterpret_cast<const char*>(&magic), 4);
        f.write(reinterpret_cast<const char*>(&ver),   4);
        // Write all scene states (knobs + image paths)
        for (const auto& s : scenes_) {
            for (const auto& row : s.knobs)
                for (float v : row)
                    f.write(reinterpret_cast<const char*>(&v), sizeof(float));
            for (float v : s.imageCrossfadeSpeedNorm)
                f.write(reinterpret_cast<const char*>(&v), sizeof(float));
            for (float v : s.sceneCrossfadeSpeedNorm)
                f.write(reinterpret_cast<const char*>(&v), sizeof(float));
            f.write(reinterpret_cast<const char*>(&s.lifTopologyIndex), sizeof(int));
            f.write(reinterpret_cast<const char*>(&s.lifNeuronCount), sizeof(int));
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
    // v8: per-scene image-load and scene-change crossfade speed settings
    // v9: per-scene LIF topology and neuron count settings
    // v10: 32 scenes (added second 16-note scene bank, starts at E3)
    const bool isV3 = (ver == 3);
    const bool isV4 = (ver == 4);
    const bool isV5 = (ver == 5);
    const bool isV6 = (ver == 6);
    const bool isV7 = (ver == 7);
    const bool isV8 = (ver == 8);
    const bool isV9 = (ver == 9);
    const bool isV10 = (ver == 10);
    if (!isV3 && !isV4 && !isV5 && !isV6 && !isV7 && !isV8 && !isV9 && !isV10) {
        std::cerr << "[App] Ignoring incompatible state file\n";
        return;
    }
    // Older saves have 14 or 16 scenes. v10+ saves all NUM_SCENES.
    const int savedSceneCount = isV10 ? NUM_SCENES : (isV6 || isV7 || isV8 || isV9) ? 16 : 14;
    for (int si = 0; si < savedSceneCount && si < NUM_SCENES; ++si) {
        auto& s = scenes_[si];
        // v3=3 modes, v4=4, v5/v6=5, v7=6
        int savedModes = isV3 ? 3 : isV4 ? 4 : (isV5 || isV6) ? 5 : SceneState::NMODES;
        for (int mi = 0; mi < savedModes; ++mi)
            for (float& v : s.knobs[mi])
                if (!f.read(reinterpret_cast<char*>(&v), sizeof(float))) return;
        if (isV8 || isV9) {
            for (float& v : s.imageCrossfadeSpeedNorm)
                if (!f.read(reinterpret_cast<char*>(&v), sizeof(float))) return;
            for (float& v : s.sceneCrossfadeSpeedNorm)
                if (!f.read(reinterpret_cast<char*>(&v), sizeof(float))) return;
        }
        if (isV9) {
            if (!f.read(reinterpret_cast<char*>(&s.lifTopologyIndex), sizeof(int))) return;
            if (!f.read(reinterpret_cast<char*>(&s.lifNeuronCount), sizeof(int))) return;
        }
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
        ensureSceneTransformDefaults(currentScene_);
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
    
    // Update pan/zoom animation (60 FPS = ~0.0167s per frame)
    updatePanZoomAnimation(1.0f / 60.0f);

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
