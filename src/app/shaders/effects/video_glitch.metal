#include <metal_stdlib>
using namespace metal;

struct Params {
    int int_params[16];
    float float_params[16];
};

// GLSL-style helpers ported to Metal
float2 mod289(float2 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float3 mod289(float3 x) {
    return x - floor(x * (1.0 / 289.0)) * 289.0;
}

float3 permute(float3 x) {
    return mod289(((x * 34.0) + 1.0) * x);
}

// 2D simplex noise (same as source shader)
float snoise(float2 v) {
    const float4 C = float4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
    float2 i  = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    
    i = mod289(i);
    float3 p = permute(permute(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));
    
    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;
    
    float3 x = 2.0 * fract(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;
    
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    
    float3 g;
    g.x  = a0.x  * x0.x  + h.x  * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

float rand(float2 co) {
    return fract(sin(dot(co, float2(12.9898, 78.233))) * 43758.5453);
}

kernel void video_glitch(texture2d<float, access::read> input  [[texture(0)]],
                         texture2d<float, access::write> output [[texture(1)]],
                         constant Params& params              [[buffer(0)]],
                         uint2 gid                            [[thread_position_in_grid]]) {
    int width = input.get_width();
    int height = input.get_height();
    
    if (gid.x >= width || gid.y >= height) {
        return;
    }
    
    float time = params.float_params[0];
    float displacement_strength = params.float_params[1];
    float interference_strength = params.float_params[2];
    float channel_shift = params.float_params[3];
    
    float2 uv = float2(gid) / float2(width, height);
    
    // Match original shader timing
    float base_time = time * 2.0;
    float noise = max(0.0, snoise(float2(base_time, uv.y * 0.3)) - 0.3) * (1.0 / 0.7);
    noise += (snoise(float2(time * 20.0, uv.y * 2.4)) - 0.5) * 0.15;
    noise = max(0.0, noise) * displacement_strength;
    
    float xpos = uv.x - noise * noise * 0.25;
    float sample_x = clamp(xpos * float(width), 0.0f, float(width - 1));
    uint2 sample_coord = uint2(sample_x, gid.y);
    float4 color = input.read(sample_coord);
    
    // Interference mix
    float line_rand = rand(float2(uv.y * time, uv.y * 13.37));
    color.rgb = mix(color.rgb, float3(line_rand), noise * interference_strength);
    
    // Scanline attenuation every 4px (fragCoord.y * 0.25 step)
    if (fmod(floor(float(gid.y) * 0.25), 2.0) == 0.0) {
        color.rgb *= (1.0 - (0.15 * noise));
    }
    
    // Channel shifts using red as anchor
    float shift = channel_shift * noise;
    float gx = clamp((xpos + shift) * float(width), 0.0f, float(width - 1));
    float bx = clamp((xpos - shift) * float(width), 0.0f, float(width - 1));
    
    float g_sample = input.read(uint2(gx, gid.y)).g;
    float b_sample = input.read(uint2(bx, gid.y)).b;
    
    color.g = mix(color.r, g_sample, 0.25);
    color.b = mix(color.r, b_sample, 0.25);
    
    output.write(color, gid);
}
