#include "CompositorFactory.h"

#include "ICompositor.h"

#if defined(__APPLE__)
#include "MetalCompositor.h"
#endif

std::unique_ptr<ICompositor> createCompositor() {
#if defined(__APPLE__)
    return std::make_unique<MetalCompositor>();
#else
    return nullptr;
#endif
}
