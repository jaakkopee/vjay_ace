#include <metal_stdlib>
using namespace metal;

struct Params { int int_params[16]; float float_params[16]; };

inline uint hash_u(int x, int y, int seed) {
    uint n = uint(seed) + uint(x) * 374761393u + uint(y) * 668265263u;
    n = (n ^ (n >> 13)) * 1274126177u;
    return n ^ (n >> 16);
}

// texture(0): current frame, texture(1): output, texture(2): previous frame
kernel void datamosh_effect(texture2d<float, access::read> input_image [[texture(0)]],
                            texture2d<float, access::write> output_image [[texture(1)]],
                            texture2d<float, access::read> prev_image [[texture(2)]],
                            constant Params& params [[ buffer(0) ]],
                            uint2 gid [[thread_position_in_grid]]) {
    int width = input_image.get_width();
    int height = input_image.get_height();
    if (gid.x >= width || gid.y >= height) return;

    float intensity = clamp(params.float_params[0], 0.0f, 1.0f);
    int block_size = max(4, min(32, params.int_params[0]));
    int seed = 54321;

    int bx = int(gid.x) / block_size;
    int by = int(gid.y) / block_size;

    bool use_previous = float(hash_u(bx, by, seed) & 0x7fffffff) / 2147483647.0f < intensity;
    float4 pix = use_previous ? prev_image.read(gid) : input_image.read(gid);
    output_image.write(pix, gid);
}
