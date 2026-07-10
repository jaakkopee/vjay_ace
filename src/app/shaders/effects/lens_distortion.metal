#include <metal_stdlib>
using namespace metal;

struct Params {
    int int_params[16];
    float float_params[16];
};

float4 sample_bilinear(texture2d<float, access::read> tex, float2 coord) {
    int2 dims = int2(tex.get_width(), tex.get_height());
    if (coord.x < 0.0 || coord.y < 0.0 || coord.x >= dims.x || coord.y >= dims.y) {
        return float4(0.0);
    }

    int x1 = int(floor(coord.x));
    int y1 = int(floor(coord.y));
    int x2 = x1 + 1;
    int y2 = y1 + 1;
    if (x1 < 0 || y1 < 0 || x2 >= dims.x || y2 >= dims.y) return float4(0.0);

    float fx = coord.x - float(x1);
    float fy = coord.y - float(y1);

    float4 p1 = tex.read(uint2(x1, y1));
    float4 p2 = tex.read(uint2(x2, y1));
    float4 p3 = tex.read(uint2(x1, y2));
    float4 p4 = tex.read(uint2(x2, y2));

    float4 res = p1 * (1.0 - fx) * (1.0 - fy) + p2 * fx * (1.0 - fy) + 
                   p3 * (1.0 - fx) * fy + p4 * fx * fy;
    return res;
}

kernel void lens_distortion(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int width = input.get_width();
    int height = input.get_height();
    if (gid.x >= width || gid.y >= height) return;

    float strength = params.float_params[0];
    float zoom = params.float_params[1];

    float cx = float(width) * 0.5;
    float cy = float(height) * 0.5;
    float2 coord = float2(gid.x, gid.y);

    float nx = (coord.x - cx) / cx;
    float ny = (coord.y - cy) / cy;
    float r = sqrt(nx * nx + ny * ny);

    float r_distorted = r * (1.0 + strength * r * r);
    r_distorted *= zoom;

    float scale = (r > 0.0) ? (r_distorted / r) : 1.0;
    float src_x = cx + (coord.x - cx) * scale;
    float src_y = cy + (coord.y - cy) * scale;

    float4 sampled = sample_bilinear(input, float2(src_x, src_y));
    output.write(sampled, gid);
}
