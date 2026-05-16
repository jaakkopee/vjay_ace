#include <metal_stdlib>
using namespace metal;

struct Params { int int_params[16]; float float_params[16]; };

inline float3 rgb_to_hsv(float3 rgb) {
    float maxc = max(rgb.r, max(rgb.g, rgb.b));
    float minc = min(rgb.r, min(rgb.g, rgb.b));
    float delta = maxc - minc;

    float h = 0.0f;
    if (delta > 0.00001f) {
        if (maxc == rgb.r) {
            h = fmod((rgb.g - rgb.b) / delta, 6.0f);
        } else if (maxc == rgb.g) {
            h = ((rgb.b - rgb.r) / delta) + 2.0f;
        } else {
            h = ((rgb.r - rgb.g) / delta) + 4.0f;
        }
        h /= 6.0f;
        if (h < 0.0f) h += 1.0f;
    }

    float s = (maxc == 0.0f) ? 0.0f : delta / maxc;
    float v = maxc;
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

// texture(0): input, texture(1): output
kernel void psychedelic_colors(texture2d<float, access::read> input_image [[texture(0)]],
                               texture2d<float, access::write> output_image [[texture(1)]],
                               constant Params& params [[ buffer(0) ]],
                               uint2 gid [[thread_position_in_grid]]) {
    int width = input_image.get_width();
    int height = input_image.get_height();
    if (gid.x >= width || gid.y >= height) return;

    float intensity = clamp(params.float_params[0], 0.0f, 2.0f);

    float2 pos = float2(gid);
    float wave = sin((pos.x + pos.y) * 0.1f); // wavy hue shift component

    float4 pix = input_image.read(gid);
    float3 hsv = rgb_to_hsv(pix.rgb);
    hsv.x += intensity * 0.5f * wave; // hue shift
    hsv.y = clamp(hsv.y * (1.0f + intensity), 0.0f, 1.0f); // saturation boost
    hsv.z = clamp(hsv.z * (1.0f + intensity * 0.3f), 0.0f, 1.0f); // brightness boost

    float3 out_rgb = hsv_to_rgb(hsv);
    output_image.write(float4(out_rgb, pix.a), gid);
}
