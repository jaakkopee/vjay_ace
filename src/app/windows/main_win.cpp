#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "../CompositorFactory.h"
#include "../ICompositor.h"
#include "../StartupOptions.h"
#include "WindowsCompositorD3D11.h"

#include <cstdint>
#include <iostream>
#include <vector>

static const wchar_t* kClassName = L"vjay_ace_preview";
static bool           g_running  = true;

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_DESTROY:
        g_running = false;
        PostQuitMessage(0);
        return 0;
    case WM_KEYDOWN:
        if (wp == VK_ESCAPE) {
            g_running = false;
            DestroyWindow(hwnd);
        }
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

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
} // namespace

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

    // ── Window ───────────────────────────────────────────────────────────────
    constexpr int kPreviewW = 960;
    constexpr int kPreviewH = 540;

    WNDCLASSEXW wc   = {};
    wc.cbSize        = sizeof(wc);
    wc.style         = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc   = WndProc;
    wc.hInstance     = GetModuleHandleW(nullptr);
    wc.hCursor       = LoadCursor(nullptr, IDC_ARROW);
    wc.lpszClassName = kClassName;
    if (!RegisterClassExW(&wc)) {
        std::cerr << "[windows-main] failed to register window class.\n";
        return 1;
    }

    RECT rc = {0, 0, kPreviewW, kPreviewH};
    AdjustWindowRect(&rc, WS_OVERLAPPEDWINDOW, FALSE);
    HWND hwnd = CreateWindowExW(
        0, kClassName, L"vjay_ace preview",
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT,
        rc.right - rc.left, rc.bottom - rc.top,
        nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);

    if (!hwnd) {
        std::cerr << "[windows-main] failed to create window.\n";
        return 1;
    }

    // ── Compositor ───────────────────────────────────────────────────────────
    auto compositor = createCompositor();
    if (!compositor) {
        std::cerr << "[windows-main] compositor factory returned null.\n";
        return 3;
    }
    if (!compositor->init()) {
        std::cerr << "[windows-main] compositor initialization failed.\n";
        return 4;
    }

    // ── Swap chain ───────────────────────────────────────────────────────────
    auto* d3d11 = dynamic_cast<WindowsCompositorD3D11*>(compositor.get());
    const bool hasSwapChain = d3d11 && d3d11->initSwapChain(hwnd, kPreviewW, kPreviewH);
    if (!hasSwapChain) {
        std::cerr << "[windows-main] swap chain init failed; no preview window.\n";
    }

    // ── Test content ─────────────────────────────────────────────────────────
    compositor->setFxPatch(0, FxPatchId::Ripple);
    compositor->setFxPatch(1, FxPatchId::Scanline);
    compositor->setFxPatch(2, FxPatchId::FeedbackZoom);
    compositor->setFxParams(0, 0.65f, 0.40f);
    compositor->setFxParams(1, 0.25f, 0.72f);
    compositor->setFxParams(2, 0.55f, 0.50f);

    uploadTestPattern(*compositor, 0, 255,  30,  30);
    uploadTestPattern(*compositor, 1,  30, 255,  30);
    uploadTestPattern(*compositor, 2,  30,  30, 255);

    // ── Show window ──────────────────────────────────────────────────────────
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    std::cout << "vjay_ace preview running at " << kPreviewW << "x" << kPreviewH
              << ". Press Escape or close the window to quit.\n";

    // ── Message + render loop ────────────────────────────────────────────────
    MSG msg = {};
    while (g_running) {
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
            if (msg.message == WM_QUIT) {
                g_running = false;
            }
        }
        if (!g_running) break;

        if (hasSwapChain) {
            d3d11->presentToWindow();
        } else {
            // Headless fallback: just keep GPU passes running
            std::vector<uint8_t> dummy;
            compositor->composite(dummy);
        }
    }

    return 0;
}
