#import "MCInterface.h"
#import <QuartzCore/QuartzCore.h>

UIColor *MCInterfaceAccent(void) { return [UIColor colorWithRed:.55 green:.94 blue:.80 alpha:1]; }
UIColor *MCInterfaceBackground(void) { return [UIColor colorWithWhite:.045 alpha:1]; }
UIFont *MCCompactFont(CGFloat size, UIFontWeight weight) {
    // Camera controls keep a fixed, reachable footprint; full Dynamic Type is
    // available in the editor. VoiceOver provides every compact control's name.
    return [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline]
        scaledFontForFont:[UIFont systemFontOfSize:size weight:weight] maximumPointSize:size+3];
}
void MCConfigureSymbol(UIButton *button, NSString *symbol, CGFloat size) {
    UIImageSymbolConfiguration *config=[UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightMedium];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:config] forState:UIControlStateNormal];
    button.imageView.contentMode=UIViewContentModeScaleAspectFit;
    if (button.currentTitle.length) {
        button.imageEdgeInsets=UIEdgeInsetsMake(0,-3,0,3);
        button.titleEdgeInsets=UIEdgeInsetsMake(0,3,0,-3);
    }
}

@implementation MCToolButton
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self=[super initWithFrame:frame])) {
        self.layer.cornerRadius=14; self.layer.cornerCurve=kCACornerCurveContinuous;
        self.titleLabel.font=MCCompactFont(13,UIFontWeightSemibold);
        self.titleLabel.adjustsFontSizeToFitWidth=YES; self.titleLabel.minimumScaleFactor=.85;
        self.contentEdgeInsets=UIEdgeInsetsMake(0,8,0,8);
        self.adjustsImageWhenHighlighted=NO;
        [self setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [self setTitleColor:MCInterfaceAccent() forState:UIControlStateSelected];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshAppearance)
            name:UIAccessibilityReduceTransparencyStatusDidChangeNotification object:nil];
        [self refreshAppearance];
    } return self;
}
- (void)setHighlighted:(BOOL)highlighted { [super setHighlighted:highlighted]; [self refreshAppearance]; }
- (void)setSelected:(BOOL)selected { [super setSelected:selected]; [self refreshAppearance]; }
- (void)setEnabled:(BOOL)enabled { [super setEnabled:enabled]; [self refreshAppearance]; }
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous]; self.titleLabel.font=MCCompactFont(13,UIFontWeightSemibold); [self refreshAppearance];
}
- (void)refreshAppearance {
    // A tap is acknowledged on touch-down, and committed by UIKit on touch-up.
    // No spring/scale animation can delay a second tap or accumulate on bursts.
    BOOL solid=UIAccessibilityIsReduceTransparencyEnabled() || self.traitCollection.accessibilityContrast==UIAccessibilityContrastHigh;
    self.backgroundColor=self.highlighted ? [UIColor colorWithWhite:.30 alpha:1] :
        (self.selected ? [UIColor colorWithRed:.16 green:.25 blue:.22 alpha:solid?1:.94] :
        (solid ? [UIColor colorWithWhite:.14 alpha:1] : [UIColor colorWithWhite:.08 alpha:.82]));
    self.tintColor=self.selected ? MCInterfaceAccent() : UIColor.whiteColor;
    self.alpha=self.enabled ? 1 : .42;
    self.layer.borderWidth=self.selected || self.traitCollection.accessibilityContrast==UIAccessibilityContrastHigh ? 1 : 0;
    self.layer.borderColor=[(self.selected?MCInterfaceAccent():UIColor.whiteColor) colorWithAlphaComponent:.55].CGColor;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end

@interface MCShutterButton ()
@property(nonatomic,strong) CAShapeLayer *ringLayer;
@property(nonatomic,strong) CAShapeLayer *coreLayer;
@end
@implementation MCShutterButton
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self=[super initWithFrame:frame])) {
        self.backgroundColor=UIColor.clearColor;
        self.ringLayer=[CAShapeLayer layer]; self.coreLayer=[CAShapeLayer layer];
        [self.layer addSublayer:self.ringLayer]; [self.layer addSublayer:self.coreLayer];
        self.ringLayer.fillColor=UIColor.clearColor.CGColor; self.ringLayer.lineWidth=3;
        self.ringLayer.strokeColor=UIColor.whiteColor.CGColor;
        self.accessibilityIdentifier=@"camera.shutter";
    } return self;
}
- (void)setHighlighted:(BOOL)highlighted { [super setHighlighted:highlighted]; [self setNeedsLayout]; [self layoutIfNeeded]; }
- (void)setVideoMode:(BOOL)videoMode { _videoMode=videoMode; [self setNeedsLayout]; }
- (void)setRecording:(BOOL)recording { _recording=recording; [self setNeedsLayout]; }
- (void)layoutSubviews {
    [super layoutSubviews]; [CATransaction begin]; [CATransaction setDisableActions:YES];
    self.ringLayer.frame=self.bounds; self.coreLayer.frame=self.bounds;
    self.ringLayer.path=[UIBezierPath bezierPathWithOvalInRect:CGRectInset(self.bounds,2,2)].CGPath;
    CGFloat inset=self.recording ? self.bounds.size.width*.31 : (self.highlighted ? 11 : 8);
    CGRect core=CGRectInset(self.bounds,inset,inset);
    self.coreLayer.path=(self.recording ? [UIBezierPath bezierPathWithRoundedRect:core cornerRadius:5] : [UIBezierPath bezierPathWithOvalInRect:core]).CGPath;
    self.coreLayer.fillColor=(self.videoMode?UIColor.systemRedColor:(self.highlighted?MCInterfaceAccent():UIColor.whiteColor)).CGColor;
    [CATransaction commit];
}
@end

@interface MCChromeView ()
@property(nonatomic,strong) UIVisualEffectView *material;
@end
@implementation MCChromeView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self=[super initWithFrame:frame])) {
        self.userInteractionEnabled=NO;
        self.material=[[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
        self.material.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        [self addSubview:self.material];
        self.layer.cornerRadius=28; self.layer.cornerCurve=kCACornerCurveContinuous;
        self.layer.maskedCorners=kCALayerMinXMinYCorner|kCALayerMaxXMinYCorner; self.clipsToBounds=YES;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshAppearance)
            name:UIAccessibilityReduceTransparencyStatusDidChangeNotification object:nil];
        [self refreshAppearance];
    } return self;
}
- (void)layoutSubviews { [super layoutSubviews]; self.material.frame=self.bounds; }
- (void)traitCollectionDidChange:(UITraitCollection *)previous { [super traitCollectionDidChange:previous]; [self refreshAppearance]; }
- (void)refreshAppearance {
    BOOL solid=UIAccessibilityIsReduceTransparencyEnabled() || self.traitCollection.accessibilityContrast==UIAccessibilityContrastHigh;
    self.material.hidden=solid; self.backgroundColor=solid ? MCInterfaceBackground() : [UIColor colorWithWhite:.02 alpha:.50];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
