#pragma once

#include <ostream>
#include <string>

struct StartupOptions {
    bool listDevices = false;
    bool showHelp = false;
    int audioInIdx = -1;
    int audioOutIdx = -1;
    int midiInIdx = -1;
    int midiOutIdx = -1;
};

bool parseStartupOptions(int argc, char** argv, StartupOptions& out, std::string& error);
void printStartupHelp(std::ostream& out);
