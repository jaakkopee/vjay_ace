#include <metal_stdlib>
using namespace metal;

struct Params { int int_params[16]; float float_params[16]; };

inline uint hash_u(int x, int y, int seed) {
    uint n = uint(seed) + uint(x) * 374761393u + uint(y) * 668265263u;
    n = (n ^ (n >> 13)) * 1274126177u;
    return n ^ (n >> 16);
}

inline float rand01(int x, int y, int seed) {
    return float(hash_u(x, y, seed) & 0x7fffffff) / 2147483647.0f;
}

inline float4 sample_bilinear(texture2d<float, access::read> tex, float2 coord) {
    int2 dims = int2(tex.get_width(), tex.get_height());
    if (coord.x < 0.0f || coord.y < 0.0f || coord.x >= dims.x || coord.y >= dims.y) {
        return float4(0.0);
    }
    int x1 = int(floor(coord.x));
    int y1 = int(floor(coord.y));
    int x2 = min(x1 + 1, dims.x - 1);
    int y2 = min(y1 + 1, dims.y - 1);
    float fx = coord.x - float(x1);
    float fy = coord.y - float(y1);
    float4 p1 = tex.read(uint2(x1, y1));
    float4 p2 = tex.read(uint2(x2, y1));
    float4 p3 = tex.read(uint2(x1, y2));
    float4 p4 = tex.read(uint2(x2, y2));
    return p1 * (1.0f - fx) * (1.0f - fy) + p2 * fx * (1.0f - fy) + p3 * (1.0f - fx) * fy + p4 * fx * fy;
}

// texture(0): input, texture(1): output
kernel void noise_distortion(texture2d<float, access::read> input_image [[texture(0)]],
                             texture2d<float, access::write> output_image [[texture(1)]],
                             constant Params& params [[ buffer(0) ]],
                             uint2 gid [[thread_position_in_grid]]) {
    int width = input_image.get_width();
    int height = input_image.get_height();
    if (gid.x >= width || gid.y >= height) return;

    float intensity = clamp(params.float_params[0], 0.0f, 100.0f);
    float scale = clamp(params.float_params[1], 0.01f, 1.0f);
    int seed = params.int_params[0];

    float nx = rand01(int(float(gid.x) * scale), int(float(gid.y) * scale), seed);
    float ny = rand01(int(float(gid.x) * scale), int(float(gid.y) * scale), seed + 1);

    float disp_x = (nx - 0.5f) * intensity;
    float disp_y = (ny - 0.5f) * intensity;

    float src_x = float(gid.x) + disp_x;
    float src_y = float(gid.y) + disp_y;

    float4 sampled = sample_bilinear(input_image, float2(src_x, src_y));
    output_image.write(sampled, gid);
}
