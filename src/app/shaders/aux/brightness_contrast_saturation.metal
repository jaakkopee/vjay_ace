#include <metal_stdlib>
using namespace metal;

struct Params {
    int int_params[16];
    float float_params[16];
};

// Brightness adjustment
kernel void adjust_brightness(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) {
        return;
    }
    
    float factor = params.float_params[0];
    float4 pixel = input.read(gid);
    pixel.rgb *= factor;  // Multiply like CPU version (factor=1.0 is no change, >1.0 brightens)
    output.write(clamp(pixel, 0.0f, 1.0f), gid);
}

// Contrast adjustment
kernel void adjust_contrast(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) {
        return;
    }
    
    float factor = params.float_params[0];
    float4 pixel = input.read(gid);
    pixel.rgb = (pixel.rgb - 0.5f) * factor + 0.5f;
    output.write(clamp(pixel, 0.0f, 1.0f), gid);
}

// Saturation adjustment
kernel void adjust_saturation(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) {
        return;
    }
    
    float factor = params.float_params[0];
    float4 pixel = input.read(gid);
    
    // Calculate luminance
    float gray = 0.299f * pixel.r + 0.587f * pixel.g + 0.114f * pixel.b;
    
    // Interpolate between gray and color
    pixel.rgb = gray + (pixel.rgb - gray) * factor;
    
    output.write(clamp(pixel, 0.0f, 1.0f), gid);
}

