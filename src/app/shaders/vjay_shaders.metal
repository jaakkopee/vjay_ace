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
    int bs = max(1, params.int_params[0]);
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
    float  speed  = params.float_params[0];
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
    float blend = params.float_params[2];

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
    float decay = clamp(params.float_params[1], 0.0f, 0.9999f);
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
    texture2d<float, access::sample> input  [[texture(0)]],
    texture2d<float, access::write>  output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = input.get_width(), h = input.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float zoom  = params.float_params[0];
    float rot   = params.float_params[1];
    float mix_  = params.float_params[2];
    float hue   = params.float_params[3];

    float cx = float(w) * 0.5f, cy = float(h) * 0.5f;
    float dx = float(gid.x) - cx, dy = float(gid.y) - cy;
    // Inverse: where in the input does this output pixel come from?
    float cosR = cos(rot), sinR = sin(rot);
    float srcX = (cosR * dx + sinR * dy) / zoom + cx;
    float srcY = (-sinR * dx + cosR * dy) / zoom + cy;

    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float4 feedback = input.sample(s, float2(srcX / float(w), srcY / float(h)));

    // Colour tint the feedback
    float3 hsv = rgb_to_hsv(feedback.rgb);
    hsv.x = fmod(hsv.x + hue * 0.5f, 360.0f);
    feedback.rgb = hsv_to_rgb(hsv);

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

    int cols  = max(4, params.int_params[0]);
    float rs  = params.float_params[0];
    float hoff= params.float_params[1];

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

    if (dist <= radius) {
        float3 hsv = rgb_to_hsv(samp.rgb);
        hsv.x = fmod(hsv.x + hoff, 360.0f);
        hsv.y = min(1.0f, hsv.y + 0.2f);
        output.write(float4(hsv_to_rgb(hsv), samp.a), gid);
    } else {
        output.write(float4(0.05f, 0.05f, 0.08f, 1.0f), gid); // dark bg
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
    float hbase  = params.float_params[2];

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

    int   rule   = params.int_params[0] & 0xFF;
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
