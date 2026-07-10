# Copilot instructions for vjay_ace

Purpose: give Copilot sessions quick, precise pointers for building, navigating, and changing this macOS Metal-based VJ compositor.

## Quick build / run commands
- Configure & generate build files (from repo root):
  mkdir -p build && cd build && cmake ..
- Build the main app (single target):
  cmake --build build --target vjay_ace -j$(sysctl -n hw.ncpu)
- Build the MIDI monitor tool (single target):
  cmake --build build --target midi_monitor -j$(sysctl -n hw.ncpu)
- Alternative / Makefile (from repo root):
  make vjay_ace
  make midi_monitor
- Build helper target: copy_metal_shader (ensures shader is next to executable):
  cmake --build build --target copy_metal_shader
- Run (from build/):
  ./vjay_ace

Notes: the runtime expects build/vjay_shaders.metal next to the executable (CMake target copy_metal_shader handles this).

## Tests & lint
- No unit-test framework or lint configuration detected in the repository. (If tests are added, place invocation examples here.)

## High-level architecture (big picture)
- Purpose: live-performance compositor for macOS / Apple Silicon using Metal for GPU kernels and SFML/TGUI for control UI.
- Layer model: three source slots, each with an FX patch; processed slots are alpha-composited into the final output.
- Major components and where to look:
  - Renderer / Metal pipeline: src/app/MetalCompositor.mm / .h
  - App orchestration & state: src/app/App.mm and src/app/App.h
  - Audio capture & analysis: src/app/AudioAnalyzer.mm / .h (RMS + 8-band spectrum)
  - MIDI routing & CC mapping: src/app/MidiRouter.cpp
  - Layer/media state: src/app/LayerManager.cpp
  - Video decode path: src/app/VideoDecoder.cpp
  - UI windows: src/app/ControlWindow.cpp, PerformanceWindow.cpp, MediaPickerWindow.mm
  - FX host / descriptors: src/app/FxPatch.cpp and the Metal shader: src/app/shaders/vjay_shaders.metal
  - Constants and scene lists: src/app/Constants.h
- App stores persistent state in ~/.vjay_ace_state and aggressively saves changes (scenes, media assignments, knob values).

## Key repository conventions & patterns
- Platform/Tooling:
  - Primary platform: macOS (APPLE) with Objective-C++ usage enabled (CMake sets OBJCXX for APPLE builds).
  - Homebrew packages are referenced under /opt/homebrew in CMakeLists (expect Homebrew-installed deps on Apple Silicon).
  - C++ standard: C++20 (set in CMakeLists).
- Shader handling:
  - src/app/shaders/vjay_shaders.metal is copied to build/vjay_shaders.metal during build; runtime expects that file next to the executable.
  - When changing kernels, ensure the copy_metal_shader step runs so runtime finds the updated shader.
- Build targets and names:
  - Main app target: vjay_ace
  - MIDI monitor: midi_monitor
  - Helper: copy_metal_shader
- Input mappings and state model:
  - Scenes: 32 scenes mapped to MIDI notes starting at note 36 (see README and src/app/Constants.h)
  - Knobs (CC): CC 3, 9, 12, 13, 14, 15 map to knob indices 0–5 (documented in README and enforced by MidiRouter)
  - Global overrides vs local scene values: global override values become authoritative until a local value is touched again — scene state is primary source of truth.
- FX conventions:
  - Each FX exposes up to two parameters (see README table and FxPatch implementation). Many effects rely on injected audio bands and RMS.
  - FX IDs and built-in scene presets are listed in Constants.h / README; update both when adding new presets.
- Objective-C++ and ARC:
  - CMake sets -fobjc-arc for vjay_ace; Objective-C++ source files (.mm) are used for macOS APIs and Metal integration.

## Files and docs to consult during edits
- README.md (high-level features, run & build notes)
- key_modifiers.md (keyboard bindings and modifier semantics)
- src/app/Constants.h (scene lists, FX IDs, MIDI constants)
- src/app/shaders/vjay_shaders.metal (all Metal kernels)
- src/app/MetalCompositor.* (rendering pipeline)
- src/app/AudioAnalyzer.* (audio band layout & injection points)

## AI assistant config files
- No CLAUDE.md, AGENTS.md, .cursorrules, .windsurfrules, CONVENTIONS.md, or similar assistant config files were found. Add them to the repo if you want Copilot/other assistants to follow extra conventions.

---

Created to help future Copilot sessions quickly find build/run commands, the main systems, and repository-specific patterns. Update this file when platform, build targets, or input mappings change.