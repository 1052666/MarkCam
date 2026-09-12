#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface MCProcessingQueue : NSObject
@property(nonatomic) BOOL foreground;
@property(nonatomic) BOOL captureBusy;
@property(nonatomic) BOOL manuallyPaused;
@property(nonatomic,readonly) BOOL processing;
@property(nonatomic,readonly) BOOL heavyProcessing;
@property(nonatomic,readonly) NSUInteger pendingCount;
@property(nonatomic,readonly) float progress;
@property(nonatomic,copy,readonly) NSString *summary;
@property(nonatomic,strong,readonly,nullable) NSURL *activeMeta;
@property(nonatomic,copy,nullable) void (^onChange)(void);
- (void)refresh;
- (void)tick;
- (void)didCapture;
- (void)memoryPressure;
- (BOOL)allowsCaptureLive:(BOOL)live;
- (BOOL)allowsCaptureLive:(BOOL)live reservedCount:(NSUInteger)reserved;
- (nullable NSString *)captureBlockReasonForLive:(BOOL)live reservedCount:(NSUInteger)reserved;
/// Resume only jobs known to have stopped before saving because Photos denied access.
- (void)resumeAfterPhotoAuthorization;
- (void)retry:(NSURL *)meta;
- (void)pause;
- (BOOL)isActive:(NSURL *)meta;
+ (NSURL *)directory;
+ (nullable NSURL *)fileForJob:(NSDictionary *)job key:(NSString *)key;
+ (BOOL)writeJob:(NSDictionary *)job URL:(NSURL *)meta;
+ (void)cleanupJob:(NSDictionary *)job meta:(NSURL *)meta;
@end
NS_ASSUME_NONNULL_END
