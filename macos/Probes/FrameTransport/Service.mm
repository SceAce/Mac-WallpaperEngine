#include "Shared.hpp"
#include <memory>
#include <vector>

using namespace vivid::probe;

struct Surface {
    IOSurfaceRef value;
    explicit Surface(IOSurfaceRef surface) : value(surface) {}
    ~Surface() {
        if (value)
            CFRelease(value);
    }
    Surface(const Surface&) = delete;
    Surface& operator=(const Surface&) = delete;
};

struct Session {
    dispatch_queue_t owner = dispatch_queue_create("org.sceace.vivid.probe.frames", DISPATCH_QUEUE_SERIAL);
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> commands = [device newCommandQueue];
    FramePool pool;
    std::vector<std::unique_ptr<Surface>> surfaces;
    std::array<id<MTLTexture>, FramePool::size> textures{};
    bool playing = true;
};

static void handle(std::shared_ptr<Session> session, xpc_connection_t peer, xpc_object_t request) {
    auto reply = xpc_dictionary_create_reply(request);
    if (!reply)
        return;
    try {
        require(integer(request, "version") == version, "Protocol version mismatch");
        const char* name = xpc_dictionary_get_string(request, "operation");
        require(name != nullptr, "Missing operation");
        const std::string operation(name);
        require(session->device && session->commands, "Metal device unavailable");
        if (operation == "configure") {
            uint64_t generation = integer(request, "generation");
            size_t width = integer(request, "width");
            size_t height = integer(request, "height");
            require(width > 0 && height > 0 && width <= 4096 && height <= 4096, "Invalid dimensions");
            if (!session->pool.idle()) {
                sendReply(peer, reply, "busy");
                return;
            }
            require(generation > session->pool.generation(), "Generation must increase");
            std::vector<std::unique_ptr<Surface>> surfaces;
            std::array<id<MTLTexture>, FramePool::size> textures{};
            auto objects = xpc_array_create(nullptr, 0);
            const auto rowBytes = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4);
            for (size_t i = 0; i < FramePool::size; ++i) {
                NSDictionary* properties = @{
                    (id)kIOSurfaceWidth : @(width),
                    (id)kIOSurfaceHeight : @(height),
                    (id)kIOSurfaceBytesPerElement : @4,
                    (id)kIOSurfaceBytesPerRow : @(rowBytes),
                    (id)kIOSurfaceAllocSize : @(rowBytes * height),
                    (id)kIOSurfacePixelFormat : @(bgra),
                };
                auto surface =
                    std::make_unique<Surface>(IOSurfaceCreate((__bridge CFDictionaryRef)properties));
                require(surface->value != nullptr, "IOSurface allocation failed");
                textures[i] = [session->device newTextureWithDescriptor:descriptor(width, height)
                                                              iosurface:surface->value
                                                                  plane:0];
                require(textures[i] != nil, "IOSurface Metal import failed");
                auto object = IOSurfaceCreateXPCObject(surface->value);
                require(object != nullptr, "IOSurface XPC export failed");
                xpc_array_append_value(objects, object);
                surfaces.push_back(std::move(surface));
            }
            require(session->pool.configure(generation), "Pool transition failed");
            session->textures = std::move(textures);
            session->surfaces = std::move(surfaces);
            xpc_dictionary_set_value(reply, "surfaces", objects);
            xpc_dictionary_set_uint64(reply, "generation", generation);
            xpc_dictionary_set_uint64(reply, "width", width);
            xpc_dictionary_set_uint64(reply, "height", height);
            xpc_dictionary_set_uint64(reply, "producer-pid", getpid());
            sendReply(peer, reply, "ok");
        } else if (operation == "render") {
            if (!session->playing) {
                sendReply(peer, reply, "paused");
                return;
            }
            auto acquired = session->pool.acquire();
            if (!acquired) {
                sendReply(peer, reply, "busy");
                return;
            }
            const Token token = *acquired;
            auto command = [session->commands commandBuffer];
            auto pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = session->textures[token.slot];
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.colorAttachments[0].clearColor = color(token);
            auto encoder = [command renderCommandEncoderWithDescriptor:pass];
            require(command && encoder, "Metal command encoding failed");
            [encoder endEncoding];
            [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
              dispatch_async(session->owner, ^{
                // Failed GPU work never makes its slot reusable.
                if (completed.status != MTLCommandBufferStatusCompleted || !session->pool.ready(token)) {
                    sendReply(peer, reply, "gpu-failed");
                    xpc_connection_cancel(peer);
                    return;
                }
                setToken(reply, token);
                sendReply(peer, reply, "ready");
              });
            }];
            [command commit];
        } else if (operation == "release") {
            sendReply(peer, reply, session->pool.release(getToken(request)) ? "ok" : "invalid-token");
        } else if (operation == "pause" || operation == "resume") {
            session->playing = operation == "resume";
            sendReply(peer, reply, "ok");
        } else if (operation == "exit") {
            // Deliberate peer death tests the consumer's interruption path.
            _exit(0);
        } else {
            throw std::runtime_error("Unknown operation");
        }
    } catch (const std::exception& error) {
        xpc_dictionary_set_string(reply, "detail", error.what());
        sendReply(peer, reply, "error");
    }
}

int main() {
    xpc_main([](xpc_connection_t peer) {
        auto session = std::make_shared<Session>();
        xpc_connection_set_target_queue(peer, session->owner);
        xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
          @autoreleasepool {
              if (xpc_get_type(event) == XPC_TYPE_DICTIONARY)
                  handle(session, peer, event);
              else if (event == XPC_ERROR_CONNECTION_INVALID) {
                  xpc_connection_set_event_handler(peer, ^(xpc_object_t){
                                                   });
              }
          }
        });
        xpc_connection_resume(peer);
    });
}
