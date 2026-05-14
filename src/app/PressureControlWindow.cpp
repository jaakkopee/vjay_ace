#include "PressureControlWindow.h"

#include <algorithm>
#include <cstdio>

namespace {
const tgui::Color BG_DARK {14, 14, 20};
const tgui::Color TEXT_DIM {155, 170, 205};
const tgui::Color TEXT_VAL {220, 228, 255};
}

PressureControlWindow::PressureControlWindow() = default;

void PressureControlWindow::open(int displayX, int displayY, int width, int height,
                                 const std::vector<std::string>& targetNames) {
    window_.create(sf::VideoMode({static_cast<unsigned>(width), static_cast<unsigned>(height)}),
                   "vjay_ace - Pressure Control");
    window_.setPosition({displayX, displayY});
    window_.setFramerateLimit(60);
    gui_.setWindow(window_);
    buildGui(width, height, targetNames);
}

bool PressureControlWindow::isOpen() const { return window_.isOpen(); }
void PressureControlWindow::close() { window_.close(); }

bool PressureControlWindow::handleEvents() {
    while (const auto event = window_.pollEvent()) {
        gui_.handleEvent(*event);
        if (event->is<sf::Event::Closed>()) {
            window_.close();
            return false;
        }
    }
    return true;
}

void PressureControlWindow::render() {
    window_.clear(sf::Color(BG_DARK));
    gui_.draw();
    window_.display();
}

void PressureControlWindow::setSceneName(const std::string& sceneName) {
    if (sceneLabel_)
        sceneLabel_->setText("SCENE: " + sceneName);
}

void PressureControlWindow::setTargetStates(const std::vector<uint8_t>& enabled,
                                            const std::vector<float>& amount) {
    suppressCallbacks_ = true;
    const std::size_t n = std::min(rows_.size(), std::min(enabled.size(), amount.size()));
    for (std::size_t i = 0; i < n; ++i) {
        rows_[i].enabled->setChecked(enabled[i] != 0);
        const float clamped = std::clamp(amount[i], -1.0f, 1.0f);
        rows_[i].amount->setValue(clamped * 100.0f);
        rows_[i].value->setText(amountText(clamped));
    }
    suppressCallbacks_ = false;
}

void PressureControlWindow::buildGui(int width, int height,
                                     const std::vector<std::string>& targetNames) {
    titleLabel_ = tgui::Label::create("Pressure Mapping (Channel Pressure CH10)");
    titleLabel_->setPosition(12, 10);
    titleLabel_->setTextSize(18);
    titleLabel_->getRenderer()->setTextColor(tgui::Color(255, 210, 80));
    gui_.add(titleLabel_);

    sceneLabel_ = tgui::Label::create("SCENE: None");
    sceneLabel_->setPosition(12, 36);
    sceneLabel_->setTextSize(13);
    sceneLabel_->getRenderer()->setTextColor(TEXT_DIM);
    gui_.add(sceneLabel_);

    panel_ = tgui::ScrollablePanel::create({static_cast<float>(width - 16), static_cast<float>(height - 60)});
    panel_->setPosition(8, 52);
    panel_->getRenderer()->setBackgroundColor(tgui::Color(18, 18, 26));
    gui_.add(panel_);

    rows_.clear();
    rows_.reserve(targetNames.size());

    const float rowH = 34.0f;
    for (std::size_t i = 0; i < targetNames.size(); ++i) {
        const float y = i * rowH;

        RowWidgets row;
        row.enabled = tgui::CheckBox::create();
        row.enabled->setPosition(8, y + 7);
        row.enabled->setSize(18, 18);
        panel_->add(row.enabled);

        row.name = tgui::Label::create(targetNames[i]);
        row.name->setPosition(34, y + 7);
        row.name->setSize(210, 20);
        row.name->setTextSize(12);
        row.name->getRenderer()->setTextColor(TEXT_VAL);
        panel_->add(row.name);

        row.amount = tgui::Slider::create(-100.0f, 100.0f);
        row.amount->setStep(1.0f);
        row.amount->setValue(0.0f);
        row.amount->setPosition(252, y + 10);
        row.amount->setSize(180, 14);
        panel_->add(row.amount);

        row.value = tgui::Label::create("+0.00");
        row.value->setPosition(438, y + 7);
        row.value->setSize(58, 20);
        row.value->setTextSize(12);
        row.value->getRenderer()->setTextColor(TEXT_DIM);
        panel_->add(row.value);

        row.enabled->onChange([this, i](bool checked) {
            if (suppressCallbacks_) return;
            if (!onMappingChanged) return;
            float amount = rows_[i].amount->getValue() / 100.0f;
            // Enabling a target with zero amount would appear non-functional.
            // Give it a sensible default depth immediately.
            if (checked && std::abs(amount) < 0.001f) {
                amount = 0.35f;
                suppressCallbacks_ = true;
                rows_[i].amount->setValue(amount * 100.0f);
                rows_[i].value->setText(amountText(amount));
                suppressCallbacks_ = false;
            }
            onMappingChanged(static_cast<int>(i), checked, amount);
        });

        row.amount->onValueChange([this, i](float value) {
            const float amount = std::clamp(value / 100.0f, -1.0f, 1.0f);
            rows_[i].value->setText(amountText(amount));
            if (suppressCallbacks_) return;
            if (!onMappingChanged) return;
            onMappingChanged(static_cast<int>(i), rows_[i].enabled->isChecked(), amount);
        });

        rows_.push_back(row);
    }

    panel_->setContentSize({static_cast<float>(width - 16), targetNames.size() * rowH + 6.0f});
}

std::string PressureControlWindow::amountText(float amount) {
    char buf[16];
    std::snprintf(buf, sizeof(buf), "%+.2f", amount);
    return std::string(buf);
}
