#import "WMEditorViewController.h"
#import "WMEngine.h"
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <ImageIO/ImageIO.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static UIColor *WMEMint(void) { return [UIColor colorWithRed:.54 green:.94 blue:.81 alpha:1]; }
static CGFloat WMEClamp(CGFloat n, CGFloat low, CGFloat high) { return isfinite(n) ? MAX(low, MIN(high, n)) : low; }
static const NSUInteger WMEMaxImageBytes = 20 * 1024 * 1024;
static const NSUInteger WMEMaxBackupBytes = 32 * 1024 * 1024;
static const NSUInteger WMEMaxLayers = 48;
static NSError *WMEError(NSString *message) { return [NSError errorWithDomain:@"MarkCam.Editor" code:1 userInfo:@{NSLocalizedDescriptionKey:message}]; }
static id WMEDeepCopy(id value) {
    if (!value || ![NSJSONSerialization isValidJSONObject:value]) return nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
}
static UIColor *WMEColor(NSString *hex) {
    if (![hex isKindOfClass:NSString.class] || hex.length != 7 || ![hex hasPrefix:@"#"]) return UIColor.whiteColor;
    unsigned value = 0; [[NSScanner scannerWithString:[hex substringFromIndex:1]] scanHexInt:&value];
    return [UIColor colorWithRed:((value >> 16) & 255)/255.0 green:((value >> 8)&255)/255.0 blue:(value&255)/255.0 alpha:1];
}
static NSString *WMEHex(UIColor *color) {
    CGFloat r=1,g=1,b=1,a=1; [color getRed:&r green:&g blue:&b alpha:&a];
    return [NSString stringWithFormat:@"#%02X%02X%02X",(int)lround(r*255),(int)lround(g*255),(int)lround(b*255)];
}

/// A proper multiline text entry sheet, rather than an alert with a truncated field.
@interface WMETextEntryController : UIViewController <UITextViewDelegate>
@property(nonatomic, copy) NSString *initialText;
@property(nonatomic, copy) void (^completion)(NSString *);
@property(nonatomic, strong) UITextView *textView;
@property(nonatomic, strong) UILabel *counter;
@end
@implementation WMETextEntryController
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"水印文字"; self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = UIColor.systemBackgroundColor; self.view.tintColor = WMEMint();
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone target:self action:@selector(done)];
    self.textView = [[UITextView alloc] init]; self.textView.text = self.initialText ?: @"";
    self.textView.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; self.textView.adjustsFontForContentSizeCategory = YES;
    self.textView.delegate = self; self.textView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.textView.layer.cornerRadius = 14; self.textView.textContainerInset = UIEdgeInsetsMake(14,12,14,12);
    self.textView.accessibilityLabel = @"水印文字，可换行，支持日期时间占位符";
    self.counter = [[UILabel alloc] init]; self.counter.numberOfLines = 0; self.counter.textColor = UIColor.secondaryLabelColor;
    self.counter.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    UIStackView *tokens = [[UIStackView alloc] init]; tokens.spacing=12; tokens.distribution=UIStackViewDistributionFillEqually;
    for (NSString *token in @[@"{date}",@"{time}"]) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem]; [button setTitle:token forState:UIControlStateNormal];
        [button addTarget:self action:@selector(insertToken:) forControlEvents:UIControlEventTouchUpInside]; [tokens addArrangedSubview:button];
    }
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.counter,tokens,self.textView]];
    stack.axis=UILayoutConstraintAxisVertical; stack.spacing=12; stack.translatesAutoresizingMaskIntoConstraints=NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-12],
        [tokens.heightAnchor constraintEqualToConstant:44]]]; [self textViewDidChange:self.textView];
}
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; [self.textView becomeFirstResponder]; }
- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)done {
    if (self.textView.text.length > 600) return;
    NSString *text=[self.textView.text copy]; void (^completion)(NSString *)=self.completion;
    [self dismissViewControllerAnimated:YES completion:^{ if (completion) completion(text); }];
}
- (void)insertToken:(UIButton *)sender { [self.textView insertText:sender.currentTitle]; [self textViewDidChange:self.textView]; }
- (void)textViewDidChange:(UITextView *)textView {
    self.counter.text=[NSString stringWithFormat:@"%lu / 600 字符 · 支持换行\n{date} → 2026.09.10    {time} → 22:30:00\n占位符将在每次拍摄时自动更新。",(unsigned long)textView.text.length];
    self.navigationItem.rightBarButtonItem.enabled=textView.text.length<=600;
}
@end

@interface WMEditorViewController () <UITableViewDataSource,UITableViewDelegate,UIGestureRecognizerDelegate,UIColorPickerViewControllerDelegate,PHPickerViewControllerDelegate,UIDocumentPickerDelegate>
@property(nonatomic, strong) WMEngine *engine;
@property(nonatomic, strong) UITableView *table;
@property(nonatomic, strong) UIView *header;
@property(nonatomic, strong) NSLayoutConstraint *headerHeight;
@property(nonatomic, strong) UIView *canvas;
@property(nonatomic, strong) UIImageView *photoView;
@property(nonatomic, strong) UIImageView *overlayView;
@property(nonatomic, strong) UIView *reticle;
@property(nonatomic, strong) UILabel *canvasHint;
@property(nonatomic, strong) UIImage *preparedImage;
@property(nonatomic, copy) NSString *selectedID;
@property(nonatomic, copy) NSString *colorLayerID;
@property(nonatomic, copy) NSArray<NSDictionary *> *inspectorRows;
@property(nonatomic, strong) CIContext *ciContext;
@property(nonatomic, strong) dispatch_queue_t renderQueue;
@property(nonatomic, strong) dispatch_queue_t importQueue;
@property(nonatomic) BOOL rendering;
@property(nonatomic) BOOL renderAgain;
@property(nonatomic) NSUInteger renderGeneration;
@property(nonatomic) BOOL importing;
@property(nonatomic) BOOL documentIsBackup;
@property(nonatomic) NSUInteger importGeneration;
@property(nonatomic) BOOL closing;
@end

@implementation WMEditorViewController
- (void)viewDidLoad {
    [super viewDidLoad]; self.title=@"水印工坊"; self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    self.view.backgroundColor=[UIColor colorWithRed:.04 green:.07 blue:.075 alpha:1]; self.view.tintColor=WMEMint();
    self.engine=[WMEngine shared];
    self.renderQueue=dispatch_queue_create("app.markcam.editor.preview",DISPATCH_QUEUE_SERIAL);
    self.importQueue=dispatch_queue_create("app.markcam.editor.import",DISPATCH_QUEUE_SERIAL);
    self.ciContext=[CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@NO}];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone target:self action:@selector(done)];
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"添加" style:UIBarButtonItemStylePlain target:self action:@selector(showAddMenu)];
    self.table=[[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.backgroundColor=self.view.backgroundColor; self.table.delegate=self; self.table.dataSource=self;
    self.table.translatesAutoresizingMaskIntoConstraints=NO; self.table.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;
    self.table.rowHeight=UITableViewAutomaticDimension; self.table.estimatedRowHeight=56;
    [self.view addSubview:self.table];
    self.header=[[UIView alloc] initWithFrame:CGRectZero]; self.header.translatesAutoresizingMaskIntoConstraints=NO;
    [self.view addSubview:self.header]; self.headerHeight=[self.header.heightAnchor constraintEqualToConstant:280];
    [NSLayoutConstraint activateConstraints:@[
        [self.header.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.header.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [self.header.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor], self.headerHeight,
        [self.table.topAnchor constraintEqualToAnchor:self.header.bottomAnchor],
        [self.table.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [self.table.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor]]];
    self.canvas=[[UIView alloc] init]; self.canvas.backgroundColor=UIColor.blackColor; self.canvas.layer.cornerRadius=16; self.canvas.clipsToBounds=YES;
    self.canvas.accessibilityLabel=@"水印预览画布"; self.canvas.accessibilityHint=@"在下方选择图层；未锁定时可拖动、双指缩放或旋转。";
    self.photoView=[[UIImageView alloc] init]; self.overlayView=[[UIImageView alloc] init];
    self.photoView.contentMode=UIViewContentModeScaleToFill; self.overlayView.contentMode=UIViewContentModeScaleToFill;
    [self.canvas addSubview:self.photoView]; [self.canvas addSubview:self.overlayView];
    self.reticle=[[UIView alloc] initWithFrame:CGRectMake(0,0,28,28)]; self.reticle.layer.cornerRadius=14;
    self.reticle.layer.borderWidth=1.5; self.reticle.layer.borderColor=WMEMint().CGColor; self.reticle.userInteractionEnabled=NO;
    self.reticle.backgroundColor=[WMEMint() colorWithAlphaComponent:.12]; [self.canvas addSubview:self.reticle];
    self.canvasHint=[[UILabel alloc] init]; self.canvasHint.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.canvasHint.textColor=UIColor.secondaryLabelColor; self.canvasHint.textAlignment=NSTextAlignmentCenter; self.canvasHint.numberOfLines=0;
    [self.header addSubview:self.canvas]; [self.header addSubview:self.canvasHint];
    NSArray *gestures=@[[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)],
                        [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinch:)],
                        [[UIRotationGestureRecognizer alloc] initWithTarget:self action:@selector(rotate:)]];
    for (UIGestureRecognizer *gesture in gestures) { gesture.delegate=self; [self.canvas addGestureRecognizer:gesture]; }
    self.selectedID=[self layers].lastObject[@"id"]; [self rebuildInspector]; [self prepareBackground]; [self requestRender];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if(self.opensSettings){self.opensSettings=NO;[self.table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:4] atScrollPosition:UITableViewScrollPositionTop animated:NO];}
}
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; [self layoutCanvas]; }
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed || self.navigationController.isBeingDismissed || self.isMovingFromParentViewController) {
        self.closing=YES; self.importGeneration++; [self notifyChange];
    }
}
- (void)done {
    self.closing=YES; self.importGeneration++; [self.engine save]; [self notifyChange];
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)setBackgroundImage:(UIImage *)backgroundImage {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ self.backgroundImage=backgroundImage; }); return; }
    _backgroundImage=backgroundImage;
    if (self.isViewLoaded) { [self prepareBackground]; [self layoutCanvas]; [self requestRender]; }
}
- (void)prepareBackground {
    UIImage *image=self.backgroundImage; CGSize size=image ? image.size : CGSizeMake(750,1000);
    if (size.width<1 || size.height<1 || !isfinite(size.width) || !isfinite(size.height)) { image=nil; size=CGSizeMake(750,1000); }
    CGFloat scale=MIN(1,1000.0/MAX(size.width,size.height)); size=CGSizeMake(MAX(1,round(size.width*scale)),MAX(1,round(size.height*scale)));
    UIGraphicsImageRendererFormat *format=[UIGraphicsImageRendererFormat defaultFormat]; format.scale=1; format.opaque=YES;
    UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    self.preparedImage=[renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        if (image) { [image drawInRect:(CGRect){CGPointZero,size}]; return; }
        [[UIColor colorWithRed:.12 green:.2 blue:.22 alpha:1] setFill]; UIRectFill((CGRect){CGPointZero,size});
        NSArray *colors=@[(id)[UIColor colorWithRed:.09 green:.24 blue:.24 alpha:1].CGColor,(id)[UIColor colorWithRed:.22 green:.18 blue:.13 alpha:1].CGColor];
        CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB(); CGGradientRef gradient=CGGradientCreateWithColors(space,(__bridge CFArrayRef)colors,NULL);
        CGContextDrawLinearGradient(ctx.CGContext,gradient,CGPointZero,CGPointMake(size.width,size.height),0); CGGradientRelease(gradient); CGColorSpaceRelease(space);
        [@"印记 / MARKCAM" drawAtPoint:CGPointMake(size.width*.08,size.height*.12) withAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:size.width*.045 weight:UIFontWeightMedium],NSForegroundColorAttributeName:[UIColor.whiteColor colorWithAlphaComponent:.4]}];
    }];
}
- (void)layoutCanvas {
    CGFloat width=self.header.bounds.size.width; if (width<1) return;
    [self updateReticle];
    CGFloat available=MAX(180,self.view.safeAreaLayoutGuide.layoutFrame.size.height);
    CGFloat hintHeight=MAX(44,[self.canvasHint sizeThatFits:CGSizeMake(width-32,CGFLOAT_MAX)].height+4);
    CGFloat maxHeight=MIN(290,MAX(68,available*.43-hintHeight-20));
    CGSize size=self.preparedImage.size; CGFloat aspect=(size.height>0)?size.width/size.height:.75;
    CGFloat w=MIN(MAX(1,width-32),maxHeight*aspect); CGFloat h=w/MAX(.001,aspect);
    self.canvas.frame=CGRectMake((width-w)/2,8,w,h); self.photoView.frame=self.canvas.bounds; self.overlayView.frame=self.canvas.bounds;
    self.canvasHint.frame=CGRectMake(16,h+12,width-32,hintHeight);
    CGFloat height=h+hintHeight+18;
    if (fabs(self.headerHeight.constant-height)>.5) self.headerHeight.constant=height;
    [self updateReticle];
}
- (NSMutableArray *)layers {
    id layers=self.engine.settings[@"layers"];
    if (![layers isKindOfClass:NSMutableArray.class]) { layers=WMEDeepCopy(layers) ?: [NSMutableArray array]; self.engine.settings[@"layers"]=layers; }
    return layers;
}
- (NSMutableDictionary *)layerWithID:(NSString *)identifier {
    if (!identifier) return nil; NSMutableArray *layers=[self layers];
    for (NSUInteger i=0;i<layers.count;i++) {
        id layer=layers[i]; if (![layer isKindOfClass:NSDictionary.class] || ![layer[@"id"] isEqual:identifier]) continue;
        if (![layer isKindOfClass:NSMutableDictionary.class]) { layer=[layer mutableCopy]; layers[i]=layer; } return layer;
    } return nil;
}
- (NSMutableDictionary *)selectedLayer { return [self layerWithID:self.selectedID]; }
- (void)notifyChange { NSAssert(NSThread.isMainThread,@"Editor callbacks must run on main"); if (self.onChange) self.onChange(); }
- (void)commit:(BOOL)reload {
    NSAssert(NSThread.isMainThread,@"Editor settings are main-thread confined");
    [self.engine save]; [self notifyChange]; [self requestRender];
    if (reload) { [self rebuildInspector]; [self.table reloadData]; }
}

#pragma mark - Preview: tone the photo, never the overlay
- (void)requestRender {
    [self updateReticle]; self.renderGeneration++;
    if (self.rendering) { self.renderAgain=YES; return; }
    if (!self.preparedImage || self.closing) return;
    self.rendering=YES; self.renderAgain=NO;
    NSUInteger generation=self.renderGeneration; NSDictionary *snapshot=[self.engine snapshot];
    UIImage *source=self.preparedImage; WMEngine *engine=self.engine; CIContext *context=self.ciContext;
    NSDate *date=[NSDate date]; __weak typeof(self) weakSelf=self;
    dispatch_async(self.renderQueue, ^{
        @autoreleasepool {
            CIImage *input=[[CIImage alloc] initWithImage:source]; CIImage *toned=[engine applyTone:input settings:snapshot];
            CGImageRef rendered=toned ? [context createCGImage:toned fromRect:input.extent] : NULL;
            UIImage *photo=rendered ? [UIImage imageWithCGImage:rendered scale:1 orientation:UIImageOrientationUp] : source;
            if (rendered) CGImageRelease(rendered);
            UIImage *overlay=[engine overlayForSize:source.size settings:snapshot date:date];
            dispatch_async(dispatch_get_main_queue(), ^{
                WMEditorViewController *editor=weakSelf; if (!editor) return;
                editor.rendering=NO;
                if (editor.closing) return;
                if (generation==editor.renderGeneration) { editor.photoView.image=photo; editor.overlayView.image=overlay; }
                if (editor.renderAgain || generation!=editor.renderGeneration) [editor requestRender];
            });
        }
    });
}
- (void)updateReticle {
    NSDictionary *layer=[self selectedLayer]; BOOL enabled=[self.engine.settings[@"watermarkEnabled"] boolValue];
    self.reticle.hidden=!layer || !enabled;
    self.reticle.center=CGPointMake([layer[@"x"] doubleValue]*self.canvas.bounds.size.width,[layer[@"y"] doubleValue]*self.canvas.bounds.size.height);
    BOOL locked=[layer[@"locked"] boolValue]; self.reticle.layer.borderColor=(locked ? UIColor.systemOrangeColor : WMEMint()).CGColor;
    NSString *intro=self.backgroundImage ? @"实拍画面预览" : @"示例画布 · 返回相机后实拍";
    NSString *hint=!enabled ? @"水印已关闭，开启后可编辑画布" : (!layer ? @"从下方选择或添加图层" : (locked ? @"已锁定 · 解锁后可调整" : @"拖动位置 · 双指缩放 / 旋转"));
    self.canvasHint.text=[NSString stringWithFormat:@"%@\n%@ · 圆环仅为选中标记",intro,hint];
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    NSDictionary *layer=[self selectedLayer];
    return layer && ![layer[@"locked"] boolValue] && [self.engine.settings[@"watermarkEnabled"] boolValue] && !self.importing;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return gesture.view==self.canvas && other.view==self.canvas;
}
- (void)finishGesture:(UIGestureRecognizer *)gesture {
    if (gesture.state==UIGestureRecognizerStateEnded || gesture.state==UIGestureRecognizerStateCancelled) { [self rebuildInspector]; [self.table reloadData]; }
}
- (void)pan:(UIPanGestureRecognizer *)gesture {
    NSMutableDictionary *layer=[self selectedLayer]; if (!layer || [layer[@"locked"] boolValue]) return;
    CGPoint delta=[gesture translationInView:self.canvas]; [gesture setTranslation:CGPointZero inView:self.canvas];
    layer[@"x"]=@(WMEClamp([layer[@"x"] doubleValue]+delta.x/MAX(1,self.canvas.bounds.size.width),0,1));
    layer[@"y"]=@(WMEClamp([layer[@"y"] doubleValue]+delta.y/MAX(1,self.canvas.bounds.size.height),0,1));
    [self commit:NO]; [self finishGesture:gesture];
}
- (void)pinch:(UIPinchGestureRecognizer *)gesture {
    NSMutableDictionary *layer=[self selectedLayer]; if (!layer || [layer[@"locked"] boolValue]) return;
    layer[@"scale"]=@(WMEClamp([layer[@"scale"] doubleValue]*gesture.scale,.2,5)); gesture.scale=1;
    [self commit:NO]; [self finishGesture:gesture];
}
- (void)rotate:(UIRotationGestureRecognizer *)gesture {
    NSMutableDictionary *layer=[self selectedLayer]; if (!layer || [layer[@"locked"] boolValue]) return;
    CGFloat angle=[layer[@"rotation"] doubleValue]+gesture.rotation; gesture.rotation=0;
    layer[@"rotation"]=@(atan2(sin(angle),cos(angle))); [self commit:NO]; [self finishGesture:gesture];
}

#pragma mark - Row descriptions
- (NSDictionary *)action:(NSString *)title key:(NSString *)key { return @{ @"title":title, @"key":key, @"kind":@"action" }; }
- (NSDictionary *)slider:(NSString *)title key:(NSString *)key min:(double)min max:(double)max {
    return @{ @"title":title,@"key":key,@"kind":@"slider",@"min":@(min),@"max":@(max) };
}
- (NSDictionary *)toggle:(NSString *)title key:(NSString *)key { return @{ @"title":title,@"key":key,@"kind":@"toggle" }; }
- (NSArray *)toneRows { return @[
    [self action:@"调色预设" key:@"tonePreset"],
    [self slider:@"亮度" key:@"brightness" min:-.3 max:.3],
    [self slider:@"对比度" key:@"contrast" min:.5 max:1.5],
    [self slider:@"饱和度" key:@"saturation" min:0 max:2],
    [self slider:@"冷暖" key:@"warmth" min:-1 max:1]]; }
- (NSArray *)settingRows { return @[
    [self slider:@"EV 曝光补偿" key:@"exposureBias" min:-2 max:2],
    [self action:@"曝光恢复为 0 EV" key:@"resetExposure"],
    [self toggle:@"Live Photo 实况照片" key:@"livePhotoEnabled"],
    [self toggle:@"流畅优先（取景不调色）" key:@"smoothPreview"],
    [self toggle:@"自动添加水印" key:@"watermarkEnabled"], [self toggle:@"保留原片" key:@"keepOriginal"],
    [self toggle:@"相机九宫格" key:@"gridEnabled"], [self toggle:@"前置镜像" key:@"mirrorFront"],
    [self action:@"闪光灯" key:@"flashMode"], [self action:@"拍照倒计时" key:@"timerSeconds"]]; }
- (NSArray *)templateRows { return @[
    [self action:@"内置预设" key:@"presets"], [self action:@"保存为我的模板" key:@"saveTemplate"],
    [self action:@"我的模板" key:@"myTemplates"], [self action:@"导入模板备份（JSON）" key:@"importBackup"],
    [self action:@"导出当前模板备份" key:@"exportBackup"]]; }
- (void)rebuildInspector {
    NSDictionary *layer=[self selectedLayer]; if (!layer) { self.inspectorRows=@[]; return; }
    BOOL image=[layer[@"type"] isEqual:@"image"];
    NSMutableArray *rows=[NSMutableArray arrayWithObject:[self toggle:@"锁定图层" key:@"locked"]];
    if (!image) [rows addObjectsFromArray:@[[self action:@"文字内容 / 日期占位符" key:@"text"], [self action:@"文字颜色" key:@"color"], [self action:@"字体" key:@"font"], [self toggle:@"粗体" key:@"bold"], [self slider:@"字号 · 短边比例" key:@"fontSize" min:.015 max:.2]]];
    [rows addObjectsFromArray:@[[self slider:image ? @"图片宽度 · 短边比例" : @"换行宽度 · 短边比例" key:@"width" min:.08 max:1.5],
        [self slider:@"整体缩放" key:@"scale" min:.2 max:5], [self slider:@"不透明度" key:@"opacity" min:0 max:1],
        [self slider:@"旋转角度" key:@"rotation" min:-M_PI max:M_PI],
        [self slider:@"水平位置" key:@"x" min:0 max:1], [self slider:@"垂直位置" key:@"y" min:0 max:1],
        [self toggle:@"背景底板" key:@"background"], [self toggle:@"投影" key:@"shadow"],
        [self action:@"复制图层" key:@"duplicate"], [self action:@"上移一层（更靠前）" key:@"forward"],
        [self action:@"下移一层（更靠后）" key:@"backward"], [self action:@"删除图层" key:@"delete"]]];
    self.inspectorRows=rows;
}

#pragma mark - Table view
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 5; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section==0) return [self layers].count+1;
    if (section==1) return MAX(1,self.inspectorRows.count);
    if (section==2) return self.toneRows.count;
    if (section==3) return self.templateRows.count;
    return self.settingRows.count;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"图层 · 点击选中",@"选中图层",@"基础调色",@"模板资料库",@"相机设置"][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section==0) return @"列表底部的图层绘制在最上方。圆环标记中心位置，不会出现在照片中。";
    if (section==1) return @"锁定后不能移动或修改图层；先解锁再编辑。图片保存在本机，文字支持 {date} 和 {time}。";
    if (section==2) return @"仅调整照片底图，水印颜色保持不变。这里的“原图”是调色归零，不会移除水印。";
    if (section==3) return @"切换模板只替换水印图层，调色与相机设置不变。导出包含当前图层和内嵌图片，建议及时备份。";
    return @"所有修改立即保存。EV 返回取景后生效。流畅优先使用系统预览，取景不显示调色，但水印可见，照片/视频/实况成片仍应用调色。关闭流畅优先时，有调色自动用GPU预览。0.5×只在硬件支持时提供；2×不保证为光学长焦。Live Photo需要当前镜头支持和麦克风授权。";
}
- (NSDictionary *)rowAt:(NSIndexPath *)path {
    if (path.section==1) return path.row<(NSInteger)self.inspectorRows.count ? self.inspectorRows[path.row] : nil;
    if (path.section==2) return self.toneRows[path.row];
    if (path.section==3) return self.templateRows[path.row];
    if (path.section==4) return self.settingRows[path.row]; return nil;
}
- (NSString *)valueLabel:(double)value key:(NSString *)key {
    if ([key isEqual:@"exposureBias"]) return [NSString stringWithFormat:@"%+.1f EV",value];
    if ([key isEqual:@"rotation"]) return [NSString stringWithFormat:@"%.0f°",value*180/M_PI];
    if ([@[@"x",@"y",@"opacity",@"width",@"fontSize"] containsObject:key]) return [NSString stringWithFormat:@"%.1f%%",value*100];
    return [NSString stringWithFormat:@"%.2f",value];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    // No reused control state; at most a screenful of lightweight visible cells.
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor=[UIColor colorWithRed:.085 green:.115 blue:.12 alpha:1]; cell.tintColor=WMEMint();
    cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody]; cell.textLabel.adjustsFontForContentSizeCategory=YES;
    cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1]; cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;
    cell.textLabel.numberOfLines=0; cell.detailTextLabel.numberOfLines=2; cell.detailTextLabel.textColor=UIColor.secondaryLabelColor;
    if (path.section==0) {
        if (path.row==(NSInteger)[self layers].count) { cell.textLabel.text=@"＋ 添加文字、日期或图片"; cell.textLabel.textColor=WMEMint(); return cell; }
        NSDictionary *layer=[self layers][path.row]; BOOL image=[layer[@"type"] isEqual:@"image"];
        NSString *text=image ? @"图片水印" : layer[@"text"]; if (![text isKindOfClass:NSString.class] || !text.length) text=@"空白文字";
        if (text.length>48) text=[[text substringToIndex:48] stringByAppendingString:@"…"];
        cell.textLabel.text=[NSString stringWithFormat:@"%ld  %@",(long)path.row+1,text];
        cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ · %@",image?@"图片":([layer[@"type"] isEqual:@"date"]?@"动态日期":@"文字"),[layer[@"locked"] boolValue]?@"已锁定":@"可编辑"];
        if ([layer[@"id"] isEqual:self.selectedID]) { cell.accessoryType=UITableViewCellAccessoryCheckmark; cell.textLabel.textColor=WMEMint(); }
        return cell;
    }
    NSDictionary *row=[self rowAt:path]; if (!row) { cell.textLabel.text=@"尚未选择图层"; cell.selectionStyle=UITableViewCellSelectionStyleNone; return cell; }
    NSString *key=row[@"key"]; NSString *kind=row[@"kind"];
    NSDictionary *values=path.section==1 ? [self selectedLayer] : (path.section==2 ? self.engine.settings[@"tone"] : self.engine.settings);
    BOOL disabled=path.section==1 && [[self selectedLayer][@"locked"] boolValue] && ![@[@"locked",@"duplicate"] containsObject:key];
    cell.selectionStyle=[kind isEqual:@"action"] && !disabled ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    if ([kind isEqual:@"slider"]) {
        UILabel *title=[[UILabel alloc] init]; title.numberOfLines=0; title.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]; title.adjustsFontForContentSizeCategory=YES;
        double value=[values[key] doubleValue]; title.text=[NSString stringWithFormat:@"%@  %@",row[@"title"],[self valueLabel:value key:key]]; title.tag=913;
        UISlider *slider=[[UISlider alloc] init]; slider.minimumValue=[row[@"min"] floatValue]; slider.maximumValue=[row[@"max"] floatValue]; slider.value=value;
        slider.tintColor=WMEMint(); slider.tag=path.section; slider.accessibilityIdentifier=key; slider.accessibilityLabel=row[@"title"];
        slider.accessibilityValue=[self valueLabel:value key:key]; slider.enabled=!disabled;
        [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[title,slider]]; stack.axis=UILayoutConstraintAxisVertical; stack.spacing=2;
        stack.translatesAutoresizingMaskIntoConstraints=NO; [cell.contentView addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
            [stack.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:12],
            [stack.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8], [slider.heightAnchor constraintEqualToConstant:40]]];
        stack.alpha=disabled?.4:1;
    } else {
        cell.textLabel.text=row[@"title"];
        if ([kind isEqual:@"toggle"]) {
            UISwitch *toggle=[[UISwitch alloc] init]; toggle.onTintColor=WMEMint(); toggle.on=[values[key] boolValue]; toggle.tag=path.section; toggle.accessibilityIdentifier=key;
            toggle.accessibilityLabel=row[@"title"]; toggle.enabled=!disabled; [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView=toggle;
        } else {
            cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
            if ([key isEqual:@"text"]) cell.detailTextLabel.text=values[@"text"];
            if ([key isEqual:@"font"]) cell.detailTextLabel.text=@{@"system":@"系统黑体",@"serif":@"衬线体",@"mono":@"等宽体"}[values[@"font"]?:@"system"];
            if ([key isEqual:@"color"]) { cell.detailTextLabel.text=values[key]; cell.imageView.image=[UIImage systemImageNamed:@"circle.fill"]; cell.imageView.tintColor=WMEColor(values[key]); }
            if ([key isEqual:@"flashMode"]) cell.detailTextLabel.text=@[@"关闭",@"自动",@"开启"][(NSInteger)WMEClamp([values[key] integerValue],0,2)];
            if ([key isEqual:@"timerSeconds"]) cell.detailTextLabel.text=[values[key] integerValue]==0?@"关闭":[NSString stringWithFormat:@"%@ 秒",values[key]];
            if ([key isEqual:@"myTemplates"]) cell.detailTextLabel.text=[NSString stringWithFormat:@"%lu 个已保存",(unsigned long)[self.engine.settings[@"userTemplates"] count]];
            if ([key isEqual:@"delete"]) cell.textLabel.textColor=UIColor.systemRedColor;
        }
        cell.contentView.alpha=disabled?.4:1; cell.userInteractionEnabled=!disabled;
    }
    return cell;
}

- (void)sliderChanged:(UISlider *)slider {
    NSString *key=slider.accessibilityIdentifier; NSMutableDictionary *values;
    if (slider.tag==1) { values=[self selectedLayer]; if (!values || [values[@"locked"] boolValue]) return; }
    else if (slider.tag==4) { values=self.engine.settings; }
    else { values=[self.engine.settings[@"tone"] mutableCopy] ?: [NSMutableDictionary dictionary]; self.engine.settings[@"tone"]=values; }
    values[key]=@(WMEClamp(slider.value,slider.minimumValue,slider.maximumValue));
    NSDictionary *row=nil; for (NSDictionary *candidate in slider.tag==1 ? self.inspectorRows : (slider.tag==4 ? self.settingRows : self.toneRows)) if ([candidate[@"key"] isEqual:key]) { row=candidate; break; }
    UILabel *label=[slider.superview viewWithTag:913]; label.text=[NSString stringWithFormat:@"%@  %@",row[@"title"],[self valueLabel:slider.value key:key]];
    slider.accessibilityValue=[self valueLabel:slider.value key:key]; [self commit:NO];
}
- (void)toggleChanged:(UISwitch *)toggle {
    NSString *key=toggle.accessibilityIdentifier;
    NSMutableDictionary *values=toggle.tag==1 ? [self selectedLayer] : self.engine.settings;
    if (toggle.tag==1 && ![key isEqual:@"locked"] && [values[@"locked"] boolValue]) return;
    values[key]=@(toggle.on); [self commit:[key isEqual:@"locked"]];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section==0) {
        if (path.row==(NSInteger)[self layers].count) { [self showAddMenu]; return; }
        self.selectedID=[self layers][path.row][@"id"]; [self rebuildInspector]; [self.table reloadData]; [self updateReticle]; return;
    }
    NSString *key=[self rowAt:path][@"key"];
    if ([key isEqual:@"text"]) [self editText];
    else if ([key isEqual:@"color"]) [self editColor];
    else if ([key isEqual:@"font"]) [self chooseFont];
    else if ([key isEqual:@"duplicate"]) [self duplicateLayer];
    else if ([key isEqual:@"delete"]) [self deleteLayer];
    else if ([key isEqual:@"forward"]) [self moveLayer:1];
    else if ([key isEqual:@"backward"]) [self moveLayer:-1];
    else if ([key isEqual:@"tonePreset"]) [self chooseTone];
    else if ([key isEqual:@"presets"]) [self chooseTemplates:NO];
    else if ([key isEqual:@"myTemplates"]) [self chooseTemplates:YES];
    else if ([key isEqual:@"saveTemplate"]) [self saveTemplate];
    else if ([key isEqual:@"importBackup"]) [self chooseDocument:YES];
    else if ([key isEqual:@"exportBackup"]) [self exportBackup];
    else if ([key isEqual:@"resetExposure"]) { self.engine.settings[@"exposureBias"]=@0; [self commit:YES]; }
    else if ([key isEqual:@"flashMode"]) [self chooseSetting:key titles:@[@"关闭",@"自动",@"开启"] values:@[@0,@1,@2]];
    else if ([key isEqual:@"timerSeconds"]) [self chooseSetting:key titles:@[@"关闭",@"3 秒",@"10 秒"] values:@[@0,@3,@10]];
}

#pragma mark - Actions
- (void)message:(NSString *)title detail:(NSString *)detail {
    if (self.closing) return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:detail preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:alert animated:YES completion:nil];
}
- (void)presentMenu:(UIAlertController *)menu {
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView=self.view;
    menu.popoverPresentationController.sourceRect=CGRectMake(self.view.bounds.size.width/2,self.view.bounds.size.height/2,1,1);
    [self presentViewController:menu animated:YES completion:nil];
}
- (void)confirm:(NSString *)title detail:(NSString *)detail action:(void(^)(void))action {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:detail preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确认" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) { action(); }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)showAddMenu {
    if (self.importing) { [self message:@"正在导入" detail:@"图片或模板处理完成后可继续添加。也可点击完成离开编辑器。每次只处理一个文件。 "]; return; }
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"添加图层" message:@"图片只访问你选择的文件，不申请读取整个相册。" preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf=self;
    [menu addAction:[UIAlertAction actionWithTitle:@"文字水印" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [weakSelf addType:@"text" asset:nil]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"日期与时间" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [weakSelf addType:@"date" asset:nil]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"从照片选择图片" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [weakSelf choosePhoto]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"从文件选择图片" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [weakSelf chooseDocument:NO]; }]];
    for (NSString *asset in @[@"stamp-leaf.png",@"stamp-aperture.png"]) {
        [menu addAction:[UIAlertAction actionWithTitle:[asset containsString:@"leaf"]?@"内置 · 薄荷叶印章":@"内置 · 镜头印章" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            WMEditorViewController *editor=weakSelf; if (![editor.engine imageForLayer:@{@"type":@"image",@"asset":asset}]) { [editor message:@"素材尚未就绪" detail:@"安装包中没有找到该印章，请使用照片或文件导入。 "]; return; } [editor addType:@"image" asset:asset];
        }]];
    } [self presentMenu:menu];
}

- (void)addType:(NSString *)type asset:(NSString *)asset {
    if ([self layers].count>=WMEMaxLayers) { [self message:@"图层已满" detail:@"最多支持 48 个图层，请删除部分图层后再添加。 "]; return; }
    NSMutableDictionary *layer=[@{@"id":NSUUID.UUID.UUIDString,@"type":type,@"text":[type isEqual:@"date"]?@"{date}  {time}":@"我的印记",
        @"x":@.5,@"y":@.8,@"width":[type isEqual:@"image"]?@.25:@.7,@"fontSize":@.04,@"scale":@1,@"rotation":@0,@"color":@"#FFFFFF",
        @"opacity":@1,@"background":@NO,@"shadow":@YES,@"locked":@NO,@"font":@"system",@"bold":@YES} mutableCopy];
    if (asset) layer[@"asset"]=asset; [[self layers] addObject:layer]; self.selectedID=layer[@"id"]; [self commit:YES];
    if ([type isEqual:@"text"]) [self editText];
}
- (void)editText {
    NSDictionary *layer=[self selectedLayer]; if (!layer || [layer[@"locked"] boolValue]) return;
    NSString *identifier=layer[@"id"]; WMETextEntryController *entry=[[WMETextEntryController alloc] init]; entry.initialText=layer[@"text"];
    __weak typeof(self) weakSelf=self; entry.completion=^(NSString *text) {
        WMEditorViewController *editor=weakSelf; NSMutableDictionary *target=[editor layerWithID:identifier];
        if (!editor || !target || [target[@"locked"] boolValue] || editor.closing) return;
        target[@"text"]=text; [editor commit:YES];
    };
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:entry]; navigation.modalPresentationStyle=UIModalPresentationFullScreen;
    [self presentViewController:navigation animated:YES completion:nil];
}
- (void)editColor {
    NSDictionary *layer=[self selectedLayer]; if (!layer || [layer[@"locked"] boolValue]) return;
    self.colorLayerID=layer[@"id"]; UIColorPickerViewController *picker=[[UIColorPickerViewController alloc] init];
    picker.selectedColor=WMEColor(layer[@"color"]); picker.supportsAlpha=NO; picker.delegate=self;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)colorPickerViewController:(UIColorPickerViewController *)viewController didSelectColor:(UIColor *)color continuously:(BOOL)continuously {
    NSMutableDictionary *layer=[self layerWithID:self.colorLayerID]; if (!layer || [layer[@"locked"] boolValue]) return;
    layer[@"color"]=WMEHex(color); [self commit:!continuously];
}
- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController { [self.table reloadData]; self.colorLayerID=nil; }
- (void)chooseFont {
    NSDictionary *layer=[self selectedLayer]; if (!layer || [layer[@"locked"] boolValue]) return;
    NSString *identifier=layer[@"id"]; UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"字体" message:@"使用系统字体，无需联网下载。" preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *names=@[@"系统黑体",@"衬线体",@"等宽体"], *keys=@[@"system",@"serif",@"mono"];
    __weak typeof(self) weakSelf=self;
    for (NSUInteger i=0;i<names.count;i++) [menu addAction:[UIAlertAction actionWithTitle:names[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        WMEditorViewController *editor=weakSelf; NSMutableDictionary *target=[editor layerWithID:identifier];
        if (!target || [target[@"locked"] boolValue]) return; target[@"font"]=keys[i]; [editor commit:YES];
    }]];
    [self presentMenu:menu];
}
- (void)duplicateLayer {
    NSMutableDictionary *layer=WMEDeepCopy([self selectedLayer]); if (!layer) return;
    if ([self layers].count>=WMEMaxLayers) { [self message:@"图层已满" detail:@"最多支持 48 个图层。 "]; return; }
    layer[@"id"]=NSUUID.UUID.UUIDString; layer[@"locked"]=@NO;
    layer[@"x"]=@(WMEClamp([layer[@"x"] doubleValue]+.03,0,1)); layer[@"y"]=@(WMEClamp([layer[@"y"] doubleValue]+.03,0,1));
    [[self layers] addObject:layer]; self.selectedID=layer[@"id"]; [self commit:YES];
}
- (void)deleteLayer {
    NSDictionary *layer=[self selectedLayer]; if (!layer || [layer[@"locked"] boolValue]) return;
    NSString *identifier=layer[@"id"]; __weak typeof(self) weakSelf=self;
    [self confirm:@"删除选中图层？" detail:@"此操作不能撤销。已保存的模板不受影响。" action:^{
        WMEditorViewController *editor=weakSelf; NSMutableDictionary *target=[editor layerWithID:identifier]; if (!target || [target[@"locked"] boolValue]) return;
        [[editor layers] removeObjectIdenticalTo:target]; editor.selectedID=[editor layers].lastObject[@"id"]; [editor commit:YES];
    }];
}
- (void)moveLayer:(NSInteger)direction {
    NSDictionary *layer=[self selectedLayer]; if (!layer || [layer[@"locked"] boolValue]) return;
    NSMutableArray *layers=[self layers]; NSUInteger index=[layers indexOfObjectIdenticalTo:layer];
    if (index==NSNotFound) return; NSInteger next=(NSInteger)index+direction;
    if (next<0 || next>=(NSInteger)layers.count) { [self message:@"已经到达边界" detail:direction>0?@"当前图层已经在最上方。":@"当前图层已经在最下方。"]; return; }
    [layers exchangeObjectAtIndex:index withObjectAtIndex:next]; [self commit:YES];
}
- (void)chooseSetting:(NSString *)key titles:(NSArray *)titles values:(NSArray *)values {
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:[key isEqual:@"flashMode"]?@"闪光灯":@"拍照倒计时" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf=self;
    for (NSUInteger i=0;i<titles.count;i++) [menu addAction:[UIAlertAction actionWithTitle:titles[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        WMEditorViewController *editor=weakSelf; editor.engine.settings[key]=values[i]; [editor commit:YES];
    }]];
    [self presentMenu:menu];
}
- (void)chooseTone {
    NSArray *names=@[@"原图",@"清透",@"暖色",@"复古",@"黑白"];
    NSArray *tones=@[@[@0,@1,@1,@0],@[@.035,@1.08,@1.12,@-.08],@[@.015,@1.04,@1.06,@.35],@[@.015,@.9,@.68,@.3],@[@0,@1.12,@0,@0]];
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"调色预设" message:@"会替换当前四项调色参数，水印不受影响。" preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf=self;
    for (NSUInteger i=0;i<names.count;i++) [menu addAction:[UIAlertAction actionWithTitle:names[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        WMEditorViewController *editor=weakSelf; NSArray *v=tones[i]; editor.engine.settings[@"tone"]=[@{@"brightness":v[0],@"contrast":v[1],@"saturation":v[2],@"warmth":v[3]} mutableCopy]; [editor commit:YES];
    }]];
    [self presentMenu:menu];
}

#pragma mark - Template library
- (void)applyTemplate:(NSDictionary *)template {
    NSArray *layers=template[@"layers"];
    if (![layers isKindOfClass:NSArray.class] || layers.count>WMEMaxLayers) { [self message:@"无法使用此模板" detail:@"模板图层数量超出编辑器限制。 "]; return; }
    __weak typeof(self) weakSelf=self;
    [self confirm:[NSString stringWithFormat:@"使用“%@”？",template[@"name"]?:@"模板"] detail:@"将替换当前所有图层（包括锁定图层）。当前设计如需保留，请先保存为我的模板。调色与相机设置不变。" action:^{
        WMEditorViewController *editor=weakSelf; NSMutableArray *copy=WMEDeepCopy(layers); if (!copy) return;
        for (NSMutableDictionary *layer in copy) layer[@"id"]=NSUUID.UUID.UUIDString;
        editor.engine.settings[@"layers"]=copy; editor.selectedID=copy.lastObject[@"id"]; [editor commit:YES];
    }];
}
- (void)chooseTemplates:(BOOL)personal {
    NSArray *templates=personal ? self.engine.settings[@"userTemplates"] : [self.engine presets];
    if (!templates.count) { [self message:@"暂无我的模板" detail:@"调整好水印后，点击“保存为我的模板”即可随时切换。 "]; return; }
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:personal?@"我的模板":@"内置预设" message:personal?@"点击模板可使用或删除。":@"切换前可先保存当前设计。" preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf=self;
    for (NSUInteger i=0;i<templates.count;i++) {
        NSDictionary *template=templates[i]; if (![template isKindOfClass:NSDictionary.class]) continue;
        [menu addAction:[UIAlertAction actionWithTitle:template[@"name"]?:@"未命名模板" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            WMEditorViewController *editor=weakSelf;
            if (!personal) { [editor applyTemplate:template]; return; }
            UIAlertController *options=[UIAlertController alertControllerWithTitle:template[@"name"] message:nil preferredStyle:UIAlertControllerStyleActionSheet];
            [options addAction:[UIAlertAction actionWithTitle:@"使用此模板" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a2) { [weakSelf applyTemplate:template]; }]];
            [options addAction:[UIAlertAction actionWithTitle:@"删除我的模板" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a2) {
                [weakSelf confirm:@"删除已保存模板？" detail:@"当前画布不受影响，此操作不能撤销。" action:^{
                    WMEditorViewController *current=weakSelf; NSMutableArray *items=[current.engine.settings[@"userTemplates"] mutableCopy];
                    if (i<items.count && [items[i] isEqual:template]) { [items removeObjectAtIndex:i]; current.engine.settings[@"userTemplates"]=items; [current commit:YES]; }
                }];
            }]]; [editor presentMenu:options];
        }]];
    } [self presentMenu:menu];
}
- (void)saveTemplate {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"保存我的模板" message:@"保存所有图层及图片引用，不改变当前相机设置。名称最多 40 字符。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder=@"例如：日常签名"; field.clearButtonMode=UITextFieldViewModeWhileEditing; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        WMEditorViewController *editor=weakSelf; NSString *name=[alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length || name.length>40) { [editor message:@"名称不合适" detail:@"请输入 1–40 个字符的模板名称。 "]; return; }
        NSMutableArray *templates=WMEDeepCopy(editor.engine.settings[@"userTemplates"]) ?: [NSMutableArray array];
        NSUInteger existing=[templates indexOfObjectPassingTest:^BOOL(NSDictionary *item,NSUInteger idx,BOOL *stop) { return [item[@"name"] isEqual:name]; }];
        if (existing==NSNotFound && templates.count>=30) { [editor message:@"模板已满" detail:@"最多保存 30 个我的模板，请先删除不再需要的模板。 "]; return; }
        NSDictionary *template=@{@"name":name,@"layers":WMEDeepCopy([editor layers])?:@[]};
        void (^save)(void)=^{
            WMEditorViewController *current=weakSelf;
            if (existing==NSNotFound) [templates addObject:template]; else templates[existing]=template;
            current.engine.settings[@"userTemplates"]=templates; [current commit:YES]; [current message:@"已保存" detail:@"可从“我的模板”随时切换，也可导出 JSON 备份。 "];
        };
        if (existing!=NSNotFound) [editor confirm:@"覆盖同名模板？" detail:@"旧模板将被当前设计替换，无法撤销。" action:save]; else save();
    }]]; [self presentViewController:alert animated:YES completion:nil];
}
- (void)exportBackup {
    if (self.importing) { [self message:@"正在导入" detail:@"请等当前导入完成后再导出。 "]; return; }
    NSError *error=nil; [self.engine save]; NSURL *url=[self.engine exportTemplate:&error];
    if (!url) { [self message:@"导出失败" detail:error.localizedDescription?:@"无法创建模板备份文件。 "]; return; }
    UIActivityViewController *activity=[[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    activity.popoverPresentationController.sourceView=self.view; activity.popoverPresentationController.sourceRect=CGRectMake(self.view.bounds.size.width/2,self.view.bounds.size.height/2,1,1);
    [self presentViewController:activity animated:YES completion:nil];
}

#pragma mark - Bounded local-file import
/// Runs on importQueue or an item-provider callback. No UIKit/engine state access.
+ (NSData *)readFileURL:(NSURL *)url maximum:(NSUInteger)maximum error:(NSError **)error {
    if (!url.isFileURL || url.path.length>4096) { if (error) *error=WMEError(@"仅支持本地文件或文件 App 提供的文件。"); return nil; }
    BOOL scope=[url startAccessingSecurityScopedResource]; __block NSData *result=nil; __block NSError *failure=nil;
    @try {
        NSFileCoordinator *coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil]; NSError *coordinateError=nil;
        [coordinator coordinateReadingItemAtURL:url options:NSFileCoordinatorReadingWithoutChanges error:&coordinateError byAccessor:^(NSURL *file) {
            NSDictionary *info=[file resourceValuesForKeys:@[NSURLIsRegularFileKey,NSURLIsSymbolicLinkKey,NSURLFileSizeKey] error:&failure];
            unsigned long long size=[info[NSURLFileSizeKey] unsignedLongLongValue];
            if (!info || ![info[NSURLIsRegularFileKey] boolValue] || [info[NSURLIsSymbolicLinkKey] boolValue] || !size || size>maximum) {
                failure=WMEError([NSString stringWithFormat:@"请选择真实、非空文件（最大 %lu MB），不支持目录或符号链接。",(unsigned long)(maximum/1024/1024)]); return;
            }
            NSFileHandle *handle=[NSFileHandle fileHandleForReadingFromURL:file error:&failure]; if (!handle) return;
            NSMutableData *buffer=[NSMutableData dataWithCapacity:(NSUInteger)MIN(size,262144)];
            @try {
                while (buffer.length<=maximum) {
                    NSUInteger remaining=maximum-buffer.length+1;
                    NSData *part=[handle readDataUpToLength:MIN((NSUInteger)65536,remaining) error:&failure];
                    if (!part || failure) break;
                    if (!part.length) { result=[buffer copy]; break; }
                    [buffer appendData:part];
                }
                if (buffer.length>maximum) failure=WMEError(@"文件超过允许大小，已停止导入。");
            } @finally { [handle closeAndReturnError:nil]; }
        }];
        if (coordinateError) failure=coordinateError;
    } @catch (NSException *exception) { failure=WMEError(@"文件读取失败，请重新从文件 App 选择。"); }
    @finally { if (scope) [url stopAccessingSecurityScopedResource]; }
    if (failure || !result.length) { if (error) *error=failure?:WMEError(@"文件为空或无法读取。"); return nil; } return result;
}
+ (NSString *)storeImageData:(NSData *)data documents:(NSURL *)documents error:(NSError **)error {
    if (!data.length || data.length>WMEMaxImageBytes) { if (error) *error=WMEError(@"图片为空或超过 20 MB。"); return nil; }
    CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)data,(__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCache:@NO});
    if (!source) { if (error) *error=WMEError(@"无法解码此图片，请使用 PNG、JPEG 或 HEIC 文件。"); return nil; }
    CFStringRef rawType=CGImageSourceGetType(source); UTType *type=rawType ? [UTType typeWithIdentifier:(__bridge NSString *)rawType] : nil;
    NSDictionary *props=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL));
    double width=[props[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue], height=[props[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];
    if (![type conformsToType:UTTypeImage] || width<1 || height<1 || width>16384 || height>16384 || width*height>60000000) {
        CFRelease(source); if (error) *error=WMEError(@"图片格式不支持或尺寸过大（最多 6000 万像素，单边不超过 16384）。"); return nil;
    }
    NSDictionary *options=@{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform:@YES,(__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize:@2048,
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately:@YES};
    CGImageRef cg=CGImageSourceCreateThumbnailAtIndex(source,0,(__bridge CFDictionaryRef)options); CFRelease(source);
    if (!cg) { if (error) *error=WMEError(@"图片解码失败，请选择其他图片。"); return nil; }
    UIImage *image=[UIImage imageWithCGImage:cg scale:1 orientation:UIImageOrientationUp]; CGImageRelease(cg);
    NSData *png=UIImagePNGRepresentation(image);
    if (!png.length || png.length>12*1024*1024) { if (error) *error=WMEError(@"图片转换后超过引擎的12 MB上限，请换用较小图片。"); return nil; }
    NSFileManager *fm=NSFileManager.defaultManager;
    NSURL *root=documents.URLByStandardizingPath.URLByResolvingSymlinksInPath;
    if (!root.isFileURL) { if (error) *error=WMEError(@"本机素材目录无效。"); return nil; }
    NSURL *assets=[root URLByAppendingPathComponent:@"assets" isDirectory:YES];
    NSDictionary *old=[assets resourceValuesForKeys:@[NSURLIsSymbolicLinkKey,NSURLIsDirectoryKey] error:nil];
    if (old && ([old[NSURLIsSymbolicLinkKey] boolValue] || ![old[NSURLIsDirectoryKey] boolValue])) { if (error) *error=WMEError(@"素材目录不安全，无法写入。"); return nil; }
    if (![fm createDirectoryAtURL:assets withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    if (![assets.URLByResolvingSymlinksInPath.path isEqualToString:assets.path]) { if (error) *error=WMEError(@"素材目录路径校验失败。"); return nil; }
    NSString *name=[[NSUUID.UUID.UUIDString lowercaseString] stringByAppendingPathExtension:@"png"];
    NSURL *destination=[assets URLByAppendingPathComponent:name isDirectory:NO];
    if (![[destination URLByDeletingLastPathComponent].path isEqual:assets.path]) { if (error) *error=WMEError(@"图片路径校验失败。"); return nil; }
    if (![png writeToURL:destination options:NSDataWritingAtomic error:error]) return nil;
    [destination setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil]; return name;
}
- (NSUInteger)beginImport {
    self.importing=YES; self.importGeneration++; self.title=@"正在导入…";
    self.navigationItem.leftBarButtonItem.enabled=NO; self.table.userInteractionEnabled=NO;
    return self.importGeneration;
}
- (void)endImport {
    self.importing=NO; self.title=@"水印工坊"; self.navigationItem.leftBarButtonItem.enabled=YES; self.table.userInteractionEnabled=YES;
}
- (void)finishImage:(NSString *)asset error:(NSError *)error documents:(NSURL *)documents generation:(NSUInteger)generation {
    NSAssert(NSThread.isMainThread,@"Image provider must hand off to main");
    if (self.closing || generation!=self.importGeneration) {
        if (asset) { NSURL *url=[[documents URLByAppendingPathComponent:@"assets" isDirectory:YES] URLByAppendingPathComponent:asset]; dispatch_async(self.importQueue, ^{ [NSFileManager.defaultManager removeItemAtURL:url error:nil]; }); } return;
    }
    [self endImport];
    if (!asset) { [self message:@"图片导入失败" detail:error.localizedDescription?:@"没有读取到有效图片，请重试。"]; return; }
    [self addType:@"image" asset:asset];
}

- (void)choosePhoto {
    if (self.importing) return;
    if ([self layers].count>=WMEMaxLayers) { [self message:@"图层已满" detail:@"请先删除部分图层再导入图片。 "]; return; }
    PHPickerConfiguration *config=[[PHPickerConfiguration alloc] init]; config.selectionLimit=1; config.filter=PHPickerFilter.imagesFilter;
    config.preferredAssetRepresentationMode=PHPickerConfigurationAssetRepresentationModeCurrent;
    PHPickerViewController *picker=[[PHPickerViewController alloc] initWithConfiguration:config]; picker.delegate=self;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self picker:picker didFinishPicking:results]; }); return; }
    [picker dismissViewControllerAnimated:YES completion:^{
        if (!results.count || self.closing) return;
        NSItemProvider *provider=results.firstObject.itemProvider; NSString *identifier=nil;
        for (NSString *candidate in provider.registeredTypeIdentifiers) {
            if ([[UTType typeWithIdentifier:candidate] conformsToType:UTTypeImage]) { identifier=candidate; break; }
        }
        if (!identifier) { [self message:@"无法导入" detail:@"此项目未提供可读取的图片文件。 "]; return; }
        NSUInteger generation=[self beginImport]; NSURL *documents=[self.engine documentsURL];
        dispatch_queue_t queue=self.importQueue; __weak typeof(self) weakSelf=self;
        // File representation avoids eagerly allocating an unbounded NSData/UIImage.
        [provider loadFileRepresentationForTypeIdentifier:identifier completionHandler:^(NSURL *url,NSError *providerError) {
            // The provider's temporary URL expires when this callback returns.
            // Complete only the bounded read here; expensive decode/re-encode is off main.
            NSError *readError=providerError;
            NSData *data=url ? [WMEditorViewController readFileURL:url maximum:WMEMaxImageBytes error:&readError] : nil;
            dispatch_async(queue, ^{
                @autoreleasepool {
                    NSError *error=readError; NSString *asset=data ? [WMEditorViewController storeImageData:data documents:documents error:&error] : nil;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        WMEditorViewController *editor=weakSelf;
                        if (editor) [editor finishImage:asset error:error documents:documents generation:generation];
                        else if (asset) dispatch_async(queue, ^{ [NSFileManager.defaultManager removeItemAtURL:[[documents URLByAppendingPathComponent:@"assets"] URLByAppendingPathComponent:asset] error:nil]; });
                    });
                }
            });
        }];
    }];
}
- (void)chooseDocument:(BOOL)backup {
    if (self.importing) { [self message:@"正在导入" detail:@"请等当前导入完成后再选择其他文件。 "]; return; }
    if (!backup && [self layers].count>=WMEMaxLayers) { [self message:@"图层已满" detail:@"请先删除部分图层再导入图片。 "]; return; }
    if (backup) {
        __weak typeof(self) weakSelf=self;
        [self confirm:@"导入模板备份？" detail:@"导入成功后将由引擎替换模板相关状态。请先导出当前设计以便恢复。只接受 JSON，不解压 ZIP。" action:^{ [weakSelf presentDocument:YES]; }];
    } else [self presentDocument:NO];
}
- (void)presentDocument:(BOOL)backup {
    self.documentIsBackup=backup;
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:backup?@[UTTypeJSON]:@[UTTypeImage] asCopy:NO];
    picker.allowsMultipleSelection=NO; picker.delegate=self; [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { self.documentIsBackup=NO; }
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self documentPicker:controller didPickDocumentsAtURLs:urls]; }); return; }
    if (!urls.count || self.closing) return;
    NSURL *url=urls.firstObject; BOOL backup=self.documentIsBackup;
    if (backup && ![url.pathExtension.lowercaseString isEqual:@"json"]) { [self message:@"格式不支持" detail:@"模板备份必须是 .json 文件。 "]; return; }
    NSUInteger generation=[self beginImport]; NSURL *documents=[self.engine documentsURL];
    dispatch_queue_t queue=self.importQueue; __weak typeof(self) weakSelf=self;
    dispatch_async(queue, ^{
        @autoreleasepool {
            NSError *error=nil; NSData *data=[WMEditorViewController readFileURL:url maximum:backup?WMEMaxBackupBytes:WMEMaxImageBytes error:&error];
            NSString *asset=nil; NSURL *staged=nil;
            if (data && backup) {
                id json=[NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
                if (![json isKindOfClass:NSDictionary.class]) error=WMEError(@"备份内容必须是合法的 JSON 对象。");
                if (!error) {
                    NSString *name=[NSString stringWithFormat:@"markcam-editor-%@.json",NSUUID.UUID.UUIDString];
                    staged=[[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:name];
                    if (![data writeToURL:staged options:NSDataWritingAtomic error:&error]) staged=nil;
                }
            } else if (data) asset=[WMEditorViewController storeImageData:data documents:documents error:&error];
            dispatch_async(dispatch_get_main_queue(), ^{
                WMEditorViewController *editor=weakSelf;
                if (!backup) {
                    if (editor) [editor finishImage:asset error:error documents:documents generation:generation];
                    else if (asset) dispatch_async(queue, ^{ [NSFileManager.defaultManager removeItemAtURL:[[documents URLByAppendingPathComponent:@"assets"] URLByAppendingPathComponent:asset] error:nil]; });
                    return;
                }
                if (!editor || editor.closing || generation!=editor.importGeneration) {
                    if (staged) dispatch_async(queue, ^{ [NSFileManager.defaultManager removeItemAtURL:staged error:nil]; }); return;
                }
                // WMEngine owns schema, embedded-asset/path validation and atomic import.
                NSError *importError=error; BOOL success=staged ? [editor.engine importTemplateURL:staged error:&importError] : NO;
                if (staged) dispatch_async(queue, ^{ [NSFileManager.defaultManager removeItemAtURL:staged error:nil]; });
                [editor endImport];
                if (success) { editor.selectedID=[editor layers].lastObject[@"id"]; [editor commit:YES]; [editor message:@"导入完成" detail:@"模板已保存到本机。 "]; }
                else [editor message:@"模板导入失败" detail:importError.localizedDescription?:@"备份不符合印记相机模板格式。 "];
            });
        }
    });
}
@end
