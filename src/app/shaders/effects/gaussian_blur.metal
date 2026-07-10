#include <metal_stdlib>
using namespace metal;

struct Params { int int_params[16]; float float_params[16]; };

kernel void gaussian_blur(texture2d<float, access::read> input_image [[texture(0)]],
                          texture2d<float, access::write> output_image [[texture(1)]],
                          constant Params& params [[ buffer(0) ]],
                          uint2 gid [[thread_position_in_grid]]) {
    int width = input_image.get_width();
    int height = input_image.get_height();
    if (gid.x >= width || gid.y >= height) return;

    int kernel_size = max(1, params.int_params[0]);
    float sigma = max(0.001f, params.float_params[0]);
    int half_size = kernel_size / 2; // avoid colliding with Metal's half type
    float denom = 2.0f * sigma * sigma;

    float4 accum = float4(0.0f);
    float weight_sum = 0.0f;

    for (int y = -half_size; y <= half_size; ++y) {
        int sy = clamp(int(gid.y) + y, 0, height - 1);
        for (int x = -half_size; x <= half_size; ++x) {
            int sx = clamp(int(gid.x) + x, 0, width - 1);
            float dist2 = float(x * x + y * y);
            float w = exp(-dist2 / denom);
            accum += input_image.read(uint2(sx, sy)) * w;
            weight_sum += w;
        }
    }

    output_image.write(accum / weight_sum, gid);
}
