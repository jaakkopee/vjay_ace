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
    psoReadback_     = makePSO(@"readback_rgba8");
    psoRotate_       = makePSO(@"rotate_source");
    psoZoom_         = makePSO(@"zoom_source");
    psoFxBlend_      = makePSO(@"fx_blend");

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
    }

    // CPU-readable buffer for readback (RGBA8, 4 bytes/pixel)
    NSUInteger readbackSize = WORK_W * WORK_H * 4;
    readbackBuf_ = [device_ newBufferWithLength:readbackSize
                                        options:MTLResourceStorageModeShared];
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
        p.float_params[0] = opacity_[i * 2]; // source layer opacity
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
    frameTime_ = elapsedSeconds();

    id<MTLCommandBuffer> cmd = [cmdQueue_ commandBuffer];

    // For each FX slot (0=layer1, 1=layer3, 2=layer5):
    //   1. Rotate the source layer into rotateTex_[slot]
    //   2. Run FX pass: rotateTex_[slot] → layerTex_[fxLayerIdx]
    const int fxLayerIndices[NUM_FX_LAYERS] = {1, 3, 5};
    for (int slot = 0; slot < NUM_FX_LAYERS; ++slot) {
        int li = fxLayerIndices[slot];
        // 1. Rotation pre-pass
        {
            ShaderParams rp{};
            rp.float_params[0] = rotations_[slot];
            id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
            dispatch(enc, psoRotate_, layerTex_[li - 1], rotateTex_[slot], rp);
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
        // 3. FX pass on fully-transformed source
        runFxPass(cmd, slot, zoomTex_[slot], layerTex_[li]);
        // 4. Blend FX output with pre-FX source using the FX layer's opacity.
        //    opacity_[li] == 1.0 → full FX; 0.0 → unprocessed source.
        if (psoFxBlend_) {
            ShaderParams bp{};
            bp.float_params[0] = opacity_[li];
            id<MTLComputeCommandEncoder> benc = [cmd computeCommandEncoder];
            [benc setComputePipelineState:psoFxBlend_];
            [benc setTexture:zoomTex_[slot] atIndex:0]; // pre-FX
            [benc setTexture:layerTex_[li]  atIndex:1]; // post-FX
            [benc setTexture:scratch_[1]    atIndex:2]; // temp output
            [benc setBytes:&bp length:sizeof(bp) atIndex:0];
            MTLSize bthr = {psoFxBlend_.threadExecutionWidth, 8, 1};
            MTLSize bgrp = {(WORK_W + bthr.width  - 1) / bthr.width,
                            (WORK_H + bthr.height - 1) / bthr.height, 1};
            [benc dispatchThreadgroups:bgrp threadsPerThreadgroup:bthr];
            [benc endEncoding];
            // Commit blend result back into the FX layer texture.
            id<MTLBlitCommandEncoder> blitFx = [cmd blitCommandEncoder];
            [blitFx copyFromTexture:scratch_[1] sourceSlice:0 sourceLevel:0
                       sourceOrigin:MTLOriginMake(0,0,0)
                         sourceSize:MTLSizeMake(WORK_W, WORK_H, 1)
                          toTexture:layerTex_[li] destinationSlice:0 destinationLevel:0
             destinationOrigin:MTLOriginMake(0,0,0)];
            [blitFx endEncoding];
        }
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
