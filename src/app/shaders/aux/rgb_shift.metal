#include <metal_stdlib>
using namespace metal;

struct Params {
    int int_params[16];
    float float_params[16];
};

kernel void rgb_shift_glitch(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;

    float shift_amount = params.float_params[0];
    float angle = params.float_params[1];

    float2 uv = float2(gid);
    int width = input.get_width();
    int height = input.get_height();

    // Offset in pixels
    float2 offset = float2(cos(angle), sin(angle)) * shift_amount;

    // Calculate sample coords
    float2 r_pos = uv + offset;
    float2 g_pos = uv;
    float2 b_pos = uv - offset;

    // Clamp sample positions
    r_pos.x = clamp(r_pos.x, 0.0f, width - 1.0f);
    r_pos.y = clamp(r_pos.y, 0.0f, height - 1.0f);
    g_pos.x = clamp(g_pos.x, 0.0f, width - 1.0f);
    g_pos.y = clamp(g_pos.y, 0.0f, height - 1.0f);
    b_pos.x = clamp(b_pos.x, 0.0f, width - 1.0f);
    b_pos.y = clamp(b_pos.y, 0.0f, height - 1.0f);

    float4 r_sample = input.read(uint2(r_pos));
    float4 g_sample = input.read(uint2(g_pos));
    float4 b_sample = input.read(uint2(b_pos));

    float a = g_sample.a; // use green channel alpha for output alpha
    float3 result = float3(r_sample.r, g_sample.g, b_sample.b);

    output.write(float4(result, a), gid);
}
