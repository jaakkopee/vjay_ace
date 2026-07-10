#include "../CompositorFactory.h"
#include "../ICompositor.h"
#include "../StartupOptions.h"

#include <cstdint>
#include <iostream>
#include <vector>

namespace {
void uploadTestPattern(ICompositor& compositor, int srcSlot, uint8_t tintR, uint8_t tintG, uint8_t tintB) {
    std::vector<uint8_t> pixels(static_cast<size_t>(WORK_W) * static_cast<size_t>(WORK_H) * 4u);

    for (int y = 0; y < WORK_H; ++y) {
        for (int x = 0; x < WORK_W; ++x) {
            const size_t idx = (static_cast<size_t>(y) * static_cast<size_t>(WORK_W) + static_cast<size_t>(x)) * 4u;
            const uint8_t v = static_cast<uint8_t>((x + y + srcSlot * 53) % 255);
            pixels[idx + 0] = static_cast<uint8_t>((v + tintR) / 2);
            pixels[idx + 1] = static_cast<uint8_t>((255 - v + tintG) / 2);
            pixels[idx + 2] = static_cast<uint8_t>((v / 2 + tintB) / 2);
            pixels[idx + 3] = 255;
        }
    }

    const int layerIdx = srcSlot * 2;
    compositor.uploadLayerPixels(layerIdx, pixels.data(), WORK_W, WORK_H);
    compositor.setLayerOpacity(layerIdx + 1, 1.0f);
}
}

int main(int argc, char** argv) {
    StartupOptions opts;
    std::string parseError;
    if (!parseStartupOptions(argc, argv, opts, parseError)) {
        std::cerr << "[windows-main] " << parseError << "\n";
        printStartupHelp(std::cerr);
        return 2;
    }

    if (opts.showHelp) {
        printStartupHelp(std::cout);
        return 0;
    }

    if (opts.listDevices) {
        std::cout << "vjay_ace Windows device listing is not implemented yet.\n";
        std::cout << "Requested indexes: audio-in=" << opts.audioInIdx
                  << " audio-out=" << opts.audioOutIdx
                  << " midi-in=" << opts.midiInIdx
                  << " midi-out=" << opts.midiOutIdx << "\n";
        return 0;
    }

    auto compositor = createCompositor();
    if (!compositor) {
        std::cerr << "[windows-main] compositor factory returned null.\n";
        return 3;
    }

    if (!compositor->init()) {
        std::cerr << "[windows-main] compositor initialization failed.\n";
        return 4;
    }

    compositor->setFxPatch(0, FxPatchId::Ripple);
    compositor->setFxPatch(1, FxPatchId::Scanline);
    compositor->setFxPatch(2, FxPatchId::FeedbackZoom);
    compositor->setFxParams(0, 0.65f, 0.40f);
    compositor->setFxParams(1, 0.25f, 0.72f);
    compositor->setFxParams(2, 0.55f, 0.50f);

    uploadTestPattern(*compositor, 0, 255, 30, 30);
    uploadTestPattern(*compositor, 1, 30, 255, 30);
    uploadTestPattern(*compositor, 2, 30, 30, 255);

    std::vector<uint8_t> out;
    if (!compositor->composite(out)) {
        std::cerr << "[windows-main] first composite pass failed.\n";
        return 5;
    }

    std::cout << "vjay_ace Windows startup path is active. "
              << "Compositor produced " << out.size() << " bytes.\n";
    return 0;
}
