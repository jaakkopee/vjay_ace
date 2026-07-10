#include "StartupOptions.h"

#include <cstdlib>

namespace {
bool parseIndexArg(const char* value, int& out) {
    if (value == nullptr) return false;
    char* end = nullptr;
    const long parsed = std::strtol(value, &end, 10);
    if (end == value || *end != '\0') return false;
    if (parsed < -1 || parsed > 1'000'000) return false;
    out = static_cast<int>(parsed);
    return true;
}
}

bool parseStartupOptions(int argc, char** argv, StartupOptions& out, std::string& error) {
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];

        if (arg == "--list-devices" || arg == "-l") {
            out.listDevices = true;
            continue;
        }
        if (arg == "--help" || arg == "-h") {
            out.showHelp = true;
            continue;
        }

        auto requireIndex = [&](int& target, const char* flagName) -> bool {
            if (i + 1 >= argc) {
                error = std::string("Missing value for ") + flagName;
                return false;
            }
            if (!parseIndexArg(argv[i + 1], target)) {
                error = std::string("Invalid numeric value for ") + flagName + ": " + argv[i + 1];
                return false;
            }
            ++i;
            return true;
        };

        if (arg == "--audio-in") {
            if (!requireIndex(out.audioInIdx, "--audio-in")) return false;
            continue;
        }
        if (arg == "--audio-out") {
            if (!requireIndex(out.audioOutIdx, "--audio-out")) return false;
            continue;
        }
        if (arg == "--midi-in") {
            if (!requireIndex(out.midiInIdx, "--midi-in")) return false;
            continue;
        }
        if (arg == "--midi-out") {
            if (!requireIndex(out.midiOutIdx, "--midi-out")) return false;
            continue;
        }

        error = "Unknown argument: " + arg;
        return false;
    }
    return true;
}

void printStartupHelp(std::ostream& out) {
    out << "\nUsage: vjay_ace [OPTIONS]\n\n";
    out << "OPTIONS:\n";
    out << "  --list-devices, -l           List available MIDI/audio devices\n";
    out << "  --audio-in INDEX             Audio input device index\n";
    out << "  --audio-out INDEX            Audio output device index\n";
    out << "  --midi-in INDEX              MIDI input device index\n";
    out << "  --midi-out INDEX             MIDI output device index\n";
    out << "  --help, -h                   Show this help message\n\n";
}
