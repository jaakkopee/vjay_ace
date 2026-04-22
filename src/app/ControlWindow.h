#pragma once
#include "Constants.h"
#include <SFML/Graphics.hpp>
#include <TGUI/TGUI.hpp>
#include <TGUI/Backend/SFML-Graphics.hpp>
#include <TGUI/Backend/Renderer/SFML-Graphics/CanvasSFML.hpp>
#include <array>
#include <functional>
#include <string>

// ── ControlWindow ─────────────────────────────────────────────────────────────
// Screen 1 — two-column layout:
//
//  LEFT HALF                         |  RIGHT HALF
//  SCENE: [fx patch name]            |
//  MODE:  [mode name]                |  Video monitor (composite preview)
//                                    |
//  [K0]    [K1]    [K2]              |
//  name0   name1   name2             |
//  0.00    0.00    0.00              |
//                                    |
//  [K3]    [K4]    [K5]              |
//  name3   name4   name5             |
//  0.00    0.00    0.00              |
//
// CCs: 3, 9, 12, 13, 14, 15
// O held → knobs = layer opacities (LayerLevel mode)
// G held → knobs = audio gain      (FxAudio mode)
// Default → knobs = active FX patch params

class ControlWindow {
public:
    ControlWindow();

    void open(int displayX, int displayY, int width, int height);
    bool isOpen() const;
    void close();

    bool handleEvents();
    void update();
    void render(const sf::Texture& compositePreview);

    // ── State setters ───────────────────────────────────────────────────────
    // Update knob arc and value display (cc value 0-127).
    void setKnobValue(int knobIdx, int ccValue);

    // Update parameter name shown under a knob.
    void setKnobParamName(int knobIdx, const std::string& name);

    // Update the scene (FX patch) name at top-left.
    void setSceneName(const std::string& name);

    // Update mode label.
    void setKnobMode(KnobMode mode);

    // Fired when user drags a knob: knobIdx 0-5, normValue 0.0-1.0
    std::function<void(int knobIdx, float normValue)> onKnobDrag;

    // Fired when the R key is pressed (true) or released (false)
    std::function<void(bool pressed)> onRKey;

    // Fired when the Z key is pressed (true) or released (false)
    std::function<void(bool pressed)> onZKey;

    // Fired when the O key is pressed (true) or released (false) → LayerLevel mode
    std::function<void(bool pressed)> onOKey;

    // Fired when the G key is pressed (true) or released (false) → FxAudio mode
    std::function<void(bool pressed)> onGKey;

    // Fired when the P key is pressed (true) or released (false) → ImgPan mode
    std::function<void(bool pressed)> onPKey;

    // Fired when the B key is toggled (true = bypassed, false = active)
    std::function<void(bool bypassed)> onBKey;

    // Update audio level meter (8 bands 0-1, rms 0-1). Called each frame.
    void setAudioBands(const float* bands, int count, float rms);

private:
    sf::RenderWindow window_;
    tgui::Gui        gui_;

    static constexpr int KNOB_SIZE = 80;

    struct KnobState {
        int                   ccValue    = 0;
        tgui::CanvasSFML::Ptr canvas;
        tgui::Label::Ptr      paramLabel;
        tgui::Label::Ptr      valueLabel;
    };
    std::array<KnobState, NUM_KNOBS> knobs_;

    tgui::Label::Ptr sceneLabel_;
    tgui::Label::Ptr modeLabel_;
    tgui::Panel::Ptr rightPanel_;
    int              leftColW_ = 0;

    struct DragState {
        bool  active  = false;
        int   knob    = -1;
        int   startCC = 0;
        float startY  = 0.0f;
    } drag_;

    // Key polling state (previous frame)
    bool rKeyWas_ = false;
    bool zKeyWas_ = false;
    bool oKeyWas_ = false;
    bool gKeyWas_ = false;
    bool pKeyWas_ = false;
    bool bKeyWas_ = false;
    bool audioBypassed_ = false;

    // Audio bands for meter drawing (8 bands + RMS)
    std::array<float, 8> audioBands_ = {};
    float audioRms_ = 0.0f;
    tgui::CanvasSFML::Ptr audioMeterCanvas_;

    void buildGui(int width, int height);
    void drawKnob(int knobIdx);
    void drawAudioMeter();
    void onMousePressed(float x, float y);
    void onMouseReleased();
    void onMouseMoved(float x, float y);
};
