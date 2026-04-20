#pragma once
#include "Constants.h"
#include <array>
#include <string>
#include <memory>
#include <vector>

class VideoDecoder; // forward

// ── LayerManager ─────────────────────────────────────────────────────────────
// Owns all LayerState objects and the VideoDecoder instances for src layers.
// Each frame, call update() to decode the next video frame into the pixel buffer,
// then call pixelBuffer(layerIdx) to get the RGBA8 data for GPU upload.

class LayerManager {
public:
    LayerManager();
    ~LayerManager();

    // Load a media file (image or video) into a source layer.
    // layerIdx must be even (0, 2, 4, 6).
    bool loadMedia(int layerIdx, const std::string& path);

    // Decode next video frame for all active video source layers.
    // Call once per render frame.
    void update(float videoFps = 60.0f);

    // Raw RGBA8 pixel data for a given layer (width=WORK_W, height=WORK_H).
    // Returns nullptr if not loaded.
    const uint8_t* pixelBuffer(int layerIdx) const;

    // State accessors / mutators
    LayerState&       state(int idx)       { return states_[idx]; }
    const LayerState& state(int idx) const { return states_[idx]; }

    void setOpacity(int idx, float v)            { states_[idx].opacity = v; }
    void setFxPatch(int fxIdx, FxPatchId p)      { states_[fxIdx].fxPatch = p; }
    void setFxParam(int fxIdx, int slot, float v){ states_[fxIdx].fxParam[slot] = v; }
    void setAudioGain(int fxIdx, float v)        { states_[fxIdx].audioGain = v; }
    void setBandpass(int fxIdx, float hz)        { states_[fxIdx].bandpassFreqHz = hz; }

private:
    std::array<LayerState, NUM_LAYERS> states_;

    // One video decoder per source layer (null if static image or empty)
    std::array<std::unique_ptr<VideoDecoder>, NUM_SRC_LAYERS> decoders_;
    // RGBA8 pixel buffers for each layer, scaled to WORK_W x WORK_H
    std::array<std::vector<uint8_t>, NUM_LAYERS> pixels_;

    // Decode index: src layer 0→decoder[0], 2→[1], 4→[2], 6→[3]
    static int srcSlot(int layerIdx) { return layerIdx / 2; }
};
