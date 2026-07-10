#include "../CompositorFactory.h"

#include "WindowsCompositorD3D11.h"
#include "WindowsCompositorStub.h"

std::unique_ptr<ICompositor> createCompositor() {
    auto d3d11 = std::make_unique<WindowsCompositorD3D11>();
    if (d3d11->init()) {
        return d3d11;
    }
    return std::make_unique<WindowsCompositorStub>();
}
