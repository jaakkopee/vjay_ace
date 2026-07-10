#include <metal_stdlib>
using namespace metal;

struct Params {
    int int_params[16];
    float float_params[16];
};

// Grayscale conversion
kernel void grayscale(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) {
        return;
    }
    
    float4 pixel = input.read(gid);
    float gray = 0.299f * pixel.r + 0.587f * pixel.g + 0.114f * pixel.b;
    pixel.rgb = float3(gray);
    
    output.write(pixel, gid);
}

// Invert colors
kernel void invert(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) {
        return;
    }
    
    float4 pixel = input.read(gid);
    pixel.rgb = 1.0f - pixel.rgb;
    
    output.write(pixel, gid);
}

// Sepia tone effect
kernel void sepia(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) {
        return;
    }
    
    float4 pixel = input.read(gid);
    
    // Sepia transformation matrix
    float r = pixel.r * 0.393f + pixel.g * 0.769f + pixel.b * 0.189f;
    float g = pixel.r * 0.349f + pixel.g * 0.686f + pixel.b * 0.168f;
    float b = pixel.r * 0.272f + pixel.g * 0.534f + pixel.b * 0.131f;
    
    pixel.rgb = float3(r, g, b);
    
    output.write(clamp(pixel, 0.0f, 1.0f), gid);
}
