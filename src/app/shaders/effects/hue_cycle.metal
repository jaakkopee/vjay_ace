#include <metal_stdlib>
using namespace metal;

struct Params { int int_params[16]; float float_params[16]; };

inline float3 rgb_to_hsv(float3 c) {
    float c_max = max(c.r, max(c.g, c.b));
    float c_min = min(c.r, min(c.g, c.b));
    float delta = c_max - c_min;
    float h = 0.0f;
    if (delta > 0.00001f) {
        if (c_max == c.r) h = fmod((c.g - c.b) / delta, 6.0f);
        else if (c_max == c.g) h = ((c.b - c.r) / delta) + 2.0f;
        else h = ((c.r - c.g) / delta) + 4.0f;
        h /= 6.0f;
        if (h < 0.0f) h += 1.0f;
    }
    float s = c_max == 0.0f ? 0.0f : delta / c_max;
    float v = c_max;
    return float3(h, s, v);
}

inline float3 hsv_to_rgb(float3 hsv) {
    float h = hsv.x * 6.0f;
    float s = hsv.y;
    float v = hsv.z;
    int i = int(floor(h)) % 6;
    float f = h - floor(h);
    float p = v * (1.0f - s);
    float q = v * (1.0f - f * s);
    float t = v * (1.0f - (1.0f - f) * s);
    switch (i) {
        case 0: return float3(v, t, p);
        case 1: return float3(q, v, p);
        case 2: return float3(p, v, t);
        case 3: return float3(p, q, v);
        case 4: return float3(t, p, v);
        default: return float3(v, p, q);
    }
}

kernel void hue_cycle(texture2d<float, access::read> input_image [[texture(0)]],
                      texture2d<float, access::write> output_image [[texture(1)]],
                      constant Params& params [[ buffer(0) ]],
                      uint2 gid [[thread_position_in_grid]]) {
    int width = input_image.get_width();
    int height = input_image.get_height();
    if (gid.x >= width || gid.y >= height) return;

    float cycle_speed = params.float_params[0];
    float time_offset = params.float_params[1];
    float position_factor = (float(gid.x) / float(width) + float(gid.y) / float(height)) * 0.5f;
    float hue_shift = (time_offset + position_factor) * cycle_speed;

    float4 pix = input_image.read(gid);
    float3 hsv = rgb_to_hsv(pix.rgb);
    hsv.x = fract(hsv.x + hue_shift);

    float3 rgb = hsv_to_rgb(hsv);
    output_image.write(float4(rgb, pix.a), gid);
}
