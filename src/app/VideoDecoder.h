#pragma once
#include <string>
#include <vector>
#include <cstdint>
#include <filesystem>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
}

// ── VideoDecoder ─────────────────────────────────────────────────────────────
// Wraps FFmpeg to decode a video or image file frame-by-frame.
// Output is always RGBA8 at the requested width/height.
// Source is scaled with aspect-fit and centred (letterbox/pillarbox as needed).

class VideoDecoder {
public:
    VideoDecoder();
    ~VideoDecoder();

    // Open file. Returns false on error.
    bool open(const std::string& path, int outW, int outH);

    // Decode the next frame into outRGBA (sized outW*outH*4).
    // Loops back to start at EOF.
    // Returns false if no frame was available yet.
    // deltaTime: seconds elapsed since last call (used for fps-throttled sequences).
    bool nextFrame(std::vector<uint8_t>& outRGBA, float deltaTime = 1.0f / 60.0f);

    bool isOpen() const { return fmtCtx_ != nullptr; }

private:
    AVFormatContext* fmtCtx_   = nullptr;
    AVCodecContext*  codecCtx_ = nullptr;
    SwsContext*      swsCtx_   = nullptr;
    AVFrame*         frame_    = nullptr;
    AVFrame*         rgbaFrame_= nullptr;
    AVPacket*        packet_   = nullptr;
    int              streamIdx_= -1;
    int              outW_     = 0;
    int              outH_     = 0;
    // Aspect-fit intermediate size and output placement origin.
    int              scaledW_  = 0;
    int              scaledH_  = 0;
    int              padX_     = 0;
    int              padY_     = 0;

    void close();
    bool seekToStart();

    bool isStatic_  = false;          // true after first EOF — single-frame file
    bool hasCached_ = false;          // true once pixelCache_ holds a valid frame
    std::vector<uint8_t> pixelCache_; // decoded RGBA pixels for static images
    std::string concatFilePath_;      // temp ffconcat file path for image sequences (deleted on close)
    float seqFps_         = 0.0f;     // fps for image sequence (0 = no throttle)
    float seqFrameAccum_  = 0.0f;     // accumulated time waiting for next frame
};
