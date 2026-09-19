#include "Project.hpp"
#include <fstream>
#include <locale>
#include <nlohmann/json.hpp>
#include <sstream>
#include <stdexcept>

using namespace vivid::scene;
namespace fs = std::filesystem;

Project Project::load(const fs::path& directory, const fs::path& assets_directory) {
    const auto root = fs::canonical(directory);
    std::ifstream stream(root / "project.json");
    if (!stream)
        throw std::runtime_error("Missing project.json: " + root.string());
    const auto manifest = nlohmann::json::parse(stream);
    const auto type = wallpaper::LowerString(manifest.value("type", std::string{}));
    const auto entry = fs::path(manifest.value("file", std::string{"scene.json"}));
    if ((!type.empty() && type != "scene") || entry.is_absolute())
        throw std::runtime_error("Project is not a scene wallpaper");
    for (const auto& component : entry)
        if (component == "..")
            throw std::runtime_error("Scene entry escapes project directory");
    Project project;
    project.source = root / entry;
    auto package = project.source;
    package.replace_extension("pkg");
    if (!fs::is_regular_file(project.source) && !fs::is_regular_file(package))
        throw std::runtime_error("Missing scene entry or package: " + project.source.string());
    project.assets = fs::canonical(assets_directory);
    if (!fs::is_regular_file(project.assets / "shaders/common.h"))
        throw std::runtime_error("Invalid Wallpaper Engine assets directory");
    const auto general = manifest.value("general", nlohmann::json::object());
    project.property_definitions = general.value("properties", nlohmann::json::object());
    project.properties = parseProperties(project.property_definitions, nlohmann::json::object());
    return project;
}

wallpaper::UserPropertyMap Project::parseProperties(nlohmann::json definitions,
                                                    const nlohmann::json& values) {
    if (!values.is_object())
        throw std::runtime_error("User properties must be an object");
    for (const auto& [name, value] : values.items()) {
        if (definitions.contains(name) && definitions[name].is_object())
            definitions[name]["value"] =
                value.is_object() && value.contains("value") ? value["value"] : value;
    }
    wallpaper::UserPropertyMap result;
    for (const auto& [name, object] : definitions.items()) {
        if (!object.is_object() || !object.contains("value"))
            continue;
        const auto property_type = wallpaper::LowerString(object.value("type", std::string{}));
        const auto& value = object.at("value");
        wallpaper::UserProperty property;
        property.condition = object.value("condition", std::string{});
        property.is_boolean = property_type == "bool";
        const bool string_value = property_type == "text" || property_type == "textinput" ||
                                  property_type == "combo" || property_type == "file" ||
                                  property_type == "directory" || property_type == "scenetexture";
        if (value.is_array()) {
            if (string_value || value.empty())
                continue;
            std::vector<float> components;
            for (const auto& component : value) {
                if (component.is_boolean())
                    components.push_back(component.get<bool>() ? 1.0f : 0.0f);
                else if (component.is_number())
                    components.push_back(component.get<float>());
                else
                    throw std::runtime_error("Non-numeric property component: " + name);
            }
            property.value = wallpaper::ShaderValue(components);
        } else if (property.is_boolean) {
            bool enabled;
            if (value.is_boolean())
                enabled = value.get<bool>();
            else if (value.is_number())
                enabled = std::abs(value.get<double>()) >= 0.0001;
            else if (value.is_string()) {
                const auto text = wallpaper::LowerString(value.get<std::string>());
                enabled = !text.empty() && text != "0" && text != "false";
            } else
                continue;
            property.value = wallpaper::MakeUserPropertyBool(enabled);
        } else if (value.is_boolean()) {
            property.value = wallpaper::MakeUserPropertyBool(value.get<bool>());
        } else if (value.is_number()) {
            if (string_value)
                property.value = value.dump();
            else
                property.value = wallpaper::MakeUserPropertyNumber(value.get<float>());
        } else if (value.is_string()) {
            auto text = value.get<std::string>();
            if (string_value) {
                property.value = std::move(text);
                result.emplace(name, std::move(property));
                continue;
            }
            std::replace(text.begin(), text.end(), ',', ' ');
            std::istringstream tokens(text);
            tokens.imbue(std::locale::classic());
            std::vector<float> components;
            std::string token;
            while (tokens >> token) {
                std::istringstream number_stream(token);
                number_stream.imbue(std::locale::classic());
                float number;
                if (number_stream >> number)
                    components.push_back(number);
            }
            if (components.empty())
                property.value = value.get<std::string>();
            else
                property.value = wallpaper::ShaderValue(components);
        } else {
            continue;
        }
        result.emplace(name, std::move(property));
    }
    return result;
}
