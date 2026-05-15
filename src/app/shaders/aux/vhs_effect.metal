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

// texture(0): input, texture(1): output
kernel void vhs_effect(texture2d<float, access::read> input_image [[texture(0)]],
                       texture2d<float, access::write> output_image [[texture(1)]],
                       constant Params& params [[ buffer(0) ]],
                       uint2 gid [[thread_position_in_grid]]) {
    int width = input_image.get_width();
    int height = input_image.get_height();
    if (gid.x >= width || gid.y >= height) return;

    float noise_intensity = clamp(params.float_params[0], 0.0f, 1.0f);
    float distortion = clamp(params.float_params[1], 0.0f, 1.0f);
    float color_bleed = clamp(params.float_params[2], 0.0f, 10.0f);
    int seed = 12345;

    float wave = sin(float(gid.y) * 0.1f) * distortion * 10.0f;
    int shift = int(wave);

    int src_x = int(gid.x) + shift;
    while (src_x < 0) src_x += width;
    while (src_x >= width) src_x -= width;

    float4 pix = input_image.read(uint2(src_x, gid.y));

    // Color bleed from previous pixel
    if (color_bleed > 0.0f && gid.x > 0) {
        float4 prev = input_image.read(uint2(src_x > 0 ? src_x - 1 : src_x, gid.y));
        pix = pix * 0.7f + prev * 0.3f * (color_bleed / 10.0f);
    }

    // Add noise
    if (noise_intensity > 0.0f) {
        float noise_r = rand01(src_x, int(gid.y), seed) - 0.5f;
        float noise_g = rand01(src_x, int(gid.y), seed + 1) - 0.5f;
        float noise_b = rand01(src_x, int(gid.y), seed + 2) - 0.5f;
        pix.r += noise_r * noise_intensity * 0.3f;
        pix.g += noise_g * noise_intensity * 0.3f;
        pix.b += noise_b * noise_intensity * 0.3f;
    }

    output_image.write(clamp(pix, 0.0f, 1.0f), gid);
}
