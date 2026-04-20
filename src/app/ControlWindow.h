#pragma once
#include "Constants.h"
#include <SFML/Graphics.hpp>
#include <TGUI/TGUI.hpp>
#include <TGUI/Backend/SFML-Graphics.hpp>
#include <array>
#include <functional>
#include <string>

// ── ControlWindow ─────────────────────────────────────────────────────────────
// Screen 1 — two-column layout:
//
// LEFT COLUMN (per-effect row for 6 effect slots):
//   [effect name label]  [6 colour-coded knobs]
//
// RIGHT COLUMN:
//   Full-resolution preview of the composited output (scaled to fit)
//
// Knob colour: dark blue (cc=0) → bright red (cc=127)
// Knobs are draggable by mouse (vertical drag) and reflect incoming MIDI CC.

class ControlWindow {
public:
    ControlWindow();

    // Place window on the given display index / position.
    void open(int displayX, int displayY, int width, int height);
    bool isOpen() const;
    void close();

    // Call each frame. Returns false if window was closed.
    bool handleEvents();
    void update();
    void render(const sf::Texture& compositePreview);

    // ── State setters (called by App on MIDI or mouse events) ─────────────
    // Update one knob's visual value (0–127) and colour.
    void setKnobValue(int layerRow, int knobIdx, int ccValue);

    // Update the effect name shown in the left column for a given row (0–5).
    void setEffectName(int row, const std::string& name);

    // Update mode label (LayerLevel / FxAudio / FxParam).
    void setKnobMode(KnobMode mode);

    // ── onKnobDrag: fired when user drags a knob with mouse
    // layerRow 0–5, knobIdx 0–5, normValue 0.0–1.0
    std::function<void(int layerRow, int knobIdx, float normValue)> onKnobDrag;

private:
    sf::RenderWindow window_;
    tgui::Gui        gui_;

    // Layout constants
    static constexpr int NUM_ROWS = 6;
    static constexpr int NUM_KNOBS = 6;
    static constexpr int LEFT_COL_W = 420;
    static constexpr int ROW_H      = 80;
    static constexpr int KNOB_SIZE  = 48;

    // Per-row knob state
    struct KnobState {
        int ccValue = 0;
        tgui::Canvas::Ptr canvas;
    };
    std::array<std::array<KnobState, NUM_KNOBS>, NUM_ROWS> knobs_;
    std::array<tgui::Label::Ptr, NUM_ROWS> effectLabels_;
    tgui::Label::Ptr modeLabel_;

    // Right column: composite preview
    sf::Sprite   previewSprite_;
    tgui::Panel::Ptr rightPanel_;

    // Knob drag tracking
    struct DragState {
        bool   active    = false;
        int    row       = -1;
        int    knob      = -1;
        int    startCC   = 0;
        float  startY    = 0.0f;
    } drag_;

    void buildGui(int width, int height);
    void drawKnob(KnobState& ks, int row, int knob);
    void onMousePressed(float x, float y);
    void onMouseReleased();
    void onMouseMoved(float x, float y);
};
