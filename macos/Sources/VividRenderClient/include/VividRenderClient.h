#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

NS_SWIFT_UI_ACTOR
@interface VividRenderFrame : NSObject
@property(nonatomic, readonly) id<MTLTexture> texture;
@property(nonatomic, readonly) uint64_t sequence;
- (void)releaseFrame NS_SWIFT_NAME(releaseFrame());
@end

NS_SWIFT_UI_ACTOR
@interface VividRenderClient : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device
                       onFrame:(void (^)(VividRenderFrame*))onFrame
                     onFailure:(void (^)(NSString*))onFailure;
- (instancetype)initWithDevice:(id<MTLDevice>)device
                   serviceName:(NSString*)serviceName
                       onFrame:(void (^)(VividRenderFrame*))onFrame
                     onFailure:(void (^)(NSString*))onFailure;
- (void)startProject:(NSURL*)project
              assets:(NSURL*)assets
               cache:(NSURL*)cache
               width:(NSUInteger)width
              height:(NSUInteger)height
               muted:(BOOL)muted;
- (void)configureWithSettings:(NSData*)settings;
- (void)sendPointerX:(double)x y:(double)y left:(BOOL)left;
- (void)setPaused:(BOOL)paused;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
