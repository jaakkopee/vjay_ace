#include "MediaPickerWindow.h"
#import  <AppKit/AppKit.h>
#include <filesystem>
#include <algorithm>
#include <iostream>
#include <cstdio>
#include <unordered_set>

namespace fs = std::filesystem;

// Image/video extensions considered valid media
static bool isMediaFile(const fs::path& p) {
    static const std::vector<std::string> exts = {
        ".jpg", ".jpeg", ".png", ".bmp", ".tiff", ".tif", ".gif",
        ".webp", ".heic", ".mp4", ".mov", ".avi", ".mkv", ".webm"
    };
    std::string ext = p.extension().string();
    // lowercase compare
    std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
    for (const auto& e : exts)
        if (ext == e) return true;
    return false;
}

static const tgui::Color BG_DARK  {16,  16,  20 };
static const tgui::Color TEXT_DIM {150, 165, 195};
static const tgui::Color TEXT_VAL {215, 225, 255};
static const tgui::Color ACTIVE_CLR{80, 180, 255};
static const tgui::Color ROW_HOVER {40,  50,  70 };

MediaPickerWindow::MediaPickerWindow() = default;

void MediaPickerWindow::open(int displayX, int displayY, int width, int height,
                              const std::string& scanRoot) {
    scanRoot_ = scanRoot;
    window_.create(sf::VideoMode({static_cast<unsigned>(width),
                                  static_cast<unsigned>(height)}),
                   "vjay_ace - Media Picker");
    window_.setPosition({displayX, displayY});
    window_.setFramerateLimit(30);
    gui_.setWindow(window_);
    buildGui(width, height);
    scanDirectory();
    rebuildFileList();
}

bool MediaPickerWindow::isOpen() const { return window_.isOpen(); }
void MediaPickerWindow::close()        { window_.close(); }

// ── GUI construction ──────────────────────────────────────────────────────────

void MediaPickerWindow::buildGui(int width, int height) {
    // Scene label
    sceneLabel_ = tgui::Label::create("SCENE: None");
    sceneLabel_->setPosition(12, 10);
    sceneLabel_->setTextSize(18);
    sceneLabel_->getRenderer()->setTextColor(tgui::Color(255, 210, 80));
    gui_.add(sceneLabel_);

    // Active-slot hint
    slotLabel_ = tgui::Label::create("Active slot: 1");
    slotLabel_->setPosition(12, 38);
    slotLabel_->setTextSize(13);
    slotLabel_->getRenderer()->setTextColor(TEXT_DIM);
    gui_.add(slotLabel_);

    // 3 slot buttons — evenly spaced
    const int btnW  = (width - 30) / 3;
    const int btnY  = 62;
    const int btnH  = 38;
    for (int i = 0; i < NUM_SRC_LAYERS; ++i) {
        slotButtons_[i] = tgui::Button::create("Slot " + std::to_string(i + 1) + ": empty");
        slotButtons_[i]->setPosition(10 + i * (btnW + 5), btnY);
        slotButtons_[i]->setSize(btnW, btnH);
        slotButtons_[i]->setTextSize(12);
        slotButtons_[i]->getRenderer()->setTextColor(tgui::Color(230, 235, 255));
        slotButtons_[i]->onPress([this, i]{ selectSlot(i); });
        gui_.add(slotButtons_[i]);
    }

    // Build effect selection section
    buildEffectSection(110, width);

    // Scrollable file list panel
    const int panelY = HEADER_H;
    const int panelH = height - HEADER_H - FOOTER_H;
    filePanel_ = tgui::ScrollablePanel::create({static_cast<float>(width),
                                                static_cast<float>(panelH)});
    filePanel_->setPosition(0, panelY);
    filePanel_->getRenderer()->setBackgroundColor(tgui::Color(20, 20, 28));
    gui_.add(filePanel_, "filePanel");

    // Browse button
    browseButton_ = tgui::Button::create("Browse…");
    browseButton_->setPosition(10, height - FOOTER_H + 8);
    browseButton_->setSize(120, 34);
    browseButton_->setTextSize(13);
    browseButton_->onPress([this]{
        std::string picked = nativeFilePicker();
        if (!picked.empty()) {
            // Add to list if not already there
            if (std::find(fileList_.begin(), fileList_.end(), picked) == fileList_.end()) {
                fileList_.push_back(picked);
                rebuildFileList();
            }
            // Assign to active slot
            if (onFileSelected) onFileSelected(activeSlot_, picked);
            // Update slot button label
            fs::path p(picked);
            slotButtons_[activeSlot_]->setText(
                "Slot " + std::to_string(activeSlot_ + 1) + ": " + p.filename().string());
        }
    });
    gui_.add(browseButton_);

    // Highlight the default active slot
    selectSlot(0);
}

// ── Effect section building ──────────────────────────────────────────────────

void MediaPickerWindow::buildEffectSection(int y, int width) {
    // Label
    auto effectLabel = tgui::Label::create("EFFECTS");
    effectLabel->setPosition(12, y);
    effectLabel->setTextSize(13);
    effectLabel->getRenderer()->setTextColor(TEXT_DIM);
    gui_.add(effectLabel);

    const int btnW  = (width - 30) / 3;
    const int btnY  = y + 20;
    const int btnH  = 24;
    const int panelH = 15 * 28;  // 15 visible effects at once

    // Create 3 effect selection buttons + scrollable panels for FX layers 1, 3, 5
    for (int i = 0; i < NUM_FX_LAYERS; ++i) {
        const int btnX = 10 + i * (btnW + 5);
        int fxLayerIdx = 1 + i * 2;  // 1, 3, 5

        // Button showing current selection
        auto btn = tgui::Button::create(fxPatchName(FxPatchId::None));
        btn->setPosition(btnX, btnY);
        btn->setSize(btnW, btnH);
        btn->setTextSize(11);
        btn->getRenderer()->setTextColor(tgui::Color(230, 235, 255));
        btn->getRenderer()->setBackgroundColor(tgui::Color(40, 40, 55));
        btn->getRenderer()->setBackgroundColorHover(tgui::Color(50, 60, 80));
        
        // Create hidden scrollable panel with effect list — opens downward below the button
        auto panel = tgui::ScrollablePanel::create({static_cast<float>(btnW),
                                                     static_cast<float>(panelH)});
        panel->setPosition(btnX, btnY + btnH + 2);
        panel->getRenderer()->setBackgroundColor(tgui::Color(30, 30, 45));
        panel->setVisible(false);  // hidden by default
        gui_.add(panel);

        // Populate panel with effect buttons
        for (int j = 0; j < static_cast<int>(FxPatchId::COUNT); ++j) {
            auto effectBtn = tgui::Button::create(fxPatchName(static_cast<FxPatchId>(j)));
            effectBtn->setPosition(0, j * 28);
            effectBtn->setSize(btnW - 4, 26);
            effectBtn->setTextSize(10);
            effectBtn->getRenderer()->setBackgroundColor((j % 2 == 0)
                ? tgui::Color(35, 35, 50) : tgui::Color(40, 40, 60));
            effectBtn->getRenderer()->setBackgroundColorHover(ROW_HOVER);
            effectBtn->getRenderer()->setBorders(0);
            effectBtn->getRenderer()->setTextColor(tgui::Color(230, 235, 255));

            // Capture effect selection
            FxPatchId patch = static_cast<FxPatchId>(j);
            effectBtn->onPress([this, i, fxLayerIdx, patch, btn]() {
                selectedEffects_[i] = patch;
                btn->setText(fxPatchName(patch));
                effectPanels_[i]->setVisible(false);
                openEffectDropdown_ = -1;
                if (onEffectSelected) {
                    onEffectSelected(fxLayerIdx, patch);
                }
            });
            panel->add(effectBtn);
        }
        
        // Set scroll content size
        panel->setContentSize({static_cast<float>(btnW - 4),
                               static_cast<float>(static_cast<int>(FxPatchId::COUNT) * 28)});

        // Button click toggles panel visibility
        btn->onPress([this, i, panel, btn]() {
            // Close other open panels
            if (openEffectDropdown_ >= 0 && openEffectDropdown_ != i) {
                effectPanels_[openEffectDropdown_]->setVisible(false);
            }
            // Toggle current panel
            bool isVisible = panel->isVisible();
            panel->setVisible(!isVisible);
            if (!isVisible) panel->moveToFront();  // render above file list
            openEffectDropdown_ = isVisible ? -1 : i;
        });

        effectButtons_[i] = btn;
        effectPanels_[i] = panel;
        gui_.add(btn);
    }
}

// ── Setters ───────────────────────────────────────────────────────────────────

void MediaPickerWindow::setLayerEffect(int fxLayerIdx, FxPatchId patch) {
    // fxLayerIdx is 1, 3, or 5; convert to dropdown index 0, 1, 2
    int btnIdx = (fxLayerIdx - 1) / 2;
    if (btnIdx < 0 || btnIdx >= NUM_FX_LAYERS) return;

    selectedEffects_[btnIdx] = patch;
    if (effectButtons_[btnIdx]) {
        effectButtons_[btnIdx]->setText(fxPatchName(patch));
    }
}

// ── Slot selection ─────────────────────────────────────────────────────────────

void MediaPickerWindow::selectSlot(int idx) {
    activeSlot_ = idx;
    slotLabel_->setText("Active slot: " + std::to_string(idx + 1)
                        + "  (will receive next file pick)");
    for (int i = 0; i < NUM_SRC_LAYERS; ++i) {
        auto rnd = slotButtons_[i]->getRenderer();
        if (i == idx) {
            rnd->setBackgroundColor(tgui::Color(40, 90, 160));
            rnd->setBorderColor(ACTIVE_CLR);
        } else {
            rnd->setBackgroundColor(tgui::Color(45, 45, 60));
            rnd->setBorderColor(tgui::Color(80, 80, 100));
        }
    }
}

// ── Directory scan ────────────────────────────────────────────────────────────

void MediaPickerWindow::scanDirectory() {
    fileList_.clear();
    if (scanRoot_.empty()) return;

    std::vector<fs::path> roots;
    roots.push_back(fs::path(scanRoot_));

    // Also include project-local images directory when scanRoot points to
    // the stash folder (e.g. <project>/Heikki_stash).
    const fs::path stashRoot(scanRoot_);
    const fs::path imagesSibling = stashRoot.parent_path() / "images";
    if (fs::exists(imagesSibling) && fs::is_directory(imagesSibling))
        roots.push_back(imagesSibling);

    std::unordered_set<std::string> seen;
    try {
        for (const auto& root : roots) {
            if (!fs::exists(root) || !fs::is_directory(root)) continue;
            for (const auto& entry : fs::recursive_directory_iterator(root,
                    fs::directory_options::skip_permission_denied)) {
                if (!entry.is_regular_file() || !isMediaFile(entry.path())) continue;
                const std::string path = entry.path().string();
                if (seen.insert(path).second)
                    fileList_.push_back(path);
            }
        }
    } catch (const std::exception& e) {
        std::cerr << "[MediaPicker] Scan error: " << e.what() << "\n";
    }
    std::sort(fileList_.begin(), fileList_.end());
    std::cout << "[MediaPicker] Found " << fileList_.size() << " media files\n";
}

// ── Rebuild scrollable file list rows ────────────────────────────────────────

void MediaPickerWindow::rebuildFileList() {
    filePanel_->removeAllWidgets();
    const int panelW = static_cast<int>(filePanel_->getSize().x);

    for (int i = 0; i < static_cast<int>(fileList_.size()); ++i) {
        const std::string& path = fileList_[i];
        std::string fname = fs::path(path).filename().string();
        std::string fdir  = fs::path(path).parent_path().filename().string();

        // Row panel (button-like)
        auto row = tgui::Button::create(fdir + " / " + fname);
        row->setPosition(0, i * ROW_HEIGHT);
        row->setSize(panelW, ROW_HEIGHT - 2);
        row->setTextSize(11);
        row->getRenderer()->setBackgroundColor((i % 2 == 0)
            ? tgui::Color(24, 24, 34) : tgui::Color(28, 28, 40));
        row->getRenderer()->setBackgroundColorHover(ROW_HOVER);
        row->getRenderer()->setBorders(0);
        row->getRenderer()->setTextColor(TEXT_VAL);

        // Capture by value
        row->onPress([this, path]{
            if (onFileSelected) onFileSelected(activeSlot_, path);
            fs::path p(path);
            slotButtons_[activeSlot_]->setText(
                "Slot " + std::to_string(activeSlot_ + 1) + ": " + p.filename().string());
        });
        filePanel_->add(row);
    }
    // Set scroll content height
    filePanel_->setContentSize({static_cast<float>(panelW),
                                static_cast<float>(fileList_.size() * ROW_HEIGHT + 4)});
}

// ── Setters ───────────────────────────────────────────────────────────────────

void MediaPickerWindow::setSlotPaths(const std::array<std::string, NUM_SRC_LAYERS>& paths) {
    for (int i = 0; i < NUM_SRC_LAYERS; ++i) {
        std::string label = "Slot " + std::to_string(i + 1) + ": ";
        if (paths[i].empty()) {
            label += "empty";
        } else {
            label += fs::path(paths[i]).filename().string();
        }
        slotButtons_[i]->setText(label);
    }
}

void MediaPickerWindow::setSceneName(const std::string& name) {
    if (sceneLabel_) sceneLabel_->setText("SCENE: " + name);
}

// ── Events / render ───────────────────────────────────────────────────────────

bool MediaPickerWindow::handleEvents() {
    while (const auto event = window_.pollEvent()) {
        // Close open effect dropdowns on Escape
        if (event->is<sf::Event::KeyPressed>()) {
            auto keyEvent = event->getIf<sf::Event::KeyPressed>();
            if (keyEvent && keyEvent->code == sf::Keyboard::Key::Escape && openEffectDropdown_ >= 0) {
                effectPanels_[openEffectDropdown_]->setVisible(false);
                openEffectDropdown_ = -1;
                continue;  // don't pass to gui
            }
        }
        
        gui_.handleEvent(*event);
        
        if (event->is<sf::Event::Closed>()) { window_.close(); return false; }
    }
    return true;
}

void MediaPickerWindow::render() {
    window_.clear(sf::Color(16, 16, 20));
    gui_.draw();
    window_.display();
}

// ── Native file picker (macOS) ────────────────────────────────────────────────

std::string MediaPickerWindow::nativeFilePicker() {
    __block std::string result;
    auto block = ^{
        NSOpenPanel* panel = [NSOpenPanel openPanel];
        panel.canChooseFiles          = YES;
        panel.canChooseDirectories    = YES;
        panel.allowsMultipleSelection = NO;
        // Accept all files — extension filtering is done by our scanner
        if ([panel runModal] == NSModalResponseOK && panel.URL) {
            result = panel.URL.path.UTF8String;
        }
    };
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
    return result;
}
