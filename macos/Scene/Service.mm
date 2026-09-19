#include "Project.hpp"
#include "SceneWallpaper.hpp"
#include "SceneWallpaperSurface.hpp"
#include "Vulkan/VulkanExSwapchain.hpp"
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#include <array>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <xpc/xpc.h>

namespace {
constexpr uint64_t protocol_version = 1;
struct Slot {
    enum class State { Free, Writing, Ready } state = State::Free;
    uint64_t sequence = 0;
};

class Session : public std::enable_shared_from_this<Session> {
  public:
    explicit Session(xpc_connection_t peer)
        : peer_(peer),
          queue_(dispatch_queue_create(
              "org.sceace.vivid.scene.session",
              dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0))) {}
    dispatch_queue_t queue() const { return queue_; }

    void receive(xpc_object_t message) {
        try {
            if (xpc_dictionary_get_uint64(message, "version") != protocol_version)
                throw std::runtime_error("Scene protocol version mismatch");
            const auto operation = string(message, "operation");
            if (operation == "start") {
                if (renderer_ || stopped_)
                    throw std::runtime_error("Scene session already started or stopped");
                start(message);
            } else if (operation == "release") {
                const auto slot = xpc_dictionary_get_uint64(message, "slot");
                const auto sequence = xpc_dictionary_get_uint64(message, "sequence");
                std::lock_guard lock(mutex_);
                if (xpc_dictionary_get_uint64(message, "generation") == 1 && slot < slots_.size() &&
                    slots_[slot].state == Slot::State::Ready && slots_[slot].sequence == sequence)
                    slots_[slot].state = Slot::State::Free;
            } else if (operation == "pointer" && renderer_) {
                const double x = xpc_dictionary_get_double(message, "x");
                const double y = xpc_dictionary_get_double(message, "y");
                if (std::isfinite(x) && std::isfinite(y))
                    renderer_->mouseInput(x, y);
                renderer_->mouseLeftButton(xpc_dictionary_get_bool(message, "left"));
            } else if (operation == "pause" && renderer_) {
                const bool paused = xpc_dictionary_get_bool(message, "paused");
                setActive(!paused);
                if (paused)
                    renderer_->pause();
                else
                    renderer_->play();
            } else if (operation == "configure" && renderer_) {
                configure(message, false);
            } else if (operation == "stop") {
                stop();
            } else {
                throw std::runtime_error("Invalid scene operation");
            }
        } catch (const std::exception& error) {
            fail(error.what());
        }
    }

    void stop() {
        {
            std::lock_guard lock(mutex_);
            stopped_ = true;
        }
        renderer_.reset();
        setActive(false);
        request_ = nil;
    }

  private:
    nlohmann::json property_definitions_;
    nlohmann::json last_properties_;
    xpc_connection_t peer_;
    // The start request owns the asynchronous rendering transaction until teardown.
    // Retaining it also preserves the client's XPC importance donation while drawing.
    xpc_object_t request_ = nil;
    dispatch_queue_t queue_;
    std::unique_ptr<wallpaper::SceneWallpaper> renderer_;
    wallpaper::ExSwapchain* swapchain_ = nullptr;
    std::mutex mutex_;
    std::array<Slot, 3> slots_;
    uint64_t sequence_ = 0;
    bool stopped_ = false;
    id activity_ = nil;

    void setActive(bool active) {
        if (active && !activity_)
            activity_ = [NSProcessInfo.processInfo
                beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
                                  reason:@"Render the active desktop wallpaper"];
        else if (!active && activity_) {
            [NSProcessInfo.processInfo endActivity:activity_];
            activity_ = nil;
        }
    }

    static std::string string(xpc_object_t message, const char* key) {
        const char* value = xpc_dictionary_get_string(message, key);
        if (!value || !*value)
            throw std::runtime_error(std::string("Missing scene field: ") + key);
        return value;
    }

    xpc_object_t event(const char* operation) const {
        auto message = xpc_dictionary_create(nullptr, nullptr, 0);
        xpc_dictionary_set_uint64(message, "version", protocol_version);
        xpc_dictionary_set_uint64(message, "generation", 1);
        xpc_dictionary_set_string(message, "operation", operation);
        return message;
    }

    void fail(const std::string& reason) {
        auto message = event("failed");
        xpc_dictionary_set_string(message, "reason", reason.c_str());
        xpc_connection_send_message(peer_, message);
        stop();
    }

    void configure(xpc_object_t message, bool initial) {
        size_t length = 0;
        const auto* bytes = static_cast<const char*>(xpc_dictionary_get_data(message, "settings", &length));
        if (!bytes)
            return;
        if (length > 1024 * 1024)
            throw std::runtime_error("Scene settings exceed size limit");
        const auto settings = nlohmann::json::parse(bytes, bytes + length);
        const int fps = settings.value("fps", 30);
        const int fit = settings.value("fit", 1);
        const float volume = settings.value("volume", 1.0f);
        if (fps < 5 || fps > 240 || fit < 1 || fit > 3 || !std::isfinite(volume) || volume < 0 || volume > 1)
            throw std::runtime_error("Invalid scene playback settings");
        renderer_->setPropertyInt32(wallpaper::PROPERTY_FPS, fps);
        renderer_->setPropertyBool(wallpaper::PROPERTY_MUTED, settings.value("muted", false));
        renderer_->setPropertyFloat(wallpaper::PROPERTY_VOLUME, volume);
        const auto fill = fit == 1   ? wallpaper::FillMode::ASPECTCROP
                          : fit == 2 ? wallpaper::FillMode::ASPECTFIT
                                     : wallpaper::FillMode::STRETCH;
        renderer_->setPropertyInt32(wallpaper::PROPERTY_FILLMODE, static_cast<int32_t>(fill));
        const auto values = settings.value("properties", nlohmann::json::object());
        if (initial || values != last_properties_) {
            auto properties = vivid::scene::Project::parseProperties(property_definitions_, values);
            renderer_->setPropertyObject(initial ? wallpaper::PROPERTY_LOAD_USER_PROPERTIES
                                                 : wallpaper::PROPERTY_USER_PROPERTIES,
                                         std::make_shared<wallpaper::UserPropertyMap>(std::move(properties)));
            last_properties_ = values;
        }
    }

    void start(xpc_object_t message) {
        request_ = message;
        const auto cache = std::filesystem::path(string(message, "cache"));
        std::filesystem::create_directories(cache);
        const auto log = cache / ("scene-" + std::to_string(getpid()) + ".log");
        if (!std::freopen(log.c_str(), "w", stderr))
            throw std::runtime_error("Cannot create scene log");
        const auto project =
            vivid::scene::Project::load(string(message, "project"), string(message, "assets"));
        const auto width = xpc_dictionary_get_uint64(message, "width");
        const auto height = xpc_dictionary_get_uint64(message, "height");
        if (!width || !height || width > 8192 || height > 8192)
            throw std::runtime_error("Invalid scene dimensions");
        auto weak = weak_from_this();
        setActive(true);
        renderer_ = std::make_unique<wallpaper::SceneWallpaper>([weak](std::string reason) {
            if (auto self = weak.lock())
                dispatch_async(self->queue_, ^{
                  self->fail(reason);
                });
        });
        if (!renderer_->init())
            throw std::runtime_error("Scene initialization failed");
        renderer_->setOffscreenFrameReleaseCallback([weak](uint32_t slot) {
            const auto self = weak.lock();
            if (!self)
                return false;
            std::lock_guard lock(self->mutex_);
            if (self->stopped_ || slot >= self->slots_.size() ||
                self->slots_[slot].state != Slot::State::Free)
                return false;
            self->slots_[slot] = {Slot::State::Writing, ++self->sequence_};
            return true;
        });
        renderer_->setOffscreenFrameReadyCallback([weak](uint32_t slot) {
            const auto self = weak.lock();
            if (!self)
                return;
            uint64_t sequence;
            {
                std::lock_guard lock(self->mutex_);
                if (self->stopped_ || slot >= self->slots_.size() ||
                    self->slots_[slot].state != Slot::State::Writing)
                    return;
                self->slots_[slot].state = Slot::State::Ready;
                sequence = self->slots_[slot].sequence;
            }
            self->swapchain_->eatFrame();
            dispatch_async(self->queue_, ^{
              auto ready = self->event("frame");
              xpc_dictionary_set_uint64(ready, "slot", slot);
              xpc_dictionary_set_uint64(ready, "sequence", sequence);
              xpc_connection_send_message(self->peer_, ready);
            });
        });
        wallpaper::RenderInitInfo info;
        info.offscreen = true;
        info.export_mode = wallpaper::ExternalFrameExportMode::IOSURFACE;
        info.width = static_cast<uint16_t>(width);
        info.height = static_cast<uint16_t>(height);
        info.ex_swapchain_factory = [weak, width,
                                     height](const wallpaper::RenderInitInfo::ExSwapchainHandles& handles) {
            auto chain = wallpaper::vulkan::CreateExSwapchain(
                *handles.renderer_device, static_cast<uint32_t>(width), static_cast<uint32_t>(height),
                VK_IMAGE_TILING_OPTIMAL, wallpaper::ExternalFrameExportMode::IOSURFACE);
            if (!chain)
                return chain;
            if (auto self = weak.lock())
                self->swapchain_ = chain.get();
            const auto snapshots = chain->handlesSnapshot();
            if (auto self = weak.lock())
                dispatch_async(self->queue_, ^{
                  auto pool = self->event("pool");
                  auto surfaces = xpc_array_create(nullptr, 0);
                  for (const auto& handle : snapshots) {
                      auto object =
                          IOSurfaceCreateXPCObject(static_cast<IOSurfaceRef>(handle.native_surface.get()));
                      xpc_array_append_value(surfaces, object);
                  }
                  xpc_dictionary_set_value(pool, "surfaces", surfaces);
                  xpc_connection_send_message(self->peer_, pool);
                });
            return chain;
        };
        renderer_->initVulkan(info);
        renderer_->setPropertyInt32(wallpaper::PROPERTY_FPS, 30);
        renderer_->setPropertyBool(wallpaper::PROPERTY_MUTED, xpc_dictionary_get_bool(message, "muted"));
        renderer_->setPropertyString(wallpaper::PROPERTY_CACHE_PATH, string(message, "cache"));
        renderer_->setPropertyObject(wallpaper::PROPERTY_LOAD_USER_PROPERTIES,
                                     std::make_shared<wallpaper::UserPropertyMap>(project.properties));
        property_definitions_ = project.property_definitions;
        configure(message, true);
        renderer_->setPropertyString(wallpaper::PROPERTY_ASSETS, project.assets.string());
        renderer_->setPropertyString(wallpaper::PROPERTY_SOURCE, project.source.string());
        renderer_->play();
    }
};
} // namespace

int main() {
    xpc_main([](xpc_connection_t peer) {
        const auto session = std::make_shared<Session>(peer);
        xpc_connection_set_target_queue(peer, session->queue());
        xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
          @autoreleasepool {
              if (xpc_get_type(message) == XPC_TYPE_DICTIONARY)
                  session->receive(message);
              else {
                  session->stop();
                  xpc_connection_set_event_handler(peer, ^(xpc_object_t){
                                                   });
              }
          }
        });
        xpc_connection_resume(peer);
    });
}
