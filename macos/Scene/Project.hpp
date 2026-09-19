#pragma once
#include "WPUserProperties.hpp"
#include <filesystem>
#include <nlohmann/json.hpp>

namespace vivid::scene {
struct Project {
    std::filesystem::path source;
    std::filesystem::path assets;
    wallpaper::UserPropertyMap properties;
    nlohmann::json property_definitions;
    static wallpaper::UserPropertyMap parseProperties(nlohmann::json definitions,
                                                      const nlohmann::json& values);
    static Project load(const std::filesystem::path&, const std::filesystem::path&);
};
} // namespace vivid::scene
