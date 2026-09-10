#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface WMEditorViewController : UIViewController
/// Supply an upright, unfiltered camera frame; nil shows a labelled sample canvas.
@property(nonatomic, strong, nullable) UIImage *backgroundImage;
/// Always invoked on main after a saved change and when the editor leaves.
@property(nonatomic, copy, nullable) void (^onChange)(void);
@end
NS_ASSUME_NONNULL_END
