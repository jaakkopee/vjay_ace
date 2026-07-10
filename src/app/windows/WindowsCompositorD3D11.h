#pragma once

#include "../ICompositor.h"

#include <array>
#include <vector>

#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <d3d11.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#endif

class WindowsCompositorD3D11 : public ICompositor {
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

    // Window presentation — call after init(). Creates a DXGI swap chain for
    // the given HWND at the specified preview dimensions.
    bool initSwapChain(HWND hwnd, int windowW, int windowH);
    // Runs the GPU compute passes and blits the result to the swap chain.
    // Returns false if no swap chain has been initialized.
    bool presentToWindow();

private:
    void runGPUPasses(); // shared by composite() and presentToWindow()

    bool initialized_ = false;

    std::array<std::array<float, 2>, NUM_SRC_LAYERS> pan_ = {};
    std::array<float, NUM_SRC_LAYERS> zoom_ = {1.0f, 1.0f, 1.0f};
    std::array<float, NUM_SRC_LAYERS> rotation_ = {0.0f, 0.0f, 0.0f};
    std::array<float, NUM_FX_LAYERS> fxOpacity_ = {1.0f, 1.0f, 1.0f};
    std::array<float, NUM_FX_LAYERS> audioGain_ = {1.0f, 1.0f, 1.0f};
    std::array<FxPatchId, NUM_FX_LAYERS> fxPatches_ = {
        FxPatchId::Passthrough,
        FxPatchId::Passthrough,
        FxPatchId::Passthrough,
    };
    std::array<std::array<float, 2>, NUM_FX_LAYERS> fxParams_ = {{
        {0.5f, 0.5f},
        {0.5f, 0.5f},
        {0.5f, 0.5f},
    }};
    std::array<float, 8> audioBands_ = {};
    float audioRms_ = 0.0f;
    LIFTopology topology_ = LIFTopology::Ring;
    int lifNeuronCount_ = 1024;
    std::vector<LIFDriver> lifDrivers_;

#if defined(_WIN32)
    Microsoft::WRL::ComPtr<ID3D11Device> device_;
    Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
    std::array<Microsoft::WRL::ComPtr<ID3D11Texture2D>, NUM_SRC_LAYERS> srcTex_;
    std::array<Microsoft::WRL::ComPtr<ID3D11Texture2D>, NUM_SRC_LAYERS> fxTex_;
    std::array<Microsoft::WRL::ComPtr<ID3D11Texture2D>, NUM_SRC_LAYERS> feedbackTex_;
    Microsoft::WRL::ComPtr<ID3D11Texture2D> compositeTex_;
    Microsoft::WRL::ComPtr<ID3D11Texture2D> readbackTex_;
    std::array<Microsoft::WRL::ComPtr<ID3D11ShaderResourceView>, NUM_SRC_LAYERS> srcSrv_;
    std::array<Microsoft::WRL::ComPtr<ID3D11ShaderResourceView>, NUM_SRC_LAYERS> fxSrv_;
    std::array<Microsoft::WRL::ComPtr<ID3D11ShaderResourceView>, NUM_SRC_LAYERS> feedbackSrv_;
    std::array<Microsoft::WRL::ComPtr<ID3D11UnorderedAccessView>, NUM_SRC_LAYERS> fxUav_;
    Microsoft::WRL::ComPtr<ID3D11UnorderedAccessView> compositeUav_;
    Microsoft::WRL::ComPtr<ID3D11ComputeShader> fxCs_;
    Microsoft::WRL::ComPtr<ID3D11ComputeShader> compositeCs_;
    Microsoft::WRL::ComPtr<ID3D11Buffer> fxParamsCb_;
    Microsoft::WRL::ComPtr<ID3D11Buffer> compositeParamsCb_;
    // Swap chain + blit pipeline (populated by initSwapChain)
    Microsoft::WRL::ComPtr<IDXGISwapChain>              swapChain_;
    Microsoft::WRL::ComPtr<ID3D11VertexShader>          blitVs_;
    Microsoft::WRL::ComPtr<ID3D11PixelShader>           blitPs_;
    Microsoft::WRL::ComPtr<ID3D11SamplerState>          linearSampler_;
    Microsoft::WRL::ComPtr<ID3D11ShaderResourceView>    compositeSrv_;
    int swapW_ = 0;
    int swapH_ = 0;
#endif

    std::array<std::vector<uint8_t>, NUM_SRC_LAYERS> uploadScratch_;
    std::array<bool, NUM_SRC_LAYERS> feedbackPrimed_ = {false, false, false};
};
