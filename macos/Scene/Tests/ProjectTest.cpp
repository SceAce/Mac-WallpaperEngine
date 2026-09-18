#include "Project.hpp"
#include <fstream>
#include <iostream>
#include <nlohmann/json.hpp>
#include <stdexcept>
#include <unistd.h>

namespace fs = std::filesystem;

int main() {
    const auto root = fs::temp_directory_path() / ("vivid-project-test-" + std::to_string(getpid()));
    struct Cleanup {
        fs::path path;
        ~Cleanup() {
            std::error_code error;
            fs::remove_all(path, error);
        }
    } cleanup{root};
    try {
        fs::create_directories(root / "assets/shaders");
        std::ofstream(root / "assets/shaders/common.h") << "// fixture";
        std::ofstream(root / "scene.pkg") << "fixture";
        nlohmann::json manifest = {
            {"type", "Scene"},
            {"file", "scene.json"},
            {"general",
             {{"properties",
               {{"toggle", {{"type", "bool"}, {"value", "false"}}},
                {"enabled", {{"type", "bool"}, {"value", 0.5}}},
                {"color", {{"type", "color"}, {"value", {0.2, 0.4, 0.6}}}},
                {"text", {{"type", "textinput"}, {"value", "123 hello"}}},
                {"combo", {{"type", "combo"}, {"value", "1"}}},
                {"vector", {{"type", "color"}, {"value", "0.5, 0.25, 1"}, {"condition", "enabled"}}}}}}}};
        const auto save = [&] { std::ofstream(root / "project.json") << manifest; };
        const auto require = [](bool condition) {
            if (!condition)
                throw std::runtime_error("Project contract mismatch");
        };
        save();
        const auto project = vivid::scene::Project::load(root, root / "assets");
        require(project.properties.size() == 6);
        require(!wallpaper::IsUserPropertyTruthy(project.properties.at("toggle").value));
        require(wallpaper::IsUserPropertyTruthy(project.properties.at("enabled").value));
        require(std::get<std::string>(project.properties.at("text").value) == "123 hello");
        require(std::get<std::string>(project.properties.at("combo").value) == "1");
        require(std::get<wallpaper::ShaderValue>(project.properties.at("color").value).size() == 3);
        require(std::get<wallpaper::ShaderValue>(project.properties.at("vector").value).size() == 3);
        require(project.properties.at("vector").condition == "enabled");
        for (const auto entry : {"../scene.json", "/tmp/scene.json", "missing.json"}) {
            manifest["file"] = entry;
            save();
            bool rejected = false;
            try {
                (void)vivid::scene::Project::load(root, root / "assets");
            } catch (const std::runtime_error&) {
                rejected = true;
            }
            require(rejected);
        }
        std::cout << "PASS: scene project paths and user properties\n";
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
