#pragma once
#include "WPUserProperties.hpp"
#include <filesystem>

namespace vivid::scene {
struct Project {
    std::filesystem::path source;
    std::filesystem::path assets;
    wallpaper::UserPropertyMap properties;
    static Project load(const std::filesystem::path&, const std::filesystem::path&);
};
} // namespace vivid::scene
