#pragma once
#include "Parameters.hpp"
#include <IOSurface/IOSurfaceRef.h>
#include <optional>

namespace wallpaper::vulkan
{
class Device;
std::optional<ExImageParameters> ImportIOSurfaceImage(const Device&, IOSurfaceRef, VkFormat,
                                                      bool initialized = false);
} // namespace wallpaper::vulkan
