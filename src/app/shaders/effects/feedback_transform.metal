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

// texture(0): current frame, texture(1): output, texture(2): previous frame
kernel void feedback_transform(texture2d<float, access::read> input_image [[texture(0)]],
                               texture2d<float, access::write> output_image [[texture(1)]],
                               texture2d<float, access::read> prev_image [[texture(2)]],
                               constant Params& params [[ buffer(0) ]],
                               uint2 gid [[thread_position_in_grid]]) {
    int width = input_image.get_width();
    int height = input_image.get_height();
    if (gid.x >= width || gid.y >= height) return;

    float mix_ratio = clamp(params.float_params[0], 0.0f, 1.0f);
    float zoom = max(params.float_params[1], 0.001f);
    float rotation = params.float_params[2]; // degrees
    float translate_x = params.float_params[3];
    float translate_y = params.float_params[4];

    float cx = float(width) * 0.5f;
    float cy = float(height) * 0.5f;
    float angle_rad = rotation * 3.14159265358979323846f / 180.0f;
    float cos_a = cos(angle_rad);
    float sin_a = sin(angle_rad);

    float dx = float(gid.x) - cx;
    float dy = float(gid.y) - cy;

    float rx = dx * cos_a - dy * sin_a;
    float ry = dx * sin_a + dy * cos_a;

    rx /= zoom;
    ry /= zoom;

    float src_x = cx + rx + translate_x;
    float src_y = cy + ry + translate_y;

    float4 prev = sample_bilinear(prev_image, float2(src_x, src_y));
    float4 current = input_image.read(gid);

    float4 blended = current * (1.0f - mix_ratio) + prev * mix_ratio;
    output_image.write(blended, gid);
}
