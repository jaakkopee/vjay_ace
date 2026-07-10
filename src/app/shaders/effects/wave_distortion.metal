#include <metal_stdlib>
using namespace metal;

struct Params { int int_params[16]; float float_params[16]; };

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
kernel void wave_distortion(texture2d<float, access::read> input_image [[texture(0)]],
                            texture2d<float, access::write> output_image [[texture(1)]],
                            constant Params& params [[ buffer(0) ]],
                            uint2 gid [[thread_position_in_grid]]) {
    int width = input_image.get_width();
    int height = input_image.get_height();
    if (gid.x >= width || gid.y >= height) return;

    float amplitude = clamp(params.float_params[0], 0.0f, 100.0f);
    float frequency = params.float_params[1];
    float phase = params.float_params[2];
    bool horizontal = params.int_params[0] != 0;

    // Optimization: use fast_sincos for better performance
    float src_x = float(gid.x);
    float src_y = float(gid.y);

    if (horizontal) {
        float arg = 2.0f * 3.14159265358979323846f * frequency * float(gid.y) / float(height) + phase;
        float wave = fast::sin(arg);
        src_x += amplitude * wave;
    } else {
        float arg = 2.0f * 3.14159265358979323846f * frequency * float(gid.x) / float(width) + phase;
        float wave = fast::sin(arg);
        src_y += amplitude * wave;
    }

    // Already using bilinear sampling which is good
    float4 sampled = sample_bilinear(input_image, float2(src_x, src_y));
    output_image.write(sampled, gid);
}
