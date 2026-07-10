#pragma once

#include "Constants.h"
#include <array>
#include <cstdint>
#include <vector>

class ICompositor {
public:
    enum class LIFTopology {
        Ring = 0,
        FullyConnected,
        Feedforward,
        SparseRandom,
        SmallWorld,
    };

    struct LIFDriver {
        int srcSlot = 0;
        float influenceNorm = 0.5f;
        float topologyNorm = 0.0f;
    };

    static constexpr int NUM_LIF_TONE_BINS = 16;

    virtual ~ICompositor() = default;

    virtual bool init() = 0;
    virtual void uploadLayerPixels(int layerIdx, const uint8_t* rgba, int width, int height) = 0;
    virtual void setFxPatch(int fxLayerIdx, FxPatchId patch) = 0;
    virtual void setFxParams(int fxLayerIdx, float p0, float p1) = 0;
    virtual void setLayerOpacity(int layerIdx, float opacity) = 0;
    virtual void setLayerRotation(int srcSlot, float radians) = 0;
    virtual void setLayerZoom(int srcSlot, float factor) = 0;
    virtual void setLayerPanX(int srcSlot, float offset) = 0;
    virtual void setLayerPanY(int srcSlot, float offset) = 0;
    virtual void getLayerPan(int srcSlot, float& outOffsetX, float& outOffsetY) const = 0;
    virtual float getLayerZoom(int srcSlot) const = 0;
    virtual void setAudioBands(const float* bands, int count, float rms) = 0;
    virtual void setAudioGain(int fxSlot, float gain) = 0;
    virtual void setLIFTopology(LIFTopology topology) = 0;
    virtual void setLIFNeuronCount(int neuronCount) = 0;
    virtual void setLIFDrivers(const std::vector<LIFDriver>& drivers) = 0;
    virtual std::array<float, NUM_LIF_TONE_BINS> sampleLIFColumn(float phase01) const = 0;
    virtual void beginCrossfade(int srcSlot) = 0;
    virtual void setCrossfadeSpeed(int srcSlot, float seconds) = 0;
    virtual void resetFeedbackBuffers() = 0;
    virtual bool composite(std::vector<uint8_t>& outRGBA) = 0;
};
