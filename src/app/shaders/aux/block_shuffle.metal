#include <metal_stdlib>
using namespace metal;

struct Params { int int_params[16]; float float_params[16]; };

inline uint hash_u(int x, int y, int seed) {
    uint n = uint(seed) + uint(x) * 374761393u + uint(y) * 668265263u;
    n = (n ^ (n >> 13)) * 1274126177u;
    return n ^ (n >> 16);
}

// texture(0): input, texture(1): output
kernel void block_shuffle(texture2d<float, access::read> input_image [[texture(0)]],
                          texture2d<float, access::write> output_image [[texture(1)]],
                          constant Params& params [[ buffer(0) ]],
                          uint2 gid [[thread_position_in_grid]]) {
    int width = input_image.get_width();
    int height = input_image.get_height();
    if (gid.x >= width || gid.y >= height) return;

    int block_size = params.int_params[0];
    block_size = max(4, min(128, block_size));
    float intensity = clamp(params.float_params[0], 0.0f, 1.0f);
    int seed = params.int_params[1];

    int blocks_x = (width + block_size - 1) / block_size;
    int blocks_y = (height + block_size - 1) / block_size;

    int bx = int(gid.x) / block_size;
    int by = int(gid.y) / block_size;

    float rnd = float(hash_u(bx, by, seed) & 0x7fffffff) / 2147483647.0f;
    int target_bx = bx;
    int target_by = by;
    if (rnd <= intensity) {
        target_bx = int((float(hash_u(bx, by, seed + 1) & 0x7fffffff) / 2147483647.0f) * blocks_x) % blocks_x;
        target_by = int((float(hash_u(bx, by, seed + 2) & 0x7fffffff) / 2147483647.0f) * blocks_y) % blocks_y;
    }

    int local_x = int(gid.x) - bx * block_size;
    int local_y = int(gid.y) - by * block_size;
    int src_x = target_bx * block_size + local_x;
    int src_y = target_by * block_size + local_y;

    if (src_x < width && src_y < height) {
        float4 pix = input_image.read(uint2(src_x, src_y));
        output_image.write(pix, gid);
    } else {
        output_image.write(float4(0.0f), gid);
    }
}
