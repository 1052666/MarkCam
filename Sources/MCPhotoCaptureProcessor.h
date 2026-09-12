#import <AVFoundation/AVFoundation.h>

// JPEG/Live callbacks are optional in Apple's protocol, but required by this app.
@protocol MCPhotoCaptureContract <AVCapturePhotoCaptureDelegate>
@required
- (void)captureOutput:(AVCapturePhotoOutput *)output didCapturePhotoForResolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings;
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error;
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings error:(NSError *)error;
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingLivePhotoToMovieFileAtURL:(NSURL *)url duration:(CMTime)duration photoDisplayTime:(CMTime)photoDisplayTime resolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings error:(NSError *)error;
@end

@interface MCPhotoCaptureProcessor : NSObject <MCPhotoCaptureContract>
@property(nonatomic,copy,readonly) NSString *identifier;
@property(nonatomic,copy,readonly) NSDictionary *settings;
@property(nonatomic,readonly) BOOL live;
@property(nonatomic,strong,readonly) NSURL *movieURL;
// Both notifications run on main. Completion follows all native callbacks and disk writes.
@property(nonatomic,copy) void (^onExposureFinished)(MCPhotoCaptureProcessor *capture);
@property(nonatomic,copy) void (^onCompletion)(MCPhotoCaptureProcessor *capture, NSDictionary *job, NSURL *meta, NSError *error);
- (instancetype)initWithSettings:(NSDictionary *)settings date:(NSDate *)date live:(BOOL)live diskQueue:(dispatch_queue_t)queue;
- (BOOL)prepare:(NSError **)error;
- (void)rejectRequest:(NSError *)error;
@end
