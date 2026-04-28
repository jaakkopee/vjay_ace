#include "VideoDecoder.h"
#include <algorithm>
#include <cstring>
#include <iostream>
#include <fstream>
#include <filesystem>

namespace fs = std::filesystem;

// ── Image sequence helper ─────────────────────────────────────────────────────
// Scans a directory for images (sorted), writes an ffconcat file so the total
// loop duration equals targetDuration seconds. outFps receives computed fps.
// Returns empty string on failure.
static std::string buildConcatFile(const std::string& dir, float targetDuration, float& outFps) {
    static const std::vector<std::string> imgExts = {".png", ".jpg", ".jpeg", ".bmp", ".tiff", ".tif"};
    std::vector<std::string> files;
    for (auto& entry : fs::directory_iterator(dir)) {
        if (!entry.is_regular_file()) continue;
        std::string ext = entry.path().extension().string();
        std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
        for (const auto& e : imgExts)
            if (ext == e) { files.push_back(entry.path().string()); break; }
    }
    if (files.empty()) return "";
    std::sort(files.begin(), files.end());

    // Compute fps so that all frames together fill targetDuration seconds.
    outFps = static_cast<float>(files.size()) / targetDuration;
    float frameDuration = targetDuration / static_cast<float>(files.size());

    std::string concatPath = dir + "/.vjay_seq.ffconcat";
    std::ofstream f(concatPath);
    if (!f) return "";
    f << "ffconcat version 1.0\n";
    for (const auto& file : files) {
        f << "file '" << file << "'\n";
        f << "duration " << frameDuration << "\n";
    }
    // Repeat first file at end (duration 0) to avoid last-frame hang before loop
    f << "file '" << files[0] << "'\n";
    f << "duration 0\n";
    return concatPath;
}

VideoDecoder::VideoDecoder() = default;

VideoDecoder::~VideoDecoder() { close(); }

bool VideoDecoder::open(const std::string& path, int outW, int outH) {
    close();
    outW_ = outW; outH_ = outH;

    // If path is a directory, build an ffconcat image sequence file.
    std::string openPath = path;
    if (fs::is_directory(path)) {
        float computedFps = 1.0f;
        concatFilePath_ = buildConcatFile(path, 30.0f, computedFps);
        if (concatFilePath_.empty()) {
            std::cerr << "[VideoDecoder] No images found in folder: " << path << "\n";
            return false;
        }
        seqFps_ = computedFps;
        seqFrameAccum_ = 0.0f;
        openPath = concatFilePath_;
        const AVInputFormat* concatFmt = av_find_input_format("concat");
        AVDictionary* opts = nullptr;
        av_dict_set(&opts, "safe", "0", 0);
        if (avformat_open_input(&fmtCtx_, openPath.c_str(), concatFmt, &opts) < 0) {
            av_dict_free(&opts);
            std::cerr << "[VideoDecoder] Cannot open concat sequence: " << openPath << "\n";
            return false;
        }
        av_dict_free(&opts);
    } else {
        if (avformat_open_input(&fmtCtx_, openPath.c_str(), nullptr, nullptr) < 0) {
            std::cerr << "[VideoDecoder] Cannot open: " << path << "\n";
            return false;
        }
    }
    if (avformat_find_stream_info(fmtCtx_, nullptr) < 0) {
        close(); return false;
    }
    streamIdx_ = av_find_best_stream(fmtCtx_, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (streamIdx_ < 0) { close(); return false; }

    AVStream* stream = fmtCtx_->streams[streamIdx_];
    const AVCodec* codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) { close(); return false; }

    codecCtx_ = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(codecCtx_, stream->codecpar);
    if (avcodec_open2(codecCtx_, codec, nullptr) < 0) { close(); return false; }

    // Map deprecated "yuvj*" full-range formats to their standard equivalents
    // and record whether the source is full-range so we can tell swscale.
    AVPixelFormat srcFmt   = codecCtx_->pix_fmt;
    bool          fullRange = false;
    switch (srcFmt) {
        case AV_PIX_FMT_YUVJ420P:  srcFmt = AV_PIX_FMT_YUV420P;  fullRange = true; break;
        case AV_PIX_FMT_YUVJ422P:  srcFmt = AV_PIX_FMT_YUV422P;  fullRange = true; break;
        case AV_PIX_FMT_YUVJ444P:  srcFmt = AV_PIX_FMT_YUV444P;  fullRange = true; break;
        case AV_PIX_FMT_YUVJ440P:  srcFmt = AV_PIX_FMT_YUV440P;  fullRange = true; break;
        case AV_PIX_FMT_YUVJ411P:  srcFmt = AV_PIX_FMT_YUV411P;  fullRange = true; break;
        default: break;
    }

    // Aspect-fit into outW_ x outH_ (preserve whole frame, letterbox if needed).
    {
        float srcAR = float(codecCtx_->width) / float(codecCtx_->height);
        float dstAR = float(outW_) / float(outH_);
        if (srcAR > dstAR) { // wider than output: match width, letterbox top/bottom
            scaledW_ = outW_;
            scaledH_ = int(outW_ / srcAR + 0.5f);
        } else {             // taller than output: match height, pillarbox left/right
            scaledH_ = outH_;
            scaledW_ = int(outH_ * srcAR + 0.5f);
        }
        // Keep dimensions even (some codecs require it)
        scaledW_ = std::min(outW_, std::max(2, scaledW_ & ~1));
        scaledH_ = std::min(outH_, std::max(2, scaledH_ & ~1));
        padX_ = std::max(0, (outW_ - scaledW_) / 2);
        padY_ = std::max(0, (outH_ - scaledH_) / 2);
    }

    swsCtx_ = sws_getContext(
        codecCtx_->width, codecCtx_->height, srcFmt,
        scaledW_, scaledH_, AV_PIX_FMT_RGBA,
        SWS_BILINEAR, nullptr, nullptr, nullptr);
    if (!swsCtx_) { close(); return false; }

    // Set input/output colour range so swscale doesn't guess (and warn).
    int srcRange = fullRange ? 1 : 0;
    int dstRange = 1;
    sws_setColorspaceDetails(swsCtx_,
        sws_getCoefficients(SWS_CS_DEFAULT), srcRange,
        sws_getCoefficients(SWS_CS_DEFAULT), dstRange,
        0, 1 << 16, 1 << 16);

    frame_     = av_frame_alloc();
    rgbaFrame_ = av_frame_alloc();
    packet_    = av_packet_alloc();

    rgbaFrame_->format = AV_PIX_FMT_RGBA;
    rgbaFrame_->width  = scaledW_;
    rgbaFrame_->height = scaledH_;
    av_image_alloc(rgbaFrame_->data, rgbaFrame_->linesize,
                   scaledW_, scaledH_, AV_PIX_FMT_RGBA, 32);

    return true;
}

bool VideoDecoder::nextFrame(std::vector<uint8_t>& outRGBA, float deltaTime) {
    if (!fmtCtx_) return false;

    // Static image: return cached pixels without re-decoding.
    if (isStatic_ && hasCached_) {
        outRGBA = pixelCache_;
        return true;
    }

    // Image sequence fps throttle: only advance when enough time has elapsed.
    if (seqFps_ > 0.0f && hasCached_) {
        seqFrameAccum_ += deltaTime;
        if (seqFrameAccum_ < 1.0f / seqFps_) {
            outRGBA = pixelCache_;
            return true;
        }
        seqFrameAccum_ -= 1.0f / seqFps_;
    }

    // Loop guard: avoid spinning forever on broken/unseekable streams.
    int attempts = 0;
    constexpr int MAX_ATTEMPTS = 256;

    while (attempts++ < MAX_ATTEMPTS) {
        int ret = av_read_frame(fmtCtx_, packet_);
        if (ret == AVERROR_EOF) {
            if (!hasCached_) {
                // No frame decoded at all — give up.
                if (!seekToStart()) return false;
                continue;
            }
            // Loop all media types (videos, concat sequences, etc.) by seeking.
            if (seekToStart()) {
                avcodec_flush_buffers(codecCtx_);
                continue;
            }
            // Seek failed — return last cached frame.
            outRGBA = pixelCache_;
            return true;
        }
        if (ret < 0) return false;
        if (packet_->stream_index != streamIdx_) {
            av_packet_unref(packet_);
            continue;
        }
        avcodec_send_packet(codecCtx_, packet_);
        av_packet_unref(packet_);

        ret = avcodec_receive_frame(codecCtx_, frame_);
        if (ret == AVERROR(EAGAIN)) continue;
        if (ret < 0) return false;

        // Scale to aspect-fit RGBA dimensions.
        sws_scale(swsCtx_,
                  frame_->data, frame_->linesize, 0, codecCtx_->height,
                  rgbaFrame_->data, rgbaFrame_->linesize);
        av_frame_unref(frame_);

        // Composite scaled frame into output with letterbox/pillarbox as needed.
        std::size_t byteCount = outW_ * outH_ * 4;
        outRGBA.assign(byteCount, 0);
        const uint8_t* src = rgbaFrame_->data[0];
        int srcStride = rgbaFrame_->linesize[0];
        for (int row = 0; row < scaledH_; ++row) {
            const uint8_t* srcRow = src + row * srcStride;
            uint8_t* dst = outRGBA.data() + ((padY_ + row) * outW_ + padX_) * 4;
            std::memcpy(dst, srcRow, scaledW_ * 4);
        }

        // Cache for potential static re-use
        pixelCache_ = outRGBA;
        hasCached_  = true;
        return true;
    }

    // Gave up — return cached frame if available.
    if (hasCached_) { outRGBA = pixelCache_; return true; }
    return false;
}

bool VideoDecoder::seekToStart() {
    return av_seek_frame(fmtCtx_, streamIdx_, 0, AVSEEK_FLAG_BACKWARD) >= 0;
}

void VideoDecoder::close() {
    if (swsCtx_)   { sws_freeContext(swsCtx_); swsCtx_ = nullptr; }
    if (frame_)    { av_frame_free(&frame_); }
    if (rgbaFrame_){
        if (rgbaFrame_->data[0]) av_freep(&rgbaFrame_->data[0]);
        av_frame_free(&rgbaFrame_);
    }
    if (packet_)   { av_packet_free(&packet_); }
    if (codecCtx_) { avcodec_free_context(&codecCtx_); }
    if (fmtCtx_)   { avformat_close_input(&fmtCtx_); }
    streamIdx_ = -1;
    isStatic_  = false;
    hasCached_ = false;
    pixelCache_.clear();
    seqFps_        = 0.0f;
    seqFrameAccum_ = 0.0f;
    if (!concatFilePath_.empty()) {
        std::remove(concatFilePath_.c_str());
        concatFilePath_.clear();
    }
}
