#include "AudioAnalyzer.h"
#import  <AVFoundation/AVFoundation.h>
#include <Accelerate/Accelerate.h>
#include <cmath>
#include <algorithm>
#include <cstring>
#include <iostream>

// ── helpers ───────────────────────────────────────────────────────────────────

// Band frequency edges (Hz), 9 values → 8 intervals
static constexpr float kBandEdges[AudioAnalyzer::NUM_BANDS + 1] = {
    20.f, 60.f, 250.f, 500.f, 2000.f, 4000.f, 6000.f, 12000.f, 20000.f
};

static int freqToBin(float hz, float sampleRate) {
    return static_cast<int>(hz / (sampleRate / AudioAnalyzer::FFT_SIZE));
}

// ── AudioAnalyzer ─────────────────────────────────────────────────────────────

AudioAnalyzer::AudioAnalyzer() {
    ring_.resize(FFT_SIZE * 4, 0.0f);
    fftReal_.resize(FFT_SIZE, 0.0f);
    fftImag_.resize(FFT_SIZE, 0.0f);
    magnitude_.resize(FFT_SIZE / 2, 0.0f);
    window_.resize(FFT_SIZE);

    // Hann window
    vDSP_hann_window(window_.data(), FFT_SIZE, vDSP_HANN_NORM);

    // vDSP FFT setup (log2(2048) = 11)
    fftSetup_ = vDSP_create_fftsetup(11, FFT_RADIX2);
}

AudioAnalyzer::~AudioAnalyzer() {
    stop();
    if (fftSetup_) vDSP_destroy_fftsetup(static_cast<FFTSetup>(fftSetup_));
}

// ── Core Audio AUHAL setup ────────────────────────────────────────────────────

bool AudioAnalyzer::start(int inputDeviceIndex, int outputDeviceIndex) {
    if (running_) return true;

    // Note: AVAudioEngine uses the system default input/output devices.
    // To use specific devices, we would need to use Core Audio AUHAL directly,
    // which is significantly more complex. For now, we accept the parameters
    // for future compatibility but use the system defaults.
    // The output device can be influenced via AVAudioSession on iOS, but
    // on macOS we're limited to system defaults for now.
    (void)inputDeviceIndex;   // Unused for now
    (void)outputDeviceIndex;   // Unused for now

    AVAudioEngine*    engine    = [[AVAudioEngine alloc] init];
    AVAudioInputNode* inputNode = engine.inputNode;
    AVAudioFormat*    fmt       = [inputNode outputFormatForBus:0];

    sampleRate_ = static_cast<float>(fmt.sampleRate);

    // Store engine – manual retain so it survives beyond ARC scope
    auUnit_ = (__bridge_retained void*)engine;

    // ── Player node for passthrough to system output device ──────────────────
    // Direct inputNode→mainMixerNode connection is unreliable when the input
    // and output are different hardware devices (e.g. built-in mic + headphones).
    // Instead we feed captured buffers into an AVAudioPlayerNode.
    AVAudioPlayerNode* player = [[AVAudioPlayerNode alloc] init];
    [engine attachNode:player];
    [engine connect:player to:engine.mainMixerNode format:fmt];
    playerNode_ = (__bridge_retained void*)player;

    // ── Tap: mix down to mono for FFT analysis + schedule buffer for playback ─
    AudioAnalyzer* selfPtr = this;
    [inputNode installTapOnBus:0
                    bufferSize:FFT_SIZE
                        format:fmt
                         block:^(AVAudioPCMBuffer* buf, AVAudioTime* when) {
        if (!buf.floatChannelData || buf.frameLength == 0) return;
        UInt32 nFrames   = buf.frameLength;
        UInt32 nChannels = buf.format.channelCount;
        // Analysis: mix to mono
        std::vector<float> mono(nFrames, 0.0f);
        for (UInt32 c = 0; c < nChannels; ++c) {
            const float* ch = buf.floatChannelData[c];
            for (UInt32 f = 0; f < nFrames; ++f)
                mono[f] += ch[f];
        }
        float inv = 1.0f / static_cast<float>(nChannels);
        for (float& s : mono) s *= inv;
        selfPtr->processBlock(mono.data(), static_cast<int>(nFrames));
        // Passthrough: schedule the original buffer on the player node
        AVAudioPlayerNode* p = (__bridge AVAudioPlayerNode*)selfPtr->playerNode_;
        [p scheduleBuffer:buf completionHandler:nil];
    }];

    NSError* err = nil;
    if (![engine startAndReturnError:&err]) {
        std::cerr << "[Audio] AVAudioEngine start failed: "
                  << (err ? err.localizedDescription.UTF8String : "unknown") << "\n";
        AVAudioEngine* e = (__bridge_transfer AVAudioEngine*)auUnit_;
        (void)e;
        auUnit_ = nullptr;
        return false;
    }

    running_ = true;
    [player play];
    std::cout << "[Audio] Capture + passthrough started ("
              << static_cast<int>(sampleRate_) << " Hz, "
              << fmt.channelCount << "ch)\n";
    return true;
}

void AudioAnalyzer::stop() {
    if (!running_) return;
    running_ = false;
    if (playerNode_) {
        AVAudioPlayerNode* player = (__bridge_transfer AVAudioPlayerNode*)playerNode_;
        playerNode_ = nullptr;
        [player stop];
    }
    if (auUnit_) {
        AVAudioEngine* engine = (__bridge_transfer AVAudioEngine*)auUnit_;
        auUnit_ = nullptr;
        [engine.inputNode removeTapOnBus:0];
        [engine stop];
    }
}

// ── DSP (called from audio thread) ───────────────────────────────────────────

void AudioAnalyzer::processBlock(const float* samples, int count) {
    // Write into ring buffer
    {
        std::lock_guard<std::mutex> lock(ringMutex_);
        for (int i = 0; i < count; ++i) {
            ring_[ringWrite_] = samples[i];
            ringWrite_ = (ringWrite_ + 1) % static_cast<int>(ring_.size());
        }
    }

    // Only run FFT when we have at least FFT_SIZE new samples
    // (simple heuristic: run every callback if count >= 512)
    if (count < 512) return;

    // Grab the most recent FFT_SIZE samples from ring
    std::array<float, FFT_SIZE> block;
    {
        std::lock_guard<std::mutex> lock(ringMutex_);
        int start = (ringWrite_ - FFT_SIZE + static_cast<int>(ring_.size()))
                    % static_cast<int>(ring_.size());
        for (int i = 0; i < FFT_SIZE; ++i)
            block[i] = ring_[(start + i) % static_cast<int>(ring_.size())];
    }
    computeFFT(block.data());
}

void AudioAnalyzer::computeFFT(const float* samples) {
    // Apply Hann window
    std::array<float, FFT_SIZE> windowed;
    vDSP_vmul(samples, 1, window_.data(), 1, windowed.data(), 1, FFT_SIZE);

    // Deinterleave to split-complex
    DSPSplitComplex spc{ fftReal_.data(), fftImag_.data() };
    vDSP_ctoz(reinterpret_cast<const DSPComplex*>(windowed.data()), 2, &spc, 1, FFT_SIZE / 2);

    vDSP_fft_zrip(static_cast<FFTSetup>(fftSetup_), &spc, 1, 11, kFFTDirection_Forward);

    // Compute magnitudes
    vDSP_zvmags(&spc, 1, magnitude_.data(), 1, FFT_SIZE / 2);

    // Normalise magnitudes
    float scale = 1.0f / static_cast<float>(FFT_SIZE);
    vDSP_vsmul(magnitude_.data(), 1, &scale, magnitude_.data(), 1, FFT_SIZE / 2);

    // RMS
    float rms = 0.0f;
    vDSP_rmsqv(samples, 1, &rms, FFT_SIZE);
    rms_.store(std::min(rms * 4.0f, 1.0f), std::memory_order_relaxed);

    // Peak with slow decay
    float newPeak = std::max(rms_.load(), peak_.load() * 0.995f);
    peak_.store(newPeak, std::memory_order_relaxed);

    // Compute 8 band averages
    std::array<float, NUM_BANDS> newBands{};
    const float sm = smoothing;
    {
        std::lock_guard<std::mutex> lock(outMutex_);
        for (int b = 0; b < NUM_BANDS; ++b) {
            int lo = freqToBin(kBandEdges[b],     sampleRate_);
            int hi = std::min(freqToBin(kBandEdges[b + 1], sampleRate_), FFT_SIZE / 2 - 1);
            lo = std::max(lo, 0);
            if (lo >= hi) hi = lo + 1;
            newBands[b] = bandMagnitude(lo, hi);
        }
        for (int b = 0; b < NUM_BANDS; ++b)
            bands_[b] = bands_[b] * sm + newBands[b] * (1.0f - sm);
    }
}

float AudioAnalyzer::bandMagnitude(int binLo, int binHi) const {
    float sum = 0.0f;
    for (int i = binLo; i < binHi && i < static_cast<int>(magnitude_.size()); ++i)
        sum += magnitude_[i];
    float avg = sum / static_cast<float>(std::max(binHi - binLo, 1));
    // Convert to dB-ish log scale and clamp 0-1
    float db = 10.0f * std::log10(avg + 1e-9f);
    return std::clamp((db + 60.0f) / 60.0f, 0.0f, 1.0f);
}

std::array<float, AudioAnalyzer::NUM_BANDS> AudioAnalyzer::bands() const {
    std::lock_guard<std::mutex> lock(outMutex_);
    return bands_;
}
