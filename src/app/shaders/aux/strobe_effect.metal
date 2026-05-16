#include <metal_stdlib>
using namespace metal;

struct Params { int int_params[16]; float float_params[16]; };

// texture(0): input, texture(1): output
kernel void strobe_effect(texture2d<float, access::read> input_image [[texture(0)]],
                          texture2d<float, access::write> output_image [[texture(1)]],
                          constant Params& params [[ buffer(0) ]],
                          uint2 gid [[thread_position_in_grid]]) {
    int width = input_image.get_width();
    int height = input_image.get_height();
    if (gid.x >= width || gid.y >= height) return;

    float intensity = clamp(params.float_params[0], 0.0f, 1.0f);
    bool flash_on = params.int_params[0] != 0;

    float4 pix = input_image.read(gid);
    float factor = flash_on ? (1.0f + intensity * 2.0f) : (1.0f - intensity * 0.5f);
    output_image.write(clamp(pix * factor, 0.0f, 1.0f), gid);
}
