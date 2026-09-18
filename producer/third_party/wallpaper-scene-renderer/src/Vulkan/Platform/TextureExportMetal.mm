#include "Device.hpp"
#include "MetalImage.hpp"
#include "TextureCache.hpp"
#include "Utils/Logging.h"

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>

using namespace wallpaper;
using namespace wallpaper::vulkan;

std::optional<ExImageParameters> wallpaper::vulkan::ImportIOSurfaceImage(const Device& renderer,
                                                                         IOSurfaceRef surface,
                                                                         VkFormat format, bool initialized) {
    if (!surface)
        return std::nullopt;
    @autoreleasepool {
        const auto width = static_cast<uint32_t>(IOSurfaceGetWidth(surface));
        const auto height = static_cast<uint32_t>(IOSurfaceGetHeight(surface));
        ExImageParameters image;
        CFRetain(surface);
        image.native_surface =
            std::shared_ptr<void>(surface, [](void* value) { CFRelease(static_cast<IOSurfaceRef>(value)); });
        image.handle_type = ExternalFrameHandleType::IOSURFACE;
        image.extent = {width, height, 1};
        VkImportMetalIOSurfaceInfoEXT import_info{
            .sType = VK_STRUCTURE_TYPE_IMPORT_METAL_IO_SURFACE_INFO_EXT,
            .ioSurface = surface,
        };
        VkImageCreateInfo image_info{
            .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = &import_info,
            .imageType = VK_IMAGE_TYPE_2D,
            .format = format,
            .extent = image.extent,
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = VK_SAMPLE_COUNT_1_BIT,
            .tiling = VK_IMAGE_TILING_OPTIMAL,
            .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT |
                     VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
            .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
            .initialLayout = initialized ? VK_IMAGE_LAYOUT_PREINITIALIZED : VK_IMAGE_LAYOUT_UNDEFINED,
        };
        const auto& device = renderer.handle();
        VVK_CHECK_ACT(return std::nullopt, device.CreateImage(image_info, image.handle));
        image.mem_reqs = device.GetImageMemoryRequirements(*image.handle);
        const auto properties_mem = renderer.gpu().GetMemoryProperties().memoryProperties;
        uint32_t memory_type = properties_mem.memoryTypeCount;
        for (uint32_t i = 0; i < properties_mem.memoryTypeCount; ++i) {
            if ((image.mem_reqs.memoryTypeBits & (1u << i)) &&
                (properties_mem.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
                memory_type = i;
                break;
            }
        }
        if (memory_type == properties_mem.memoryTypeCount)
            return std::nullopt;
        VkMemoryDedicatedAllocateInfo dedicated{
            .sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
            .image = *image.handle,
        };
        VkMemoryAllocateInfo allocation{
            .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = &dedicated,
            .allocationSize = image.mem_reqs.size,
            .memoryTypeIndex = memory_type,
        };
        VVK_CHECK_ACT(return std::nullopt, device.AllocateMemory(allocation, image.mem));
        VVK_CHECK_ACT(return std::nullopt, image.handle.BindMemory(*image.mem, 0));
        VkImageViewCreateInfo view_info{
            .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = *image.handle,
            .viewType = VK_IMAGE_VIEW_TYPE_2D,
            .format = format,
            .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
        };
        VVK_CHECK_ACT(return std::nullopt, device.CreateImageView(view_info, image.view));
        VkSamplerCreateInfo sampler_info{
            .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .magFilter = VK_FILTER_LINEAR,
            .minFilter = VK_FILTER_LINEAR,
            .mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        };
        VVK_CHECK_ACT(return std::nullopt, device.CreateSampler(sampler_info, image.sampler));

        return image;
    }
}

std::optional<ExImageParameters> TextureCache::CreateExTex(uint32_t width, uint32_t height, VkFormat format,
                                                           VkImageTiling tiling,
                                                           ExternalFrameExportMode export_mode, uint32_t,
                                                           std::span<const uint64_t>,
                                                           ExternalFrameMemoryPreference) {
    if (export_mode != ExternalFrameExportMode::IOSURFACE || format != VK_FORMAT_R8G8B8A8_UNORM ||
        tiling != VK_IMAGE_TILING_OPTIMAL) {
        LOG_ERROR("macOS output requires an optimal RGBA8 IOSurface");
        return std::nullopt;
    }
    @autoreleasepool {
        const size_t row_bytes = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, size_t(width) * 4);
        NSDictionary* properties = @{
            (id)kIOSurfaceWidth : @(width),
            (id)kIOSurfaceHeight : @(height),
            (id)kIOSurfaceBytesPerElement : @4,
            (id)kIOSurfaceBytesPerRow : @(row_bytes),
            (id)kIOSurfaceAllocSize : @(row_bytes * height),
            (id)kIOSurfacePixelFormat : @(kCVPixelFormatType_32RGBA),
        };
        IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
        if (!surface)
            return std::nullopt;
        auto result = ImportIOSurfaceImage(m_device, surface, format);
        CFRelease(surface);
        return result;
    }
}
