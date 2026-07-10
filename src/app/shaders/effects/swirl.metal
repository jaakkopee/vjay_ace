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

kernel void swirl(texture2d<float, access::read> input [[texture(0)]], texture2d<float, access::write> output [[texture(1)]], constant Params& params [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    int width = input.get_width();
    int height = input.get_height();
    if (gid.x >= width || gid.y >= height) return;

    float angle = params.float_params[0];
    float radius = params.float_params[1];
    float center_x = params.float_params[2];
    float center_y = params.float_params[3];

    if (center_x < 0.0f) center_x = float(width) * 0.5f;
    if (center_y < 0.0f) center_y = float(height) * 0.5f;
    if (radius <= 0.0f) radius = sqrt(float(width*width + height*height)) * 0.25f;

    float angle_rad = angle * 3.14159265358979323846f / 180.0f;

    float dx = float(gid.x) - center_x;
    float dy = float(gid.y) - center_y;
    float distance = sqrt(dx*dx + dy*dy);

    if (distance < radius && distance > 0.0f) {
        float swirl_factor = (radius - distance) / radius;
        float swirl_angle = angle_rad * swirl_factor * swirl_factor;
        float cos_a = cos(swirl_angle);
        float sin_a = sin(swirl_angle);
        float src_x = center_x + dx * cos_a - dy * sin_a;
        float src_y = center_y + dx * sin_a + dy * cos_a;
        float4 sampled = sample_bilinear(input, float2(src_x, src_y));
        output.write(sampled, gid);
    } else {
        output.write(input.read(gid), gid);
    }
}
