#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
/// Processes a native Live Photo pair. Does not save to Photos or delete inputs.
@interface MCLivePhotoProcessor : NSObject
@property(atomic,readonly) float progress;
- (void)processPhoto:(NSURL *)photo movie:(NSURL *)movie
        outputPhoto:(NSURL *)outputPhoto outputMovie:(NSURL *)outputMovie
           settings:(NSDictionary *)settings date:(NSDate *)date
         completion:(void (^)(NSError * _Nullable error))completion;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
