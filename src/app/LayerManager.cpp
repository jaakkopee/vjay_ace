#include "LayerManager.h"
#include "VideoDecoder.h"
#include <cassert>
#include <iostream>

LayerManager::LayerManager() {
    for (auto& buf : pixels_)
        buf.resize(WORK_W * WORK_H * 4, 0);
}

LayerManager::~LayerManager() = default;

bool LayerManager::loadMedia(int layerIdx, const std::string& path) {
    assert(isSrcLayer(layerIdx));
    states_[layerIdx].mediaPath = path;
    int slot = srcSlot(layerIdx);

    decoders_[slot] = std::make_unique<VideoDecoder>();
    if (!decoders_[slot]->open(path, WORK_W, WORK_H)) {
        std::cerr << "[LayerManager] Failed to open: " << path << "\n";
        decoders_[slot].reset();
        return false;
    }
    // Decode first frame immediately so display shows something right away
    decoders_[slot]->nextFrame(pixels_[layerIdx]);
    return true;
}

void LayerManager::update(float deltaTime) {
    for (int li = 0; li < NUM_LAYERS; li += 2) {  // even = source layers
        int slot = srcSlot(li);
        if (decoders_[slot] && decoders_[slot]->isOpen())
            decoders_[slot]->nextFrame(pixels_[li], deltaTime);
    }
}

const uint8_t* LayerManager::pixelBuffer(int layerIdx) const {
    if (pixels_[layerIdx].empty()) return nullptr;
    return pixels_[layerIdx].data();
}
