cmake_minimum_required(VERSION 3.24)
set(CMAKE_OSX_DEPLOYMENT_TARGET "26.0" CACHE STRING "Minimum macOS version")
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "Supported architecture")
project(VividFrameProbe LANGUAGES CXX OBJCXX)
if(NOT APPLE OR NOT CMAKE_OSX_ARCHITECTURES STREQUAL "arm64")
    message(FATAL_ERROR "The frame transport probe requires Apple Silicon macOS")
endif()
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_executable(VividFrameService MACOSX_BUNDLE Service.mm)
set_target_properties(VividFrameService PROPERTIES
    BUNDLE_EXTENSION xpc
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Service.plist")
add_executable(VividFrameProbe MACOSX_BUNDLE Probe.mm)
set_target_properties(VividFrameProbe PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Probe.plist")
foreach(target VividFrameService VividFrameProbe)
    target_compile_options(${target} PRIVATE -fobjc-arc -Wall -Wextra -Werror)
    target_link_libraries(${target} PRIVATE
        "-framework Foundation" "-framework Metal" "-framework IOSurface")
endforeach()
add_dependencies(VividFrameProbe VividFrameService)
add_custom_target(frame_probe_bundle ALL
    COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_BUNDLE_DIR:VividFrameProbe>/Contents/XPCServices"
    COMMAND ${CMAKE_COMMAND} -E copy_directory "$<TARGET_BUNDLE_DIR:VividFrameService>"
        "$<TARGET_BUNDLE_DIR:VividFrameProbe>/Contents/XPCServices/VividFrameService.xpc"
    COMMAND /usr/bin/codesign --force --sign -
        "$<TARGET_BUNDLE_DIR:VividFrameProbe>/Contents/XPCServices/VividFrameService.xpc"
    COMMAND /usr/bin/codesign --force --sign - "$<TARGET_BUNDLE_DIR:VividFrameProbe>"
    DEPENDS VividFrameProbe VividFrameService
    VERBATIM)
enable_testing()
add_test(NAME frame_transport COMMAND $<TARGET_FILE:VividFrameProbe>)
set_tests_properties(frame_transport PROPERTIES TIMEOUT 60)
