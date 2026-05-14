#pragma once

#include <SFML/Graphics.hpp>
#include <TGUI/TGUI.hpp>
#include <TGUI/Backend/SFML-Graphics.hpp>
#include <TGUI/Backend/Renderer/SFML-Graphics/CanvasSFML.hpp>

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

class PressureControlWindow {
public:
    PressureControlWindow();

    void open(int displayX, int displayY, int width, int height,
              const std::vector<std::string>& targetNames);
    bool isOpen() const;
    void close();

    bool handleEvents();
    void render();

    void setSceneName(const std::string& sceneName);
    void setTargetStates(const std::vector<uint8_t>& enabled,
                         const std::vector<float>& amount);

    std::function<void(int targetIdx, bool enabled, float amount)> onMappingChanged;

private:
    sf::RenderWindow window_;
    tgui::Gui gui_;

    tgui::Label::Ptr titleLabel_;
    tgui::Label::Ptr sceneLabel_;
    tgui::ScrollablePanel::Ptr panel_;

    struct RowWidgets {
        tgui::CheckBox::Ptr enabled;
        tgui::Label::Ptr name;
        tgui::Slider::Ptr amount;
        tgui::Label::Ptr value;
    };
    std::vector<RowWidgets> rows_;

    bool suppressCallbacks_ = false;

    void buildGui(int width, int height, const std::vector<std::string>& targetNames);
    static std::string amountText(float amount);
};
