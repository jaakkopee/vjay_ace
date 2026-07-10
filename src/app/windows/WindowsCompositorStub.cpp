#include "WindowsCompositorStub.h"

#include <algorithm>

bool WindowsCompositorStub::init() {
    return true;
}

void WindowsCompositorStub::uploadLayerPixels(int, const uint8_t*, int, int) {}
void WindowsCompositorStub::setFxPatch(int, FxPatchId) {}
void WindowsCompositorStub::setFxParams(int, float, float) {}
void WindowsCompositorStub::setLayerOpacity(int, float) {}
void WindowsCompositorStub::setLayerRotation(int, float) {}

void WindowsCompositorStub::setLayerZoom(int srcSlot, float factor) {
    if (srcSlot < 0 || srcSlot >= NUM_SRC_LAYERS) return;
    zoom_[srcSlot] = std::max(0.001f, factor);
}

void WindowsCompositorStub::setLayerPanX(int srcSlot, float offset) {
    if (srcSlot < 0 || srcSlot >= NUM_SRC_LAYERS) return;
    pan_[srcSlot][0] = offset;
}

void WindowsCompositorStub::setLayerPanY(int srcSlot, float offset) {
    if (srcSlot < 0 || srcSlot >= NUM_SRC_LAYERS) return;
    pan_[srcSlot][1] = offset;
}

void WindowsCompositorStub::getLayerPan(int srcSlot, float& outOffsetX, float& outOffsetY) const {
    if (srcSlot < 0 || srcSlot >= NUM_SRC_LAYERS) {
        outOffsetX = 0.0f;
        outOffsetY = 0.0f;
        return;
    }
    outOffsetX = pan_[srcSlot][0];
    outOffsetY = pan_[srcSlot][1];
}

float WindowsCompositorStub::getLayerZoom(int srcSlot) const {
    if (srcSlot < 0 || srcSlot >= NUM_SRC_LAYERS) return 1.0f;
    return zoom_[srcSlot];
}

void WindowsCompositorStub::setAudioBands(const float*, int, float) {}

void WindowsCompositorStub::setAudioGain(int fxSlot, float gain) {
    if (fxSlot < 0 || fxSlot >= NUM_FX_LAYERS) return;
    audioGain_[fxSlot] = gain;
}

void WindowsCompositorStub::setLIFTopology(LIFTopology topology) {
    topology_ = topology;
}

void WindowsCompositorStub::setLIFNeuronCount(int neuronCount) {
    lifNeuronCount_ = std::max(1, neuronCount);
}

void WindowsCompositorStub::setLIFDrivers(const std::vector<LIFDriver>& drivers) {
    lifDrivers_ = drivers;
}

std::array<float, ICompositor::NUM_LIF_TONE_BINS> WindowsCompositorStub::sampleLIFColumn(float) const {
    return {};
}

void WindowsCompositorStub::beginCrossfade(int) {}
void WindowsCompositorStub::setCrossfadeSpeed(int, float) {}
void WindowsCompositorStub::resetFeedbackBuffers() {}

bool WindowsCompositorStub::composite(std::vector<uint8_t>& outRGBA) {
    outRGBA.assign(static_cast<size_t>(WORK_W) * static_cast<size_t>(WORK_H) * 4u, 0u);
    return true;
}
