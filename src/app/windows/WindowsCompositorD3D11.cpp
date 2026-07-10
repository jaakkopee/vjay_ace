#include "WindowsCompositorD3D11.h"

#include <algorithm>
#include <cstdint>
#include <cstring>

namespace {
struct FxParams {
    UINT outWidth;
    UINT outHeight;
    UINT effectMode;
    UINT pad0;
    float p0;
    float p1;
    float panX;
    float panY;
    float zoom;
    float rotation;
    float audioGain;
    float audioRms;
    float bandLo;
    float bandHi;
    float pad1;
    float pad2;
};

struct CompositeParams {
    UINT outWidth;
    UINT outHeight;
    UINT pad0;
    UINT pad1;
    float opacity0;
    float opacity1;
    float opacity2;
    float pad2;
};

UINT effectModeFromPatch(FxPatchId patch) {
    switch (patch) {
        case FxPatchId::Invert:    return 1u;
        case FxPatchId::Grayscale: return 2u;
        case FxPatchId::Sepia:     return 3u;
        case FxPatchId::Ripple:    return 4u;
        case FxPatchId::WaveDistort:return 4u;
        case FxPatchId::Strobe:    return 5u;
        case FxPatchId::Scanline:  return 6u;
        default:                   return 0u;
    }
}
}

bool WindowsCompositorD3D11::init() {
    if (initialized_) return true;

#if defined(_WIN32)
    static const char* kFxCs = R"(
Texture2D<float4> srcTex : register(t0);
RWTexture2D<float4> fxTex : register(u0);

cbuffer FxParams : register(b0) {
    uint outWidth;
    uint outHeight;
    uint effectMode;
    uint pad0;
    float p0;
    float p1;
    float panX;
    float panY;
    float zoom;
    float rotation;
    float audioGain;
    float audioRms;
    float bandLo;
    float bandHi;
    float pad1;
    float pad2;
};

[numthreads(8, 8, 1)]
void main(uint3 tid : SV_DispatchThreadID) {
    if (tid.x >= outWidth || tid.y >= outHeight) {
        return;
    }
    float2 dim = float2(outWidth, outHeight);
    float2 uv = (float2(tid.xy) + 0.5) / dim;
    float2 centered = uv - float2(0.5, 0.5);
    float cs = cos(-rotation);
    float sn = sin(-rotation);
    float2 rotated = float2(
        centered.x * cs - centered.y * sn,
        centered.x * sn + centered.y * cs
    );
    float z = max(zoom, 0.001);
    float2 sampledUv = rotated / z + float2(0.5 + panX * 0.5, 0.5 + panY * 0.5);

    if (effectMode == 4) {
        float2 d = sampledUv - float2(0.5, 0.5);
        float dist = length(d);
        float2 dir = (dist > 1e-5) ? (d / dist) : float2(0.0, 0.0);
        float waveFreq = 30.0 + p1 * 120.0;
        float wave = sin(dist * waveFreq + audioRms * 12.0 + bandHi * 6.0);
        float amp = (0.001 + p0 * 0.02) * (0.4 + saturate(audioRms * audioGain));
        sampledUv += dir * wave * amp;
    }

    sampledUv = saturate(sampledUv);
    int2 sampleCoord = int2(sampledUv * (dim - 1.0));

    float4 c = srcTex[sampleCoord];
    if (effectMode == 1) {
        float4 inv = float4(1.0 - c.rgb, c.a);
        c = lerp(c, inv, saturate(p0 * 2.0));
    } else if (effectMode == 2) {
        float l = dot(c.rgb, float3(0.299, 0.587, 0.114));
        float4 g = float4(l, l, l, c.a);
        c = lerp(c, g, saturate(p0 * 2.0));
    } else if (effectMode == 3) {
        float3 s = float3(
            dot(c.rgb, float3(0.393, 0.769, 0.189)),
            dot(c.rgb, float3(0.349, 0.686, 0.168)),
            dot(c.rgb, float3(0.272, 0.534, 0.131))
        );
        float4 sep = float4(saturate(s), c.a);
        c = lerp(c, sep, saturate(p0 * 2.0));
    } else if (effectMode == 6) {
        float density = 80.0 + p1 * 360.0;
        float line = 0.5 + 0.5 * sin((uv.y + bandHi * 0.03) * density);
        float depth = saturate(0.15 + p0 * 0.75);
        float mask = lerp(1.0, line, depth);
        c.rgb *= mask;
    }

    float audioDrive = saturate(audioRms * audioGain);
    float tint = saturate((bandHi - bandLo) * 0.5 + 0.5);
    float3 audioTint = float3(1.0 + tint * 0.2, 1.0, 1.0 + (1.0 - tint) * 0.2);
    c.rgb *= (1.0 + audioDrive * (0.25 + p1 * 0.35));
    c.rgb = saturate(c.rgb * audioTint);

    if (effectMode == 5) {
        float gateSignal = bandLo * audioGain + audioRms * (0.5 + p0);
        float threshold = 0.20 + (1.0 - p1) * 0.45;
        float gate = (gateSignal > threshold) ? 1.0 : (0.08 + p0 * 0.18);
        c.rgb *= gate;
    }

    fxTex[tid.xy] = c;
}
    )";

    static const char* kCompositeCs = R"(
Texture2D<float4> fx0 : register(t0);
Texture2D<float4> fx1 : register(t1);
Texture2D<float4> fx2 : register(t2);
RWTexture2D<float4> outTex : register(u0);

cbuffer CompositeParams : register(b0) {
    uint outWidth;
    uint outHeight;
    uint pad0;
    uint pad1;
    float opacity0;
    float opacity1;
    float opacity2;
    float pad2;
};

[numthreads(8, 8, 1)]
void main(uint3 tid : SV_DispatchThreadID) {
    if (tid.x >= outWidth || tid.y >= outHeight) {
        return;
    }
    float4 a = fx0[tid.xy];
    float4 b = fx1[tid.xy];
    float4 c = fx2[tid.xy];

    float4 outC = float4(0.0, 0.0, 0.0, 1.0);
    outC.rgb = lerp(outC.rgb, a.rgb, saturate(opacity0));
    outC.rgb = lerp(outC.rgb, b.rgb, saturate(opacity1));
    outC.rgb = lerp(outC.rgb, c.rgb, saturate(opacity2));
    outTex[tid.xy] = outC;
}
    )";

    D3D_FEATURE_LEVEL createdFeatureLevel = D3D_FEATURE_LEVEL_11_0;
    const D3D_FEATURE_LEVEL requestedLevels[] = {
        D3D_FEATURE_LEVEL_11_1,
        D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1,
        D3D_FEATURE_LEVEL_10_0,
    };

    UINT createFlags = 0;
#if defined(_DEBUG)
    createFlags |= D3D11_CREATE_DEVICE_DEBUG;
#endif

    HRESULT hr = D3D11CreateDevice(
        nullptr,
        D3D_DRIVER_TYPE_HARDWARE,
        nullptr,
        createFlags,
        requestedLevels,
        static_cast<UINT>(std::size(requestedLevels)),
        D3D11_SDK_VERSION,
        device_.GetAddressOf(),
        &createdFeatureLevel,
        context_.GetAddressOf());

    if (FAILED(hr)) {
        hr = D3D11CreateDevice(
            nullptr,
            D3D_DRIVER_TYPE_WARP,
            nullptr,
            createFlags,
            requestedLevels,
            static_cast<UINT>(std::size(requestedLevels)),
            D3D11_SDK_VERSION,
            device_.GetAddressOf(),
            &createdFeatureLevel,
            context_.GetAddressOf());
    }

    if (FAILED(hr)) {
        return false;
    }

    D3D11_TEXTURE2D_DESC texDesc = {};
    texDesc.Width = WORK_W;
    texDesc.Height = WORK_H;
    texDesc.MipLevels = 1;
    texDesc.ArraySize = 1;
    texDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    texDesc.SampleDesc.Count = 1;
    texDesc.Usage = D3D11_USAGE_DEFAULT;
    texDesc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    for (int i = 0; i < NUM_SRC_LAYERS; ++i) {
        hr = device_->CreateTexture2D(&texDesc, nullptr, srcTex_[i].GetAddressOf());
        if (FAILED(hr)) return false;
    }

    texDesc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_UNORDERED_ACCESS;
    for (int i = 0; i < NUM_SRC_LAYERS; ++i) {
        hr = device_->CreateTexture2D(&texDesc, nullptr, fxTex_[i].GetAddressOf());
        if (FAILED(hr)) return false;
    }
    hr = device_->CreateTexture2D(&texDesc, nullptr, compositeTex_.GetAddressOf());
    if (FAILED(hr)) return false;

    D3D11_SHADER_RESOURCE_VIEW_DESC srvDesc = {};
    srvDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    srvDesc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
    srvDesc.Texture2D.MipLevels = 1;
    for (int i = 0; i < NUM_SRC_LAYERS; ++i) {
        hr = device_->CreateShaderResourceView(srcTex_[i].Get(), &srvDesc, srcSrv_[i].GetAddressOf());
        if (FAILED(hr)) return false;
        hr = device_->CreateShaderResourceView(fxTex_[i].Get(), &srvDesc, fxSrv_[i].GetAddressOf());
        if (FAILED(hr)) return false;
    }

    D3D11_UNORDERED_ACCESS_VIEW_DESC uavDesc = {};
    uavDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    uavDesc.ViewDimension = D3D11_UAV_DIMENSION_TEXTURE2D;
    for (int i = 0; i < NUM_SRC_LAYERS; ++i) {
        hr = device_->CreateUnorderedAccessView(fxTex_[i].Get(), &uavDesc, fxUav_[i].GetAddressOf());
        if (FAILED(hr)) return false;
    }
    hr = device_->CreateUnorderedAccessView(compositeTex_.Get(), &uavDesc, compositeUav_.GetAddressOf());
    if (FAILED(hr)) return false;

    D3D11_TEXTURE2D_DESC readbackDesc = texDesc;
    readbackDesc.BindFlags = 0;
    readbackDesc.Usage = D3D11_USAGE_STAGING;
    readbackDesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    hr = device_->CreateTexture2D(&readbackDesc, nullptr, readbackTex_.GetAddressOf());
    if (FAILED(hr)) return false;

    Microsoft::WRL::ComPtr<ID3DBlob> shaderBlob;
    Microsoft::WRL::ComPtr<ID3DBlob> errorBlob;
    hr = D3DCompile(
        kFxCs,
        std::strlen(kFxCs),
        nullptr,
        nullptr,
        nullptr,
        "main",
        "cs_5_0",
        0,
        0,
        shaderBlob.GetAddressOf(),
        errorBlob.GetAddressOf());
    if (FAILED(hr)) {
        return false;
    }

    hr = device_->CreateComputeShader(
        shaderBlob->GetBufferPointer(),
        shaderBlob->GetBufferSize(),
        nullptr,
        fxCs_.GetAddressOf());
    if (FAILED(hr)) return false;

    shaderBlob.Reset();
    errorBlob.Reset();
    hr = D3DCompile(
        kCompositeCs,
        std::strlen(kCompositeCs),
        nullptr,
        nullptr,
        nullptr,
        "main",
        "cs_5_0",
        0,
        0,
        shaderBlob.GetAddressOf(),
        errorBlob.GetAddressOf());
    if (FAILED(hr)) {
        return false;
    }
    hr = device_->CreateComputeShader(
        shaderBlob->GetBufferPointer(),
        shaderBlob->GetBufferSize(),
        nullptr,
        compositeCs_.GetAddressOf());
    if (FAILED(hr)) return false;

    D3D11_BUFFER_DESC cbDesc = {};
    cbDesc.ByteWidth = sizeof(FxParams);
    cbDesc.Usage = D3D11_USAGE_DEFAULT;
    cbDesc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    hr = device_->CreateBuffer(&cbDesc, nullptr, fxParamsCb_.GetAddressOf());
    if (FAILED(hr)) return false;

    cbDesc.ByteWidth = sizeof(CompositeParams);
    hr = device_->CreateBuffer(&cbDesc, nullptr, compositeParamsCb_.GetAddressOf());
    if (FAILED(hr)) return false;
#else
    return false;
#endif

    for (int i = 0; i < NUM_SRC_LAYERS; ++i)
        uploadScratch_[i].assign(static_cast<size_t>(WORK_W) * static_cast<size_t>(WORK_H) * 4u, 0u);
#if defined(_WIN32)
    for (int i = 0; i < NUM_SRC_LAYERS; ++i)
        context_->UpdateSubresource(srcTex_[i].Get(), 0, nullptr, uploadScratch_[i].data(), WORK_W * 4, 0);
#endif
    initialized_ = true;
    return true;
}

void WindowsCompositorD3D11::uploadLayerPixels(int layerIdx, const uint8_t* rgba, int width, int height) {
    if (!initialized_ || rgba == nullptr || width <= 0 || height <= 0) return;
    if (!isSrcLayer(layerIdx)) return;
    const int srcSlot = layerIdx / 2;
    if (srcSlot < 0 || srcSlot >= NUM_SRC_LAYERS) return;

#if defined(_WIN32)
    auto& scratch = uploadScratch_[srcSlot];
    std::fill(scratch.begin(), scratch.end(), 0u);
    const int copyW = std::min(width, WORK_W);
    const int copyH = std::min(height, WORK_H);
    const size_t dstStride = static_cast<size_t>(WORK_W) * 4u;
    const size_t srcStride = static_cast<size_t>(width) * 4u;

    for (int y = 0; y < copyH; ++y) {
        const uint8_t* srcRow = rgba + static_cast<size_t>(y) * srcStride;
        uint8_t* dstRow = scratch.data() + static_cast<size_t>(y) * dstStride;
        std::memcpy(dstRow, srcRow, static_cast<size_t>(copyW) * 4u);
    }

    context_->UpdateSubresource(srcTex_[srcSlot].Get(), 0, nullptr, scratch.data(), WORK_W * 4, 0);
#endif
}

void WindowsCompositorD3D11::setFxPatch(int fxLayerIdx, FxPatchId patch) {
    if (fxLayerIdx < 0 || fxLayerIdx >= NUM_FX_LAYERS) return;
    fxPatches_[fxLayerIdx] = patch;
}

void WindowsCompositorD3D11::setFxParams(int fxLayerIdx, float p0, float p1) {
    if (fxLayerIdx < 0 || fxLayerIdx >= NUM_FX_LAYERS) return;
    fxParams_[fxLayerIdx][0] = std::clamp(p0, 0.0f, 1.0f);
    fxParams_[fxLayerIdx][1] = std::clamp(p1, 0.0f, 1.0f);
}
void WindowsCompositorD3D11::setLayerOpacity(int layerIdx, float opacity) {
    if (!isFxLayer(layerIdx)) return;
    const int fxSlot = layerIdx / 2;
    if (fxSlot < 0 || fxSlot >= NUM_FX_LAYERS) return;
    fxOpacity_[fxSlot] = std::clamp(opacity, 0.0f, 1.0f);
}
void WindowsCompositorD3D11::setLayerRotation(int srcSlot, float radians) {
    if (srcSlot < 0 || srcSlot >= NUM_SRC_LAYERS) return;
    rotation_[srcSlot] = radians;
}

void WindowsCompositorD3D11::setLayerZoom(int srcSlot, float factor) {
    if (srcSlot < 0 || srcSlot >= NUM_SRC_LAYERS) return;
    zoom_[srcSlot] = std::max(0.001f, factor);
}

void WindowsCompositorD3D11::setLayerPanX(int srcSlot, float offset) {
    if (srcSlot < 0 || srcSlot >= NUM_SRC_LAYERS) return;
    pan_[srcSlot][0] = offset;
}

void WindowsCompositorD3D11::setLayerPanY(int srcSlot, float offset) {
    if (srcSlot < 0 || srcSlot >= NUM_SRC_LAYERS) return;
    pan_[srcSlot][1] = offset;
}

void WindowsCompositorD3D11::getLayerPan(int srcSlot, float& outOffsetX, float& outOffsetY) const {
    if (srcSlot < 0 || srcSlot >= NUM_SRC_LAYERS) {
        outOffsetX = 0.0f;
        outOffsetY = 0.0f;
        return;
    }
    outOffsetX = pan_[srcSlot][0];
    outOffsetY = pan_[srcSlot][1];
}

float WindowsCompositorD3D11::getLayerZoom(int srcSlot) const {
    if (srcSlot < 0 || srcSlot >= NUM_SRC_LAYERS) return 1.0f;
    return zoom_[srcSlot];
}

void WindowsCompositorD3D11::setAudioBands(const float* bands, int count, float rms) {
    if (bands != nullptr && count > 0) {
        const int n = std::min(count, static_cast<int>(audioBands_.size()));
        for (int i = 0; i < n; ++i) audioBands_[i] = bands[i];
    }
    audioRms_ = rms;
}

void WindowsCompositorD3D11::setAudioGain(int fxSlot, float gain) {
    if (fxSlot < 0 || fxSlot >= NUM_FX_LAYERS) return;
    audioGain_[fxSlot] = gain;
}

void WindowsCompositorD3D11::setLIFTopology(LIFTopology topology) {
    topology_ = topology;
}

void WindowsCompositorD3D11::setLIFNeuronCount(int neuronCount) {
    lifNeuronCount_ = std::max(1, neuronCount);
}

void WindowsCompositorD3D11::setLIFDrivers(const std::vector<LIFDriver>& drivers) {
    lifDrivers_ = drivers;
}

std::array<float, ICompositor::NUM_LIF_TONE_BINS> WindowsCompositorD3D11::sampleLIFColumn(float) const {
    return {};
}

void WindowsCompositorD3D11::beginCrossfade(int) {}
void WindowsCompositorD3D11::setCrossfadeSpeed(int, float) {}
void WindowsCompositorD3D11::resetFeedbackBuffers() {}

bool WindowsCompositorD3D11::composite(std::vector<uint8_t>& outRGBA) {
    if (!initialized_) return false;

#if defined(_WIN32)
    const UINT groupsX = static_cast<UINT>((WORK_W + 7) / 8);
    const UINT groupsY = static_cast<UINT>((WORK_H + 7) / 8);

    for (int slot = 0; slot < NUM_FX_LAYERS; ++slot) {
        const int bandBase = slot * 2;
        const float bandLo = audioBands_[bandBase];
        const float bandHi = audioBands_[bandBase + 1];
        const FxParams fxParams = {
            static_cast<UINT>(WORK_W),
            static_cast<UINT>(WORK_H),
            effectModeFromPatch(fxPatches_[slot]),
            0,
            fxParams_[slot][0],
            fxParams_[slot][1],
            pan_[slot][0],
            pan_[slot][1],
            zoom_[slot],
            rotation_[slot],
            audioGain_[slot],
            audioRms_,
            bandLo,
            bandHi,
            0.0f,
            0.0f,
        };
        context_->UpdateSubresource(fxParamsCb_.Get(), 0, nullptr, &fxParams, 0, 0);

        ID3D11ShaderResourceView* fxInputSrv[] = {srcSrv_[slot].Get()};
        ID3D11UnorderedAccessView* fxOutputUav[] = {fxUav_[slot].Get()};
        ID3D11Buffer* fxCb[] = {fxParamsCb_.Get()};

        context_->CSSetShader(fxCs_.Get(), nullptr, 0);
        context_->CSSetShaderResources(0, 1, fxInputSrv);
        context_->CSSetUnorderedAccessViews(0, 1, fxOutputUav, nullptr);
        context_->CSSetConstantBuffers(0, 1, fxCb);
        context_->Dispatch(groupsX, groupsY, 1);
    }

    ID3D11ShaderResourceView* nullSrv[] = {nullptr, nullptr, nullptr};
    ID3D11UnorderedAccessView* nullUav[] = {nullptr};
    context_->CSSetShaderResources(0, 3, nullSrv);
    context_->CSSetUnorderedAccessViews(0, 1, nullUav, nullptr);

    const CompositeParams compositeParams = {
        static_cast<UINT>(WORK_W),
        static_cast<UINT>(WORK_H),
        0,
        0,
        fxOpacity_[0],
        fxOpacity_[1],
        fxOpacity_[2],
        0.0f,
    };
    context_->UpdateSubresource(compositeParamsCb_.Get(), 0, nullptr, &compositeParams, 0, 0);

    ID3D11ShaderResourceView* compositeSrv[] = {
        fxSrv_[0].Get(),
        fxSrv_[1].Get(),
        fxSrv_[2].Get(),
    };
    ID3D11UnorderedAccessView* compositeUav[] = {compositeUav_.Get()};
    ID3D11Buffer* compositeCb[] = {compositeParamsCb_.Get()};
    context_->CSSetShader(compositeCs_.Get(), nullptr, 0);
    context_->CSSetShaderResources(0, 3, compositeSrv);
    context_->CSSetUnorderedAccessViews(0, 1, compositeUav, nullptr);
    context_->CSSetConstantBuffers(0, 1, compositeCb);
    context_->Dispatch(groupsX, groupsY, 1);

    context_->CSSetShaderResources(0, 3, nullSrv);
    context_->CSSetUnorderedAccessViews(0, 1, nullUav, nullptr);
    context_->CSSetShader(nullptr, nullptr, 0);

    context_->CopyResource(readbackTex_.Get(), compositeTex_.Get());

    D3D11_MAPPED_SUBRESOURCE mapped = {};
    HRESULT hr = context_->Map(readbackTex_.Get(), 0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(hr)) return false;

    const size_t rowBytes = static_cast<size_t>(WORK_W) * 4u;
    outRGBA.resize(static_cast<size_t>(WORK_W) * static_cast<size_t>(WORK_H) * 4u);
    for (int y = 0; y < WORK_H; ++y) {
        const uint8_t* srcRow = static_cast<const uint8_t*>(mapped.pData) + static_cast<size_t>(y) * mapped.RowPitch;
        uint8_t* dstRow = outRGBA.data() + static_cast<size_t>(y) * rowBytes;
        std::memcpy(dstRow, srcRow, rowBytes);
    }
    context_->Unmap(readbackTex_.Get(), 0);
#else
    outRGBA.assign(static_cast<size_t>(WORK_W) * static_cast<size_t>(WORK_H) * 4u, 0u);
#endif

    return true;
}
