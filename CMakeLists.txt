cmake_minimum_required(VERSION 3.20)
project(vjay_ace VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Homebrew prefix (Apple Silicon default)
set(HOMEBREW_PREFIX "/opt/homebrew" CACHE PATH "Homebrew prefix")

list(APPEND CMAKE_PREFIX_PATH
    "${HOMEBREW_PREFIX}/opt/sfml"
    "${HOMEBREW_PREFIX}/opt/tgui"
    "${HOMEBREW_PREFIX}/opt/rtmidi"
    "${HOMEBREW_PREFIX}/opt/fftw"
)

find_package(SFML 3 COMPONENTS Graphics Window System Audio REQUIRED)
find_package(TGUI REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(RTMIDI REQUIRED rtmidi)

# ── MIDI Monitor ─────────────────────────────────────────────────────────────
add_executable(midi_monitor
    src/midi_monitor/main.cpp
    src/midi_monitor/MidiMonitor.cpp
)

target_include_directories(midi_monitor PRIVATE
    src
    ${RTMIDI_INCLUDE_DIRS}
)

target_link_directories(midi_monitor PRIVATE ${RTMIDI_LIBRARY_DIRS})

target_link_libraries(midi_monitor PRIVATE
    SFML::Graphics SFML::Window SFML::System
    TGUI::TGUI
    ${RTMIDI_LIBRARIES}
)

target_compile_options(midi_monitor PRIVATE ${RTMIDI_CFLAGS_OTHER})
