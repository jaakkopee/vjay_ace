#include <metal_stdlib>
using namespace metal;

struct Params { int int_params[16]; float float_params[16]; };

// texture(0): current frame, texture(1): output, texture(2): previous frame
kernel void echo_trails(texture2d<float, access::read> input_image [[texture(0)]],
                        texture2d<float, access::write> output_image [[texture(1)]],
                        texture2d<float, access::read> prev_image [[texture(2)]],
                        constant Params& params [[ buffer(0) ]],
                        uint2 gid [[thread_position_in_grid]]) {
    int width = input_image.get_width();
    int height = input_image.get_height();
    if (gid.x >= width || gid.y >= height) return;

    float prev_weight = params.float_params[0];
    float curr_weight = params.float_params[1];
    
    // Backward compatibility: if curr_weight isn't provided, interpret float_params[0] as decay.
    if (curr_weight <= 0.0f) {
        float decay = clamp(prev_weight, 0.0f, 1.0f);
        prev_weight = decay * 0.3f;
        curr_weight = 0.7f;
    }

    float4 current = input_image.read(gid);
    float4 previous = prev_image.read(gid);

    float4 blended = current * curr_weight + previous * prev_weight;
    output_image.write(blended, gid);
}
