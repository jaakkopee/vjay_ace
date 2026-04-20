#include "MetalCompositor.h"
#import  <Foundation/Foundation.h>
#import  <Metal/Metal.h>
#include <stdexcept>
#include <cassert>
#include <cstring>
#include <chrono>

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

    // Allocate layer textures
    for (int i = 0; i < NUM_LAYERS; ++i)
        layerTex_[i] = makeTexture(WORK_W, WORK_H);

    scratch_[0] = makeTexture(WORK_W, WORK_H);
    scratch_[1] = makeTexture(WORK_W, WORK_H);
    outputTex_  = makeTexture(WORK_W, WORK_H);

    // CPU-readable buffer for readback (RGBA8, 4 bytes/pixel)
    NSUInteger readbackSize = WORK_W * WORK_H * 4;
    readbackBuf_ = [device_ newBufferWithLength:readbackSize
                                        options:MTLResourceStorageModeShared];
    return true;
}

// ── texture / PSO factories ───────────────────────────────────────────────────

id<MTLTexture> MetalCompositor::makeTexture(int w, int h, bool /*halfRes*/) {
    MTLTextureDescriptor* desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                           width:w
                                                          height:h
                                                       mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
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

    // Upload RGBA8 into an upload texture, then blit or just replace.
    // For simplicity in this sketch we create a shared staging texture per call.
    MTLTextureDescriptor* desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    desc.storageMode = MTLStorageModeShared;
    desc.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> staging = [device_ newTextureWithDescriptor:desc];
    [staging replaceRegion:MTLRegionMake2D(0,0,width,height)
               mipmapLevel:0
                 withBytes:rgba
               bytesPerRow:width * 4];

    // Blit staging → layerTex_ (converts RGBA8 → RGBA16Float on GPU)
    id<MTLCommandBuffer> cmd = [cmdQueue_ commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
    [blit copyFromTexture:staging sourceSlice:0 sourceLevel:0
              sourceOrigin:MTLOriginMake(0,0,0)
                sourceSize:MTLSizeMake(width,height,1)
               toTexture:tex destinationSlice:0 destinationLevel:0
       destinationOrigin:MTLOriginMake(0,0,0)];
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
    }

    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    dispatch(enc, pso, src, dst, params);
    [enc endEncoding];
}

// ── final composite ────────────────────────────────────────────────────────────

void MetalCompositor::runComposite(id<MTLCommandBuffer> cmd,
                                    const std::array<id<MTLTexture>, 4>& groups) {
    // Alpha-composite 4 group textures top-to-bottom using their opacities.
    // Kernel 'alpha_composite' takes two textures and a float alpha, blends them.
    // We chain: composite(group[0..3]) sequentially into outputTex_.
    // (A production version would do this in one multi-texture kernel.)
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    if (!psoComposite_) { [enc endEncoding]; return; }

    // groups[0] = processed layer 0+1, groups[1] = 2+3, groups[2] = 4+5, groups[3] = layer 6
    // Odd-layer FX already modulated the src below; opacity is applied here.
    // We simply alpha-over each group using layer opacity.
    // For this sketch the kernel takes (bottom, overlay, alpha) → output.
    for (int i = 0; i < 4; ++i) {
        if (!groups[i]) continue;
        ShaderParams p{};
        p.float_params[0] = opacity_[i * 2]; // source layer opacity
        [enc setComputePipelineState:psoComposite_];
        [enc setTexture:(i == 0 ? outputTex_ : outputTex_) atIndex:0]; // bottom
        [enc setTexture:groups[i] atIndex:1];                           // overlay
        [enc setTexture:outputTex_ atIndex:2];                          // output
        [enc setBytes:&p length:sizeof(p) atIndex:0];
        MTLSize threads     = {psoComposite_.threadExecutionWidth, 8, 1};
        MTLSize threadGroups = {(WORK_W + threads.width - 1) / threads.width,
                                (WORK_H + threads.height - 1) / threads.height, 1};
        [enc dispatchThreadgroups:threadGroups threadsPerThreadgroup:threads];
    }
    [enc endEncoding];
}

// ── main composite entry ──────────────────────────────────────────────────────

bool MetalCompositor::composite(std::vector<uint8_t>& outRGBA) {
    if (!device_ || !outputTex_) return false;
    frameTime_ = elapsedSeconds();

    id<MTLCommandBuffer> cmd = [cmdQueue_ commandBuffer];

    // For each FX slot (0=layer1, 1=layer3, 2=layer5):
    //   src = layerTex_[fxLayerIdx - 1]  (processed even layer below)
    //   dst = layerTex_[fxLayerIdx]       (FX output stored back in odd slot)
    const int fxLayerIndices[NUM_FX_LAYERS] = {1, 3, 5};
    for (int slot = 0; slot < NUM_FX_LAYERS; ++slot) {
        int li = fxLayerIndices[slot];
        runFxPass(cmd, slot, layerTex_[li - 1], layerTex_[li]);
    }

    // Composite: group0 = (layer0 modulated by layer1), etc.
    std::array<id<MTLTexture>, 4> groups = {
        layerTex_[1],  // FX-processed version of layer 0
        layerTex_[3],  // FX-processed version of layer 2
        layerTex_[5],  // FX-processed version of layer 4
        layerTex_[6],  // top source
    };
    runComposite(cmd, groups);

    // Readback output texture to CPU (RGBA8)
    id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
    // Convert RGBA16Float → RGBA8 via a temporary RGBA8 texture then copy to buffer
    MTLTextureDescriptor* desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:WORK_W height:WORK_H
                                                       mipmapped:NO];
    desc.storageMode = MTLStorageModeShared;
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> rgba8 = [device_ newTextureWithDescriptor:desc];
    [blit copyFromTexture:outputTex_ toTexture:rgba8];
    [blit copyFromTexture:rgba8 sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake(0,0,0)
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
