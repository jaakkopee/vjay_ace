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
    int ks = max(1, params.int_params[0]);
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
    int off = params.int_params[0];
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
    float shift = (params.float_params[1] + pos) * params.float_params[0] * 360.0f;
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
    float dstr = params.float_params[1];
    float istr = params.float_params[2];
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
    float rot = params.float_params[0];
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
    float amp  = params.float_params[0];
    float freq = params.float_params[1];
    float phase= params.float_params[2];
    float2 uv  = float2(gid) / float2(w, h);
    float dx   = amp * sin(uv.y * float(w) * freq + phase);
    float dy   = amp * sin(uv.x * float(h) * freq + phase * 1.3f);
    int2 src   = int2(clamp(int(gid.x) + int(dx), 0, w-1),
                      clamp(int(gid.y) + int(dy), 0, h-1));
    output.write(input.read(uint2(src)), gid);
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
    float mag   = sqrt(gx*gx + gy*gy) * params.float_params[1];
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
// Uses bilinear sampling; pixels outside the rotated area become transparent black.
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
    float dx   = float(gid.x) - cx;
    float dy   = float(gid.y) - cy;
    float srcX = cosA * dx + sinA * dy + cx;
    float srcY = -sinA * dx + cosA * dy + cy;

    if (srcX < 0.0f || srcX >= float(w) || srcY < 0.0f || srcY >= float(h)) {
        output.write(float4(0.0f), gid);
        return;
    }

    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_zero);
    float2 uv = float2(srcX / float(w), srcY / float(h));
    output.write(input.sample(s, uv), gid);
}

// ── zoom_source ───────────────────────────────────────────────────────────────
// Zooms a source texture around its centre.
// float_params[0] = zoom factor (1.0 = no change, >1 = zoom in, <1 = zoom out)
// Pixels outside the source area are transparent black.
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
    float srcX = cx + (float(gid.x) - cx) / zoom;
    float srcY = cy + (float(gid.y) - cy) / zoom;

    if (srcX < 0.0f || srcX >= float(w) || srcY < 0.0f || srcY >= float(h)) {
        output.write(float4(0.0f), gid);
        return;
    }

    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_zero);
    float2 uv = float2(srcX / float(w), srcY / float(h));
    output.write(input.sample(s, uv), gid);
}
