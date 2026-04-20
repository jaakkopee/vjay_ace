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
// C2 held  → knobs = layer opacities
// C#2 held → knobs = audio gain
// Default  → knobs = active FX patch params

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

    void buildGui(int width, int height);
    void drawKnob(int knobIdx);
    void onMousePressed(float x, float y);
    void onMouseReleased();
    void onMouseMoved(float x, float y);
};
