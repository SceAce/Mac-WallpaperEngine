set(LIB_NAME wpVulkan)

find_package(Vulkan REQUIRED)
if(APPLE)
    enable_language(OBJCXX)
    set(platform_sources Platform/TextureExportMetal.mm Platform/VideoTextureCacheAVFoundation.mm)
else()
    pkg_check_modules(GSTREAMER REQUIRED
    gstreamer-1.0
    gstreamer-app-1.0
    gstreamer-allocators-1.0
    gstreamer-video-1.0
    gstreamer-va-1.0
    gstreamer-cuda-1.0
    libdrm
    libva
    ffnvcodec
        gio-2.0)
    set(platform_sources Platform/TextureExportLinux.cpp Platform/VideoTextureCacheLinux.cpp)
endif()

add_library(${LIB_NAME}
STATIC
Instance.cpp
Device.cpp
GraphicsPipeline.cpp
Shader.cpp
StagingBuffer.cpp
Swapchain.cpp
TextureCache.cpp
${platform_sources}
ImmutableMeshStore.cpp
Parameters.cpp
Vma.cpp
vulkan_wrapper.cpp
)

target_link_libraries(${LIB_NAME}
PUBLIC
    spirv-reflect-static
    Vulkan::Vulkan
    wpScene
PRIVATE
    ${GSTREAMER_LIBRARIES}
)
if(APPLE)
    target_compile_definitions(${LIB_NAME} PUBLIC VK_USE_PLATFORM_METAL_EXT)
    target_link_libraries(${LIB_NAME} PRIVATE
        "-framework Foundation" "-framework IOSurface" "-framework Metal"
        "-framework AVFoundation" "-framework CoreVideo" "-framework CoreMedia")
    set_source_files_properties(${platform_sources} PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
endif()
if(HANABI_HAS_DXC)
    target_compile_definitions(${LIB_NAME} PRIVATE HANABI_HAS_DXC=1)
    target_link_libraries(${LIB_NAME} PRIVATE Hanabi::DxCompiler)
    if(TARGET HanabiVendoredDxc)
        add_dependencies(${LIB_NAME} HanabiVendoredDxc)
    endif()
endif()
target_include_directories(${LIB_NAME} PUBLIC include PRIVATE include/Vulkan include/vkk ${GSTREAMER_INCLUDE_DIRS})
target_include_directories(${LIB_NAME} SYSTEM PUBLIC ../../third_party)
target_compile_definitions(${LIB_NAME} PRIVATE GST_USE_UNSTABLE_API)
target_compile_options(${LIB_NAME} PRIVATE ${warn_opts} -Wno-missing-field-initializers ${GSTREAMER_CFLAGS_OTHER})
set_property(TARGET ${LIB_NAME} PROPERTY POSITION_INDEPENDENT_CODE ON)
