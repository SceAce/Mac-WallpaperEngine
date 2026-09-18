#include "Shared.hpp"
#include <cmath>
#include <cstdio>
#include <vector>

using namespace vivid::probe;

static xpc_object_t request(xpc_connection_t peer, xpc_object_t value) {
    auto done = dispatch_semaphore_create(0);
    __block xpc_object_t response = nullptr;
    xpc_connection_send_message_with_reply(
        peer, value, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(xpc_object_t reply) {
          response = reply;
          dispatch_semaphore_signal(done);
        });
    require(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0,
            "XPC response timed out");
    return response;
}

static void expect(xpc_object_t reply, const char* expected) {
    require(xpc_get_type(reply) == XPC_TYPE_DICTIONARY, "XPC connection failed");
    require(integer(reply, "version") == version, "Response version mismatch");
    auto status = xpc_dictionary_get_string(reply, "status");
    if (!status || std::string(status) != expected) {
        auto detail = xpc_dictionary_get_string(reply, "detail");
        throw std::runtime_error(std::string("Expected ") + expected + ", received " +
                                 (status ? status : "no status") + ": " + (detail ? detail : ""));
    }
}

static xpc_object_t configure(xpc_connection_t peer, uint64_t generation, size_t width, size_t height) {
    auto value = message("configure");
    xpc_dictionary_set_uint64(value, "generation", generation);
    xpc_dictionary_set_uint64(value, "width", width);
    xpc_dictionary_set_uint64(value, "height", height);
    return request(peer, value);
}

static void release(xpc_connection_t peer, Token token, const char* expected = "ok") {
    auto value = message("release");
    setToken(value, token);
    expect(request(peer, value), expected);
}

static Token render(xpc_connection_t peer) {
    auto reply = request(peer, message("render"));
    expect(reply, "ready");
    return getToken(reply);
}

static std::vector<id<MTLTexture>> importPool(id<MTLDevice> device, xpc_object_t reply) {
    expect(reply, "ok");
    require(integer(reply, "producer-pid") != uint64_t(getpid()), "Producer must be a different process");
    size_t width = integer(reply, "width"), height = integer(reply, "height");
    auto objects = xpc_dictionary_get_value(reply, "surfaces");
    require(objects && xpc_get_type(objects) == XPC_TYPE_ARRAY &&
                xpc_array_get_count(objects) == FramePool::size,
            "Invalid surface pool");
    std::vector<id<MTLTexture>> textures;
    for (size_t i = 0; i < FramePool::size; ++i) {
        auto surface = IOSurfaceLookupFromXPCObject(xpc_array_get_value(objects, i));
        require(surface != nullptr, "IOSurface XPC import failed");
        bool valid = IOSurfaceGetWidth(surface) == width && IOSurfaceGetHeight(surface) == height &&
                     IOSurfaceGetPixelFormat(surface) == bgra &&
                     IOSurfaceGetBytesPerRow(surface) >= width * 4;
        auto texture = valid ? [device newTextureWithDescriptor:descriptor(width, height)
                                                      iosurface:surface
                                                          plane:0]
                             : nil;
        CFRelease(surface);
        require(texture != nil, "Imported surface descriptor mismatch");
        textures.push_back(texture);
    }
    return textures;
}

static int encoded(double linear) {
    double srgb = linear <= 0.0031308 ? 12.92 * linear : 1.055 * std::pow(linear, 1.0 / 2.4) - 0.055;
    return int(std::round(srgb * 255));
}

// Readback is exclusively a probe assertion, outside the future presenter path.
// The producer's shared slot is read by a GPU blit into a consumer-owned texture.
static void verifyPixels(id<MTLDevice> device, id<MTLCommandQueue> queue, id<MTLTexture> source,
                         Token token) {
    size_t width = source.width, height = source.height, row = ((width * 4 + 255) / 256) * 256;
    auto spec = descriptor(width, height);
    spec.storageMode = MTLStorageModePrivate;
    auto owned = [device newTextureWithDescriptor:spec];
    auto buffer = [device newBufferWithLength:row * height options:MTLResourceStorageModeShared];
    auto command = [queue commandBuffer];
    auto blit = [command blitCommandEncoder];
    require(owned && buffer && command && blit, "Consumer GPU allocation failed");
    [blit copyFromTexture:source toTexture:owned];
    [blit copyFromTexture:owned
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(width, height, 1)
                        toBuffer:buffer
               destinationOffset:0
          destinationBytesPerRow:row
        destinationBytesPerImage:row * height];
    [blit endEncoding];
    auto done = dispatch_semaphore_create(0);
    [command addCompletedHandler:^(id<MTLCommandBuffer>) {
      dispatch_semaphore_signal(done);
    }];
    [command commit];
    require(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0,
            "Consumer GPU timed out");
    require(command.status == MTLCommandBufferStatusCompleted, "Consumer GPU failed");
    auto clear = color(token);
    std::array<int, 4> expected{encoded(clear.blue), encoded(clear.green), encoded(clear.red), 255};
    const auto* pixels = static_cast<const uint8_t*>(buffer.contents);
    for (size_t y = 0; y < height; ++y)
        for (size_t x = 0; x < width; ++x) {
            for (size_t c = 0; c < 4; ++c) {
                require(std::abs(int(pixels[y * row + x * 4 + c]) - expected[c]) <= 1,
                        "Cross-process pixel mismatch (color, visibility or slot ownership)");
            }
        }
}

static void run(xpc_connection_t peer) {
    require(NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26, "macOS 26 required");
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    auto queue = [device newCommandQueue];
    require(device && queue, "Metal unavailable");
    auto textures = importPool(device, configure(peer, 1, 64, 32));
    Token first = render(peer), second = render(peer), third = render(peer);
    expect(request(peer, message("render")), "busy");
    expect(configure(peer, 2, 97, 53), "busy");
    // Deliberately hold all slots while the producer remains alive.
    usleep(150000);
    for (auto token : {first, second, third})
        verifyPixels(device, queue, textures.at(token.slot), token);
    release(peer, first);
    release(peer, first, "invalid-token");
    auto replacement = render(peer);
    require(replacement.slot == first.slot && replacement.sequence > first.sequence,
            "Slot reuse contract failed");
    release(peer, first, "invalid-token");
    expect(request(peer, message("render")), "busy");
    verifyPixels(device, queue, textures.at(replacement.slot), replacement);
    release(peer, replacement);
    release(peer, third);
    release(peer, second);
    expect(request(peer, message("pause")), "ok");
    expect(request(peer, message("render")), "paused");
    textures = importPool(device, configure(peer, 2, 97, 53));
    release(peer, first, "invalid-token");
    expect(request(peer, message("render")), "paused");
    expect(request(peer, message("resume")), "ok");
    for (size_t i = 0; i < 100; ++i) {
        auto token = render(peer);
        require(token.generation == 2, "Wrong generation after resize");
        verifyPixels(device, queue, textures.at(token.slot), token);
        release(peer, token);
    }
    auto invalid = message("render");
    xpc_dictionary_set_uint64(invalid, "version", version + 1);
    expect(request(peer, invalid), "error");
    auto finalToken = render(peer);
    auto interrupted = request(peer, message("exit"));
    require(xpc_get_type(interrupted) == XPC_TYPE_ERROR, "Expected peer interruption");
    // An imported frame remains owned by the consumer after producer death.
    verifyPixels(device, queue, textures.at(finalToken.slot), finalToken);
    printf("{\"result\":\"pass\",\"frames\":105,\"poolSlots\":3,\"generations\":2,"
           "\"checks\":[\"cross-process-pixels\",\"backpressure\",\"slow-consumer\","
           "\"duplicate-release\",\"stale-sequence\",\"stale-generation\",\"busy-resize\","
           "\"pause-resize-resume\",\"version-rejection\",\"producer-exit\"]}\n");
}

int main() {
    @autoreleasepool {
        auto peer = xpc_connection_create("org.sceace.vivid.frame-probe.renderer",
                                          dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
        xpc_connection_set_event_handler(peer, ^(xpc_object_t){
                                         });
        xpc_connection_resume(peer);
        int result = 0;
        try {
            run(peer);
        } catch (const std::exception& error) {
            fprintf(stderr, "FAIL: %s\n", error.what());
            result = 1;
        }
        xpc_connection_cancel(peer);
        return result;
    }
}
