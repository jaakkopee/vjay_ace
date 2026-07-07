// vjay_shaders.metal
// Master shader file for vjay_ace.
// Combines ported MachinaVFX kernels + new kernels for the VJ layer compositor.
// All kernels follow the MachinaVFX Params convention:
//   constant Params& params [[buffer(0)]]  →  int_params[16], float_params[16]

#include <metal_stdlib>
using namespace metal;

// ── Shared param struct (mirrors MachinaVFX convention) ─────────────────────
struct Params {
    int   int_params[16];
    float float_params[16];
};

struct LIFSimParams {
    uint  neuronCount;
    uint  gridSize;
    float dt;
    float leak;
    float threshold;
    float reset;
    float refractory;
    float rms;
    float timeSeconds;
};

// ── Utility: RGB ↔ HSV ────────────────────────────────────────────────────────
float3 rgb_to_hsv(float3 rgb) {
    float cmax = max(max(rgb.r, rgb.g), rgb.b);
    float cmin = min(min(rgb.r, rgb.g), rgb.b);
    float delta = cmax - cmin;
    float h = 0, s = (cmax > 0.0001f) ? delta / cmax : 0, v = cmax;
    if (delta > 0.0001f) {
        if (cmax == rgb.r)      h = 60.0f * fmod((rgb.g - rgb.b) / delta, 6.0f);
        else if (cmax == rgb.g) h = 60.0f * ((rgb.b - rgb.r) / delta + 2.0f);
        else                    h = 60.0f * ((rgb.r - rgb.g) / delta + 4.0f);
        if (h < 0) h += 360.0f;
    }
    return float3(h, s, v);
}
float3 hsv_to_rgb(float3 hsv) {
    float h = hsv.x, s = hsv.y, v = hsv.z;
    float c = v * s, x = c * (1.0f - abs(fmod(h / 60.0f, 2.0f) - 1.0f)), m = v - c;
    float3 rgb;
    if      (h < 60)  rgb = float3(c, x, 0);
    else if (h < 120) rgb = float3(x, c, 0);
    else if (h < 180) rgb = float3(0, c, x);
    else if (h < 240) rgb = float3(0, x, c);
    else if (h < 300) rgb = float3(x, 0, c);
    else              rgb = float3(c, 0, x);
    return rgb + m;
}

// ── Simplex noise (ported from video_glitch — used by glitch + wave) ─────────
float2 _mod289f2(float2 x) { return x - floor(x * (1.0/289.0)) * 289.0; }
float3 _mod289f3(float3 x) { return x - floor(x * (1.0/289.0)) * 289.0; }
float3 _permute(float3 x)  { return _mod289f3(((x * 34.0) + 1.0) * x); }
float snoise(float2 v) {
    const float4 C = float4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
    float2 i  = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    float2 i1 = (x0.x > x0.y) ? float2(1,0) : float2(0,1);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = _mod289f2(i);
    float3 p = _permute(_permute(i.y + float3(0,i1.y,1)) + i.x + float3(0,i1.x,1));
    float3 m = max(0.5 - float3(dot(x0,x0), dot(x12.xy,x12.xy), dot(x12.zw,x12.zw)), 0.0);
    m = m*m; m = m*m;
    float3 x  = 2.0 * fract(p * C.www) - 1.0;
    float3 h  = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0*a0 + h*h);
    float3 g;
    g.x  = a0.x  * x0.x   + h.x  * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}
float rand2(float2 co) { return fract(sin(dot(co, float2(12.9898, 78.233))) * 43758.5453); }

// ═══════════════════════════════════════════════════════════════════════════
//  KERNELS
// ═══════════════════════════════════════════════════════════════════════════

// ── passthrough ──────────────────────────────────────────────────────────────
kernel void passthrough(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;
    output.write(input.read(gid), gid);
}

// ── box_blur ─────────────────────────────────────────────────────────────────
// int_params[0] = kernel_size (odd, 3–21)
kernel void box_blur(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = input.get_width(), h = input.get_height();
    if (gid.x >= (uint)w || gid.y >= (uint)h) return;
    // audio: bass pumps blur radius
    int ks = max(1, params.int_params[0] + int(params.float_params[9] * 8.0f));
    int hks = ks / 2;
    float weight = 1.0f / float(ks * ks);
    float4 sum = 0;
    for (int ky = -hks; ky <= hks; ++ky)
        for (int kx = -hks; kx <= hks; ++kx)
            sum += input.read(uint2(clamp(int(gid.x)+kx,0,w-1), clamp(int(gid.y)+ky,0,h-1)));
    output.write(sum * weight, gid);
}

// ── chromatic_aberration ─────────────────────────────────────────────────────
// int_params[0] = pixel offset
kernel void chromatic_aberration(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = input.get_width(), h = input.get_height();
    if (gid.x >= (uint)w || gid.y >= (uint)h) return;
    // audio: bass drives chromatic offset
    int off = params.int_params[0] + int(params.float_params[9] * 15.0f);
    float r = input.read(uint2(clamp(int(gid.x)-off,0,w-1), gid.y)).r;
    float g = input.read(gid).g;
    float b = input.read(uint2(clamp(int(gid.x)+off,0,w-1), gid.y)).b;
    output.write(float4(r, g, b, input.read(gid).a), gid);
}

// ── hue_cycle ────────────────────────────────────────────────────────────────
// float_params[0] = cycle_speed,  float_params[1] = time_offset
kernel void hue_cycle(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = input.get_width(), h = input.get_height();
    if (gid.x >= (uint)w || gid.y >= (uint)h) return;
    float4 pixel = input.read(gid);
    float pos = (float(gid.x)/float(w) + float(gid.y)/float(h)) * 0.5f;
    // audio: RMS adds rotation speed
    float shift = (params.float_params[1] + pos) * (params.float_params[0] + params.float_params[7] * 2.0f) * 360.0f;
    float3 hsv = rgb_to_hsv(pixel.rgb);
    hsv.x = fmod(hsv.x + shift + 360.0f, 360.0f);
    output.write(clamp(float4(hsv_to_rgb(hsv), pixel.a), 0.0f, 1.0f), gid);
}

// ── video_glitch ─────────────────────────────────────────────────────────────
// float_params[0]=time  [1]=displacement_strength  [2]=interference  [3]=channel_shift
kernel void video_glitch(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = input.get_width(), h = input.get_height();
    if (gid.x >= (uint)w || gid.y >= (uint)h) return;
    float time = params.float_params[0];
    // audio: bass drives displacement, mid drives interference
    float dstr = params.float_params[1] + params.float_params[9] * 0.6f;
    float istr = params.float_params[2] + params.float_params[11] * 0.4f;
    float csh  = params.float_params[3];
    float2 uv  = float2(gid) / float2(w, h);
    float noise = max(0.0f, snoise(float2(time*2.0f, uv.y*0.3f)) - 0.3f) * (1.0f/0.7f);
    noise += (snoise(float2(time*20.0f, uv.y*2.4f)) - 0.5f) * 0.15f;
    noise = max(0.0f, noise) * dstr;
    float xpos  = uv.x - noise * noise * 0.25f;
    uint2 sc    = uint2(clamp(xpos * float(w), 0.0f, float(w-1)), gid.y);
    float4 color = input.read(sc);
    float lr = rand2(float2(uv.y * time, uv.y * 13.37f));
    color.rgb = mix(color.rgb, float3(lr), noise * istr);
    float shift = csh * noise;
    float gx = clamp((xpos + shift) * float(w), 0.0f, float(w-1));
    float bx = clamp((xpos - shift) * float(w), 0.0f, float(w-1));
    color.g = mix(color.r, input.read(uint2(gx, gid.y)).g, 0.25f);
    color.b = mix(color.r, input.read(uint2(bx, gid.y)).b, 0.25f);
    output.write(color, gid);
}

// ── kaleidoscope ─────────────────────────────────────────────────────────────
// int_params[0] = segments,  float_params[0] = rotation (radians)
kernel void kaleidoscope(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = input.get_width(), h = input.get_height();
    if (gid.x >= (uint)w || gid.y >= (uint)h) return;
    int segs = max(2, params.int_params[0]);
    // audio: RMS adds rotation
    float rot = params.float_params[0] + params.float_params[7] * 0.4f;
    float2 uv = float2(gid) / float2(w, h) - 0.5f;
    float angle = atan2(uv.y, uv.x) + rot;
    float radius = length(uv);
    float slice  = M_PI_F / float(segs);
    angle = fmod(abs(angle), 2.0f * slice);
    if (angle > slice) angle = 2.0f * slice - angle;
    float2 nuv = float2(cos(angle), sin(angle)) * radius + 0.5f;
    nuv = clamp(nuv, 0.0f, 1.0f);
    uint2 src = uint2(nuv * float2(w-1, h-1));
    output.write(input.read(src), gid);
}

// ── wave_distort ─────────────────────────────────────────────────────────────
// float_params[0]=amplitude(px)  [1]=frequency  [2]=phase(time)
kernel void wave_distort(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = input.get_width(), h = input.get_height();
    if (gid.x >= (uint)w || gid.y >= (uint)h) return;
    // audio: bass adds wave amplitude
    float amp  = params.float_params[0] + params.float_params[9] * 25.0f;
    float freq = params.float_params[1];
    float phase= params.float_params[2];
    float2 uv  = float2(gid) / float2(w, h);
    float dx   = amp * sin(uv.y * float(w) * freq + phase);
    float dy   = amp * sin(uv.x * float(h) * freq + phase * 1.3f);
    int2 src   = int2(clamp(int(gid.x) + int(dx), 0, w-1),
                      clamp(int(gid.y) + int(dy), 0, h-1));
    output.write(input.read(uint2(src)), gid);
}

// ── vignette ────────────────────────────────────────────────────────────────
// float_params[0] = strength (0-1)
// float_params[1] = radius (0-1, where 1 reaches image corners)
kernel void vignette(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = input.get_width(), h = input.get_height();
    if (gid.x >= (uint)w || gid.y >= (uint)h) return;

    float strength = clamp(params.float_params[0], 0.0f, 1.0f);
    float radius = clamp(params.float_params[1], 0.05f, 1.0f);

    float2 uv = (float2(gid) / float2(w, h)) * 2.0f - 1.0f;
    uv.x *= float(w) / float(h);
    float d = length(uv);
    float v = smoothstep(radius, 1.25f, d);

    float4 c = input.read(gid);
    float gain = 1.0f - v * strength;
    output.write(float4(c.rgb * gain, c.a), gid);
}

// ── ripple_distort ──────────────────────────────────────────────────────────
// float_params[0] = amplitude(px)
// float_params[1] = wavelength(px)
// float_params[2] = phase(time)
kernel void ripple_distort(
    texture2d<float, access::sample> input  [[texture(0)]],
    texture2d<float, access::write>  output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = input.get_width(), h = input.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float amp = params.float_params[0] + params.float_params[9] * 18.0f;
    float wavelength = max(2.0f, params.float_params[1]);
    float phase = params.float_params[2];
    float2 center = float2(w, h) * 0.5f;
    float2 p = float2(gid) - center;
    float dist = length(p);
    float wave = sin((dist / wavelength) * 6.28318f - phase);
    float2 dir = dist > 0.001f ? (p / dist) : float2(0.0f);
    float2 src = float2(gid) + dir * wave * amp;

    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    output.write(input.sample(s, src / float2(w, h)), gid);
}

// ── lens_distortion ─────────────────────────────────────────────────────────
// float_params[0] = strength (-1..1)
// float_params[1] = zoom (0.5..1.5)
kernel void lens_distortion(
    texture2d<float, access::sample> input  [[texture(0)]],
    texture2d<float, access::write>  output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = input.get_width(), h = input.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float strength = params.float_params[0] + params.float_params[7] * 0.35f;
    float zoom = max(0.1f, params.float_params[1]);

    float2 uv = (float2(gid) / float2(w, h)) * 2.0f - 1.0f;
    uv /= zoom;
    float r2 = dot(uv, uv);
    float k = 1.0f + strength * r2;
    float2 dst = uv * k;
    float2 src = (dst * 0.5f + 0.5f);

    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_zero);
    output.write(input.sample(s, src), gid);
}

// ── swirl_distort ───────────────────────────────────────────────────────────
// float_params[0] = angle magnitude (radians)
// float_params[1] = radius (0..1)
kernel void swirl_distort(
    texture2d<float, access::sample> input  [[texture(0)]],
    texture2d<float, access::write>  output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = input.get_width(), h = input.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float2 center = float2(w, h) * 0.5f;
    float2 p = float2(gid) - center;
    float maxR = min(float(w), float(h)) * 0.5f * clamp(params.float_params[1], 0.05f, 1.0f);
    float d = length(p);

    float2 src = float2(gid);
    if (d < maxR) {
        float t = 1.0f - (d / maxR);
        float angle = (params.float_params[0] + params.float_params[11] * 3.0f) * t * t;
        float ca = cos(angle), sa = sin(angle);
        float2 rp = float2(ca * p.x - sa * p.y, sa * p.x + ca * p.y);
        src = rp + center;
    }

    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    output.write(input.sample(s, src / float2(w, h)), gid);
}

// ── rgb_modulate ────────────────────────────────────────────────────────────
// float_params[0] = red gain
// float_params[1] = blue gain
kernel void rgb_modulate(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = input.get_width(), h = input.get_height();
    if (gid.x >= (uint)w || gid.y >= (uint)h) return;

    float rg = max(0.0f, params.float_params[0]);
    float bg = max(0.0f, params.float_params[1]);
    float gg = max(0.0f, 0.75f + params.float_params[7] * 1.2f);

    float4 c = input.read(gid);
    c.r *= rg;
    c.g *= gg;
    c.b *= bg;
    output.write(clamp(c, 0.0f, 1.0f), gid);
}

// ── color_temperature ───────────────────────────────────────────────────────
// float_params[0] = temperature (-1..1)
// float_params[1] = contrast
kernel void color_temperature(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = input.get_width(), h = input.get_height();
    if (gid.x >= (uint)w || gid.y >= (uint)h) return;

    float t = clamp(params.float_params[0], -1.0f, 1.0f);
    float contrast = max(0.0f, params.float_params[1]);
    float warm = max(t, 0.0f);
    float cool = max(-t, 0.0f);

    float4 c = input.read(gid);
    c.r *= (1.0f + warm * 0.45f);
    c.g *= (1.0f + warm * 0.10f - cool * 0.12f);
    c.b *= (1.0f + cool * 0.5f);
    c.rgb = (c.rgb - 0.5f) * contrast + 0.5f;
    output.write(clamp(c, 0.0f, 1.0f), gid);
}

// ── scanline ────────────────────────────────────────────────────────────────
// float_params[0] = intensity (0..1)
// float_params[1] = density   (1..8)
// float_params[2] = time
kernel void scanline(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = input.get_width(), h = input.get_height();
    if (gid.x >= (uint)w || gid.y >= (uint)h) return;

    float intensity = clamp(params.float_params[0], 0.0f, 1.0f);
    float density = max(1.0f, params.float_params[1]);
    float t = params.float_params[2] * 8.0f;
    float line = 0.5f + 0.5f * sin((float(gid.y) * density + t));
    float mask = mix(1.0f - intensity, 1.0f, line);

    float4 c = input.read(gid);
    c.rgb *= mask;
    output.write(c, gid);
}

// ── strobe_gate ─────────────────────────────────────────────────────────────
// float_params[0] = rate (Hz)
// float_params[1] = duty (0..1)
// float_params[2] = time
kernel void strobe_gate(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = input.get_width(), h = input.get_height();
    if (gid.x >= (uint)w || gid.y >= (uint)h) return;

    float rate = max(0.01f, params.float_params[0] + params.float_params[9] * 12.0f);
    float duty = clamp(params.float_params[1], 0.02f, 0.98f);
    float t = params.float_params[2] * rate;
    float phase = fract(t);
    float gate = (phase < duty) ? 1.0f : 0.0f;

    float4 c = input.read(gid);
    output.write(float4(c.rgb * gate, c.a), gid);
}

// ── edge_ink ──────────────────────────────────────────────────────────────────
// float_params[0]=threshold(0-1)  [1]=edge_strength
kernel void edge_ink(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = input.get_width(), h = input.get_height();
    if (gid.x >= (uint)w || gid.y >= (uint)h) return;
    // Sobel edge detect on luminance
    const int sobelX[3][3] = {{-1,0,1},{-2,0,2},{-1,0,1}};
    const int sobelY[3][3] = {{-1,-2,-1},{0,0,0},{1,2,1}};
    float gx = 0, gy = 0;
    for (int ky = -1; ky <= 1; ++ky)
        for (int kx = -1; kx <= 1; ++kx) {
            float4 p = input.read(uint2(clamp(int(gid.x)+kx,0,w-1), clamp(int(gid.y)+ky,0,h-1)));
            float lum = dot(p.rgb, float3(0.299f, 0.587f, 0.114f));
            gx += lum * sobelX[ky+1][kx+1];
            gy += lum * sobelY[ky+1][kx+1];
        }
    // audio: RMS boosts edge strength
    float mag   = sqrt(gx*gx + gy*gy) * (params.float_params[1] + params.float_params[7] * 2.0f);
    float thresh = params.float_params[0];
    float4 orig  = input.read(gid);
    // Overlay ink on bright edges
    float4 ink   = float4(0.12f, 0.78f, 1.0f, 1.0f); // cyan ink
    float  t     = step(thresh, mag);
    output.write(mix(orig, ink, t), gid);
}

// ── alpha_composite ───────────────────────────────────────────────────────────
// Porter-Duff "over" blend: overlay on top of bottom using master opacity.
// Texture bindings: 0=bottom, 1=overlay, 2=output
kernel void alpha_composite(
    texture2d<float, access::read>  bottom  [[texture(0)]],
    texture2d<float, access::read>  overlay [[texture(1)]],
    texture2d<float, access::write> output  [[texture(2)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= bottom.get_width() || gid.y >= bottom.get_height()) return;
    float4 b = bottom.read(gid);
    float4 o = overlay.read(gid);
    float alpha = params.float_params[0]; // master layer opacity
    float eff   = alpha * o.a;            // effective alpha
    float4 result = float4(mix(b.rgb, o.rgb, eff), b.a + eff * (1.0f - b.a));
    output.write(clamp(result, 0.0f, 1.0f), gid);
}

// ── pixelate ─────────────────────────────────────────────────────────────────
// int_params[0] = block_size (2–64)
kernel void pixelate(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = input.get_width(), h = input.get_height();
    if (gid.x >= (uint)w || gid.y >= (uint)h) return;
    // audio: loud signal → bigger pixel blocks
    int bs = max(1, params.int_params[0] + int(params.float_params[7] * 16.0f));
    uint2 block = uint2((gid.x / bs) * bs, (gid.y / bs) * bs);
    block = clamp(block, uint2(0), uint2(w-1, h-1));
    output.write(input.read(block), gid);
}

// ── rainbow_shift ─────────────────────────────────────────────────────────────
// Full-spectrum HSV rotation travelling across the image.
// float_params[0] = speed (time multiplier)
// float_params[1] = wave_scale (spatial frequency of colour bands)
kernel void rainbow_shift(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = input.get_width(), h = input.get_height();
    if (gid.x >= (uint)w || gid.y >= (uint)h) return;
    float4 pixel  = input.read(gid);
    // audio: RMS accelerates rainbow cycling
    float  speed  = params.float_params[0] + params.float_params[7] * 3.0f;
    float  wscale = params.float_params[1];
    float  t      = params.float_params[2]; // elapsed time
    float  phase  = (float(gid.x) / float(w) + float(gid.y) / float(h)) * wscale
                    + t * speed;
    float3 hsv = rgb_to_hsv(pixel.rgb);
    hsv.x = fmod(hsv.x + phase * 360.0f + 360.0f, 360.0f);
    hsv.y = min(1.0f, hsv.y + 0.3f);   // boost saturation
    output.write(clamp(float4(hsv_to_rgb(hsv), pixel.a), 0.0f, 1.0f), gid);
}

// ── julia_fractal ─────────────────────────────────────────────────────────────
// Renders a Julia set and blends/multiplies it with the source image.
// float_params[0] = cx  (-1..1, real part of c)
// float_params[1] = cy  (-1..1, imag part of c)
// float_params[2] = blend  (0=source, 1=fractal colour)
// float_params[3] = time (for animated c)
kernel void julia_fractal(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = input.get_width(), h = input.get_height();
    if (gid.x >= (uint)w || gid.y >= (uint)h) return;

    float t    = params.float_params[3];
    float cx   = params.float_params[0] * cos(t * 0.4f) - params.float_params[1] * sin(t * 0.4f);
    float cy   = params.float_params[0] * sin(t * 0.4f) + params.float_params[1] * cos(t * 0.4f);
    // audio: RMS blends in more fractal overlay
    float blend = clamp(params.float_params[2] + params.float_params[7] * 0.5f, 0.0f, 1.0f);

    float2 uv = (float2(gid) / float2(w, h) - 0.5f) * 3.5f;
    float zx = uv.x, zy = uv.y;
    int iter = 0, maxIter = 80;
    while (iter < maxIter && zx*zx + zy*zy < 4.0f) {
        float tmp = zx*zx - zy*zy + cx;
        zy = 2.0f * zx * zy + cy;
        zx = tmp;
        ++iter;
    }
    float norm = float(iter) / float(maxIter);
    float3 fcolor = hsv_to_rgb(float3(norm * 300.0f + 180.0f, 1.0f, norm < 1.0f ? 1.0f : 0.0f));
    float4 src = input.read(gid);
    output.write(clamp(float4(mix(src.rgb, fcolor, blend), src.a), 0.0f, 1.0f), gid);
}

// ── mold_trails ───────────────────────────────────────────────────────────────
// GPU physarum-style slime simulation (single-pass approximation):
// samples 3 sensor directions, computes trail gradient, diffuses.
// input  = previous trail map (grayscale in R channel)
// output = new trail map
// float_params[0] = sensor_angle (radians)
// float_params[1] = decay (0.9–0.99)
kernel void mold_trails(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = input.get_width(), h = input.get_height();
    if (gid.x >= (uint)w || gid.y >= (uint)h) return;

    float sa    = params.float_params[0]; // sensor angle
    // audio: bass slows trail decay (trails persist longer on beats)
    float decay = clamp(params.float_params[1] + params.float_params[9] * 0.08f, 0.0f, 0.9999f);
    float speed = 2.0f;

    // Current heading (derived from a hash of position for deterministic spread)
    float rng    = rand2(float2(gid) * 0.017f) * 6.28318f;
    float heading = rng;

    // Sample three sensors (forward, left, right)
    float fwd, left, right;
    {
        float sx = float(gid.x) + cos(heading) * speed * 5.0f;
        float sy = float(gid.y) + sin(heading) * speed * 5.0f;
        fwd = input.read(uint2(clamp(int(sx),0,w-1), clamp(int(sy),0,h-1))).r;
    }
    {
        float sx = float(gid.x) + cos(heading + sa) * speed * 5.0f;
        float sy = float(gid.y) + sin(heading + sa) * speed * 5.0f;
        left = input.read(uint2(clamp(int(sx),0,w-1), clamp(int(sy),0,h-1))).r;
    }
    {
        float sx = float(gid.x) + cos(heading - sa) * speed * 5.0f;
        float sy = float(gid.y) + sin(heading - sa) * speed * 5.0f;
        right = input.read(uint2(clamp(int(sx),0,w-1), clamp(int(sy),0,h-1))).r;
    }

    // Steer towards highest concentration
    float deposit = 1.0f;
    if (fwd >= left && fwd >= right) {
        heading += 0.0f;
    } else if (left > right) {
        heading += sa;
    } else {
        heading -= sa;
    }

    // Move and deposit
    float nx = float(gid.x) + cos(heading) * speed;
    float ny = float(gid.y) + sin(heading) * speed;
    uint2 nc = uint2(clamp(int(nx),0,w-1), clamp(int(ny),0,h-1));
    (void)nc; // deposit handled by diffusion below

    // Diffuse: box blur 3x3 of current trail, then deposit and decay
    float diffuse = 0.0f;
    for (int dy2 = -1; dy2 <= 1; ++dy2)
        for (int dx2 = -1; dx2 <= 1; ++dx2)
            diffuse += input.read(uint2(clamp(int(gid.x)+dx2,0,w-1),
                                       clamp(int(gid.y)+dy2,0,h-1))).r;
    diffuse /= 9.0f;

    float val = (diffuse + deposit * 0.1f) * decay;
    val = clamp(val, 0.0f, 1.0f);
    float3 col = hsv_to_rgb(float3(val * 180.0f + 120.0f, 0.9f, val));
    output.write(float4(col, 1.0f), gid);
}

// ── feedback_zoom ─────────────────────────────────────────────────────────────
// Infinite zoom / rotate feedback loop. Read previous frame, zoom+rotate
// by a small delta, tint, and mix with source.
// float_params[0] = zoom_delta   (e.g. 1.02 for slow zoom in)
// float_params[1] = rotate_delta (radians per frame, e.g. 0.01)
// float_params[2] = feedback_mix (0=source only, 1=full feedback)
// float_params[3] = tint_hue     (0-360)
kernel void feedback_zoom(
    texture2d<float, access::read>   input  [[texture(0)]],
    texture2d<float, access::write>  output [[texture(1)]],
    texture2d<float, access::sample> feedbackTex [[texture(2)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = input.get_width(), h = input.get_height();
    if (gid.x >= w || gid.y >= h) return;

    // audio: bass pumps zoom, RMS increases feedback mix
    float zoom  = params.float_params[0] + params.float_params[9] * 0.08f;
    float rot   = params.float_params[1];
    float mix_  = clamp(params.float_params[2] + params.float_params[7] * 0.25f, 0.0f, 0.98f);
    float hue   = params.float_params[3];

    float cx = float(w) * 0.5f, cy = float(h) * 0.5f;
    float dx = float(gid.x) - cx, dy = float(gid.y) - cy;
    // Inverse: where in the input does this output pixel come from?
    float cosR = cos(rot), sinR = sin(rot);
    float srcX = (cosR * dx + sinR * dy) / zoom + cx;
    float srcY = (-sinR * dx + cosR * dy) / zoom + cy;

    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float4 feedback = feedbackTex.sample(s, float2(srcX / float(w), srcY / float(h)));

    // --- Enhance contrast and brightness ---
    float3 hsv = rgb_to_hsv(feedback.rgb);
    hsv.x = fmod(hsv.x + hue * 0.5f, 360.0f);
    hsv.y *= 0.33f; // less desaturation
    // Stronger S-curve for contrast, then boost brightness
    hsv.z = pow(smoothstep(0.18f, 0.82f, hsv.z), 1.15f) * 1.25f;
    feedback.rgb = clamp(hsv_to_rgb(hsv), 0.0f, 1.0f);

    // --- Magnify local maxima pixels ---
    float maxLocal = feedback.rgb.r;
    for (int dy = -1; dy <= 1; ++dy)
    for (int dx = -1; dx <= 1; ++dx) {
        if (dx == 0 && dy == 0) continue;
        float2 uv = float2((float(gid.x)+dx)/float(w), (float(gid.y)+dy)/float(h));
        float4 n = feedbackTex.sample(s, uv);
        maxLocal = max(maxLocal, n.r);
    }
    // If this pixel is a local max in R, boost all channels for a pop effect
    if (feedback.rgb.r >= maxLocal - 0.001f && feedback.rgb.r > 0.25f) {
        feedback.rgb = clamp(feedback.rgb * 1.7f + 0.15f, 0.0f, 1.0f);
    }

    // Blend with the original pixel
    float4 src = input.read(gid);
    output.write(clamp(mix(src, feedback, mix_), 0.0f, 1.0f), gid);
}

// ── circle_quilt ──────────────────────────────────────────────────────────────
// Grid of circles whose radius and colour are driven by luminance.
// int_params[0]   = grid_cols  (8–64)
// float_params[0] = radius_scale (0-1 → fraction of cell that max circle fills)
// float_params[1] = hue_offset (0-360)
kernel void circle_quilt(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = input.get_width(), h = input.get_height();
    if (gid.x >= (uint)w || gid.y >= (uint)h) return;

    int   baseCols = max(4, params.int_params[0]);
    float rms      = params.float_params[7];
    float bass     = params.float_params[9];   // 60-250 Hz
    float mid      = params.float_params[11];  // 500-2 kHz
    float air      = params.float_params[15];  // 12-20 kHz

    // audio: bass opens up the quilt (fewer/larger cells), highs add detail.
    int cols = clamp(int(float(baseCols) - bass * 24.0f + air * 8.0f), 4, 96);
    float pulse = smoothstep(0.15f, 0.9f, max(rms, bass * 0.7f + mid * 0.3f));

    // audio: loud moments increase radius and rotate hue.
    float rs   = clamp(params.float_params[0] + rms * 0.7f + bass * 0.35f, 0.05f, 1.25f);
    float hoff = params.float_params[1] + mid * 120.0f + air * 180.0f;

    // Cell this pixel belongs to
    float cellW = float(w) / float(cols);
    float cellH = float(h) / float(cols); // keep cells square-ish
    int   ci    = int(float(gid.x) / cellW);
    int   ri    = int(float(gid.y) / cellH);
    float2 cellCentre = float2((float(ci) + 0.5f) * cellW,
                                (float(ri) + 0.5f) * cellH);
    // Sample input at cell centre for representative colour
    uint2  samplePos = uint2(clamp(int(cellCentre.x),0,w-1),
                             clamp(int(cellCentre.y),0,h-1));
    float4 samp = input.read(samplePos);
    float  lum  = dot(samp.rgb, float3(0.299f, 0.587f, 0.114f));

    float maxRadius = min(cellW, cellH) * 0.5f * rs;
    float radius    = lum * maxRadius;
    float dist      = length(float2(gid) - cellCentre);
    float ringW     = max(0.8f, min(cellW, cellH) * (0.02f + pulse * 0.12f));

    if (dist <= radius) {
        float3 hsv = rgb_to_hsv(samp.rgb);
        hsv.x = fmod(hsv.x + hoff, 360.0f);
        hsv.y = min(1.0f, hsv.y + 0.2f + pulse * 0.25f);
        hsv.z = min(1.0f, hsv.z + rms * 0.25f);
        output.write(float4(hsv_to_rgb(hsv), samp.a), gid);
    } else if (dist <= radius + ringW) {
        float3 hsv = rgb_to_hsv(samp.rgb);
        hsv.x = fmod(hsv.x + hoff + 90.0f, 360.0f);
        hsv.y = min(1.0f, 0.8f + pulse * 0.2f);
        hsv.z = min(1.0f, 0.35f + pulse * 0.65f);
        output.write(float4(hsv_to_rgb(hsv), 1.0f), gid);
    } else {
        float bgV = 0.03f + bass * 0.09f + rms * 0.12f;
        float bgH = fmod(220.0f + mid * 80.0f + air * 70.0f, 360.0f);
        float3 bg = hsv_to_rgb(float3(bgH, 0.35f, clamp(bgV, 0.0f, 0.35f)));
        output.write(float4(bg, 1.0f), gid);
    }
}

// ── ca_glow ───────────────────────────────────────────────────────────────────
// Conway-CA-inspired neighbour sum → glow map, overlaid with soft colour.
// Each pixel "lives" if its luminance exceeds a threshold; neighbours count
// determine output brightness.
// float_params[0] = threshold (0-1)
// float_params[1] = glow_spread (blur radius, integer cast 1-5)
// float_params[2] = hue_base (0-360)
kernel void ca_glow(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = input.get_width(), h = input.get_height();
    if (gid.x >= (uint)w || gid.y >= (uint)h) return;

    float thresh = params.float_params[0];
    int   spread = max(1, min(5, int(params.float_params[1] * 5.0f + 1.0f)));
    // audio: loud signal shifts glow hue
    float hbase  = params.float_params[2] + params.float_params[7] * 120.0f;

    // Count live neighbours in spread radius
    float live = 0.0f, total = 0.0f;
    for (int dy2 = -spread; dy2 <= spread; ++dy2)
        for (int dx2 = -spread; dx2 <= spread; ++dx2) {
            if (dx2 == 0 && dy2 == 0) continue;
            float4 p = input.read(uint2(clamp(int(gid.x)+dx2,0,w-1),
                                       clamp(int(gid.y)+dy2,0,h-1)));
            float lum = dot(p.rgb, float3(0.299f,0.587f,0.114f));
            if (lum > thresh) live += 1.0f;
            total += 1.0f;
        }

    float density = live / max(total, 1.0f);
    float4 src    = input.read(gid);
    float  srcLum = dot(src.rgb, float3(0.299f,0.587f,0.114f));

    float3 glowCol = hsv_to_rgb(float3(fmod(hbase + density * 180.0f, 360.0f), 0.9f, density));
    float  glow    = density * 1.5f;
    float3 result  = clamp(src.rgb + glowCol * glow, 0.0f, 1.0f);
    output.write(float4(result, src.a), gid);
}

// ── bitplane_reactor ──────────────────────────────────────────────────────────
// Wolfram elementary CA per row: rule applied to bitplane of luminance.
// Each output row is the next CA generation of the row above.
// int_params[0]   = rule number (0-255)
// float_params[0] = threshold for "on" bit (0-1)
// float_params[1] = colour_hue (0-360 for "alive" cells)
kernel void bitplane_reactor(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = input.get_width(), h = input.get_height();
    if (gid.x >= (uint)w || gid.y >= (uint)h) return;

    // audio: bass shifts Wolfram rule number
    int   rule   = (params.int_params[0] + int(params.float_params[9] * 64.0f)) & 0xFF;
    float thresh = params.float_params[0];
    float chue   = params.float_params[1];

    // Read three cells from the row above (wrapping)
    int prevY = int(gid.y) > 0 ? int(gid.y) - 1 : h - 1;
    int left, centre, right;
    {
        float4 p = input.read(uint2(clamp(int(gid.x)-1, 0, w-1), prevY));
        left = (dot(p.rgb, float3(0.299f,0.587f,0.114f)) > thresh) ? 1 : 0;
    }
    {
        float4 p = input.read(uint2(clamp(int(gid.x),   0, w-1), prevY));
        centre = (dot(p.rgb, float3(0.299f,0.587f,0.114f)) > thresh) ? 1 : 0;
    }
    {
        float4 p = input.read(uint2(clamp(int(gid.x)+1, 0, w-1), prevY));
        right = (dot(p.rgb, float3(0.299f,0.587f,0.114f)) > thresh) ? 1 : 0;
    }
    int pattern = (left << 2) | (centre << 1) | right;
    int alive   = (rule >> pattern) & 1;

    float4 src = input.read(gid);
    float3 col = alive
        ? hsv_to_rgb(float3(chue, 1.0f, 1.0f))
        : src.rgb * 0.4f;
    output.write(float4(col, src.a), gid);
}

// ── fx_blend ─────────────────────────────────────────────────────────────────
// Linear mix between the pre-FX source and the FX-processed result.
// float_params[0] = blend amount  (0 = full source, 1 = full FX)
// Texture bindings: 0=source (pre-FX), 1=fx (post-FX), 2=output
kernel void fx_blend(
    texture2d<float, access::read>  src    [[texture(0)]],
    texture2d<float, access::read>  fx     [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) return;
    float t = clamp(params.float_params[0], 0.0f, 1.0f);
    output.write(mix(src.read(gid), fx.read(gid), t), gid);
}

// ── readback_rgba8 ───────────────────────────────────────────────────────
// Converts RGBA16Float texture to a packed RGBA8 CPU-readable byte buffer.
// Avoids the Metal restriction that blit copies require matching pixel formats.
kernel void readback_rgba8(
    texture2d<float, access::read> input  [[texture(0)]],
    device uchar*                  output [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = input.get_width(), h = input.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float4 c  = clamp(input.read(gid), 0.0f, 1.0f);
    uint   idx = (gid.y * w + gid.x) * 4;
    output[idx+0] = uchar(c.r * 255.0f + 0.5f);
    output[idx+1] = uchar(c.g * 255.0f + 0.5f);
    output[idx+2] = uchar(c.b * 255.0f + 0.5f);
    output[idx+3] = uchar(c.a * 255.0f + 0.5f);
}

// ── rotate_source ────────────────────────────────────────────────────────────
// Rotates a source texture around its centre by float_params[0] radians.
// Uses bilinear sampling with edge clamp to avoid black borders.
kernel void rotate_source(
    texture2d<float, access::sample> input  [[texture(0)]],
    texture2d<float, access::write>  output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = input.get_width(), h = input.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float angle = params.float_params[0];
    float cosA  = cos(angle);
    float sinA  = sin(angle);
    float cx    = float(w) * 0.5f;
    float cy    = float(h) * 0.5f;

    // Inverse rotation: find which input pixel maps to this output pixel
    float dx   = (float(gid.x) + 0.5f) - cx;
    float dy   = (float(gid.y) + 0.5f) - cy;
    float srcX = cosA * dx + sinA * dy + cx;
    float srcY = -sinA * dx + cosA * dy + cy;

    float2 uv = float2(srcX / float(w), srcY / float(h));
    if (uv.x < 0.0f || uv.x > 1.0f || uv.y < 0.0f || uv.y > 1.0f) {
        output.write(float4(0.0f, 0.0f, 0.0f, 0.0f), gid);
        return;
    }
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_zero);
    output.write(input.sample(s, uv), gid);
}

// ── zoom_source ───────────────────────────────────────────────────────────────
// Zooms a source texture around its centre.
// float_params[0] = zoom factor (1.0 = no change, >1 = zoom in, <1 = zoom out)
// Uses zero clamp to avoid edge-colour streak artifacts when sampling OOB.
kernel void zoom_source(
    texture2d<float, access::sample> input  [[texture(0)]],
    texture2d<float, access::write>  output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = input.get_width(), h = input.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float zoom = params.float_params[0];
    float cx   = float(w) * 0.5f;
    float cy   = float(h) * 0.5f;

    // Inverse mapping: find which input pixel maps to this output pixel
    float srcX = cx + ((float(gid.x) + 0.5f) - cx) / zoom;
    float srcY = cy + ((float(gid.y) + 0.5f) - cy) / zoom;

    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_zero);
    float2 uv = float2(srcX / float(w), srcY / float(h));
    output.write(input.sample(s, uv), gid);
}

// ── crossfade_blend ───────────────────────────────────────────────────────────
// Blends two source textures for layer crossfade transitions.
// texture(0) = old frame, texture(1) = new frame, texture(2) = output
// float_params[0] = blend factor (0.0 = all old, 1.0 = all new)
kernel void crossfade_blend(
    texture2d<float, access::read>  src0   [[texture(0)]],
    texture2d<float, access::read>  src1   [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = src1.get_width(), h = src1.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float t = clamp(params.float_params[0], 0.0f, 1.0f);
    output.write(mix(src0.read(gid), src1.read(gid), t), gid);
}

// ── pan_source ────────────────────────────────────────────────────────────────
// Translates (pans) a source texture by a fractional pixel offset.
// float_params[0] = panX  (-1.0 = max left,  0.0 = centre, +1.0 = max right)
// float_params[1] = panY  (-1.0 = max up,    0.0 = centre, +1.0 = max down)
// float_params[2] = zoom factor used by zoom_source pre-pass
// Pan amount is bounded and zoom-aware to avoid hard out-of-bounds cropping.
kernel void pan_source(
    texture2d<float, access::sample> input  [[texture(0)]],
    texture2d<float, access::write>  output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = input.get_width(), h = input.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float zoom = max(params.float_params[2], 0.001f);

    // Keep pan responsive even at zoom=1 while staying in a conservative range.
    float baseOffset = 0.18f;
    float maxOffsetX = baseOffset / max(zoom, 1.0f);
    float maxOffsetY = baseOffset / max(zoom, 1.0f);

    float panX = clamp(params.float_params[0], -1.0f, 1.0f) * maxOffsetX;
    float panY = clamp(params.float_params[1], -1.0f, 1.0f) * maxOffsetY;

    // Inverse map in normalized UV space.
    float2 uv = (float2(gid) + 0.5f) / float2(w, h);
    float2 srcUV = uv - float2(panX, panY);

    // Hard OOB reject avoids repeating border-line artifacts completely.
    if (srcUV.x < 0.0f || srcUV.x > 1.0f || srcUV.y < 0.0f || srcUV.y > 1.0f) {
        output.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
        return;
    }

    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_zero);
    output.write(input.sample(s, srcUV), gid);
}

// ── lif_network ───────────────────────────────────────────────────────────────
// Leaky Integrate-and-Fire (LIF) neuron network modulating image data.
// Each pixel acts as a LIF neuron driven by local image luminance.
// Topology parameter varies the neighbourhood connectivity pattern from
// purely excitatory local coupling to an inhibitory-surround (Mexican-hat)
// long-range topology, producing distinct spatial activation patterns.
//
// float_params[0] = threshold  (0–1): membrane potential firing threshold
// float_params[1] = topology   (0–1): 0=local excitatory, 1=inhibitory-surround
// float_params[2] = time (animated noise drift)
// float_params[7] = RMS audio  (lowers threshold — audio reactivity)
// float_params[9] = bass band  (modulates topology radius)
kernel void lif_network(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int w = input.get_width(), h = input.get_height();
    if (gid.x >= (uint)w || gid.y >= (uint)h) return;

    // audio: RMS lowers firing threshold (more neurons activate on loud beats)
    float thresh   = max(0.05f, params.float_params[0] - params.float_params[7] * 0.3f);
    float topology = params.float_params[1];
    float t        = params.float_params[2];

    // Connectivity radius: topology 0 → radius 1 (local 3x3),
    //                      topology 1 → radius 8 (long-range)
    // audio: bass band widens radius slightly
    int radius = 1 + int(topology * 7.0f) + int(params.float_params[9] * 2.0f);
    radius = min(radius, 10); // cap to avoid excessive sampling

    float inner_r = float(radius) * 0.5f;

    // Integrate membrane potential from neighbourhood.
    // Mexican-hat weight: topology=0 → pure excitatory (all neighbours +1),
    //                     topology=1 → inhibitory centre, excitatory surround.
    float potential = 0.0f;
    float weight_sum = 0.0f;
    for (int dy = -radius; dy <= radius; ++dy) {
        for (int dx = -radius; dx <= radius; ++dx) {
            float d = sqrt(float(dx*dx + dy*dy));
            if (d > float(radius)) continue;

            float weight;
            if (topology < 0.5f) {
                weight = 1.0f;
            } else {
                // Smooth Mexican-hat: excitatory surround, inhibitory centre
                float t2 = (topology - 0.5f) * 2.0f;
                weight = (d > inner_r) ? 1.0f : -(t2 * 1.5f);
            }

            uint2 pos = uint2(clamp(int(gid.x)+dx, 0, w-1),
                              clamp(int(gid.y)+dy, 0, h-1));
            float lum = dot(input.read(pos).rgb, float3(0.299f, 0.587f, 0.114f));
            potential += lum * weight;
            weight_sum += abs(weight);
        }
    }
    if (weight_sum > 0.0f) potential /= weight_sum;

    // Leaky noise: approximates temporal membrane potential drift
    float drift = snoise(float2(float(gid.x) * 0.012f + t * 0.25f,
                                float(gid.y) * 0.012f + t * 0.18f)) * 0.12f;
    potential = clamp(potential + drift, -1.0f, 1.0f);

    float4 src = input.read(gid);
    float3 result;

    if (potential > thresh) {
        // Neuron fires: colourise by overshoot and topology
        float overshoot = clamp((potential - thresh) / max(1.0f - thresh, 0.001f),
                                0.0f, 1.0f);
        float hue = fmod(topology * 240.0f + overshoot * 90.0f + t * 18.0f, 360.0f);
        float3 actColor = hsv_to_rgb(float3(hue, 0.85f, 1.0f));
        result = mix(src.rgb, actColor, clamp(overshoot * 0.95f, 0.0f, 1.0f));
    } else {
        // Neuron at rest: slight attenuation proportional to sub-threshold gap
        float rest = 1.0f - (thresh - potential) * 0.75f;
        result = src.rgb * clamp(rest, 0.05f, 1.0f);
    }

    output.write(float4(clamp(result, 0.0f, 1.0f), src.a), gid);
}

kernel void lif_step(
    texture2d<float, access::sample> source [[texture(0)]],
    device const float4* prevState [[buffer(0)]],
    device float4* nextState [[buffer(1)]],
    device const float* weights [[buffer(2)]],
    device const float* inputCurrents [[buffer(3)]],
    constant LIFSimParams& sim [[buffer(4)]],
    uint neuronIdx [[thread_position_in_grid]])
{
    if (neuronIdx >= sim.neuronCount) return;

    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);

    uint gx = neuronIdx % sim.gridSize;
    uint gy = neuronIdx / sim.gridSize;
    float2 uv = float2((float(gx) + 0.5f) / float(sim.gridSize),
                       (float(gy) + 0.5f) / float(sim.gridSize));

    float3 src = source.sample(s, uv).rgb;
    float luminance = dot(src, float3(0.299f, 0.587f, 0.114f));
    float noise = snoise(float2(uv.x * 11.0f + sim.timeSeconds * 0.17f,
                                uv.y * 13.0f - sim.timeSeconds * 0.11f)) * 0.04f;

    float4 prev = prevState[neuronIdx];
    float membrane = prev.x;
    float refractoryLeft = max(prev.z - sim.dt, 0.0f);
    float lastSpikeTime = prev.w;

    float synaptic = 0.0f;
    const device float* row = weights + neuronIdx * sim.neuronCount;
    for (uint j = 0; j < sim.neuronCount; ++j)
        synaptic += row[j] * prevState[j].y;

    float threshold = max(0.12f, sim.threshold - sim.rms * 0.12f);
    float drive = inputCurrents[neuronIdx] + luminance * (0.25f + sim.rms * 0.75f) + noise;
    float spike = 0.0f;

    if (refractoryLeft <= 0.0f) {
        membrane = membrane * (1.0f - sim.leak * sim.dt) + (drive + synaptic) * sim.dt;
        membrane = clamp(membrane, 0.0f, 2.0f);
        if (membrane >= threshold) {
            spike = 1.0f;
            membrane = sim.reset;
            refractoryLeft = sim.refractory;
            lastSpikeTime = sim.timeSeconds;
        }
    } else {
        membrane = max(sim.reset, membrane - sim.leak * sim.dt * 0.5f);
    }

    nextState[neuronIdx] = float4(membrane, spike, refractoryLeft, lastSpikeTime);
}

kernel void lif_to_texture(
    device const float4* state [[buffer(0)]],
    texture2d<float, access::write> output [[texture(0)]],
    constant LIFSimParams& sim [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = output.get_width(), h = output.get_height();
    if (gid.x >= w || gid.y >= h) return;

    uint gx = min(uint(float(gid.x) / float(w) * float(sim.gridSize)), sim.gridSize - 1);
    uint gy = min(uint(float(gid.y) / float(h) * float(sim.gridSize)), sim.gridSize - 1);
    uint idx = min(gy * sim.gridSize + gx, sim.neuronCount - 1);
    float4 st = state[idx];

    float membrane = clamp(st.x, 0.0f, 1.0f);
    float spike = clamp(st.y, 0.0f, 1.0f);
    float refractory = clamp(st.z / max(sim.refractory, 0.001f), 0.0f, 1.0f);
    float sinceSpike = clamp(sim.timeSeconds - st.w, 0.0f, 1.0f);
    float hue = fmod(membrane * 220.0f + spike * 90.0f + sim.timeSeconds * 20.0f, 360.0f);
    float3 color = hsv_to_rgb(float3(hue, 0.55f + spike * 0.4f, max(0.15f, membrane + spike * 0.5f)));
    float activity = clamp(0.35f + membrane * 0.55f + spike * 0.6f - refractory * 0.25f, 0.0f, 1.0f);
    output.write(float4(color.r, activity, 1.0f - sinceSpike, 1.0f), gid);
}

kernel void lif_modulate(
    texture2d<float, access::read>  input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    texture2d<float, access::read>  lifState [[texture(2)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = input.get_width(), h = input.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float4 src = input.read(gid);
    float4 lif = lifState.read(gid);
    float influence = clamp(params.float_params[0], 0.0f, 1.0f);
    float field = clamp(lif.g + lif.r * 0.85f, 0.0f, 1.0f);
    float pulse = clamp(field + params.float_params[7] * 0.4f, 0.0f, 1.2f);

    float3 hsv = rgb_to_hsv(src.rgb);
    hsv.x = fmod(hsv.x + lif.b * 120.0f + params.float_params[2] * 14.0f, 360.0f);
    hsv.y = clamp(hsv.y + pulse * 0.18f * influence, 0.0f, 1.0f);
    hsv.z = clamp(hsv.z * (1.0f + pulse * 0.55f * influence), 0.0f, 1.0f);

    float3 modulated = hsv_to_rgb(hsv);
    float mixAmt = clamp(influence * (0.45f + lif.g * 0.35f), 0.0f, 1.0f);
    output.write(float4(mix(src.rgb, modulated, mixAmt), src.a), gid);
}

kernel void lif_replace(
    texture2d<float, access::read>  input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    texture2d<float, access::read>  lifState [[texture(2)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = input.get_width(), h = input.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float4 src = input.read(gid);
    float4 lif = lifState.read(gid);
    float influence = clamp(params.float_params[0], 0.0f, 1.0f);
    float hue = fmod(params.float_params[2] * 24.0f + lif.r * 260.0f + lif.b * 120.0f, 360.0f);
    float value = clamp(0.15f + lif.g * 0.85f + params.float_params[7] * 0.2f, 0.0f, 1.0f);
    float3 neural = hsv_to_rgb(float3(hue, 0.75f + lif.g * 0.2f, value));
    float3 replaced = mix(src.rgb * 0.15f, neural, 0.75f + lif.g * 0.2f);
    output.write(float4(mix(src.rgb, replaced, influence), src.a), gid);
}

// ═══════════════════════════════════════════════════════════════════════════
//  AUX EFFECTS (from src/app/shaders/aux/)
// ═══════════════════════════════════════════════════════════════════════════

// ── Shared helpers used by aux kernels ───────────────────────────────────────

inline uint hash_u(int x, int y, int seed) {
    uint n = uint(seed) + uint(x) * 374761393u + uint(y) * 668265263u;
    n = (n ^ (n >> 13)) * 1274126177u;
    return n ^ (n >> 16);
}
inline float rand01(int x, int y, int seed) {
    return float(hash_u(x, y, seed) & 0x7fffffff) / 2147483647.0f;
}
inline float4 sample_bilinear(texture2d<float, access::read> tex, float2 coord) {
    int2 dims = int2(tex.get_width(), tex.get_height());
    if (coord.x < 0.0f || coord.y < 0.0f || coord.x >= dims.x || coord.y >= dims.y) return float4(0.0);
    int x1 = int(floor(coord.x)); int y1 = int(floor(coord.y));
    int x2 = min(x1 + 1, dims.x - 1); int y2 = min(y1 + 1, dims.y - 1);
    float fx = coord.x - float(x1); float fy = coord.y - float(y1);
    float4 q11 = tex.read(uint2(x1, y1)); float4 q21 = tex.read(uint2(x2, y1));
    float4 q12 = tex.read(uint2(x1, y2)); float4 q22 = tex.read(uint2(x2, y2));
    return mix(mix(q11, q21, fx), mix(q12, q22, fx), fy);
}

// ── grayscale / invert / sepia ───────────────────────────────────────────────
kernel void grayscale(texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;
    float4 p = input.read(gid); float g = 0.299f*p.r + 0.587f*p.g + 0.114f*p.b;
    output.write(float4(g, g, g, p.a), gid);
}
kernel void invert(texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;
    float4 p = input.read(gid); output.write(float4(1.0f - p.rgb, p.a), gid);
}
kernel void sepia(texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;
    float4 p = input.read(gid);
    float r = p.r*0.393f + p.g*0.769f + p.b*0.189f;
    float g = p.r*0.349f + p.g*0.686f + p.b*0.168f;
    float b = p.r*0.272f + p.g*0.534f + p.b*0.131f;
    output.write(clamp(float4(r, g, b, p.a), 0.0f, 1.0f), gid);
}

// ── mirror ───────────────────────────────────────────────────────────────────
kernel void mirror_horizontal(texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;
    output.write(input.read(uint2(input.get_width() - 1 - gid.x, gid.y)), gid);
}
kernel void mirror_vertical(texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;
    output.write(input.read(uint2(gid.x, input.get_height() - 1 - gid.y)), gid);
}

// ── sharpen ──────────────────────────────────────────────────────────────────
kernel void sharpen(texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    int W = input.get_width(), H = input.get_height();
    if (gid.x >= W || gid.y >= H) return;
    float s = params.float_params[0];
    float4 c = input.read(gid);
    float4 sum = c * (1.0f + 4.0f * s);
    int2 p = int2(gid);
    sum += input.read(uint2(clamp(p.x-1,0,W-1), p.y)) * (-s);
    sum += input.read(uint2(clamp(p.x+1,0,W-1), p.y)) * (-s);
    sum += input.read(uint2(p.x, clamp(p.y-1,0,H-1))) * (-s);
    sum += input.read(uint2(p.x, clamp(p.y+1,0,H-1))) * (-s);
    output.write(clamp(sum, 0.0f, 1.0f), gid);
}

// ── gaussian_blur ────────────────────────────────────────────────────────────
kernel void gaussian_blur(texture2d<float, access::read> input_image [[texture(0)]],
    texture2d<float, access::write> output_image [[texture(1)]],
    constant Params& params [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    int W = input_image.get_width(), H = input_image.get_height();
    if (gid.x >= W || gid.y >= H) return;
    int ks = max(1, params.int_params[0]); float sigma = max(0.001f, params.float_params[0]);
    int hs = ks / 2; float denom = 2.0f * sigma * sigma;
    float4 acc = float4(0.0f); float ws = 0.0f;
    for (int y = -hs; y <= hs; ++y) for (int x = -hs; x <= hs; ++x) {
        float w = exp(-float(x*x + y*y) / denom);
        acc += input_image.read(uint2(clamp(int(gid.x)+x,0,W-1), clamp(int(gid.y)+y,0,H-1))) * w;
        ws += w;
    }
    output_image.write(acc / ws, gid);
}

// ── vhs_effect ───────────────────────────────────────────────────────────────
kernel void vhs_effect(texture2d<float, access::read> input_image [[texture(0)]],
    texture2d<float, access::write> output_image [[texture(1)]],
    constant Params& params [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    int W = input_image.get_width(), H = input_image.get_height();
    if (gid.x >= W || gid.y >= H) return;
    float noise_int = clamp(params.float_params[0], 0.0f, 1.0f);
    float distortion = clamp(params.float_params[1], 0.0f, 1.0f);
    float color_bleed = clamp(params.float_params[2], 0.0f, 10.0f);
    int seed = 12345;
    int shift = int(sin(float(gid.y) * 0.1f) * distortion * 10.0f);
    int sx = ((int(gid.x) + shift) % W + W) % W;
    float4 pix = input_image.read(uint2(sx, gid.y));
    if (color_bleed > 0.0f && sx > 0)
        pix = pix * 0.7f + input_image.read(uint2(sx-1, gid.y)) * 0.3f * (color_bleed / 10.0f);
    if (noise_int > 0.0f) {
        pix.r += (rand01(sx, int(gid.y), seed)   - 0.5f) * noise_int * 0.3f;
        pix.g += (rand01(sx, int(gid.y), seed+1) - 0.5f) * noise_int * 0.3f;
        pix.b += (rand01(sx, int(gid.y), seed+2) - 0.5f) * noise_int * 0.3f;
    }
    output_image.write(clamp(pix, 0.0f, 1.0f), gid);
}

// ── psychedelic_colors ───────────────────────────────────────────────────────
kernel void psychedelic_colors(texture2d<float, access::read> input_image [[texture(0)]],
    texture2d<float, access::write> output_image [[texture(1)]],
    constant Params& params [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= input_image.get_width() || gid.y >= input_image.get_height()) return;
    float intensity = clamp(params.float_params[0], 0.0f, 2.0f);
    float wave = sin((float(gid.x) + float(gid.y)) * 0.1f);
    float4 pix = input_image.read(gid);
    float3 hsv = rgb_to_hsv(pix.rgb);
    hsv.x = fract(hsv.x + intensity * 0.5f * wave);
    hsv.y = clamp(hsv.y * (1.0f + intensity), 0.0f, 1.0f);
    hsv.z = clamp(hsv.z * (1.0f + intensity * 0.3f), 0.0f, 1.0f);
    output_image.write(float4(hsv_to_rgb(hsv), pix.a), gid);
}

// ── noise_distortion ─────────────────────────────────────────────────────────
kernel void noise_distortion(texture2d<float, access::read> input_image [[texture(0)]],
    texture2d<float, access::write> output_image [[texture(1)]],
    constant Params& params [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= input_image.get_width() || gid.y >= input_image.get_height()) return;
    float intensity = clamp(params.float_params[0], 0.0f, 100.0f);
    float scale = clamp(params.float_params[1], 0.01f, 1.0f);
    int seed = params.int_params[0];
    float nx = rand01(int(float(gid.x)*scale), int(float(gid.y)*scale), seed);
    float ny = rand01(int(float(gid.x)*scale), int(float(gid.y)*scale), seed+1);
    output_image.write(sample_bilinear(input_image, float2(gid) + (float2(nx, ny) - 0.5f) * intensity), gid);
}

// ── hsv_shift ────────────────────────────────────────────────────────────────
kernel void hsv_shift(texture2d<float, access::read> input_image [[texture(0)]],
    texture2d<float, access::write> output_image [[texture(1)]],
    constant Params& params [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= input_image.get_width() || gid.y >= input_image.get_height()) return;
    float4 pix = input_image.read(gid);
    float3 hsv = rgb_to_hsv(pix.rgb);
    hsv.x = fract(hsv.x + params.float_params[0]);
    hsv.y = clamp(hsv.y * params.float_params[1], 0.0f, 1.0f);
    hsv.z = clamp(hsv.z * params.float_params[2], 0.0f, 1.0f);
    output_image.write(float4(hsv_to_rgb(hsv), pix.a), gid);
}

// ── block_shuffle ────────────────────────────────────────────────────────────
kernel void block_shuffle(texture2d<float, access::read> input_image [[texture(0)]],
    texture2d<float, access::write> output_image [[texture(1)]],
    constant Params& params [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    int W = input_image.get_width(), H = input_image.get_height();
    if (gid.x >= W || gid.y >= H) return;
    int bs = max(4, min(128, params.int_params[0]));
    float intensity = clamp(params.float_params[0], 0.0f, 1.0f);
    int seed = params.int_params[1];
    int bx = int(gid.x)/bs, by = int(gid.y)/bs;
    int bsx = (W+bs-1)/bs, bsy = (H+bs-1)/bs;
    int tbx = bx, tby = by;
    if (rand01(bx, by, seed) <= intensity) {
        tbx = int(rand01(bx, by, seed+1) * bsx) % bsx;
        tby = int(rand01(bx, by, seed+2) * bsy) % bsy;
    }
    int sx = tbx*bs + int(gid.x) - bx*bs;
    int sy = tby*bs + int(gid.y) - by*bs;
    output_image.write((sx < W && sy < H) ? input_image.read(uint2(sx, sy)) : float4(0.0f), gid);
}

// ── rgb_shift_glitch ─────────────────────────────────────────────────────────
kernel void rgb_shift_glitch(texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    int W = input.get_width(), H = input.get_height();
    if (gid.x >= W || gid.y >= H) return;
    float2 off = float2(cos(params.float_params[1]), sin(params.float_params[1])) * params.float_params[0];
    float2 rp = clamp(float2(gid) + off, float2(0), float2(W-1, H-1));
    float2 bp = clamp(float2(gid) - off, float2(0), float2(W-1, H-1));
    float4 rc = input.read(uint2(rp)), gc = input.read(gid), bc = input.read(uint2(bp));
    output.write(float4(rc.r, gc.g, bc.b, gc.a), gid);
}

// ── fisheye ──────────────────────────────────────────────────────────────────
kernel void fisheye(texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    int W = input.get_width(), H = input.get_height();
    if (gid.x >= W || gid.y >= H) return;
    float strength = params.float_params[0];
    float cx = float(W)*0.5f, cy = float(H)*0.5f;
    float radius = min(cx, cy);
    float dx = float(gid.x) - cx, dy = float(gid.y) - cy;
    float dist = sqrt(dx*dx + dy*dy);
    if (dist < radius && dist > 0.0f) {
        float nd = dist / radius;
        float scale = pow(nd, 1.0f + strength) / nd;
        output.write(sample_bilinear(input, float2(cx + dx*scale, cy + dy*scale)), gid);
    } else {
        output.write(dist >= radius ? float4(0.0f) : input.read(gid), gid);
    }
}

// ── echo_trails (needs prev frame texture[2]) ────────────────────────────────
kernel void echo_trails(texture2d<float, access::read> input_image [[texture(0)]],
    texture2d<float, access::write> output_image [[texture(1)]],
    texture2d<float, access::read> prev_image [[texture(2)]],
    constant Params& params [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= input_image.get_width() || gid.y >= input_image.get_height()) return;
    float prev_w = params.float_params[0], curr_w = params.float_params[1];
    if (curr_w <= 0.0f) { prev_w = clamp(prev_w, 0.0f, 1.0f) * 0.3f; curr_w = 0.7f; }
    output_image.write(input_image.read(gid) * curr_w + prev_image.read(gid) * prev_w, gid);
}

// ── datamosh_effect (needs prev frame texture[2]) ────────────────────────────
kernel void datamosh_effect(texture2d<float, access::read> input_image [[texture(0)]],
    texture2d<float, access::write> output_image [[texture(1)]],
    texture2d<float, access::read> prev_image [[texture(2)]],
    constant Params& params [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= input_image.get_width() || gid.y >= input_image.get_height()) return;
    float intensity = clamp(params.float_params[0], 0.0f, 1.0f);
    int bs = max(4, min(32, params.int_params[0]));
    bool use_prev = rand01(int(gid.x)/bs, int(gid.y)/bs, 54321) < intensity;
    output_image.write(use_prev ? prev_image.read(gid) : input_image.read(gid), gid);
}

// ── motion_blur (needs prev frame texture[2]) ────────────────────────────────
kernel void motion_blur(texture2d<float, access::read> input_image [[texture(0)]],
    texture2d<float, access::write> output_image [[texture(1)]],
    texture2d<float, access::read> prev_image [[texture(2)]],
    constant Params& params [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= input_image.get_width() || gid.y >= input_image.get_height()) return;
    float s = clamp(params.float_params[0], 0.0f, 1.0f);
    output_image.write(input_image.read(gid)*(1.0f-s) + prev_image.read(gid)*s, gid);
}

// ── feedback_transform (needs prev frame texture[2]) ────────────────────────
kernel void feedback_transform(texture2d<float, access::read> input_image [[texture(0)]],
    texture2d<float, access::write> output_image [[texture(1)]],
    texture2d<float, access::read> prev_image [[texture(2)]],
    constant Params& params [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    int W = input_image.get_width(), H = input_image.get_height();
    if (gid.x >= W || gid.y >= H) return;
    float mix_ratio = clamp(params.float_params[0], 0.0f, 1.0f);
    float zoom = max(params.float_params[1], 0.001f);
    float angle_rad = params.float_params[2] * 3.14159265f / 180.0f;
    float tx = params.float_params[3], ty = params.float_params[4];
    float cx = float(W)*0.5f, cy = float(H)*0.5f;
    float cos_a = cos(angle_rad), sin_a = sin(angle_rad);
    float dx = float(gid.x) - cx, dy = float(gid.y) - cy;
    float rx = (dx * cos_a - dy * sin_a) / zoom;
    float ry = (dx * sin_a + dy * cos_a) / zoom;
    float4 prev = sample_bilinear(prev_image, float2(cx + rx + tx, cy + ry + ty));
    output_image.write(input_image.read(gid)*(1.0f-mix_ratio) + prev*mix_ratio, gid);
}

