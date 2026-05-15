#include <metal_stdlib>
using namespace metal;

struct Params {
    int int_params[16];
    float float_params[16];
};

// RGB to HSV conversion
float3 rgb_to_hsv(float3 rgb) {
    float cmax = max(max(rgb.r, rgb.g), rgb.b);
    float cmin = min(min(rgb.r, rgb.g), rgb.b);
    float delta = cmax - cmin;
    
    float h = 0.0f;
    float s = 0.0f;
    float v = cmax;
    
    if (delta > 0.0001f) {
        s = delta / cmax;
        
        if (cmax == rgb.r) {
            h = 60.0f * fmod((rgb.g - rgb.b) / delta, 6.0f);
        } else if (cmax == rgb.g) {
            h = 60.0f * ((rgb.b - rgb.r) / delta + 2.0f);
        } else {
            h = 60.0f * ((rgb.r - rgb.g) / delta + 4.0f);
        }
        
        if (h < 0.0f) h += 360.0f;
    }
    
    return float3(h, s, v);
}

// HSV to RGB conversion
float3 hsv_to_rgb(float3 hsv) {
    float h = hsv.x;
    float s = hsv.y;
    float v = hsv.z;
    
    float c = v * s;
    float x = c * (1.0f - abs(fmod(h / 60.0f, 2.0f) - 1.0f));
    float m = v - c;
    
    float3 rgb;
    
    if (h < 60.0f) {
        rgb = float3(c, x, 0.0f);
    } else if (h < 120.0f) {
        rgb = float3(x, c, 0.0f);
    } else if (h < 180.0f) {
        rgb = float3(0.0f, c, x);
    } else if (h < 240.0f) {
        rgb = float3(0.0f, x, c);
    } else if (h < 300.0f) {
        rgb = float3(x, 0.0f, c);
    } else {
        rgb = float3(c, 0.0f, x);
    }
    
    return rgb + m;
}

// HSV shift effect
kernel void hsv_shift(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant float& hue_shift [[buffer(0)]],
    constant float& saturation_mult [[buffer(1)]],
    constant float& value_mult [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) {
        return;
    }
    
    float4 pixel = input.read(gid);
    float3 hsv = rgb_to_hsv(pixel.rgb);
    
    // Apply transformations
    hsv.x = fmod(hsv.x + hue_shift + 360.0f, 360.0f);
    hsv.y = clamp(hsv.y * saturation_mult, 0.0f, 1.0f);
    hsv.z = clamp(hsv.z * value_mult, 0.0f, 1.0f);
    
    pixel.rgb = hsv_to_rgb(hsv);
    
    output.write(clamp(pixel, 0.0f, 1.0f), gid);
}

// Hue cycle effect
kernel void hue_cycle(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant float& cycle_speed [[buffer(0)]],
    constant float& time_offset [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    int width = input.get_width();
    int height = input.get_height();
    
    if (gid.x >= width || gid.y >= height) {
        return;
    }
    
    float4 pixel = input.read(gid);
    
    // Calculate position-based hue shift
    float position_factor = (float(gid.x) / float(width) + float(gid.y) / float(height)) * 0.5f;
    float hue_shift = (time_offset + position_factor) * cycle_speed * 360.0f;
    
    float3 hsv = rgb_to_hsv(pixel.rgb);
    hsv.x = fmod(hsv.x + hue_shift + 360.0f, 360.0f);
    pixel.rgb = hsv_to_rgb(hsv);
    
    output.write(clamp(pixel, 0.0f, 1.0f), gid);
}

// Generic HSV operation kernel for registry-level compatibility.
kernel void hsv_operations(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) {
        return;
    }

    float hue_shift = params.float_params[0];
    float saturation_mult = params.float_params[1];
    float value_mult = params.float_params[2];

    float4 pixel = input.read(gid);
    float3 hsv = rgb_to_hsv(pixel.rgb);
    hsv.x = fmod(hsv.x + hue_shift + 360.0f, 360.0f);
    hsv.y = clamp(hsv.y * saturation_mult, 0.0f, 1.0f);
    hsv.z = clamp(hsv.z * value_mult, 0.0f, 1.0f);
    pixel.rgb = hsv_to_rgb(hsv);

    output.write(clamp(pixel, 0.0f, 1.0f), gid);
}
