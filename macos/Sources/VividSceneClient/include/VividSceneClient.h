#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

NS_SWIFT_UI_ACTOR
@interface VividSceneFrame : NSObject
@property(nonatomic, readonly) id<MTLTexture> texture;
@property(nonatomic, readonly) uint64_t sequence;
- (void)releaseFrame NS_SWIFT_NAME(releaseFrame());
@end

NS_SWIFT_UI_ACTOR
@interface VividSceneClient : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device
                       onFrame:(void (^)(VividSceneFrame*))onFrame
                     onFailure:(void (^)(NSString*))onFailure;
- (void)startProject:(NSURL*)project
              assets:(NSURL*)assets
               cache:(NSURL*)cache
               width:(NSUInteger)width
              height:(NSUInteger)height
               muted:(BOOL)muted;
- (void)sendPointerX:(double)x y:(double)y left:(BOOL)left;
- (void)setPaused:(BOOL)paused;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
