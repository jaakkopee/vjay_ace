#include "AudioAnalyzer.h"
#include <AudioUnit/AudioUnit.h>
#include <AudioToolbox/AudioToolbox.h>
#include <Accelerate/Accelerate.h>
#include <CoreAudio/CoreAudio.h>
#include <cmath>
#include <algorithm>
#include <cstring>
#include <iostream>
#include <vector>

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

// ── Core Audio device helpers ─────────────────────────────────────────────────

static AudioDeviceID getAudioDeviceAtIndex(AudioObjectPropertyScope scope, int index) {
    // Query ALL devices first
    AudioObjectPropertyAddress propertyAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,  // Use global scope to get all devices
        kAudioObjectPropertyElementMain
    };
    
    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &propertyAddress, 0, NULL, &dataSize);
    if (status != noErr) return kAudioObjectUnknown;
    
    UInt32 deviceCount = dataSize / sizeof(AudioDeviceID);
    std::vector<AudioDeviceID> allDeviceIDs(deviceCount);
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propertyAddress, 0, NULL, &dataSize, allDeviceIDs.data());
    if (status != noErr) return kAudioObjectUnknown;
    
    // Filter by input/output capability
    std::vector<AudioDeviceID> filteredDevices;
    for (AudioDeviceID deviceID : allDeviceIDs) {
        // Check if device has the desired channels (input or output)
        AudioObjectPropertyAddress channelsAddress = {
            kAudioDevicePropertyStreams,
            scope,
            kAudioObjectPropertyElementMain
        };
        UInt32 channelsSize = 0;
        if (AudioObjectGetPropertyDataSize(deviceID, &channelsAddress, 0, NULL, &channelsSize) == noErr && channelsSize > 0) {
            filteredDevices.push_back(deviceID);
        }
    }
    
    if (index < 0 || index >= static_cast<int>(filteredDevices.size())) {
        return kAudioObjectUnknown;
    }
    
    return filteredDevices[index];
}

static std::string getDeviceName(AudioDeviceID deviceID) {
    CFStringRef deviceNameRef = NULL;
    AudioObjectPropertyAddress nameAddress = {
        kAudioDevicePropertyDeviceNameCFString,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 nameSize = sizeof(deviceNameRef);
    
    if (AudioObjectGetPropertyData(deviceID, &nameAddress, 0, NULL, &nameSize, &deviceNameRef) == noErr && deviceNameRef) {
        const char* name = CFStringGetCStringPtr(deviceNameRef, kCFStringEncodingUTF8);
        std::string result = name ? std::string(name) : "unknown";
        CFRelease(deviceNameRef);
        return result;
    }
    return "unknown";
}

// ── Core Audio AUHAL setup ────────────────────────────────────────────────────

bool AudioAnalyzer::start(int inputDeviceIndex, int outputDeviceIndex) {
    if (running_) return true;

    selectedInputDeviceIndex_ = inputDeviceIndex;
    selectedOutputDeviceIndex_ = outputDeviceIndex;

    // Get input device
    AudioDeviceID inputDevice = kAudioObjectUnknown;
    if (inputDeviceIndex >= 0) {
        inputDevice = getAudioDeviceAtIndex(kAudioDevicePropertyScopeInput, inputDeviceIndex);
        if (inputDevice == kAudioObjectUnknown) {
            std::cerr << "[Audio] Input device index " << inputDeviceIndex << " not found\n";
            return false;
        }
        std::cout << "[Audio] Using input device [" << inputDeviceIndex << "]: " << getDeviceName(inputDevice) << "\n";
    } else {
        // Use default input
        AudioObjectPropertyAddress address = {
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        UInt32 size = sizeof(AudioDeviceID);
        if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &inputDevice) != noErr) {
            std::cerr << "[Audio] Could not get default input device\n";
            return false;
        }
        std::cout << "[Audio] Using default input device: " << getDeviceName(inputDevice) << "\n";
    }

    // Get output device
    AudioDeviceID outputDevice = kAudioObjectUnknown;
    if (outputDeviceIndex >= 0) {
        outputDevice = getAudioDeviceAtIndex(kAudioDevicePropertyScopeOutput, outputDeviceIndex);
        if (outputDevice == kAudioObjectUnknown) {
            std::cerr << "[Audio] Output device index " << outputDeviceIndex << " not found\n";
            return false;
        }
        std::cout << "[Audio] Using output device: " << getDeviceName(outputDevice) << "\n";
    } else {
        // Use default output
        AudioObjectPropertyAddress address = {
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        UInt32 size = sizeof(AudioDeviceID);
        if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &outputDevice) != noErr) {
            std::cerr << "[Audio] Could not get default output device\n";
            return false;
        }
        std::cout << "[Audio] Using default output device: " << getDeviceName(outputDevice) << "\n";
    }

    // Create input unit
    AudioComponentDescription inputDesc{};
    inputDesc.componentType = kAudioUnitType_Output;
    inputDesc.componentSubType = kAudioUnitSubType_HALOutput;
    inputDesc.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    AudioComponent inputComp = AudioComponentFindNext(NULL, &inputDesc);
    if (!inputComp) {
        std::cerr << "[Audio] Could not find HAL input component\n";
        return false;
    }
    
    AudioUnit inputUnit;
    if (AudioComponentInstanceNew(inputComp, &inputUnit) != noErr) {
        std::cerr << "[Audio] Could not create input unit\n";
        return false;
    }
    inputUnit_ = inputUnit;

    // Enable output I/O on the output element (bus 0) - required for AudioUnitRender to work
    UInt32 enableOutput = 1;
    if (AudioUnitSetProperty(inputUnit, kAudioOutputUnitProperty_EnableIO,
                              kAudioUnitScope_Output, 0, &enableOutput, sizeof(enableOutput)) != noErr) {
        std::cerr << "[Audio] Could not enable output I/O\n";
        AudioComponentInstanceDispose(inputUnit);
        inputUnit_ = nullptr;
        return false;
    }

    // Enable input I/O on the input element (bus 1)
    UInt32 enableInput = 1;
    OSStatus status = AudioUnitSetProperty(inputUnit, kAudioOutputUnitProperty_EnableIO,
                              kAudioUnitScope_Input, 1, &enableInput, sizeof(enableInput));
    if (status != noErr) {
        std::cerr << "[Audio] Could not enable input I/O (status=" << status << ")\n";
        AudioComponentInstanceDispose(inputUnit);
        inputUnit_ = nullptr;
        return false;
    }

    // Get format from input device  
    AudioStreamBasicDescription asbd{};
    UInt32 size = sizeof(asbd);
    if (AudioUnitGetProperty(inputUnit, kAudioUnitProperty_StreamFormat,
                              kAudioUnitScope_Output, 1, &asbd, &size) != noErr) {
        std::cerr << "[Audio] Could not get input stream format\n";
        AudioComponentInstanceDispose(inputUnit);
        inputUnit_ = nullptr;
        return false;
    }
    
    sampleRate_ = asbd.mSampleRate;
    
    // Set the output bus format to match the input (required for AudioUnitRender to work)
    if (AudioUnitSetProperty(inputUnit, kAudioUnitProperty_StreamFormat,
                              kAudioUnitScope_Input, 0, &asbd, sizeof(asbd)) != noErr) {
        std::cerr << "[Audio] Could not set output stream format\n";
        AudioComponentInstanceDispose(inputUnit);
        inputUnit_ = nullptr;
        return false;
    }
    
    // Initialize input unit (no callback, we'll use a thread to pull data)
    if (AudioUnitInitialize(inputUnit) != noErr) {
        std::cerr << "[Audio] Could not initialize input unit\n";
        AudioComponentInstanceDispose(inputUnit);
        inputUnit_ = nullptr;
        return false;
    }

    // Start input unit
    if (AudioOutputUnitStart(inputUnit) != noErr) {
        std::cerr << "[Audio] Could not start input unit\n";
        AudioUnitUninitialize(inputUnit);
        AudioComponentInstanceDispose(inputUnit);
        inputUnit_ = nullptr;
        return false;
    }

    running_ = true;
    
    // Start the audio processing thread
    processingThread_ = std::thread(&AudioAnalyzer::audioProcessingThreadRun, this);
    
    std::cout << "[Audio] Capture started (" << static_cast<int>(sampleRate_) << " Hz)\n";
    return true;
}

void AudioAnalyzer::stop() {
    if (!running_) return;
    running_ = false;
    
    // Wait for processing thread to finish
    if (processingThread_.joinable()) {
        processingThread_.join();
    }
    
    if (inputUnit_) {
        AudioUnit inputUnit = static_cast<AudioUnit>(inputUnit_);
        AudioOutputUnitStop(inputUnit);
        AudioUnitUninitialize(inputUnit);
        AudioComponentInstanceDispose(inputUnit);
        inputUnit_ = nullptr;
    }
}

// ── Audio Processing Thread ──────────────────────────────────────────────────

void AudioAnalyzer::audioProcessingThreadRun() {
    // Allocate buffer for pulling audio data
    const int bufferSize = 4096;
    float* audioData = new float[bufferSize]{};
    
    AudioBufferList bufferList;
    bufferList.mNumberBuffers = 1;
    bufferList.mBuffers[0].mNumberChannels = 1;
    bufferList.mBuffers[0].mDataByteSize = bufferSize * sizeof(float);
    bufferList.mBuffers[0].mData = audioData;
    
    std::cout << "[Audio] Processing thread started\n";
    
    while (running_) {
        // Pull audio data from the HAL input unit
        AudioUnit inputUnit = static_cast<AudioUnit>(inputUnit_);
        AudioTimeStamp timeStamp{};
        AudioUnitRenderActionFlags flags = 0;
        
        // AudioUnitRender on input bus (bus 1) to get captured data
        OSStatus status = AudioUnitRender(inputUnit, &flags, &timeStamp, 1, bufferSize, &bufferList);
        if (status == noErr && bufferList.mNumberBuffers > 0) {
            float* buffer = static_cast<float*>(bufferList.mBuffers[0].mData);
            processBlock(buffer, bufferSize);
        } else if (status != noErr && status != -10874) {  // -10874 is expected initially
            std::cerr << "[Audio] AudioUnitRender failed: " << status << "\n";
            break;
        }
        
        // Small sleep to prevent excessive CPU usage
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    
    delete[] audioData;
    std::cout << "[Audio] Processing thread stopped\n";
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
