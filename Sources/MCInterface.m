#import "MCInterface.h"
#import <QuartzCore/QuartzCore.h>

UIColor *MCInterfaceAccent(void) { return UIColor.systemYellowColor; }
UIColor *MCInterfaceBackground(void) { return UIColor.blackColor; }
UIFont *MCCompactFont(CGFloat size, UIFontWeight weight) {
    return [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline]
        scaledFontForFont:[UIFont systemFontOfSize:size weight:weight] maximumPointSize:size+3];
}
void MCConfigureSymbol(UIButton *button, NSString *symbol, CGFloat size) {
    UIImageSymbolConfiguration *config=[UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightMedium];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:config] forState:UIControlStateNormal];
    button.imageView.contentMode=UIViewContentModeScaleAspectFit;
}

@interface MCToolButton ()
@property(nonatomic,strong) UIVisualEffectView *fallbackMaterial;
@end
@implementation MCToolButton
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self=[super initWithFrame:frame])) {
        // UIKit owns the optical material and its touch response. The shutter
        // remains a separate immediate control with no decorative animation.
        self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
        self.tintColor=MCInterfaceAccent();
        if (@available(iOS 26.0,*)) {
            self.configuration=[UIButtonConfiguration glassButtonConfiguration];
        } else {
            self.configuration=[UIButtonConfiguration plainButtonConfiguration];
            self.fallbackMaterial=[[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
            self.fallbackMaterial.userInteractionEnabled=NO;
            [self insertSubview:self.fallbackMaterial atIndex:0];
        }
        self.titleLabel.adjustsFontSizeToFitWidth=YES;self.titleLabel.minimumScaleFactor=.85;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(setNeedsUpdateConfiguration)
            name:UIAccessibilityReduceTransparencyStatusDidChangeNotification object:nil];
        [self setNeedsUpdateConfiguration];
    } return self;
}
- (void)updateConfiguration {
    [super updateConfiguration];
    UIButtonConfiguration *configuration=self.configuration;
    configuration.cornerStyle=UIButtonConfigurationCornerStyleCapsule;
    configuration.contentInsets=NSDirectionalEdgeInsetsMake(8,12,8,12);
    configuration.imagePadding=6;
    configuration.baseForegroundColor=self.selected ? MCInterfaceAccent() : UIColor.whiteColor;
    configuration.titleTextAttributesTransformer=^NSDictionary *(NSDictionary *incoming){
        NSMutableDictionary *attributes=[incoming mutableCopy];
        attributes[NSFontAttributeName]=MCCompactFont(14,UIFontWeightSemibold);return attributes;
    };
    self.configuration=configuration;
    if(self.fallbackMaterial){
        BOOL solid=UIAccessibilityIsReduceTransparencyEnabled()||self.traitCollection.accessibilityContrast==UIAccessibilityContrastHigh;
        self.fallbackMaterial.hidden=solid;
        self.backgroundColor=solid?[UIColor colorWithWhite:.16 alpha:1]:UIColor.clearColor;
        self.fallbackMaterial.contentView.backgroundColor=self.highlighted?[UIColor colorWithWhite:1 alpha:.16]:UIColor.clearColor;
    }
}
- (void)layoutSubviews {
    [super layoutSubviews];
    if(self.fallbackMaterial){
        self.fallbackMaterial.frame=self.bounds;
        self.fallbackMaterial.layer.cornerRadius=MIN(self.bounds.size.width,self.bounds.size.height)/2;
        self.fallbackMaterial.clipsToBounds=YES;self.layer.cornerRadius=self.fallbackMaterial.layer.cornerRadius;
    }
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];[self setNeedsUpdateConfiguration];
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
    self.coreLayer.fillColor=(self.videoMode?UIColor.systemRedColor:(self.highlighted?[UIColor colorWithWhite:.8 alpha:1]:UIColor.whiteColor)).CGColor;
    [CATransaction commit];
}
@end

@implementation MCCameraScrimView
+ (Class)layerClass { return CAGradientLayer.class; }
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])){
        self.userInteractionEnabled=NO;
        CAGradientLayer *gradient=(CAGradientLayer *)self.layer;
        gradient.colors=@[(id)UIColor.clearColor.CGColor,(id)[UIColor colorWithWhite:0 alpha:.72].CGColor,(id)UIColor.blackColor.CGColor];
        gradient.locations=@[@0,@.45,@1];
    }return self;
}
@end
