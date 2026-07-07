#pragma once
#include "Constants.h"
#include <SFML/Graphics.hpp>
#include <TGUI/TGUI.hpp>
#include <TGUI/Backend/SFML-Graphics.hpp>
#include <array>
#include <string>
#include <vector>
#include <functional>

// ── MediaPickerWindow ─────────────────────────────────────────────────────────
// Screen 0 companion window — lets the operator assign image/video files to
// the 3 source layers (0, 2, 4) of the current scene.
//
// Layout:
//   TOP:   3 slot buttons  [Slot 1: <filename>]  [Slot 2: ...]  [Slot 3: ...]
//
//   EFFECT SECTION: 3 effect dropdowns for layers 1, 3, 5 (FX layers)
//          Each dropdown shows available FX patches.
//
//   BODY:  Scrollable file list scanned from a root directory.
//          Clicking a file entry assigns it to the active slot and fires
//          onFileSelected(slotIndex 0-2, absolutePath).
//
//   BOTTOM: [Browse…] button to open a native file dialog.

class MediaPickerWindow {
public:
    MediaPickerWindow();

    // Open window at given position/size.
    // scanRoot is the directory to scan for image/video files.
    void open(int displayX, int displayY, int width, int height,
              const std::string& scanRoot);
    bool isOpen() const;
    void close();

    bool handleEvents();
    void render();

    // Refresh slot labels to show the currently assigned filenames.
    // paths: one per src layer slot (0-2). Empty string = "empty".
    void setSlotPaths(const std::array<std::string, NUM_SRC_LAYERS>& paths);

    // Update the scene name shown in the title bar area.
    void setSceneName(const std::string& name);

    // Set the currently selected effect for an FX layer (1, 3, or 5).
    // Called to refresh the dropdown when effects change from external sources.
    void setLayerEffect(int fxLayerIdx, FxPatchId patch);

    // Fired when user picks a file for a slot.
    // slotIdx 0-2 corresponds to layers 0, 2, 4.
    // path is the absolute file path.
    std::function<void(int slotIdx, const std::string& path)> onFileSelected;

    // Fired when user selects an effect for an FX layer.
    // fxLayerIdx: 1, 3, or 5 (odd-index FX layers)
    // patch: the selected FxPatchId
    std::function<void(int fxLayerIdx, FxPatchId patch)> onEffectSelected;

private:
    sf::RenderWindow window_;
    tgui::Gui        gui_;

    std::string scanRoot_;
    std::vector<std::string> fileList_; // absolute paths of discovered files
    int activeSlot_ = 0;               // which slot is currently targeted

    // TGUI widgets
    tgui::Label::Ptr      sceneLabel_;
    tgui::Label::Ptr      slotLabel_;    // "Active slot: X"
    std::array<tgui::Button::Ptr, NUM_SRC_LAYERS> slotButtons_;
    
    // Effect selection buttons + scrollable panels for FX layers 1, 3, 5
    std::array<tgui::Button::Ptr, NUM_FX_LAYERS> effectButtons_;
    std::array<tgui::ScrollablePanel::Ptr, NUM_FX_LAYERS> effectPanels_;
    std::array<FxPatchId, NUM_FX_LAYERS> selectedEffects_ = {
        FxPatchId::None, FxPatchId::None, FxPatchId::None
    };
    int openEffectDropdown_ = -1;  // which effect panel is currently open (-1 = none)
    
    tgui::ScrollablePanel::Ptr filePanel_;
    tgui::Button::Ptr     browseButton_;

    static constexpr int HEADER_H   = 190;  // increased to accommodate effect section
    static constexpr int EFFECT_SECTION_H = 80;
    static constexpr int FOOTER_H   = 50;
    static constexpr int ROW_HEIGHT = 32;

    void buildGui(int width, int height);
    void buildEffectSection(int y, int width);
    void scanDirectory();
    void rebuildFileList();
    void selectSlot(int idx);

    // Open a native macOS file-open dialog.
    std::string nativeFilePicker();
};
