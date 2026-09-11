#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface MCPhotoRenderer : NSObject
/// File-backed CI input -> JPEG on disk. No full-resolution UIImage or NSData output.
+ (BOOL)renderSource:(NSURL *)source destination:(NSURL *)destination settings:(NSDictionary *)settings date:(NSDate *)date error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
