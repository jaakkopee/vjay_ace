#include <metal_stdlib>
using namespace metal;

struct Params {
    int int_params[16];
    float float_params[16];
};

kernel void scanline(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;

    int line_width = max(1, params.int_params[0]);
    float intensity = params.float_params[0];
    float offset = params.float_params[1];

    float4 pixel = input.read(gid);

    float y_with_offset = fmod(float(gid.y) + offset, float(line_width * 2));
    if (y_with_offset < float(line_width)) {
        pixel.rgb *= (1.0 - intensity * 0.5);
    }

    output.write(pixel, gid);
}
