#pragma once

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#include <xpc/xpc.h>

#include "FramePool.hpp"
#include <stdexcept>
#include <string>

namespace vivid::probe {

inline constexpr uint64_t version = 1;
inline constexpr uint32_t bgra = 0x42475241;

inline void require(bool value, const char* message) {
    if (!value)
        throw std::runtime_error(message);
}

inline xpc_object_t message(const char* operation) {
    auto value = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_uint64(value, "version", version);
    xpc_dictionary_set_string(value, "operation", operation);
    return value;
}

inline uint64_t integer(xpc_object_t value, const char* key) {
    auto field = xpc_dictionary_get_value(value, key);
    require(field && xpc_get_type(field) == XPC_TYPE_UINT64, "Missing or invalid integer field");
    return xpc_uint64_get_value(field);
}

inline void setToken(xpc_object_t value, Token token) {
    xpc_dictionary_set_uint64(value, "generation", token.generation);
    xpc_dictionary_set_uint64(value, "sequence", token.sequence);
    xpc_dictionary_set_uint64(value, "slot", token.slot);
}

inline Token getToken(xpc_object_t value) {
    return {integer(value, "generation"), integer(value, "sequence"), integer(value, "slot")};
}

inline MTLTextureDescriptor* descriptor(size_t width, size_t height) {
    auto result = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                                                     width:width
                                                                    height:height
                                                                 mipmapped:NO];
    result.storageMode = MTLStorageModeShared;
    result.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    return result;
}

inline MTLClearColor color(Token token) {
    return MTLClearColorMake(double(token.sequence % 17) / 16, double((token.sequence / 17) % 17) / 16,
                             double(token.generation % 9) / 8, 1);
}

inline void sendReply(xpc_connection_t peer, xpc_object_t reply, const char* status) {
    xpc_dictionary_set_string(reply, "status", status);
    xpc_dictionary_set_uint64(reply, "version", version);
    xpc_connection_send_message(peer, reply);
}

} // namespace vivid::probe
