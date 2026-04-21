cmake_minimum_required(VERSION 3.20)
project(vjay_ace VERSION 0.1.0 LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 20)

# Homebrew prefix (Apple Silicon default)
set(HOMEBREW_PREFIX "/opt/homebrew" CACHE PATH "Homebrew prefix")

list(APPEND CMAKE_PREFIX_PATH
    "${HOMEBREW_PREFIX}/opt/sfml"
    "${HOMEBREW_PREFIX}/opt/tgui"
    "${HOMEBREW_PREFIX}/opt/rtmidi"
    "${HOMEBREW_PREFIX}/opt/fftw"
    "${HOMEBREW_PREFIX}/opt/ffmpeg"
    "${HOMEBREW_PREFIX}/opt/opencv"
)

find_package(SFML 3 COMPONENTS Graphics Window System Audio REQUIRED)
find_package(TGUI REQUIRED)
find_package(OpenCV REQUIRED HINTS "${HOMEBREW_PREFIX}/opt/opencv/lib/cmake/opencv4")
find_package(PkgConfig REQUIRED)
pkg_check_modules(RTMIDI REQUIRED rtmidi)
pkg_check_modules(AVCODEC  REQUIRED libavcodec)
pkg_check_modules(AVFORMAT REQUIRED libavformat)
pkg_check_modules(AVUTIL   REQUIRED libavutil)
pkg_check_modules(SWSCALE  REQUIRED libswscale)

# ────────────────────────────────────────────────────────────────────────────
# Common helper: link flags shared between vjay targets
# ────────────────────────────────────────────────────────────────────────────
set(VJAY_LINK_LIBS
    SFML::Graphics SFML::Window SFML::System SFML::Audio
    TGUI::TGUI
    ${RTMIDI_LIBRARIES}
    ${OpenCV_LIBS}
    ${AVCODEC_LIBRARIES}
    ${AVFORMAT_LIBRARIES}
    ${AVUTIL_LIBRARIES}
    ${SWSCALE_LIBRARIES}
    "-framework Metal"
    "-framework MetalKit"
    "-framework Foundation"
    "-framework AppKit"
    "-framework CoreVideo"
    "-framework CoreMedia"
)

set(VJAY_INCLUDE_DIRS
    src
    ${RTMIDI_INCLUDE_DIRS}
    ${OpenCV_INCLUDE_DIRS}
    ${AVCODEC_INCLUDE_DIRS}
    ${AVFORMAT_INCLUDE_DIRS}
    ${AVUTIL_INCLUDE_DIRS}
    ${SWSCALE_INCLUDE_DIRS}
)

# ── MIDI Monitor ─────────────────────────────────────────────────────────────
add_executable(midi_monitor
    src/midi_monitor/main.cpp
    src/midi_monitor/MidiMonitor.cpp
)

target_include_directories(midi_monitor PRIVATE src ${RTMIDI_INCLUDE_DIRS})
target_link_directories(midi_monitor PRIVATE ${RTMIDI_LIBRARY_DIRS})
target_link_libraries(midi_monitor PRIVATE
    SFML::Graphics SFML::Window SFML::System
    TGUI::TGUI
    ${RTMIDI_LIBRARIES}
)
target_compile_options(midi_monitor PRIVATE ${RTMIDI_CFLAGS_OTHER})

# ── vjay_ace main app ─────────────────────────────────────────────────────────
add_executable(vjay_ace
    src/app/main.mm
    src/app/App.mm
    src/app/MidiRouter.cpp
    src/app/LayerManager.cpp
    src/app/VideoDecoder.cpp
    src/app/MetalCompositor.mm
    src/app/ControlWindow.cpp
    src/app/PerformanceWindow.cpp
    src/app/MediaPickerWindow.mm
    src/app/FxPatch.cpp
)

target_include_directories(vjay_ace PRIVATE ${VJAY_INCLUDE_DIRS})
target_link_directories(vjay_ace PRIVATE
    ${RTMIDI_LIBRARY_DIRS}
    ${AVCODEC_LIBRARY_DIRS}
    ${AVFORMAT_LIBRARY_DIRS}
)
target_link_libraries(vjay_ace PRIVATE ${VJAY_LINK_LIBS})
target_compile_options(vjay_ace PRIVATE
    ${RTMIDI_CFLAGS_OTHER}
    -fobjc-arc
)

# Copy Metal shader next to the executable so it can be found at runtime
add_custom_command(TARGET vjay_ace POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy
        ${CMAKE_SOURCE_DIR}/src/app/shaders/vjay_shaders.metal
        $<TARGET_FILE_DIR:vjay_ace>/vjay_shaders.metal
    COMMENT "Copying vjay_shaders.metal to build dir"
)
