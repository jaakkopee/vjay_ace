#pragma once
#include "Constants.h"
#include "ICompositor.h"
#include "LIFNetwork.h"
#include <Metal/Metal.h>
#include <cstdint>
#include <memory>
#include <vector>
#include <string>

// ── MetalCompositor ──────────────────────────────────────────────────────────
// Owns the MTLDevice, command queue, and all pipeline state objects.
// Exposes one simple interface: given an array of layer textures + states,
// composite them into the output texture ready for display blit.
//
// Layer topology (compositing order, bottom → top):
//   layer 0  (src)   ─┐
//   layer 1  (fx)    ─┴── FX layer 1 modulates layer 0 output
//   layer 2  (src)   ─┐
//   layer 3  (fx)    ─┴── FX layer 3 modulates layer 2 output
//   layer 4  (src)   ─┐
//   layer 5  (fx)    ─┴── FX layer 5 modulates layer 4 output
//   layer 6  (src)   ─── top source, composited over FX groups
//   → final blend of 4 processed groups with individual opacities

class MetalCompositor : public ICompositor {
public:
    MetalCompositor();
    ~MetalCompositor();

    // Must be called once before any render calls.
    // Returns false if Metal is not available.
    bool init() override;

    // Upload a CPU pixel buffer (RGBA8) into layer slot idx.
    // Called each frame for video layers; less often for static images.
    void uploadLayerPixels(int layerIdx,
                           const uint8_t* rgba,
                           int width, int height) override;

    // Set the FX patch to run on a given odd-index (FX) layer.
    // The FX kernel reads from the processed source below and writes to its slot.
    void setFxPatch(int fxLayerIdx, FxPatchId patch) override;

    // Set per-FX float params (2 per FX layer).
    void setFxParams(int fxLayerIdx, float p0, float p1) override;

    // Set layer opacity (0.0–1.0).
    void setLayerOpacity(int layerIdx, float opacity) override;

    // Set rotation (radians) for a source layer slot (0=layer0, 1=layer2, 2=layer4).
    void setLayerRotation(int srcSlot, float radians) override;

    // Set zoom factor for a source layer slot (1.0 = no zoom; >1 = zoom in; <1 = zoom out).
    void setLayerZoom(int srcSlot, float factor) override;

    // Set pan offset for a source layer slot.
    // offset is a fraction of the frame: -1.0 = full left/up, +1.0 = full right/down, 0.0 = centre.
    void setLayerPanX(int srcSlot, float offset) override;
    void setLayerPanY(int srcSlot, float offset) override;

    // Get current pan and zoom values for a source layer slot.
    void getLayerPan(int srcSlot, float& outOffsetX, float& outOffsetY) const override;
    float getLayerZoom(int srcSlot) const override;

    // Set audio band magnitudes (0.0-1.0 each).  Call each frame from the main thread.
    // Bands are packed into float_params[8..15] of every FX ShaderParams dispatch.
    void setAudioBands(const float* bands, int count, float rms) override;

    // Set per-FX audio gain multiplier (applied to bands+RMS before shader injection).
    void setAudioGain(int fxSlot, float gain) override;

    void setLIFTopology(ICompositor::LIFTopology topology) override;
    void setLIFNeuronCount(int neuronCount) override;
    void setLIFDrivers(const std::vector<ICompositor::LIFDriver>& drivers) override;
    std::array<float, ICompositor::NUM_LIF_TONE_BINS> sampleLIFColumn(float phase01) const override;

    // Begin a crossfade for a source slot — call BEFORE uploading the new image.
    // Captures the current frame and resets the blend progress to 0.
    void beginCrossfade(int srcSlot) override;

    // Set how long (in seconds) a crossfade takes for a source slot (0.1–8.0).
    void setCrossfadeSpeed(int srcSlot, float seconds) override;

    void resetFeedbackBuffers() override;

    // Composite all layers into outputTexture and return a CPU RGBA8 snapshot
    // at WORK_W x WORK_H for blit into the SFML window.
    // Returns false if not initialised.
    bool composite(std::vector<uint8_t>& outRGBA) override;

    // Params buffer layout shared with Metal kernels.
    // Mirrors MachinaVFX convention: int_params[16], float_params[16].
    struct alignas(16) ShaderParams {
        int   int_params[16]   = {};
        float float_params[16] = {};
    };

private:
    id<MTLDevice>              device_       = nil;
    id<MTLCommandQueue>        cmdQueue_     = nil;
    id<MTLLibrary>             library_      = nil;

    // One texture per layer (RGBA16Float at WORK_W x WORK_H)
    std::array<id<MTLTexture>, NUM_LAYERS> layerTex_  = {};
    // Ping-pong scratch textures for FX chains
    id<MTLTexture>             scratch_[2]  = {nil, nil};
    // Final composited output texture
    id<MTLTexture>             outputTex_   = nil;
    // Readback buffer (CPU-accessible)
    id<MTLBuffer>              readbackBuf_ = nil;

    // PSO cache — keyed by FxPatchId
    id<MTLComputePipelineState> psoComposite_    = nil;
    id<MTLComputePipelineState> psoPassthrough_  = nil;
    id<MTLComputePipelineState> psoBlur_         = nil;
    id<MTLComputePipelineState> psoChroma_       = nil;
    id<MTLComputePipelineState> psoHueCycle_     = nil;
    id<MTLComputePipelineState> psoGlitch_       = nil;
    id<MTLComputePipelineState> psoKaleidoscope_ = nil;
    id<MTLComputePipelineState> psoWave_         = nil;
    id<MTLComputePipelineState> psoEdgeInk_      = nil;
    id<MTLComputePipelineState> psoReadback_     = nil;
    id<MTLComputePipelineState> psoRotate_       = nil;
    id<MTLComputePipelineState> psoZoom_         = nil;
    id<MTLComputePipelineState> psoFxBlend_      = nil;
    id<MTLComputePipelineState> psoPixelate_     = nil;
    id<MTLComputePipelineState> psoRainbow_      = nil;
    id<MTLComputePipelineState> psoJulia_        = nil;
    id<MTLComputePipelineState> psoFeedback_     = nil;
    id<MTLComputePipelineState> psoCircleQuilt_  = nil;
    id<MTLComputePipelineState> psoCAGlow_       = nil;
    id<MTLComputePipelineState> psoBitplane_     = nil;
    id<MTLComputePipelineState> psoLIFModulate_  = nil;
    id<MTLComputePipelineState> psoLIFReplace_   = nil;
    id<MTLComputePipelineState> psoVignette_     = nil;
    id<MTLComputePipelineState> psoRipple_       = nil;
    id<MTLComputePipelineState> psoLensDistort_  = nil;
    id<MTLComputePipelineState> psoSwirl_        = nil;
    id<MTLComputePipelineState> psoRGBModulate_  = nil;
    id<MTLComputePipelineState> psoColorTemp_    = nil;
    id<MTLComputePipelineState> psoScanline_     = nil;
    id<MTLComputePipelineState> psoStrobe_       = nil;
    id<MTLComputePipelineState> psoCrossfade_    = nil;
    // ── aux effects ──────────────────────────────────────────────────────────
    id<MTLComputePipelineState> psoGrayscale_         = nil;
    id<MTLComputePipelineState> psoInvert_            = nil;
    id<MTLComputePipelineState> psoSepia_             = nil;
    id<MTLComputePipelineState> psoMirrorH_           = nil;
    id<MTLComputePipelineState> psoMirrorV_           = nil;
    id<MTLComputePipelineState> psoSharpen_           = nil;
    id<MTLComputePipelineState> psoGaussianBlur_      = nil;
    id<MTLComputePipelineState> psoVHS_               = nil;
    id<MTLComputePipelineState> psoPsychedelic_       = nil;
    id<MTLComputePipelineState> psoNoiseDist_         = nil;
    id<MTLComputePipelineState> psoHSVShift_          = nil;
    id<MTLComputePipelineState> psoBlockShuffle_      = nil;
    id<MTLComputePipelineState> psoRGBShift_          = nil;
    id<MTLComputePipelineState> psoFisheye_           = nil;
    id<MTLComputePipelineState> psoEchoTrails_        = nil;
    id<MTLComputePipelineState> psoDatamosh_          = nil;
    id<MTLComputePipelineState> psoMotionBlur_        = nil;
    id<MTLComputePipelineState> psoFeedbackTransform_ = nil;

    // Per-source-slot rotation textures and angles
    id<MTLTexture>              rotateTex_[NUM_SRC_LAYERS] = {nil, nil, nil};
    float                       rotations_[NUM_SRC_LAYERS] = {0.0f, 0.0f, 0.0f};

    // Per-source-slot zoom textures and factors (1.0 = no change)
    id<MTLTexture>              zoomTex_[NUM_SRC_LAYERS]   = {nil, nil, nil};
    float                       zooms_[NUM_SRC_LAYERS]     = {1.0f, 1.0f, 1.0f};

    // Per-source-slot pan textures and offsets (0.0 = no pan, fraction of frame)
    id<MTLTexture>              panTex_[NUM_SRC_LAYERS]    = {nil, nil, nil};
    float                       panX_[NUM_SRC_LAYERS]      = {0.0f, 0.0f, 0.0f};
    float                       panY_[NUM_SRC_LAYERS]      = {0.0f, 0.0f, 0.0f};

    id<MTLComputePipelineState> psoPan_ = nil;

    // Per-source-slot crossfade state
    id<MTLTexture>              crossfadeTex_[NUM_SRC_LAYERS]      = {nil, nil, nil};
    id<MTLTexture>              crossfadeBlendTex_[NUM_SRC_LAYERS] = {nil, nil, nil};
    id<MTLTexture>              feedbackTex_[NUM_FX_LAYERS]        = {nil, nil, nil};
    bool                        feedbackPrimed_[NUM_FX_LAYERS]     = {false, false, false};
    float                       crossfadeProgress_[NUM_SRC_LAYERS] = {1.0f, 1.0f, 1.0f};
    float                       crossfadeSpeed_[NUM_SRC_LAYERS]    = {1.0f, 1.0f, 1.0f};
    float                       lastFrameTime_ = 0.0f;

    std::array<float, NUM_LAYERS>          opacity_  = {1,1,1,1,1,1};
    std::array<FxPatchId, NUM_FX_LAYERS>   patches_  = {};
    std::array<std::array<float,2>, NUM_FX_LAYERS> fxParams_ = {};
    float frameTime_ = 0.0f; // seconds since start, for animated FX

    // Audio bands (8 bands + RMS) passed to FX kernels each frame
    std::array<float, 8> audioBands_ = {};
    float audioRms_ = 0.0f;
    std::array<float, NUM_FX_LAYERS> audioGain_ = {1.0f, 1.0f, 1.0f};
    std::array<ICompositor::LIFDriver, NUM_FX_LAYERS> lifDrivers_ = {};
    int lifDriverCount_ = 0;
    std::unique_ptr<LIFNetwork> lifNetwork_;

    id<MTLTexture> makeTexture(int w, int h, bool halfRes = false);
    id<MTLComputePipelineState> makePSO(NSString* kernelName);

    // Dispatch a compute kernel over a full WORK_W x WORK_H texture.
    void dispatch(id<MTLComputeCommandEncoder> enc,
                  id<MTLComputePipelineState>  pso,
                  id<MTLTexture> input,
                  id<MTLTexture> output,
                  const ShaderParams& params);

    // Run the FX kernel for one FX layer (slot 0–2).
    void runFxPass(id<MTLCommandBuffer> cmd, int fxSlot,
                   id<MTLTexture> src, id<MTLTexture> dst);

    // Composite 3 processed group textures into outputTex_.
    void runComposite(id<MTLCommandBuffer> cmd,
                      const std::array<id<MTLTexture>, 3>& groups);
};
