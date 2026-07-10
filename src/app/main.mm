#include "App.h"
#include "MidiRouter.h"
#include "StartupOptions.h"
#import  <Cocoa/Cocoa.h>
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <iostream>
#include <iomanip>
#include <string>
#include <vector>

// ── Audio device enumeration ──────────────────────────────────────────────────

static std::vector<std::string> getAudioDeviceNames(AudioObjectPropertyScope scope) {
    std::vector<std::string> names;
    
    AudioObjectPropertyAddress propertyAddress = {
        kAudioHardwarePropertyDevices,
        scope,
        kAudioObjectPropertyElementMain
    };
    
    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &propertyAddress, 0, NULL, &dataSize);
    if (status != noErr) return names;
    
    UInt32 deviceCount = dataSize / sizeof(AudioDeviceID);
    std::vector<AudioDeviceID> deviceIDs(deviceCount);
    
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propertyAddress, 0, NULL, &dataSize, deviceIDs.data());
    if (status != noErr) return names;
    
    for (AudioDeviceID deviceID : deviceIDs) {
        CFStringRef deviceNameRef = NULL;
        UInt32 nameSize = sizeof(deviceNameRef);
        
        AudioObjectPropertyAddress nameAddress = {
            kAudioDevicePropertyDeviceNameCFString,
            scope,
            kAudioObjectPropertyElementMain
        };
        
        status = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, NULL, &nameSize, &deviceNameRef);
        if (status == noErr && deviceNameRef != NULL) {
            const char* deviceName = CFStringGetCStringPtr(deviceNameRef, kCFStringEncodingUTF8);
            if (deviceName) {
                names.push_back(deviceName);
            }
            CFRelease(deviceNameRef);
        }
    }
    
    return names;
}

static void listAudioDevices() {
    auto inputDevices = getAudioDeviceNames(kAudioDevicePropertyScopeInput);
    auto outputDevices = getAudioDeviceNames(kAudioDevicePropertyScopeOutput);
    
    std::cout << "\n╭─ Audio Input Devices ─────────────────────────────────────\n";
    
    if (inputDevices.empty()) {
        std::cout << "│  (none available)\n";
    } else {
        for (size_t i = 0; i < inputDevices.size(); ++i) {
            std::cout << "│  [" << i << "] " << inputDevices[i] << "\n";
        }
    }
    
    std::cout << "╰─────────────────────────────────────────────────────────────\n";
    
    std::cout << "\n╭─ Audio Output Devices ────────────────────────────────────\n";
    
    if (outputDevices.empty()) {
        std::cout << "│  (none available)\n";
    } else {
        for (size_t i = 0; i < outputDevices.size(); ++i) {
            std::cout << "│  [" << i << "] " << outputDevices[i] << "\n";
        }
    }
    
    std::cout << "╰─────────────────────────────────────────────────────────────\n";
}

// ── MIDI device enumeration ───────────────────────────────────────────────────

static void listMidiDevices() {
    MidiRouter router;
    
    auto inPorts = router.portNames();
    auto outPorts = router.outputPortNames();
    
    std::cout << "\n╭─ MIDI Input Devices ──────────────────────────────────────\n";
    if (inPorts.empty()) {
        std::cout << "│  (none available)\n";
    } else {
        for (size_t i = 0; i < inPorts.size(); ++i) {
            std::cout << "│  [" << i << "] " << inPorts[i] << "\n";
        }
    }
    std::cout << "╰─────────────────────────────────────────────────────────────\n";
    
    std::cout << "\n╭─ MIDI Output Devices ─────────────────────────────────────\n";
    if (outPorts.empty()) {
        std::cout << "│  (none available)\n";
    } else {
        for (size_t i = 0; i < outPorts.size(); ++i) {
            std::cout << "│  [" << i << "] " << outPorts[i] << "\n";
        }
    }
    std::cout << "╰─────────────────────────────────────────────────────────────\n";
}

int main(int argc, char** argv) {
    StartupOptions opts;
    std::string parseError;
    if (!parseStartupOptions(argc, argv, opts, parseError)) {
        std::cerr << "[main] " << parseError << "\n";
        printStartupHelp(std::cerr);
        return 2;
    }

    if (opts.showHelp) {
        printStartupHelp(std::cout);
        return 0;
    }
    if (opts.listDevices) {
        std::cout << "\nvjay_ace Device List\n";
        listAudioDevices();
        listMidiDevices();
        std::cout << "\n";
        return 0;
    }
    
    // Cocoa requires NSApplication to be initialised before any window
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp activateIgnoringOtherApps:YES];

    App app;
    // Set device indices before init()
    if (opts.audioInIdx >= 0) app.setAudioInDevice(opts.audioInIdx);
    if (opts.audioOutIdx >= 0) app.setAudioOutDevice(opts.audioOutIdx);
    if (opts.midiInIdx >= 0) app.setMidiInDevice(opts.midiInIdx);
    if (opts.midiOutIdx >= 0) app.setMidiOutDevice(opts.midiOutIdx);
    
    if (!app.init()) return 1;
    app.run();
    return 0;
}
