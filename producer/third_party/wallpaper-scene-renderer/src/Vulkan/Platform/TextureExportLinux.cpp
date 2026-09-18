#include "TextureCache.hpp"
#include "Device.hpp"
#include "Utils/Logging.h"
#include <drm_fourcc.h>
#include <algorithm>
#include <limits>

using namespace wallpaper;
using namespace wallpaper::vulkan;

namespace {
constexpr uint32_t kDefaultDmabufFourcc = DRM_FORMAT_ABGR8888;
constexpr VkFormatFeatureFlags2 kRequiredDmabufFeatures =
    static_cast<VkFormatFeatureFlags2>(VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT) |
    static_cast<VkFormatFeatureFlags2>(VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT) |
    static_cast<VkFormatFeatureFlags2>(VK_FORMAT_FEATURE_TRANSFER_DST_BIT);

std::vector<uint64_t> FilterSupportedDrmModifiers(const vvk::PhysicalDevice& gpu,
                                                  VkFormat                   format,
                                                  std::span<const uint64_t>  preferred_modifiers) {
    if (preferred_modifiers.empty())
        return {};

    const auto supported_modifiers = gpu.GetDrmFormatModifierProperties2(format);
    std::vector<uint64_t> usable_modifiers;
    usable_modifiers.reserve(preferred_modifiers.size());

    for (const auto preferred_modifier : preferred_modifiers) {
        const auto it =
            std::find_if(supported_modifiers.begin(),
                         supported_modifiers.end(),
                         [preferred_modifier](const VkDrmFormatModifierProperties2EXT& candidate) {
                             return candidate.drmFormatModifier == preferred_modifier &&
                                 (candidate.drmFormatModifierTilingFeatures &
                                  kRequiredDmabufFeatures) == kRequiredDmabufFeatures;
                         });
        if (it != supported_modifiers.end())
            usable_modifiers.push_back(preferred_modifier);
    }

    return usable_modifiers;
}

VkResult TransImgLayout(const vvk::Queue& queue, vvk::CommandBuffer& cmd,
                        const ImageParameters& image, VkImageLayout layout) {
    VkResult result;
    do {
        result = cmd.Begin(VkCommandBufferBeginInfo {
            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = nullptr,
            .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        });
        if (result != VK_SUCCESS) break;

        VkImageSubresourceRange subresourceRange {
            .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel   = 0,
            .levelCount     = VK_REMAINING_MIP_LEVELS,
            .baseArrayLayer = 0,
            .layerCount     = VK_REMAINING_ARRAY_LAYERS,
        };
        {
            VkImageMemoryBarrier out_bar {
                .sType            = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .pNext            = nullptr,
                .srcAccessMask    = VK_ACCESS_MEMORY_WRITE_BIT,
                .dstAccessMask    = VK_ACCESS_MEMORY_READ_BIT,
                .oldLayout        = VK_IMAGE_LAYOUT_UNDEFINED,
                .newLayout        = layout,
                .image            = image.handle,
                .subresourceRange = subresourceRange,
            };
            cmd.PipelineBarrier(VK_PIPELINE_STAGE_TRANSFER_BIT,
                                VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                                VK_DEPENDENCY_BY_REGION_BIT,
                                out_bar);
        }
        result = cmd.End();
        if (result != VK_SUCCESS) break;

        VkSubmitInfo sub_info {
            .sType              = VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext              = nullptr,
            .commandBufferCount = 1,
            .pCommandBuffers    = cmd.address(),
        };
        result = queue.Submit(sub_info);
    } while (false);
    return result;
}

std::optional<vvk::DeviceMemory> AllocateMemory(const vvk::Device& device, vvk::PhysicalDevice gpu,
                                                VkMemoryRequirements  reqs,
                                                VkMemoryPropertyFlags property,
                                                VkMemoryPropertyFlags forbidden_property = 0,
                                                void*                 pNext = NULL) {
    VkPhysicalDeviceMemoryProperties pros = gpu.GetMemoryProperties().memoryProperties;
    for (uint32_t i = 0; i < pros.memoryTypeCount; ++i) {
        const VkMemoryPropertyFlags flags = pros.memoryTypes[i].propertyFlags;
        if ((reqs.memoryTypeBits & (1 << i)) &&
            (flags & property) == property &&
            (forbidden_property == 0 || (flags & forbidden_property) == 0)) {
            VkMemoryAllocateInfo memory_allocate_info { .sType =
                                                            VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                                        .pNext           = pNext,
                                                        .allocationSize  = reqs.size,
                                                        .memoryTypeIndex = i };
            vvk::DeviceMemory    mem;
            VkResult             res = device.AllocateMemory(memory_allocate_info, mem);
            if (res == VK_SUCCESS) {
                return mem;
            } else {
                VVK_CHECK(res);
                return std::nullopt;
            }
        }
    }
    LOG_ERROR("vulkan allocate memory failed, no memory type matches required=0x%x forbidden=0x%x",
              property,
              forbidden_property);
    return std::nullopt;
}

std::optional<ExImageParameters> CreateExImage(uint32_t width, uint32_t height, VkFormat format,
                                               VkImageTiling       tiling,
                                               VkSamplerCreateInfo sampler_info,
                                               VkImageUsageFlags usage, const vvk::Device& device,
                                               const vvk::PhysicalDevice& gpu,
                                               ExternalFrameExportMode export_mode,
                                               uint32_t export_drm_fourcc,
                                               std::span<const uint64_t> export_drm_modifiers,
                                               ExternalFrameMemoryPreference memory_preference) {
    ExImageParameters image;
    do {
        const bool dmabuf_export = export_mode == ExternalFrameExportMode::DMA_BUF;
        const auto drm_fourcc = export_drm_fourcc != 0 ? export_drm_fourcc : kDefaultDmabufFourcc;
        const auto usable_drm_modifiers =
            dmabuf_export ? FilterSupportedDrmModifiers(gpu, format, export_drm_modifiers)
                          : std::vector<uint64_t> {};
        const bool use_modifier_tiling = !usable_drm_modifiers.empty();

        if (dmabuf_export && !use_modifier_tiling && tiling != VK_IMAGE_TILING_LINEAR) {
            LOG_ERROR("dma-buf export currently requires linear image tiling");
            break;
        }

        const auto handle_type = dmabuf_export
            ? VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT
            : VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
        VkExternalMemoryImageCreateInfo ex_info {
            .sType       = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
            .pNext       = NULL,
            .handleTypes = handle_type
        };
        VkImageDrmFormatModifierListCreateInfoEXT drm_modifier_info {
            .sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT,
            .pNext = &ex_info,
            .drmFormatModifierCount = static_cast<uint32_t>(usable_drm_modifiers.size()),
            .pDrmFormatModifiers = usable_drm_modifiers.data(),
        };
        VkExportMemoryAllocateInfo ex_mem_info { .sType =
                                                     VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO,
                                                 .pNext = NULL,
                                                 .handleTypes = handle_type };
        VkImageCreateInfo          info {
                     .sType       = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
                     .pNext       = use_modifier_tiling
                        ? static_cast<const void*>(&drm_modifier_info)
                        : static_cast<const void*>(&ex_info),
                     .imageType   = VK_IMAGE_TYPE_2D,
                     .format      = format,
                     .extent      = VkExtent3D { .width = width, .height = height, .depth = 1 },
                     .mipLevels   = 1,
                     .arrayLayers = 1,
                     .samples     = VK_SAMPLE_COUNT_1_BIT,
                     .tiling      = use_modifier_tiling
                        ? VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT
                        : tiling,
                     .usage       = usage,
                     .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
                     .queueFamilyIndexCount = 0,
                     .initialLayout         = VK_IMAGE_LAYOUT_UNDEFINED,
        };
        image.extent = info.extent;
        image.handle_type = dmabuf_export
            ? ExternalFrameHandleType::DMA_BUF
            : ExternalFrameHandleType::OPAQUE_FD;

        VVK_CHECK_ACT(break, device.CreateImage(info, image.handle));

        image.mem_reqs = device.GetImageMemoryRequirements(*image.handle);

        VkMemoryDedicatedAllocateInfo dedicated_info {
            .sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
            .pNext = nullptr,
            .image = *image.handle,
            .buffer = VK_NULL_HANDLE,
        };
        /*
         * Keep the producer DMA-BUF contract identical to Waywallen's Vulkan
         * pool: one exported image owns one dedicated VkDeviceMemory
         * allocation.  In particular, do not infer modifier-image allocation
         * semantics from a LINEAR external-image capability query.
         */
        if (dmabuf_export)
            ex_mem_info.pNext = &dedicated_info;

        /*
         * Keep the historical DMA-BUF default as HOST_VISIBLE because it is the
         * safest cross-GPU export memory class. The producer can now explicitly
         * request DEVICE_LOCAL after it has proven that producer and consumer
         * are on the same render node and has selected a shared DRM modifier;
         * that is the waywallen-style fast path. Do not infer DEVICE_LOCAL from
         * modifier tiling alone, because a modifier can still be used in a relay
         * or cross-device topology where private VRAM is the wrong allocation.
         */
        VkMemoryPropertyFlags required_memory_flags = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
        VkMemoryPropertyFlags forbidden_memory_flags = 0;
        if (dmabuf_export) {
            if (memory_preference == ExternalFrameMemoryPreference::DeviceLocal) {
                required_memory_flags = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
            } else {
                required_memory_flags =
                    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
                if (gpu.GetProperties().deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU)
                    forbidden_memory_flags = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
            }
        }
        if (auto opt = AllocateMemory(device,
                                      gpu,
                                      image.mem_reqs,
                                      required_memory_flags,
                                      forbidden_memory_flags,
                                      &ex_mem_info);
            opt.has_value()) {
            image.mem = std::move(opt.value());
        } else
            break;

        VVK_CHECK_ACT(break, image.handle.BindMemory(*image.mem, 0));
        {
            VkImageViewCreateInfo createinfo {
                .sType    = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .pNext    = nullptr,
                .image    = *image.handle,
                .viewType = VK_IMAGE_VIEW_TYPE_2D,
                .format   = format,
                .subresourceRange =
                    VkImageSubresourceRange {
                        .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
                        .baseMipLevel   = 0,
                        .levelCount     = 1,
                        .baseArrayLayer = 0,
                        .layerCount     = 1,
                    },
            };
            VVK_CHECK_ACT(break, device.CreateImageView(createinfo, image.view));
        }
        VVK_CHECK_ACT(break, device.CreateSampler(sampler_info, image.sampler));
        VVK_CHECK_ACT(break, image.mem.GetMemoryFdKHR(handle_type, &image.fd));

        if (dmabuf_export) {
            if (format != VK_FORMAT_R8G8B8A8_UNORM) {
                LOG_ERROR("unsupported dma-buf export format: %d", static_cast<int>(format));
                break;
            }

            /*
             * VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT exposes memory-plane
             * layouts, not the color-aspect layout used by linear images.
             * Querying COLOR here returns an unusable zero row pitch on Mesa,
             * which later makes an otherwise valid exported pool fail the
             * renderer protocol's stride validation.
             */
            const VkImageSubresource subresource {
                .aspectMask = use_modifier_tiling
                    ? VK_IMAGE_ASPECT_MEMORY_PLANE_0_BIT_EXT
                    : VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .arrayLayer = 0,
            };
            const auto layout = image.handle.GetSubresourceLayout(subresource);
            if (layout.rowPitch == 0 ||
                layout.rowPitch > std::numeric_limits<uint32_t>::max() ||
                layout.offset > std::numeric_limits<uint32_t>::max()) {
                LOG_ERROR("invalid dma-buf plane layout rowPitch=%llu offset=%llu modifier-tiling=%s",
                          static_cast<unsigned long long>(layout.rowPitch),
                          static_cast<unsigned long long>(layout.offset),
                          use_modifier_tiling ? "true" : "false");
                break;
            }

            image.drm_fourcc = drm_fourcc;
            if (use_modifier_tiling) {
                VkImageDrmFormatModifierPropertiesEXT modifier_properties {
                    .sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_PROPERTIES_EXT,
                };
                VVK_CHECK_ACT(break, image.handle.GetDrmFormatModifierProperties(modifier_properties));
                image.drm_modifier = modifier_properties.drmFormatModifier;
            } else {
                image.drm_modifier = DRM_FORMAT_MOD_LINEAR;
            }
            image.n_planes = 1;
            image.planes[0].fd = image.fd;
            image.planes[0].offset = static_cast<uint32_t>(layout.offset);
            image.planes[0].stride = static_cast<uint32_t>(layout.rowPitch);
        }

        return image;

    } while (false);
    return std::nullopt;
}

} // namespace

std::optional<ExImageParameters> TextureCache::CreateExTex(uint32_t width, uint32_t height,
                                                           VkFormat format,
                                                           VkImageTiling tiling,
                                                           ExternalFrameExportMode export_mode,
                                                           uint32_t export_drm_fourcc,
                                                           std::span<const uint64_t> export_drm_modifiers,
                                                           ExternalFrameMemoryPreference memory_preference) {
    if (export_mode == ExternalFrameExportMode::DMA_BUF &&
        ! m_device.supportExt(VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME)) {
        LOG_ERROR("vulkan device missing %s for dma-buf export",
                  VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME);
        return std::nullopt;
    }

    VkSamplerCreateInfo sampler_info {
        .sType                   = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .pNext                   = nullptr,
        .magFilter               = VK_FILTER_NEAREST,
        .minFilter               = VK_FILTER_NEAREST,
        .mipmapMode              = VK_SAMPLER_MIPMAP_MODE_LINEAR,
        .addressModeU            = VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT,
        .addressModeV            = VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT,
        .addressModeW            = VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT,
        .anisotropyEnable        = false,
        .maxAnisotropy           = 1.0f,
        .compareEnable           = false,
        .compareOp               = VK_COMPARE_OP_NEVER,
        .minLod                  = 0.0f,
        .maxLod                  = 1.0f,
        .borderColor             = VK_BORDER_COLOR_INT_OPAQUE_BLACK,
        .unnormalizedCoordinates = false,
    };

    auto opt = CreateExImage(width,
                             height,
                             format,
                             tiling,
                             sampler_info,
                             VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                                 VK_IMAGE_USAGE_TRANSFER_DST_BIT,
                             m_device.device(),
                             m_device.gpu(),
                             export_mode,
                             export_drm_fourcc,
                             m_device.supportExt(VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME)
                                 ? export_drm_modifiers
                                 : std::span<const uint64_t> {},
                             memory_preference);
    if (opt.has_value()) {
        const auto& eximg = opt.value();

        if (! m_tex_cmd) allocateCmd();
        TransImgLayout(m_device.graphics_queue().handle, m_tex_cmd, eximg, VK_IMAGE_LAYOUT_GENERAL);
        VVK_CHECK(m_device.handle().WaitIdle());
    }
    return opt;
}
