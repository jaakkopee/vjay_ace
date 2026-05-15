#include <metal_stdlib>
using namespace metal;

struct Params { int int_params[16]; float float_params[16]; };

// texture(0): input, texture(1): output
kernel void color_temperature(texture2d<float, access::read> input_image [[texture(0)]],
                              texture2d<float, access::write> output_image [[texture(1)]],
                              constant Params& params [[ buffer(0) ]],
                              uint2 gid [[thread_position_in_grid]]) {
    int width = input_image.get_width();
    int height = input_image.get_height();
    if (gid.x >= width || gid.y >= height) return;

    float temp_factor = clamp(params.float_params[0], -1.0f, 1.0f);

    float4 pix = input_image.read(gid);
    if (temp_factor > 0.0f) {
        // Cool (more blue)
        pix.r *= (1.0f - temp_factor * 0.3f);
        pix.g *= (1.0f - temp_factor * 0.1f);
        pix.b *= (1.0f + temp_factor * 0.2f);
    } else {
        float warmth = -temp_factor;
        pix.r *= (1.0f + warmth * 0.3f);
        pix.g *= (1.0f + warmth * 0.1f);
        pix.b *= (1.0f - warmth * 0.4f);
    }

    output_image.write(clamp(pix, 0.0f, 1.0f), gid);
}
