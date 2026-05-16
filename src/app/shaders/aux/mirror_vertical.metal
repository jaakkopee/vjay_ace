#include <metal_stdlib>
using namespace metal;

kernel void mirror_vertical(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) {
        return;
    }

    uint2 flipped = uint2(gid.x, input.get_height() - 1 - gid.y);
    output.write(input.read(flipped), gid);
}
