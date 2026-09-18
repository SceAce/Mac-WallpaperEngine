#include "Device.hpp"
#include "Image.hpp"
#include "MetalImage.hpp"
#include "VideoTextureCache.hpp"

#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <stdexcept>

using namespace wallpaper;
using namespace wallpaper::vulkan;

namespace {

struct Entry {
    std::string key;
    NSURL* file = nil;
    AVPlayer* player = nil;
    AVPlayerItemVideoOutput* output = nil;
    ExImageParameters target;
    std::optional<ExImageParameters> decoded;
    std::shared_ptr<void> pixel_buffer;
    bool paused = false;
    bool stopped = false;
    bool initialized = false;
    bool dirty = false;
    double rate = 1.0;

    ~Entry() {
        [player pause];
        [player replaceCurrentItemWithPlayerItem:nil];
        if (file)
            [[NSFileManager defaultManager] removeItemAtURL:file error:nil];
    }
};

class AVFoundationVideoTextureCache final : public VideoTextureCache {
  public:
    explicit AVFoundationVideoTextureCache(const Device& device) : device_(device) {}

    ImageSlotsRef Acquire(std::string_view key, const SceneTexture& texture, const Image& image,
                          VideoTexturePlaybackState state) override {
        @autoreleasepool {
            auto found = entries_.find(std::string(key));
            if (found == entries_.end()) {
                if (image.slots.empty() || image.slots[0].mipmaps.empty() ||
                    !image.slots[0].mipmaps[0].data || image.slots[0].mipmaps[0].size <= 0)
                    throw std::runtime_error("Video texture has no encoded payload: " + std::string(key));
                auto entry = std::make_unique<Entry>();
                entry->key = key;
                entry->file = [NSURL
                    fileURLWithPath:[NSTemporaryDirectory()
                                        stringByAppendingPathComponent:[NSUUID.UUID.UUIDString
                                                                           stringByAppendingString:@".mp4"]]];
                const auto& payload = image.slots[0].mipmaps[0];
                NSData* data = [NSData dataWithBytesNoCopy:payload.data.get()
                                                    length:static_cast<NSUInteger>(payload.size)
                                              freeWhenDone:NO];
                NSError* error = nil;
                if (![data writeToURL:entry->file options:NSDataWritingAtomic error:&error])
                    throw std::runtime_error(error.localizedDescription.UTF8String);
                AVPlayerItem* item = [AVPlayerItem playerItemWithURL:entry->file];
                entry->output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{
                    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                    (id)kCVPixelBufferMetalCompatibilityKey : @YES,
                    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
                }];
                entry->output.suppressesPlayerRendering = YES;
                [item addOutput:entry->output];
                entry->player = [AVPlayer playerWithPlayerItem:item];
                entry->player.muted = YES;
                entry->player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
                const auto width = static_cast<uint32_t>(
                    std::max(1, texture.mapWidth > 0 ? texture.mapWidth : image.slots[0].width));
                const auto height = static_cast<uint32_t>(
                    std::max(1, texture.mapHeight > 0 ? texture.mapHeight : image.slots[0].height));
                auto target = device_.tex_cache().CreateExTex(width, height, VK_FORMAT_R8G8B8A8_UNORM,
                                                              VK_IMAGE_TILING_OPTIMAL,
                                                              ExternalFrameExportMode::IOSURFACE);
                if (!target)
                    throw std::runtime_error("Cannot create video texture: " + std::string(key));
                entry->target = std::move(*target);
                found = entries_.emplace(std::string(key), std::move(entry)).first;
            }
            auto& entry = *found->second;
            entry.stopped = state == VideoTexturePlaybackState::Stopped;
            entry.paused = state != VideoTexturePlaybackState::Playing;
            applyRate(entry);
            ImageSlotsRef result;
            result.slots.push_back(ImageParameters(entry.target));
            return result;
        }
    }

    void ApplyPlaybackStates(const std::unordered_map<std::string, bool>& paused,
                             const std::unordered_set<std::string>& stopped,
                             const std::unordered_map<std::string, double>& rates) override {
        for (auto& [key, owned] : entries_) {
            auto& entry = *owned;
            const bool was_stopped = entry.stopped;
            entry.stopped = stopped.contains(key);
            if (const auto it = paused.find(key); it != paused.end())
                entry.paused = it->second;
            if (const auto it = rates.find(key); it != rates.end()) {
                if (std::isfinite(it->second) && it->second > 0)
                    entry.rate = it->second;
            }
            if (entry.stopped && !was_stopped)
                [entry.player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
            applyRate(entry);
        }
    }

    void SetGlobalPaused(bool paused) override {
        paused_ = paused;
        for (auto& [_, entry] : entries_)
            applyRate(*entry);
    }

    void ApplySeekRequests(std::unordered_map<std::string, double>& requests) override {
        for (auto it = requests.begin(); it != requests.end();) {
            const auto entry = entries_.find(it->first);
            if (entry == entries_.end()) {
                ++it;
                continue;
            }
            if (std::isfinite(it->second) && it->second >= 0) {
                [entry->second->player seekToTime:CMTimeMakeWithSeconds(it->second, 600)
                                  toleranceBefore:kCMTimeZero
                                   toleranceAfter:kCMTimeZero];
            }
            it = requests.erase(it);
        }
    }

    void Poll() override {
        @autoreleasepool {
            for (auto& [_, owned] : entries_) {
                auto& entry = *owned;
                AVPlayerItem* item = entry.player.currentItem;
                if (item.status == AVPlayerItemStatusFailed)
                    throw std::runtime_error("Video texture " + entry.key + ": " +
                                             item.error.localizedDescription.UTF8String);
                const auto time = item.currentTime;
                const auto duration = CMTimeGetSeconds(item.duration);
                if (!paused_ && !entry.paused && !entry.stopped && std::isfinite(duration) && duration > 0 &&
                    CMTimeGetSeconds(time) >= duration) {
                    [entry.player seekToTime:kCMTimeZero
                             toleranceBefore:kCMTimeZero
                              toleranceAfter:kCMTimeZero];
                    applyRate(entry);
                }
                if (![entry.output hasNewPixelBufferForItemTime:time])
                    continue;
                CVPixelBufferRef pixel = [entry.output copyPixelBufferForItemTime:time
                                                               itemTimeForDisplay:nil];
                if (!pixel)
                    continue;
                auto retained = std::shared_ptr<void>(
                    pixel, [](void* p) { CVPixelBufferRelease(static_cast<CVPixelBufferRef>(p)); });
                auto decoded = ImportIOSurfaceImage(device_, CVPixelBufferGetIOSurface(pixel),
                                                    VK_FORMAT_B8G8R8A8_UNORM, true);
                if (!decoded)
                    throw std::runtime_error("Cannot import decoded video IOSurface: " + entry.key);
                entry.decoded = std::move(decoded);
                entry.pixel_buffer = std::move(retained);
                entry.dirty = true;
            }
        }
    }

    void PublishRuntimeStates(std::unordered_map<std::string, VideoTextureRuntimeState>& states,
                              const std::unordered_set<std::string>& requested) override {
        for (const auto& key : requested) {
            const auto it = entries_.find(key);
            if (it == entries_.end())
                continue;
            const auto& entry = *it->second;
            const double duration = CMTimeGetSeconds(entry.player.currentItem.duration);
            const double time = CMTimeGetSeconds(entry.player.currentTime);
            states[key] = {std::isfinite(time) ? time : 0.0, std::isfinite(duration) ? duration : 0.0,
                           entry.rate, entry.player.rate != 0};
        }
    }

    void RecordUploads(vvk::CommandBuffer& command) override {
        for (auto& [_, owned] : entries_) {
            auto& entry = *owned;
            if (entry.initialized && !entry.dirty)
                continue;
            VkImageMemoryBarrier target{
                .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .srcAccessMask = entry.initialized ? VK_ACCESS_SHADER_READ_BIT : 0u,
                .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
                .oldLayout =
                    entry.initialized ? VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL : VK_IMAGE_LAYOUT_UNDEFINED,
                .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                .image = *entry.target.handle,
                .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
            };
            command.PipelineBarrier(VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
                                    target);
            if (entry.dirty && entry.decoded) {
                auto source = target;
                source.srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT;
                source.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
                source.oldLayout = VK_IMAGE_LAYOUT_PREINITIALIZED;
                source.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
                source.image = *entry.decoded->handle;
                command.PipelineBarrier(VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
                                        source);
                VkImageBlit blit{
                    .srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
                    .srcOffsets = {{0, 0, 0},
                                   {static_cast<int32_t>(entry.decoded->extent.width),
                                    static_cast<int32_t>(entry.decoded->extent.height), 1}},
                    .dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
                    .dstOffsets = {{0, 0, 0},
                                   {static_cast<int32_t>(entry.target.extent.width),
                                    static_cast<int32_t>(entry.target.extent.height), 1}},
                };
                command.BlitImage(source.image, source.newLayout, target.image, target.newLayout,
                                  std::span<VkImageBlit>(&blit, 1), VK_FILTER_LINEAR);
            } else {
                VkClearColorValue black{{0, 0, 0, 1}};
                command.ClearColorImage(target.image, target.newLayout, &black, target.subresourceRange);
            }
            target.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
            target.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
            target.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
            target.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            command.PipelineBarrier(VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0,
                                    target);
            entry.initialized = true;
            entry.dirty = false;
        }
    }

    void Clear() override { entries_.clear(); }
    bool Release(std::string_view key) override { return entries_.erase(std::string(key)) != 0; }
    std::size_t GetTrackedBytes() const override {
        std::size_t bytes = 0;
        for (const auto& [_, entry] : entries_)
            bytes += entry->target.mem_reqs.size + (entry->decoded ? entry->decoded->mem_reqs.size : 0);
        return bytes;
    }
    std::size_t GetTrackedEntryCount() const override { return entries_.size(); }

  private:
    const Device& device_;
    std::unordered_map<std::string, std::unique_ptr<Entry>> entries_;
    bool paused_ = false;

    void applyRate(Entry& entry) {
        const float desired =
            paused_ || entry.paused || entry.stopped ? 0.0f : static_cast<float>(entry.rate);
        if (entry.player.rate != desired)
            entry.player.rate = desired;
    }
};
} // namespace

std::unique_ptr<VideoTextureCache> wallpaper::vulkan::CreateVideoTextureCache(const Device& device,
                                                                              VideoTextureDecoderSettings) {
    return std::make_unique<AVFoundationVideoTextureCache>(device);
}
