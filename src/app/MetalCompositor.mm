#include "MetalCompositor.h"
#import  <Foundation/Foundation.h>
#import  <Metal/Metal.h>
#include <stdexcept>
#include <cassert>
#include <cstring>
#include <chrono>

namespace {
LIFNetwork::Topology topologyFromParam(float value) {
    int bucket = std::clamp(static_cast<int>(value * 5.0f), 0, 4);
    switch (bucket) {
        case 0: return LIFNetwork::Topology::Ring;
        case 1: return LIFNetwork::Topology::FullyConnected;
        case 2: return LIFNetwork::Topology::Feedforward;
        case 3: return LIFNetwork::Topology::SparseRandom;
        default: return LIFNetwork::Topology::SmallWorld;
    }
}

bool isLIFPatch(FxPatchId patch) {
    return patch == FxPatchId::LIFModulate || patch == FxPatchId::LIFReplace;
}
}

// ── helpers ──────────────────────────────────────────────────────────────────

static auto s_start = std::chrono::steady_clock::now();

static float elapsedSeconds() {
    auto now = std::chrono::steady_clock::now();
    return std::chrono::duration<float>(now - s_start).count();
}

// ── MetalCompositor ──────────────────────────────────────────────────────────

MetalCompositor::MetalCompositor() = default;
MetalCompositor::~MetalCompositor() = default;

bool MetalCompositor::init() {
    device_ = MTLCreateSystemDefaultDevice();
    if (!device_) return false;

    cmdQueue_ = [device_ newCommandQueue];

    // Compile Metal source embedded as a string.
    // In a full build this would be a .metal file compiled via metallib.
    NSError* err = nil;
    // Resolve shader path relative to the executable (works regardless of cwd)
    NSString* exeDir = [NSBundle mainBundle].executablePath.stringByDeletingLastPathComponent;
    NSString* shaderPath = [exeDir stringByAppendingPathComponent:@"vjay_shaders.metal"];
    NSString* src = [NSString stringWithContentsOfFile:shaderPath
        encoding:NSUTF8StringEncoding error:&err];

    if (!src) {
        // Fallback: create minimal inline library so the app still links
        NSLog(@"[Metal] Could not read shader file: %@", err.localizedDescription);
        NSLog(@"[Metal] Falling back to empty library — GPU compositing disabled");
        return false;
    }

    MTLCompileOptions* opts = [MTLCompileOptions new];
    opts.languageVersion = MTLLanguageVersion3_0;
    library_ = [device_ newLibraryWithSource:src options:opts error:&err];
    if (!library_) {
        NSLog(@"[Metal] Shader compile error: %@", err.localizedDescription);
        return false;
    }

    // Build PSOs
    psoPassthrough_  = makePSO(@"passthrough");
    psoBlur_         = makePSO(@"box_blur");
    psoChroma_       = makePSO(@"chromatic_aberration");
    psoHueCycle_     = makePSO(@"hue_cycle");
    psoGlitch_       = makePSO(@"video_glitch");
    psoKaleidoscope_ = makePSO(@"kaleidoscope");
    psoWave_         = makePSO(@"wave_distort");
    psoEdgeInk_      = makePSO(@"edge_ink");
    psoComposite_    = makePSO(@"alpha_composite");
    psoReadback_     = makePSO(@"readback_rgba8");
    psoRotate_       = makePSO(@"rotate_source");
    psoZoom_         = makePSO(@"zoom_source");
    psoFxBlend_      = makePSO(@"fx_blend");
    psoPixelate_     = makePSO(@"pixelate");
    psoRainbow_      = makePSO(@"rainbow_shift");
    psoJulia_        = makePSO(@"julia_fractal");
    psoFeedback_     = makePSO(@"feedback_zoom");
    psoCircleQuilt_  = makePSO(@"circle_quilt");
    psoCAGlow_       = makePSO(@"ca_glow");
    psoBitplane_     = makePSO(@"bitplane_reactor");
    psoLIFModulate_  = makePSO(@"lif_modulate");
    psoLIFReplace_   = makePSO(@"lif_replace");
    psoVignette_     = makePSO(@"vignette");
    psoRipple_       = makePSO(@"ripple_distort");
    psoLensDistort_  = makePSO(@"lens_distortion");
    psoSwirl_        = makePSO(@"swirl_distort");
    psoRGBModulate_  = makePSO(@"rgb_modulate");
    psoColorTemp_    = makePSO(@"color_temperature");
    psoScanline_     = makePSO(@"scanline");
    psoStrobe_       = makePSO(@"strobe_gate");
    psoPan_          = makePSO(@"pan_source");
    psoCrossfade_    = makePSO(@"crossfade_blend");

    // Allocate layer textures
    for (int i = 0; i < NUM_LAYERS; ++i)
        layerTex_[i] = makeTexture(WORK_W, WORK_H);

    scratch_[0] = makeTexture(WORK_W, WORK_H);
    scratch_[1] = makeTexture(WORK_W, WORK_H);
    outputTex_  = makeTexture(WORK_W, WORK_H);

    // Per-source-slot rotation and zoom output textures
    for (int s = 0; s < NUM_SRC_LAYERS; ++s) {
        rotateTex_[s] = makeTexture(WORK_W, WORK_H);
        zoomTex_[s]   = makeTexture(WORK_W, WORK_H);
        panTex_[s]    = makeTexture(WORK_W, WORK_H);
        crossfadeTex_[s]      = makeTexture(WORK_W, WORK_H);
        crossfadeBlendTex_[s] = makeTexture(WORK_W, WORK_H);
        feedbackTex_[s]       = makeTexture(WORK_W, WORK_H);
    }

    // CPU-readable buffer for readback (RGBA8, 4 bytes/pixel)
    NSUInteger readbackSize = WORK_W * WORK_H * 4;
    readbackBuf_ = [device_ newBufferWithLength:readbackSize
                                        options:MTLResourceStorageModeShared];

    lifNetwork_ = std::make_unique<LIFNetwork>();
    if (!lifNetwork_->init(device_, cmdQueue_, library_, LIFNetwork::Topology::Ring, 1024))
        lifNetwork_.reset();
    return true;
}

// ── texture / PSO factories ───────────────────────────────────────────────────

id<MTLTexture> MetalCompositor::makeTexture(int w, int h, bool /*halfRes*/) {
    MTLTextureDescriptor* desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:w
                                                          height:h
                                                       mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite
               | MTLTextureUsageRenderTarget;
    desc.storageMode = MTLStorageModePrivate;
    return [device_ newTextureWithDescriptor:desc];
}

id<MTLComputePipelineState> MetalCompositor::makePSO(NSString* kernelName) {
    id<MTLFunction> fn = [library_ newFunctionWithName:kernelName];
    if (!fn) {
        NSLog(@"[Metal] Kernel not found: %@", kernelName);
        return nil;
    }
    NSError* err = nil;
    auto pso = [device_ newComputePipelineStateWithFunction:fn error:&err];
    if (!pso) NSLog(@"[Metal] PSO error for %@: %@", kernelName, err.localizedDescription);
    return pso;
}

// ── upload ────────────────────────────────────────────────────────────────────

void MetalCompositor::uploadLayerPixels(int layerIdx,
                                         const uint8_t* rgba,
                                         int width, int height) {
    assert(layerIdx >= 0 && layerIdx < NUM_LAYERS);
    id<MTLTexture> tex = layerTex_[layerIdx];
    if (!tex) return;

    // Create (or reuse) a shared staging texture in RGBA8Unorm — same format as
    // layerTex_, so the blit below is always valid.
    MTLTextureDescriptor* desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    desc.storageMode = MTLStorageModeShared;
    desc.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> staging = [device_ newTextureWithDescriptor:desc];
    [staging replaceRegion:MTLRegionMake2D(0, 0, width, height)
               mipmapLevel:0
                 withBytes:rgba
               bytesPerRow:width * 4];

    id<MTLCommandBuffer> cmd = [cmdQueue_ commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
    [blit copyFromTexture:staging sourceSlice:0 sourceLevel:0
              sourceOrigin:MTLOriginMake(0, 0, 0)
                sourceSize:MTLSizeMake(width, height, 1)
               toTexture:tex destinationSlice:0 destinationLevel:0
       destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [cmd commit];
}

// ── state setters ─────────────────────────────────────────────────────────────

void MetalCompositor::setFxPatch(int fxLayerIdx, FxPatchId patch) {
    assert(fxLayerIdx >= 0 && fxLayerIdx < NUM_FX_LAYERS);
    patches_[fxLayerIdx] = patch;
}

void MetalCompositor::setFxParams(int fxLayerIdx, float p0, float p1) {
    assert(fxLayerIdx >= 0 && fxLayerIdx < NUM_FX_LAYERS);
    fxParams_[fxLayerIdx][0] = p0;
    fxParams_[fxLayerIdx][1] = p1;
}

void MetalCompositor::setLayerOpacity(int layerIdx, float opacity) {
    assert(layerIdx >= 0 && layerIdx < NUM_LAYERS);
    opacity_[layerIdx] = opacity;
}

void MetalCompositor::setLayerRotation(int srcSlot, float radians) {
    assert(srcSlot >= 0 && srcSlot < NUM_SRC_LAYERS);
    rotations_[srcSlot] = radians;
}

void MetalCompositor::setLayerZoom(int srcSlot, float factor) {
    assert(srcSlot >= 0 && srcSlot < NUM_SRC_LAYERS);
    zooms_[srcSlot] = (factor > 0.001f) ? factor : 0.001f;
}

void MetalCompositor::setLayerPanX(int srcSlot, float offset) {
    assert(srcSlot >= 0 && srcSlot < NUM_SRC_LAYERS);
    panX_[srcSlot] = offset;
}

void MetalCompositor::setLayerPanY(int srcSlot, float offset) {
    assert(srcSlot >= 0 && srcSlot < NUM_SRC_LAYERS);
    panY_[srcSlot] = offset;
}

void MetalCompositor::getLayerPan(int srcSlot, float& outOffsetX, float& outOffsetY) const {
    assert(srcSlot >= 0 && srcSlot < NUM_SRC_LAYERS);
    outOffsetX = panX_[srcSlot];
    outOffsetY = panY_[srcSlot];
}

float MetalCompositor::getLayerZoom(int srcSlot) const {
    assert(srcSlot >= 0 && srcSlot < NUM_SRC_LAYERS);
    return zooms_[srcSlot];
}

void MetalCompositor::setAudioBands(const float* bands, int count, float rms) {
    int n = std::min(count, static_cast<int>(audioBands_.size()));
    for (int i = 0; i < n; ++i) audioBands_[i] = bands[i];
    audioRms_ = rms;
}

void MetalCompositor::setAudioGain(int fxSlot, float gain) {
    if (fxSlot >= 0 && fxSlot < NUM_FX_LAYERS)
        audioGain_[fxSlot] = gain;
}

void MetalCompositor::setLIFTopology(LIFNetwork::Topology topology) {
    if (lifNetwork_)
        lifNetwork_->setTopology(topology);
}

void MetalCompositor::setLIFNeuronCount(int neuronCount) {
    if (lifNetwork_)
        lifNetwork_->setNeuronCount(neuronCount);
}

void MetalCompositor::setLIFDrivers(const std::vector<LIFDriver>& drivers) {
    lifDriverCount_ = std::min(static_cast<int>(drivers.size()), NUM_FX_LAYERS);
    for (int i = 0; i < lifDriverCount_; ++i) {
        lifDrivers_[i].srcSlot = std::clamp(drivers[i].srcSlot, 0, NUM_SRC_LAYERS - 1);
        lifDrivers_[i].influenceNorm = std::clamp(drivers[i].influenceNorm, 0.0f, 1.0f);
        lifDrivers_[i].topologyNorm = std::clamp(drivers[i].topologyNorm, 0.0f, 1.0f);
    }
}

std::array<float, LIFNetwork::NUM_TONE_BINS> MetalCompositor::sampleLIFColumn(float phase01) const {
    if (!lifNetwork_)
        return {};
    return lifNetwork_->sampleColumn(phase01);
}

void MetalCompositor::beginCrossfade(int srcSlot) {
    assert(srcSlot >= 0 && srcSlot < NUM_SRC_LAYERS);
    // Capture the current source frame into crossfadeTex_ before the new image arrives.
    id<MTLCommandBuffer> cmd = [cmdQueue_ commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
    [blit copyFromTexture:layerTex_[srcSlot * 2] sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(WORK_W, WORK_H, 1)
               toTexture:crossfadeTex_[srcSlot] destinationSlice:0 destinationLevel:0
      destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [cmd commit];
    [cmd waitUntilCompleted];
    crossfadeProgress_[srcSlot] = 0.0f;
}

void MetalCompositor::setCrossfadeSpeed(int srcSlot, float seconds) {
    assert(srcSlot >= 0 && srcSlot < NUM_SRC_LAYERS);
    crossfadeSpeed_[srcSlot] = std::max(seconds, 0.05f);
}

void MetalCompositor::resetFeedbackBuffers() {
    for (int slot = 0; slot < NUM_FX_LAYERS; ++slot)
        feedbackPrimed_[slot] = false;
}

// ── dispatch helper ───────────────────────────────────────────────────────────

void MetalCompositor::dispatch(id<MTLComputeCommandEncoder> enc,
                                id<MTLComputePipelineState>  pso,
                                id<MTLTexture> input,
                                id<MTLTexture> output,
                                const ShaderParams& params) {
    if (!pso) return;
    [enc setComputePipelineState:pso];
    [enc setTexture:input  atIndex:0];
    [enc setTexture:output atIndex:1];
    [enc setBytes:&params length:sizeof(params) atIndex:0];

    MTLSize threads    = {pso.threadExecutionWidth, 8, 1};
    MTLSize threadGroups = {
        (WORK_W  + threads.width  - 1) / threads.width,
        (WORK_H + threads.height - 1) / threads.height,
        1
    };
    [enc dispatchThreadgroups:threadGroups threadsPerThreadgroup:threads];
}

// ── FX pass ───────────────────────────────────────────────────────────────────

void MetalCompositor::runFxPass(id<MTLCommandBuffer> cmd,
                                 int fxSlot,
                                 id<MTLTexture> src,
                                 id<MTLTexture> dst) {
    FxPatchId patch = patches_[fxSlot];
    float p0 = fxParams_[fxSlot][0];
    float p1 = fxParams_[fxSlot][1];
    float t  = elapsedSeconds();

    id<MTLComputePipelineState> pso = nil;
    ShaderParams params{};

    switch (patch) {
        case FxPatchId::None:
        case FxPatchId::Passthrough:
            pso = psoPassthrough_;
            break;
        case FxPatchId::Blur:
            pso = psoBlur_;
            params.int_params[0]   = 5 + static_cast<int>(p0 * 10); // kernel size 5–15
            break;
        case FxPatchId::ChromaticAberr:
            pso = psoChroma_;
            params.int_params[0]   = static_cast<int>(p0 * 20);     // offset 0–20px
            break;
        case FxPatchId::HueCycle:
            pso = psoHueCycle_;
            params.float_params[0] = p0 * 2.0f;   // cycle speed
            params.float_params[1] = t + p1 * 10.0f; // time offset
            break;
        case FxPatchId::VideoGlitch:
            pso = psoGlitch_;
            params.float_params[0] = t;
            params.float_params[1] = p0;   // displacement strength
            params.float_params[2] = 0.3f; // interference
            params.float_params[3] = p1 * 0.1f; // channel shift
            break;
        case FxPatchId::Kaleidoscope:
            pso = psoKaleidoscope_;
            params.int_params[0]   = 2 + static_cast<int>(p0 * 10); // segments 2–12
            params.float_params[0] = p1 * 6.28318f; // rotation
            break;
        case FxPatchId::WaveDistort:
            pso = psoWave_;
            params.float_params[0] = p0 * 30.0f;  // amplitude
            params.float_params[1] = p1 * 0.1f;   // frequency
            params.float_params[2] = t;            // phase
            break;
        case FxPatchId::EdgeInk:
            pso = psoEdgeInk_;
            params.float_params[0] = p0;   // threshold
            params.float_params[1] = p1;   // edge strength
            break;
        default:
            pso = psoPassthrough_;
            break;
        case FxPatchId::Pixelate:
            pso = psoPixelate_;
            params.int_params[0] = 2 + static_cast<int>(p0 * 62); // block 2-64
            break;
        case FxPatchId::RainbowShift:
            pso = psoRainbow_;
            params.float_params[0] = p0 * 3.0f;    // speed
            params.float_params[1] = p1 * 4.0f;    // wave scale
            params.float_params[2] = t;             // time
            break;
        case FxPatchId::JuliaFractal:
            pso = psoJulia_;
            params.float_params[0] = p0 * 2.0f - 1.0f; // cx -1..1
            params.float_params[1] = p1 * 2.0f - 1.0f; // cy -1..1
            params.float_params[2] = 0.6f;              // blend
            params.float_params[3] = t;                 // time
            break;
        case FxPatchId::FeedbackZoom:
            pso = psoFeedback_;
            params.float_params[0] = 1.0f + p0 * 0.45f; // zoom delta 1.0-1.45
            params.float_params[1] = p1 * 0.35f;         // rotate delta 0-0.35 rad
            params.float_params[2] = 0.94f;              // feedback mix
            params.float_params[3] = 30.0f;              // tint hue offset
            break;
        case FxPatchId::CircleQuilt:
            pso = psoCircleQuilt_;
            params.int_params[0]   = 8 + static_cast<int>(p0 * 56); // cols 8-64
            params.float_params[0] = 0.5f + p1 * 0.5f; // radius_scale 0.5-1.0
            params.float_params[1] = p0 * 180.0f;       // hue_offset
            break;
        case FxPatchId::CAGlow:
            pso = psoCAGlow_;
            params.float_params[0] = p0;             // threshold
            params.float_params[1] = p1;             // glow spread (0-1)
            params.float_params[2] = t * 20.0f;     // animated hue base
            break;
        case FxPatchId::BitplaneReactor:
            pso = psoBitplane_;
            params.int_params[0]   = static_cast<int>(p0 * 255.0f); // rule 0-255
            params.float_params[0] = 0.3f + p1 * 0.5f;             // threshold
            params.float_params[1] = fmod(t * 30.0f, 360.0f);      // animated hue
            break;
        case FxPatchId::Fractal:
            // legacy: reuse julia with fixed params
            pso = psoJulia_;
            params.float_params[0] = -0.7f;
            params.float_params[1] =  0.27f;
            params.float_params[2] =  0.7f;
            params.float_params[3] =  t;
            break;
        case FxPatchId::MoldTrails:
            pso = psoPassthrough_; // mold_trails kernel needs state — use passthrough for now
            break;
        case FxPatchId::LIFModulate:
            pso = psoLIFModulate_;
            params.float_params[0] = 0.15f + p0 * 0.85f;
            params.float_params[1] = p1;
            params.float_params[2] = t;
            break;
        case FxPatchId::LIFReplace:
            pso = psoLIFReplace_;
            params.float_params[0] = 0.25f + p0 * 0.75f;
            params.float_params[1] = p1;
            params.float_params[2] = t;
            break;
        case FxPatchId::Vignette:
            pso = psoVignette_;
            params.float_params[0] = p0;               // strength
            params.float_params[1] = 0.2f + p1 * 0.8f; // radius
            break;
        case FxPatchId::Ripple:
            pso = psoRipple_;
            params.float_params[0] = p0 * 30.0f;       // amplitude px
            params.float_params[1] = 10.0f + p1 * 140.0f; // wavelength px
            params.float_params[2] = t * 2.2f;         // phase
            break;
        case FxPatchId::LensDistort:
            pso = psoLensDistort_;
            params.float_params[0] = p0 * 1.2f - 0.6f; // strength -0.6..0.6
            params.float_params[1] = 0.7f + p1 * 0.6f; // zoom
            break;
        case FxPatchId::Swirl:
            pso = psoSwirl_;
            params.float_params[0] = (p0 * 2.0f - 1.0f) * 8.0f; // angle -8..8
            params.float_params[1] = 0.1f + p1 * 0.9f;          // radius norm
            break;
        case FxPatchId::RGBModulate:
            pso = psoRGBModulate_;
            params.float_params[0] = 0.25f + p0 * 2.0f; // red gain
            params.float_params[1] = 0.25f + p1 * 2.0f; // blue gain
            break;
        case FxPatchId::ColorTemp:
            pso = psoColorTemp_;
            params.float_params[0] = p0 * 2.0f - 1.0f; // temperature -1..1
            params.float_params[1] = 0.6f + p1 * 0.9f; // contrast
            break;
        case FxPatchId::Scanline:
            pso = psoScanline_;
            params.float_params[0] = p0;               // intensity
            params.float_params[1] = 1.0f + p1 * 7.0f; // density
            params.float_params[2] = t;
            break;
        case FxPatchId::Strobe:
            pso = psoStrobe_;
            params.float_params[0] = 0.25f + p0 * 15.0f; // rate
            params.float_params[1] = 0.05f + p1 * 0.9f;  // duty
            params.float_params[2] = t;
            break;
    }

    // Inject audio bands into float_params[8..15] and RMS into float_params[7].
    // Scale by per-FX gain so knobs 0/2/4 control audio reactivity per FX slot.
    float gain = audioGain_[fxSlot];
    params.float_params[7] = audioRms_ * gain;
    for (int b = 0; b < 8; ++b)
        params.float_params[8 + b] = audioBands_[b] * gain;

    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    if (patch == FxPatchId::FeedbackZoom && feedbackTex_[fxSlot]) {
        id<MTLTexture> feedbackInput = feedbackPrimed_[fxSlot] ? feedbackTex_[fxSlot] : src;
        [enc setComputePipelineState:pso];
        [enc setTexture:src atIndex:0];
        [enc setTexture:dst atIndex:1];
        [enc setTexture:feedbackInput atIndex:2];
        [enc setBytes:&params length:sizeof(params) atIndex:0];
        MTLSize threads = {pso.threadExecutionWidth, 8, 1};
        MTLSize groups = {(WORK_W + threads.width - 1) / threads.width,
                          (WORK_H + threads.height - 1) / threads.height,
                          1};
        [enc dispatchThreadgroups:groups threadsPerThreadgroup:threads];
    } else if (isLIFPatch(patch) && lifNetwork_ && lifNetwork_->stateTexture()) {
        [enc setComputePipelineState:pso];
        [enc setTexture:src atIndex:0];
        [enc setTexture:dst atIndex:1];
        [enc setTexture:lifNetwork_->stateTexture() atIndex:2];
        [enc setBytes:&params length:sizeof(params) atIndex:0];
        MTLSize threads = {pso.threadExecutionWidth, 8, 1};
        MTLSize groups = {(WORK_W + threads.width - 1) / threads.width,
                          (WORK_H + threads.height - 1) / threads.height,
                          1};
        [enc dispatchThreadgroups:groups threadsPerThreadgroup:threads];
    } else {
        dispatch(enc, pso, src, dst, params);
    }
    [enc endEncoding];

    if (patch == FxPatchId::FeedbackZoom && feedbackTex_[fxSlot]) {
        id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
        [blit copyFromTexture:dst sourceSlice:0 sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(WORK_W, WORK_H, 1)
                   toTexture:feedbackTex_[fxSlot] destinationSlice:0 destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        feedbackPrimed_[fxSlot] = true;
    }
}


// ── final composite ────────────────────────────────────────────────────────────

void MetalCompositor::runComposite(id<MTLCommandBuffer> cmd,
                                    const std::array<id<MTLTexture>, 3>& groups) {
    if (!psoComposite_) return;

    // Clear scratch_[0] to transparent black using a render pass (cheapest Metal clear).
    {
        MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture    = scratch_[0];
        rpd.colorAttachments[0].loadAction  = MTLLoadActionClear;
        rpd.colorAttachments[0].clearColor  = MTLClearColorMake(0, 0, 0, 0);
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        [[cmd renderCommandEncoderWithDescriptor:rpd] endEncoding];
    }

    // Ping-pong: composite each group on top of the accumulator.
    int cur = 0;
    for (int i = 0; i < 3; ++i) {
        if (!groups[i]) continue;
        int nxt = 1 - cur;
        ShaderParams p{};
        p.float_params[0] = opacity_[i * 2 + 1]; // FX layer opacity (LayerLevel knob)
        id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
        [enc setComputePipelineState:psoComposite_];
        [enc setTexture:scratch_[cur] atIndex:0]; // bottom
        [enc setTexture:groups[i]     atIndex:1]; // overlay
        [enc setTexture:scratch_[nxt] atIndex:2]; // output
        [enc setBytes:&p length:sizeof(p) atIndex:0];
        MTLSize threads      = {psoComposite_.threadExecutionWidth, 8, 1};
        MTLSize threadGroups = {(WORK_W + threads.width  - 1) / threads.width,
                                (WORK_H + threads.height - 1) / threads.height, 1};
        [enc dispatchThreadgroups:threadGroups threadsPerThreadgroup:threads];
        [enc endEncoding];
        cur = nxt;
    }

    // Copy result into outputTex_ (same format — blit is fine here).
    id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
    [blit copyFromTexture:scratch_[cur] sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(WORK_W, WORK_H, 1)
               toTexture:outputTex_ destinationSlice:0 destinationLevel:0
      destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
}

// ── main composite entry ──────────────────────────────────────────────────────

bool MetalCompositor::composite(std::vector<uint8_t>& outRGBA) {
    if (!device_ || !outputTex_) return false;
    float now = elapsedSeconds();
    float dt  = (lastFrameTime_ > 0.0f) ? (now - lastFrameTime_) : 0.016f;
    dt = std::min(dt, 0.1f); // clamp to avoid large jumps after pauses
    lastFrameTime_ = now;
    frameTime_     = now;

    id<MTLCommandBuffer> cmd = [cmdQueue_ commandBuffer];

    if (lifNetwork_ && lifDriverCount_ > 0) {
        for (int i = 0; i < lifDriverCount_; ++i) {
            const auto& driver = lifDrivers_[i];
            lifNetwork_->setTopology(topologyFromParam(driver.topologyNorm));
            const int srcLayer = std::clamp(driver.srcSlot, 0, NUM_SRC_LAYERS - 1) * 2;
            lifNetwork_->step(cmd, layerTex_[srcLayer], audioBands_, audioRms_, driver.influenceNorm, dt, now);
        }
    }

    // For each FX slot (0=layer1, 1=layer3, 2=layer5):
    //   1. Rotate the source layer into rotateTex_[slot]
    //   2. Run FX pass: rotateTex_[slot] → layerTex_[fxLayerIdx]
    const int fxLayerIndices[NUM_FX_LAYERS] = {1, 3, 5};
    for (int slot = 0; slot < NUM_FX_LAYERS; ++slot) {
        int li = fxLayerIndices[slot];

        // 0. Crossfade blend (optional) — blends old capture with new source frame.
        id<MTLTexture> srcTex = layerTex_[li - 1];
        if (crossfadeProgress_[slot] < 1.0f) {
            crossfadeProgress_[slot] = std::min(1.0f,
                crossfadeProgress_[slot] + dt / crossfadeSpeed_[slot]);
            ShaderParams cp{};
            cp.float_params[0] = crossfadeProgress_[slot];
            id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:psoCrossfade_];
            [enc setTexture:crossfadeTex_[slot]      atIndex:0]; // old
            [enc setTexture:layerTex_[li - 1]        atIndex:1]; // new
            [enc setTexture:crossfadeBlendTex_[slot] atIndex:2]; // output
            [enc setBytes:&cp length:sizeof(cp) atIndex:0];
            MTLSize threads      = {psoCrossfade_.threadExecutionWidth, 8, 1};
            MTLSize threadGroups = {(WORK_W + threads.width  - 1) / threads.width,
                                    (WORK_H + threads.height - 1) / threads.height, 1};
            [enc dispatchThreadgroups:threadGroups threadsPerThreadgroup:threads];
            [enc endEncoding];
            srcTex = crossfadeBlendTex_[slot];
        }

        // 1. Rotation pre-pass
        {
            ShaderParams rp{};
            rp.float_params[0] = rotations_[slot];
            id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
            dispatch(enc, psoRotate_, srcTex, rotateTex_[slot], rp);
            [enc endEncoding];
        }
        // 2. Zoom pre-pass (rotate output → zoom output)
        {
            ShaderParams zp{};
            zp.float_params[0] = zooms_[slot];
            id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
            dispatch(enc, psoZoom_, rotateTex_[slot], zoomTex_[slot], zp);
            [enc endEncoding];
        }
        // 3. Pan pre-pass (zoom output → pan output)
        {
            ShaderParams pp{};
            pp.float_params[0] = panX_[slot];
            pp.float_params[1] = panY_[slot];
            pp.float_params[2] = zooms_[slot];
            id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
            dispatch(enc, psoPan_, zoomTex_[slot], panTex_[slot], pp);
            [enc endEncoding];
        }
        // 4. FX pass on fully-transformed source → layerTex_[li] (always full FX)
        runFxPass(cmd, slot, panTex_[slot], layerTex_[li]);
        // Opacity is applied in the final composite via opacity_[li], not here.
    }

    // Composite: group0 = (layer0 modulated by layer1), etc.
    std::array<id<MTLTexture>, 3> groups = {
        layerTex_[1],  // FX-processed version of layer 0
        layerTex_[3],  // FX-processed version of layer 2
        layerTex_[5],  // FX-processed version of layer 4
    };
    runComposite(cmd, groups);

    // Readback: outputTex_ is RGBA8Unorm — blit directly to the shared CPU buffer.
    id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
    [blit copyFromTexture:outputTex_ sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(WORK_W, WORK_H, 1)
                 toBuffer:readbackBuf_ destinationOffset:0
       destinationBytesPerRow:WORK_W * 4
     destinationBytesPerImage:WORK_W * WORK_H * 4];
    [blit endEncoding];
    [cmd commit];
    [cmd waitUntilCompleted];

    const std::size_t byteCount = WORK_W * WORK_H * 4;
    outRGBA.resize(byteCount);
    std::memcpy(outRGBA.data(), readbackBuf_.contents, byteCount);
    return true;
}
