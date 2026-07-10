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

kernel void fisheye(texture2d<float, access::read> input [[texture(0)]], texture2d<float, access::write> output [[texture(1)]], constant Params& params [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    int width = input.get_width();
    int height = input.get_height();
    if (gid.x >= width || gid.y >= height) return;

    float strength = params.float_params[0];

    float cx = float(width) * 0.5f;
    float cy = float(height) * 0.5f;
    float radius = min(cx, cy);

    float dx = float(gid.x) - cx;
    float dy = float(gid.y) - cy;
    float distance = sqrt(dx*dx + dy*dy);

    if (distance < radius && distance > 0.0f) {
        float normalized_distance = distance / radius;
        float new_distance = pow(normalized_distance, 1.0f + strength);
        float scale = new_distance / normalized_distance;
        float src_x = cx + dx * scale;
        float src_y = cy + dy * scale;
        float4 sampled = sample_bilinear(input, float2(src_x, src_y));
        output.write(sampled, gid);
    } else {
        if (distance >= radius) {
            output.write(float4(0.0), gid);
        } else {
            output.write(input.read(gid), gid);
        }
    }
}
