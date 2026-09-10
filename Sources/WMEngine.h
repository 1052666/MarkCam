#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
NS_ASSUME_NONNULL_BEGIN
@interface WMEngine : NSObject
+ (instancetype)shared;
@property(nonatomic,strong) NSMutableDictionary *settings;
- (void)save;
- (NSDictionary *)snapshot;
- (NSArray<NSDictionary *> *)presets;
- (NSURL *)documentsURL;
- (nullable UIImage *)imageForLayer:(NSDictionary *)layer;
- (UIImage *)overlayForSize:(CGSize)size settings:(NSDictionary *)settings date:(NSDate *)date;
- (nullable UIImage *)processPhoto:(UIImage *)image settings:(NSDictionary *)settings date:(NSDate *)date;
- (CIImage *)applyTone:(CIImage *)image settings:(NSDictionary *)settings;
- (AVAssetExportSession * _Nullable)exportVideo:(NSURL *)source destination:(NSURL *)dest settings:(NSDictionary *)settings date:(NSDate *)date completion:(void(^)(NSError * _Nullable error))completion;
- (BOOL)importTemplateURL:(NSURL *)url error:(NSError **)error;
- (NSURL * _Nullable)exportTemplate:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
