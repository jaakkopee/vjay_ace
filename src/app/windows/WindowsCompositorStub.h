#pragma once

#include "../ICompositor.h"

class WindowsCompositorStub : public ICompositor {
public:
    bool init() override;

    void uploadLayerPixels(int layerIdx, const uint8_t* rgba, int width, int height) override;
    void setFxPatch(int fxLayerIdx, FxPatchId patch) override;
    void setFxParams(int fxLayerIdx, float p0, float p1) override;
    void setLayerOpacity(int layerIdx, float opacity) override;
    void setLayerRotation(int srcSlot, float radians) override;
    void setLayerZoom(int srcSlot, float factor) override;
    void setLayerPanX(int srcSlot, float offset) override;
    void setLayerPanY(int srcSlot, float offset) override;
    void getLayerPan(int srcSlot, float& outOffsetX, float& outOffsetY) const override;
    float getLayerZoom(int srcSlot) const override;
    void setAudioBands(const float* bands, int count, float rms) override;
    void setAudioGain(int fxSlot, float gain) override;
    void setLIFTopology(LIFTopology topology) override;
    void setLIFNeuronCount(int neuronCount) override;
    void setLIFDrivers(const std::vector<LIFDriver>& drivers) override;
    std::array<float, NUM_LIF_TONE_BINS> sampleLIFColumn(float phase01) const override;
    void beginCrossfade(int srcSlot) override;
    void setCrossfadeSpeed(int srcSlot, float seconds) override;
    void resetFeedbackBuffers() override;
    bool composite(std::vector<uint8_t>& outRGBA) override;

private:
    std::array<std::array<float, 2>, NUM_SRC_LAYERS> pan_ = {};
    std::array<float, NUM_SRC_LAYERS> zoom_ = {1.0f, 1.0f, 1.0f};
    std::array<float, NUM_FX_LAYERS> audioGain_ = {1.0f, 1.0f, 1.0f};
    LIFTopology topology_ = LIFTopology::Ring;
    int lifNeuronCount_ = 1024;
    std::vector<LIFDriver> lifDrivers_;
};
