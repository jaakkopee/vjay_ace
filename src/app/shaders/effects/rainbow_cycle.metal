#include <metal_stdlib>
using namespace metal;

struct Params { int int_params[16]; float float_params[16]; };

inline float3 hsv_to_rgb(float3 c) {
    float3 p = abs(fract(c.xxx + float3(0.0f, 1.0f/3.0f, 2.0f/3.0f)) * 6.0f - 3.0f);
    return c.z * mix(float3(1.0f), clamp(p - 1.0f, 0.0f, 1.0f), c.y);
}

// texture(0): input, texture(1): output
kernel void rainbow_cycle(texture2d<float, access::read> input_image [[texture(0)]],
                          texture2d<float, access::write> output_image [[texture(1)]],
                          constant Params& params [[ buffer(0) ]],
                          uint2 gid [[thread_position_in_grid]]) {
    int width = input_image.get_width();
    int height = input_image.get_height();
    if (gid.x >= width || gid.y >= height) return;

    float cycle_position = params.float_params[0];
    float2 pos = float2(gid);
    float position = (pos.x / float(width) + pos.y / float(height)) * 0.5f;
    float hue = fmod((position + cycle_position) * 360.0f, 360.0f) / 360.0f;

    float4 pix = input_image.read(gid);
    float brightness = (pix.r + pix.g + pix.b) / 3.0f;
    float3 rainbow = hsv_to_rgb(float3(hue, 1.0f, brightness));
    output_image.write(float4(rainbow, pix.a), gid);
}
