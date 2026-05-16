#include <metal_stdlib>
using namespace metal;

struct Params {
    int int_params[16];
    float float_params[16];
};

// Vignette effect
kernel void vignette(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int width = input.get_width();
    int height = input.get_height();
    
    if (gid.x >= width || gid.y >= height) {
        return;
    }
    
    float strength = clamp(params.float_params[0], 0.0f, 1.0f);
    float raw_radius = params.float_params[1];
    float raw_roundness = params.float_params[2];
    float raw_smoothness = params.float_params[3];
    float radius = clamp(raw_radius, 0.0f, 1.0f);
    float roundness = clamp(raw_roundness, 0.0f, 1.0f);
    float smoothness = clamp(raw_smoothness, 0.0f, 1.0f);
    if (raw_radius > 1.0f && raw_roundness <= 0.0f && raw_smoothness <= 0.0f) {
        // Legacy GPUEffectChain calls could pass [strength, softness].
        float softness_norm = clamp((raw_radius - 0.1f) / 3.9f, 0.0f, 1.0f);
        radius = 0.7f;
        roundness = 1.0f;
        smoothness = softness_norm;
    } else if (radius <= 0.0f && roundness <= 0.0f && smoothness <= 0.0f) {
        // Legacy GPUEffectChain calls often passed only strength.
        radius = 0.7f;
        roundness = 1.0f;
        smoothness = 0.25f;
    }
    float4 pixel = input.read(gid);
    
    float2 center = float2(width, height) * 0.5f;
    float2 inv_center = 1.0f / max(center, float2(1e-6f));
    float2 norm = abs((float2(gid) - center) * inv_center);
    float rounded_rect_dist = pow(pow(norm.x, 6.0f) + pow(norm.y, 6.0f), 1.0f / 6.0f);
    float circle_dist = length(norm) / sqrt(2.0f);
    float shape_dist = mix(rounded_rect_dist, circle_dist, roundness);
    float normalized_dist = clamp(shape_dist, 0.0f, 1.0f);
    
    // Apply vignette falloff (match CPU implementation).
    // Note: Keep this formula in sync with CPU `vignette` implementation at
    // `src/effects/basic_fx.cpp` to ensure GPU/CPU parity tests remain stable.
    float edge_width = 0.002f + 0.30f * smoothness;
    float edge_start = radius;
    float edge_end = min(1.0f, edge_start + edge_width);
    float edge_mask = smoothstep(edge_start, edge_end, normalized_dist);
    float vignette_factor = 1.0f - edge_mask * strength;
    vignette_factor = max(vignette_factor, 0.0f);
    
    pixel.rgb *= vignette_factor;
    
    output.write(clamp(pixel, 0.0f, 1.0f), gid);
}
