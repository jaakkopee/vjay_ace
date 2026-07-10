#pragma once

#include <memory>

class ICompositor;

std::unique_ptr<ICompositor> createCompositor();
