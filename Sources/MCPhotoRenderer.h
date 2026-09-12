#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString * const MCPhotoRendererErrorDomain;
typedef NS_ENUM(NSInteger, MCPhotoRendererErrorCode) {
 MCPhotoRendererErrorFailed = 1,
 MCPhotoRendererErrorInsufficientMemory = 2
};
@interface MCPhotoRenderer : NSObject
/// File-backed CI input -> JPEG on disk. No full-resolution UIImage or NSData output.
+ (BOOL)renderSource:(NSURL *)source destination:(NSURL *)destination settings:(NSDictionary *)settings date:(NSDate *)date error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
