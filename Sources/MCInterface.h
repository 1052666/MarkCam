#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Shared native chrome. Capture controls change state immediately, without animation.
UIColor *MCInterfaceAccent(void);
UIColor *MCInterfaceBackground(void);
UIFont *MCCompactFont(CGFloat size, UIFontWeight weight);
void MCConfigureSymbol(UIButton *button, NSString *symbol, CGFloat size);

@interface MCToolButton : UIButton
@end

@interface MCShutterButton : UIButton
@property(nonatomic) BOOL videoMode;
@property(nonatomic) BOOL recording;
@end

/// Contrast over video; no material is stacked behind the glass controls.
@interface MCCameraScrimView : UIView
@end

NS_ASSUME_NONNULL_END
