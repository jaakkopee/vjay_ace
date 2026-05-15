#include <metal_stdlib>
using namespace metal;

struct Params {
    int int_params[16];
    float float_params[16];
};

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
    float4 res = p1 * (1.0f - fx) * (1.0f - fy) + p2 * fx * (1.0f - fy) + p3 * (1.0f - fx) * fy + p4 * fx * fy;
    return res;
}

kernel void kaleidoscope(texture2d<float, access::read> input_image [[texture(0)]],
                         texture2d<float, access::write> output_image [[texture(1)]],
                         constant Params& params [[ buffer(0) ]],
                         uint2 gid [[thread_position_in_grid]]) {
    int2 dims = int2(input_image.get_width(), input_image.get_height());
    if (gid.x >= uint(dims.x) || gid.y >= uint(dims.y)) return;

    int segments = max(1, params.int_params[0]);
    float rotation = params.float_params[0];
    if (segments < 2) segments = 2;

    float cx = float(dims.x) * 0.5f;
    float cy = float(dims.y) * 0.5f;

    float dx = float(gid.x) - cx;
    float dy = float(gid.y) - cy;

    float radius = sqrt(dx*dx + dy*dy);
    float angle = atan2(dy, dx);

    angle += rotation;
    float two_pi = 2.0f * 3.14159265358979323846f;
    angle = fmod(angle, two_pi);
    if (angle < 0.0f) angle += two_pi;

    float angle_per_segment = two_pi / float(segments);
    float seg_idx_f = floor(angle / angle_per_segment);
    int seg_idx = int(seg_idx_f);
    float segment_angle = fmod(angle, angle_per_segment);
    if ((seg_idx & 1) == 1) {
        segment_angle = angle_per_segment - segment_angle;
    }

    float src_x = cx + radius * cos(segment_angle);
    float src_y = cy + radius * sin(segment_angle);

    float4 sampled = sample_bilinear(input_image, float2(src_x, src_y));
    output_image.write(sampled, uint2(gid.x, gid.y));
}
