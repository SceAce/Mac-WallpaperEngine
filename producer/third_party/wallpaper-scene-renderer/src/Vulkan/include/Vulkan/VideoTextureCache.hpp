#pragma once

#include "Core/NoCopyMove.hpp"
#include "Parameters.hpp"
#include "Scene/SceneTexture.h"

#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace wallpaper
{

class Image;
struct SceneTexture;

namespace vulkan
{

class Device;

enum class VideoTextureDecoderRoute
{
    Nvidia,
    Va,
    Native,
};

struct VideoTextureDecoderSettings {
    VideoTextureDecoderRoute decoder_route { VideoTextureDecoderRoute::Nvidia };
    /* DRM render node backing the renderer device; selects per-device VA factories. */
    std::string render_node;
};

class VideoTextureCache : NoCopy, NoMove {
public:
    virtual ~VideoTextureCache() = default;

    virtual ImageSlotsRef
    Acquire(std::string_view          key, const SceneTexture&, const Image&,
            VideoTexturePlaybackState initial_state = VideoTexturePlaybackState::Playing) = 0;
    virtual void
                 ApplyPlaybackStates(const std::unordered_map<std::string, bool>&   paused_by_key,
                                     const std::unordered_set<std::string>&         stopped_keys,
                                     const std::unordered_map<std::string, double>& rates_by_key) = 0;
    virtual void SetGlobalPaused(bool paused) = 0;
    virtual void
    ApplySeekRequests(std::unordered_map<std::string, double>& seek_seconds_by_key) = 0;
    virtual void Poll()                                                             = 0;
    virtual void
    PublishRuntimeStates(std::unordered_map<std::string, VideoTextureRuntimeState>& states,
                         const std::unordered_set<std::string>& requested_keys) = 0;
    virtual void        RecordUploads(vvk::CommandBuffer&)                      = 0;
    virtual void        Clear()                                                 = 0;
    virtual bool        Release(std::string_view key)                           = 0;
    virtual std::size_t GetTrackedBytes() const                                 = 0;
    virtual std::size_t GetTrackedEntryCount() const                            = 0;

protected:
    VideoTextureCache() = default;
};

std::unique_ptr<VideoTextureCache>
CreateVideoTextureCache(const Device&, VideoTextureDecoderSettings settings = {});

} // namespace vulkan
} // namespace wallpaper
