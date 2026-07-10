#include <metal_stdlib>
using namespace metal;

struct Params {
    int int_params[16];
    float float_params[16];
};

kernel void pixelate(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant Params& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) {
        return;
    }

    int pixel_size = max(1, params.int_params[0]);
    int width = input.get_width();
    int height = input.get_height();

    // Optimized: for large pixel sizes, use subsampling to reduce texture reads
    int2 block_start = int2((gid.x / pixel_size) * pixel_size,
                            (gid.y / pixel_size) * pixel_size);
    int x_end = min(block_start.x + pixel_size, width);
    int y_end = min(block_start.y + pixel_size, height);

    float4 sum = float4(0.0);
    int count = 0;
    
    // For very large blocks (>16px), subsample to avoid excessive texture reads
    int step = (pixel_size > 16) ? (pixel_size / 4) : 1;
    
    for (int by = block_start.y; by < y_end; by += step) {
        for (int bx = block_start.x; bx < x_end; bx += step) {
            sum += input.read(uint2(bx, by));
            count++;
        }
    }
    float4 avg = sum / float(max(1, count));
    output.write(avg, gid);
}
