#import "VividRenderClient.h"
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#include <xpc/xpc.h>

static xpc_object_t message(const char* operation) {
    xpc_object_t result = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(result, "version", 1);
    xpc_dictionary_set_uint64(result, "generation", 1);
    xpc_dictionary_set_string(result, "operation", operation);
    return result;
}

@interface VividRenderFrame ()
- (instancetype)initWithTexture:(id<MTLTexture>)texture
                           peer:(xpc_connection_t)peer
                           slot:(uint64_t)slot
                       sequence:(uint64_t)sequence;
@end

@implementation VividRenderFrame {
    xpc_connection_t _peer;
    uint64_t _slot;
}
- (instancetype)initWithTexture:(id<MTLTexture>)texture
                           peer:(xpc_connection_t)peer
                           slot:(uint64_t)slot
                       sequence:(uint64_t)sequence {
    self = [super init];
    if (self) {
        _texture = texture;
        _peer = peer;
        _slot = slot;
        _sequence = sequence;
    }
    return self;
}
- (void)releaseFrame {
    if (!_peer)
        return;
    xpc_object_t release = message("release");
    xpc_dictionary_set_uint64(release, "slot", _slot);
    xpc_dictionary_set_uint64(release, "sequence", _sequence);
    xpc_connection_send_message(_peer, release);
    _peer = nil;
}
- (void)dealloc {
    [self releaseFrame];
}
@end

@implementation VividRenderClient {
    NSString* _serviceName;
    NSData* _settings;
    id<MTLDevice> _device;
    xpc_connection_t _peer;
    NSArray<id<MTLTexture>>* _textures;
    void (^_onFrame)(VividRenderFrame*);
    void (^_onFailure)(NSString*);
    uint64_t _sequence;
    id _activity;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device
                       onFrame:(void (^)(VividRenderFrame*))onFrame
                     onFailure:(void (^)(NSString*))onFailure {
    return [self initWithDevice:device
                    serviceName:@"org.sceace.vivid.scene"
                        onFrame:onFrame
                      onFailure:onFailure];
}
- (instancetype)initWithDevice:(id<MTLDevice>)device
                   serviceName:(NSString*)serviceName
                       onFrame:(void (^)(VividRenderFrame*))onFrame
                     onFailure:(void (^)(NSString*))onFailure {
    self = [super init];
    if (self) {
        _serviceName = [serviceName copy];
        _device = device;
        _onFrame = [onFrame copy];
        _onFailure = [onFailure copy];
    }
    return self;
}
- (void)fail:(NSString*)reason {
    [self stop];
    _onFailure(reason);
}
- (void)startProject:(NSURL*)project
              assets:(NSURL*)assets
               cache:(NSURL*)cache
               width:(NSUInteger)width
              height:(NSUInteger)height
               muted:(BOOL)muted {
    if (_peer) {
        [self fail:@"Scene client already started"];
        return;
    }
    _sequence = 0;
    [self setActive:YES];
    _peer = xpc_connection_create(_serviceName.UTF8String, dispatch_get_main_queue());
    __weak VividRenderClient* weakSelf = self;
    xpc_connection_set_event_handler(_peer, ^(xpc_object_t event) {
      VividRenderClient* self = weakSelf;
      if (!self || !self->_peer)
          return;
      if (xpc_get_type(event) == XPC_TYPE_ERROR) {
          [self fail:@"Renderer service disconnected. See the renderer log for details."];
          return;
      }
      if (xpc_get_type(event) != XPC_TYPE_DICTIONARY || xpc_dictionary_get_uint64(event, "version") != 1 ||
          xpc_dictionary_get_uint64(event, "generation") != 1) {
          [self fail:@"Invalid renderer response"];
          return;
      }
      const char* operation = xpc_dictionary_get_string(event, "operation");
      if (!operation) {
          [self fail:@"Missing scene response operation"];
          return;
      }
      if (strcmp(operation, "pool") == 0) {
          xpc_object_t surfaces = xpc_dictionary_get_value(event, "surfaces");
          if (self->_textures || !surfaces || xpc_get_type(surfaces) != XPC_TYPE_ARRAY ||
              xpc_array_get_count(surfaces) != 3) {
              [self fail:@"Invalid renderer surface pool"];
              return;
          }
          NSMutableArray<id<MTLTexture>>* textures = [NSMutableArray arrayWithCapacity:3];
          for (size_t i = 0; i < 3; ++i) {
              IOSurfaceRef surface = IOSurfaceLookupFromXPCObject(xpc_array_get_value(surfaces, i));
              if (!surface) {
                  [self fail:@"Cannot import scene IOSurface"];
                  return;
              }
              size_t w = IOSurfaceGetWidth(surface), h = IOSurfaceGetHeight(surface);
              if (!w || !h || w > 8192 || h > 8192 ||
                  (IOSurfaceGetPixelFormat(surface) != kCVPixelFormatType_32RGBA &&
                   IOSurfaceGetPixelFormat(surface) != kCVPixelFormatType_32BGRA)) {
                  CFRelease(surface);
                  [self fail:@"Unsupported scene surface format"];
                  return;
              }
              const MTLPixelFormat format = IOSurfaceGetPixelFormat(surface) == kCVPixelFormatType_32RGBA
                                                ? MTLPixelFormatRGBA8Unorm_sRGB
                                                : MTLPixelFormatBGRA8Unorm_sRGB;
              MTLTextureDescriptor* descriptor =
                  [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                     width:w
                                                                    height:h
                                                                 mipmapped:NO];
              descriptor.usage = MTLTextureUsageShaderRead;
              descriptor.storageMode = MTLStorageModeShared;
              id<MTLTexture> texture = [self->_device newTextureWithDescriptor:descriptor
                                                                     iosurface:surface
                                                                         plane:0];
              CFRelease(surface);
              if (!texture) {
                  [self fail:@"Cannot import scene Metal texture"];
                  return;
              }
              [textures addObject:texture];
          }
          self->_textures = textures;
      } else if (strcmp(operation, "frame") == 0) {
          uint64_t slot = xpc_dictionary_get_uint64(event, "slot");
          uint64_t sequence = xpc_dictionary_get_uint64(event, "sequence");
          if (slot >= self->_textures.count || sequence <= self->_sequence) {
              [self fail:@"Invalid renderer frame lease"];
              return;
          }
          self->_sequence = sequence;
          VividRenderFrame* frame = [[VividRenderFrame alloc] initWithTexture:self->_textures[slot]
                                                                         peer:self->_peer
                                                                         slot:slot
                                                                     sequence:sequence];
          self->_onFrame(frame);
      } else if (strcmp(operation, "failed") == 0) {
          const char* reason = xpc_dictionary_get_string(event, "reason");
          [self fail:reason ? @(reason) : @"Scene loading failed"];
      } else {
          [self fail:@"Unknown renderer response"];
      }
    });
    xpc_connection_resume(_peer);
    xpc_object_t start = message("start");
    xpc_dictionary_set_string(start, "project", project.fileSystemRepresentation);
    xpc_dictionary_set_string(start, "assets", assets.fileSystemRepresentation);
    xpc_dictionary_set_string(start, "cache", cache.fileSystemRepresentation);
    xpc_dictionary_set_uint64(start, "width", width);
    xpc_dictionary_set_uint64(start, "height", height);
    xpc_dictionary_set_bool(start, "muted", muted);
    if (_settings)
        xpc_dictionary_set_data(start, "settings", _settings.bytes, _settings.length);
    xpc_connection_send_message(_peer, start);
}
- (void)configureWithSettings:(NSData*)settings {
    _settings = [settings copy];
    if (!_peer)
        return;
    xpc_object_t config = message("configure");
    xpc_dictionary_set_data(config, "settings", settings.bytes, settings.length);
    xpc_connection_send_message(_peer, config);
}
- (void)sendPointerX:(double)x y:(double)y left:(BOOL)left {
    if (!_peer)
        return;
    xpc_object_t pointer = message("pointer");
    xpc_dictionary_set_double(pointer, "x", x);
    xpc_dictionary_set_double(pointer, "y", y);
    xpc_dictionary_set_bool(pointer, "left", left);
    xpc_connection_send_message(_peer, pointer);
}
- (void)setPaused:(BOOL)paused {
    if (!_peer)
        return;
    [self setActive:!paused];
    xpc_object_t pause = message("pause");
    xpc_dictionary_set_bool(pause, "paused", paused);
    xpc_connection_send_message(_peer, pause);
}
- (void)stop {
    [self setActive:NO];
    if (!_peer)
        return;
    xpc_connection_cancel(_peer);
    _peer = nil;
    _textures = nil;
}
- (void)setActive:(BOOL)active {
    if (active && !_activity) {
        _activity =
            [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
                                                         reason:@"Present the active desktop wallpaper"];
    } else if (!active && _activity) {
        [NSProcessInfo.processInfo endActivity:_activity];
        _activity = nil;
    }
}
- (void)dealloc {
    [self stop];
}
@end
