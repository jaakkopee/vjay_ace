#include <metal_stdlib>
using namespace metal;

struct Params {
    int int_params[16];
    float float_params[16];
};

// Chromatic aberration effect
kernel void chromatic_aberration(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int width = input.get_width();
    int height = input.get_height();
    
    if (gid.x >= width || gid.y >= height) {
        return;
    }
    
    int offset = params.int_params[0];
    int2 pos = int2(gid);
    
    // Sample red channel with negative offset
    int2 r_pos = pos;
    r_pos.x = clamp(r_pos.x - offset, 0, width - 1);
    float r = input.read(uint2(r_pos)).r;
    
    // Sample green channel at original position
    float g = input.read(gid).g;
    
    // Sample blue channel with positive offset
    int2 b_pos = pos;
    b_pos.x = clamp(b_pos.x + offset, 0, width - 1);
    float b = input.read(uint2(b_pos)).b;
    
    float4 pixel = float4(r, g, b, input.read(gid).a);
    
    output.write(pixel, gid);
}
