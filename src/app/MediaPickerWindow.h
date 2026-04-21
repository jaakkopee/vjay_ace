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
//          Clicking a slot button selects it as the active assignment target.
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

    // Fired when user picks a file for a slot.
    // slotIdx 0-2 corresponds to layers 0, 2, 4.
    // path is the absolute file path.
    std::function<void(int slotIdx, const std::string& path)> onFileSelected;

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
    tgui::ScrollablePanel::Ptr filePanel_;
    tgui::Button::Ptr     browseButton_;

    static constexpr int HEADER_H   = 110;
    static constexpr int FOOTER_H   = 50;
    static constexpr int ROW_HEIGHT = 32;

    void buildGui(int width, int height);
    void scanDirectory();
    void rebuildFileList();
    void selectSlot(int idx);

    // Open a native macOS file-open dialog.
    std::string nativeFilePicker();
};
