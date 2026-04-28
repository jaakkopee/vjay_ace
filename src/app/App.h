#pragma once
#include "Constants.h"
#include "LayerManager.h"
#include "MidiRouter.h"
#include "MetalCompositor.h"
#include "ControlWindow.h"
#include "PerformanceWindow.h"
#include "MediaPickerWindow.h"
#include "AudioAnalyzer.h"
#include <vector>
#include <memory>
#include <cstdint>

// ── FxPatch (stub base for future per-patch state) ───────────────────────────
// Each FX layer holds one active patch. Parameters come from MIDI knobs.
// This will grow when individual effects need persistent state (e.g. MoldTrails agents).
struct FxPatch {
    FxPatchId id    = FxPatchId::None;
    float     p[2]  = {0.5f, 0.5f}; // param 0 and param 1
    float     audioGain     = 1.0f;
};

// ── SceneState ───────────────────────────────────────────────────────────────
// Owns all 6-knob values across all 3 modes for a single scene.
// knobs[modeIdx][knobIdx] = -1.0f means "not yet set" → first physical touch
// applies directly without any pickup blocking.
struct SceneState {
    static constexpr int NMODES = 6;  // LayerLevel, FxAudio, FxParam, ImgRotate, ImgZoom, ImgPan
    std::array<std::array<float, NUM_KNOBS>, NMODES> knobs;

    // Per-scene image paths for src layers 0, 2, 4 (slots 0, 1, 2)
    std::array<std::string, NUM_SRC_LAYERS> imgPaths;
    std::array<float, NUM_SRC_LAYERS> imageCrossfadeSpeedNorm;
    std::array<float, NUM_SRC_LAYERS> sceneCrossfadeSpeedNorm;
    std::array<uint32_t, NUM_SRC_LAYERS> imageCrossfadeVersion;
    std::array<uint32_t, NUM_SRC_LAYERS> sceneCrossfadeVersion;
    std::array<uint32_t, NUM_FX_LAYERS> opacityVersion;
    std::array<uint32_t, NUM_FX_LAYERS> audioGainVersion;
    int lifTopologyIndex = -1;
    int lifNeuronCount = 0;

    void reset() {
        for (auto& row : knobs) row.fill(-1.0f);
        imgPaths.fill("");
        imageCrossfadeSpeedNorm.fill(0.1f);
        sceneCrossfadeSpeedNorm.fill(0.1f);
        imageCrossfadeVersion.fill(0);
        sceneCrossfadeVersion.fill(0);
        opacityVersion.fill(0);
        audioGainVersion.fill(0);
        lifTopologyIndex = -1;
        lifNeuronCount = 0;
    }

    // True if at least one knob in the given mode has ever been set.
    bool hasData(int modeIdx) const {
        for (float v : knobs[modeIdx]) if (v >= 0.0f) return true;
        return false;
    }
};

// ── App ───────────────────────────────────────────────────────────────────────
// Top-level orchestrator. Owns all subsystems, wires MIDI → layer state → GPU.

class App {
public:
    App();
    ~App();

    bool init();
    void run();
    void saveState() const;   // public: called by signal handler and onImageSelected

private:
    // Subsystems
    LayerManager      layers_;
    MidiRouter        midi_;
    MetalCompositor   compositor_;
    AudioAnalyzer     audio_;
    ControlWindow     controlWin_;
    PerformanceWindow perfWin_;
    MediaPickerWindow mediaPickerWin_;

    // Per FX layer (slots 0=layer1, 1=layer3, 2=layer5)
    std::array<FxPatch, NUM_FX_LAYERS> fxPatches_;

    // Current knob mode
    KnobMode knobMode_  = KnobMode::FxParam;
    bool     rKeyHeld_  = false;  // R held → ImgRotate overrides knobMode_
    bool     zKeyHeld_  = false;  // Z held → ImgZoom overrides knobMode_
    bool     oKeyHeld_  = false;  // O held (no Shift) → local LayerLevel mode
    bool     gKeyHeld_  = false;  // G held (no Shift) → local FxAudio mode
    bool     pKeyHeld_  = false;  // P held → ImgPan mode
    bool     imgXfadeKeyHeld_         = false;  // I held (no Shift) → local image crossfade speed mode
    bool     sceneXfadeKeyHeld_       = false;  // S held (no Shift) → local scene crossfade speed mode
    bool     globalImgXfadeKeyHeld_   = false;  // Shift+I held → global image-load crossfade override
    bool     globalSceneXfadeKeyHeld_ = false;  // Shift+S held → global scene-change crossfade override
    bool     globalOpacityKeyHeld_    = false;  // Shift+O held → global opacity override mode
    bool     globalAudioGainKeyHeld_  = false;  // Shift+G held → global audio gain override mode
    bool     nKeyHeld_  = false;  // N held → LIF neuron count mode
    bool     audioBypassed_ = false;  // B key toggle → bypass audio bands

    // Returns the effective mode considering modifier keys.
    KnobMode effectiveMode() const {
        if (rKeyHeld_) return KnobMode::ImgRotate;
        if (zKeyHeld_) return KnobMode::ImgZoom;
        if (oKeyHeld_) return KnobMode::LayerLevel;
        if (globalOpacityKeyHeld_) return KnobMode::LayerLevel;
        if (globalAudioGainKeyHeld_) return KnobMode::FxAudio;
        if (gKeyHeld_) return KnobMode::FxAudio;
        if (pKeyHeld_) return KnobMode::ImgPan;
        return knobMode_;
    }

    // ── 14 scene state objects — one per MIDI pad (D2…D#3) ───────────────
    // Each scene is the single source of truth for its knob values.
    // onKnob() writes directly here; onSceneSelect() reads from here.
    // No separate "live buffer" to sync — eliminates all sync bugs.
    std::array<SceneState, NUM_SCENES> scenes_;
    int currentScene_ = -1;  // -1 = no scene active

    // Global crossfade overrides set with I/S modifiers.
    // A scene-local F/C write takes back priority by bumping that scene slot's version.
    std::array<float, NUM_SRC_LAYERS> globalImageCrossfadeNorm_ = {0.1f, 0.1f, 0.1f};
    std::array<float, NUM_SRC_LAYERS> globalSceneCrossfadeNorm_ = {0.1f, 0.1f, 0.1f};
    std::array<uint32_t, NUM_SRC_LAYERS> globalImageCrossfadeVersion_ = {0, 0, 0};
    std::array<uint32_t, NUM_SRC_LAYERS> globalSceneCrossfadeVersion_ = {0, 0, 0};
    std::array<float, NUM_FX_LAYERS> globalOpacityNorm_ = {1.0f, 1.0f, 1.0f};
    std::array<uint32_t, NUM_FX_LAYERS> globalOpacityVersion_ = {0, 0, 0};
    std::array<float, NUM_FX_LAYERS> globalAudioGainNorm_ = {0.125f, 0.125f, 0.125f};
    std::array<uint32_t, NUM_FX_LAYERS> globalAudioGainVersion_ = {0, 0, 0};

    // Pan/zoom animation state (when changing scenes)
    bool panZoomAnimating_ = false;
    float panZoomAnimTime_ = 0.0f;  // elapsed time
    float panZoomAnimDuration_ = 0.5f;  // dynamically set from scene crossfade speed
    std::array<float, NUM_SRC_LAYERS> panXFrom_, panXTo_;
    std::array<float, NUM_SRC_LAYERS> panYFrom_, panYTo_;
    std::array<float, NUM_SRC_LAYERS> zoomFrom_, zoomTo_;
    void startPanZoomAnimation();
    void updatePanZoomAnimation(float deltaTime);

    // Last raw physical CC position per knob (0.0–1.0).
    // Updated on every CC event; used for pickup catch-up detection.
    std::array<float, NUM_KNOBS> knobLastPhys_;

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
    // Called by MediaPickerWindow when an image is picked for a slot
    void onImageSelected(int slotIdx, const std::string& path);

    // ── Engine helpers ────────────────────────────────────────────────────
    // Apply one knob value to the correct engine target (no pickup, no display).
    void applyKnob(int knobIdx, float v, KnobMode mode);
    // Ensure transform modes have explicit per-scene neutral defaults.
    void ensureSceneTransformDefaults(int idx);
    void ensureSceneOpacityDefaults(int idx);
    void ensureSceneAudioGainDefaults(int idx);
    void ensureSceneLIFDefaults(int idx);
    void applySceneCrossfadeSettings(int idx);
    float effectiveImageCrossfadeNorm(int sceneIdx, int slot) const;
    float effectiveSceneCrossfadeNorm(int sceneIdx, int slot) const;
    float effectiveLayerOpacityNorm(int sceneIdx, int slot) const;
    void setLocalLayerOpacityNorm(int sceneIdx, int slot, float norm);
    void setGlobalLayerOpacityNorm(int slot, float norm);
    float effectiveAudioGainNorm(int sceneIdx, int slot) const;
    void setLocalAudioGainNorm(int sceneIdx, int slot, float norm);
    void setGlobalAudioGainNorm(int slot, float norm);
    void setLocalImageCrossfadeNorm(int sceneIdx, int slot, float norm);
    void setLocalSceneCrossfadeNorm(int sceneIdx, int slot, float norm);
    void setGlobalImageCrossfadeNorm(int slot, float norm);
    void setGlobalSceneCrossfadeNorm(int slot, float norm);
    static int lifNeuronCountFromNorm(float v);
    static float normFromLIFNeuronCount(int neuronCount);
    // Push all stored values in scenes_[idx] to the engine.
    void applySceneToEngine(int idx);
    // Sync all 6 knob arc widgets to the active scene's stored values.
    void refreshKnobDisplay();
    // Update knob param name labels based on active scene's FX patches.
    void refreshKnobParamNames();

    // ── Per-frame ────────────────────────────────────────────────────────
    void processFrame();
    void uploadLayers();
    void syncCompositorState();

    // ── State persistence ────────────────────────────────────────────────
    void loadState();         // reads file → restores scenes_ + applies to engine
    static std::string statePath();
};
