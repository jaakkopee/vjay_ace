#include <metal_stdlib>
using namespace metal;

struct Params { int int_params[16]; float float_params[16]; };

// texture(0): input, texture(1): output
kernel void rgb_modulator(texture2d<float, access::read> input_image [[texture(0)]],
                          texture2d<float, access::write> output_image [[texture(1)]],
                          constant Params& params [[ buffer(0) ]],
                          uint2 gid [[thread_position_in_grid]]) {
    int width = input_image.get_width();
    int height = input_image.get_height();
    if (gid.x >= width || gid.y >= height) return;

    float r_scale = params.float_params[0];
    float g_scale = params.float_params[1];
    float b_scale = params.float_params[2];

    float4 pix = input_image.read(gid);
    pix.r *= r_scale;
    pix.g *= g_scale;
    pix.b *= b_scale;

    output_image.write(clamp(pix, 0.0f, 1.0f), gid);
}
