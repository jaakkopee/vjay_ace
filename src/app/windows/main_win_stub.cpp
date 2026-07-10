#include <iostream>

#include "../CompositorFactory.h"

int main() {
    auto compositor = createCompositor();
    if (!compositor) {
        std::cerr << "Windows compositor factory returned null." << std::endl;
        return 1;
    }

    if (!compositor->init()) {
        std::cerr << "Windows compositor stub failed to initialize." << std::endl;
        return 2;
    }

    std::cout << "vjay_ace Windows compositor stub wired via factory." << std::endl;
    return 0;
}
