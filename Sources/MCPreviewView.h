#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>
NS_ASSUME_NONNULL_BEGIN
/// Camera buffers are rendered straight to a Metal drawable, never via UIImage.
@interface MCPreviewView : UIView
@property(nonatomic,readonly) BOOL available;
@property(atomic) BOOL renderingEnabled;
@property(atomic,copy) NSDictionary *settings;
@property(nonatomic,copy,nullable) void (^onFailure)(NSString *reason);
/// Serial capture queue. At most two GPU buffers in flight; no UI work per frame.
- (void)submitPixelBuffer:(CVPixelBufferRef)pixel;
/// Only opening the editor requests a CPU image, generated away from main.
- (void)requestSnapshot:(void (^)(UIImage * _Nullable image))completion;
- (void)reset;
- (NSDictionary *)statistics;
@end
NS_ASSUME_NONNULL_END
