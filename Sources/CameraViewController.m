#import "CameraViewController.h"
#import "WMEngine.h"
#import "WMEditorViewController.h"
#import "MCPreviewView.h"
#import "MCCameraLayout.h"
#import "MCZoomMath.h"
#import "MCProcessingQueue.h"
#import "MCPhotoCaptureProcessor.h"
#import "MCWorkPolicy.h"
#import <os/proc.h>
#import <mach/mach.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <CoreImage/CoreImage.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static UIColor *MCAccent(void){return [UIColor colorWithRed:.48 green:.92 blue:.78 alpha:1];}
static NSString *MCID(void){return [NSString stringWithFormat:@"%013lld-%@",(long long)(NSDate.date.timeIntervalSince1970*1000),NSUUID.UUID.UUIDString];}
@interface MCGridView:UIView
@property(nonatomic) BOOL grid;
@end
@implementation MCGridView
- (void)drawRect:(CGRect)rect {if(!self.grid)return;CGContextRef c=UIGraphicsGetCurrentContext();CGContextSetStrokeColorWithColor(c,[UIColor colorWithWhite:1 alpha:.25].CGColor);CGContextSetLineWidth(c,.5);for(int i=1;i<3;i++){CGFloat x=rect.size.width*i/3.,y=rect.size.height*i/3.;CGContextMoveToPoint(c,x,0);CGContextAddLineToPoint(c,x,rect.size.height);CGContextMoveToPoint(c,0,y);CGContextAddLineToPoint(c,rect.size.width,y);}CGContextStrokePath(c);}
@end
@interface CameraViewController ()<AVCaptureVideoDataOutputSampleBufferDelegate,AVCaptureFileOutputRecordingDelegate,UIGestureRecognizerDelegate>
@property(nonatomic,strong) AVCaptureSession *session;
@property(nonatomic,strong) AVCaptureDeviceInput *cameraInput;
@property(nonatomic,strong) AVCaptureDeviceInput *audioInput;
@property(nonatomic,strong) AVCapturePhotoOutput *photoOutput;
@property(nonatomic,strong) AVCaptureMovieFileOutput *movieOutput;
@property(nonatomic,strong) AVCaptureVideoDataOutput *videoOutput;
@property(nonatomic,strong) AVCaptureVideoPreviewLayer *nativePreview;
@property(atomic) BOOL nativeVideoPreview;
@property(nonatomic,strong) dispatch_queue_t sessionQueue;
@property(nonatomic,strong) dispatch_queue_t framesQueue;
@property(nonatomic,strong) dispatch_queue_t renderQueue;
@property(nonatomic,strong) dispatch_queue_t overlayQueue;
@property(nonatomic,strong) MCPreviewView *preview;
@property(nonatomic,strong) UILabel *previewHint;
@property(nonatomic,strong) UISegmentedControl *lensSelector;
@property(nonatomic,copy) NSArray<NSNumber *> *lensFactors;
@property(nonatomic) BOOL gpuFailed;
@property(nonatomic) BOOL overlayPending;
@property(nonatomic) NSUInteger overlayRevision;
@property(nonatomic,strong) NSDictionary *overlayKey;
@property(atomic) BOOL previewGeometryPending;
@property(atomic) double expectedAspect;
@property(atomic) BOOL zoomPending;
@property(atomic) CGFloat requestedZoom;
@property(nonatomic) CGFloat wideReference;
@property(nonatomic) CGFloat rememberedBackZoom;
@property(nonatomic,strong) UIImageView *overlay;
@property(nonatomic,strong) MCGridView *gridView;
@property(nonatomic,strong) UIView *stage;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UILabel *titleLabel;
@property(nonatomic,strong) UILabel *recordLabel;
@property(nonatomic,strong) UILabel *countdownLabel;
@property(nonatomic,strong) UIButton *shutter;
@property(nonatomic,strong) UIButton *switchButton;
@property(nonatomic,strong) UIButton *editButton;
@property(nonatomic,strong) UIButton *filesButton;
@property(nonatomic,strong) UIButton *watermarkButton;
@property(nonatomic,strong) UIButton *settingsButton;
@property(nonatomic,strong) UIButton *liveButton;
@property(nonatomic,strong) UISlider *zoomSlider;
@property(nonatomic,strong) UILabel *zoomLabel;
@property(nonatomic,strong) MCProcessingQueue *workQueue;
@property(nonatomic) UIBackgroundTaskIdentifier captureBackgroundTask;
@property(nonatomic) BOOL captureLeaseActive;
// Main-thread ownership keeps overlapping delegates alive through disk completion.
@property(nonatomic,strong) NSMutableDictionary<NSString *,MCPhotoCaptureProcessor *> *photoCaptures;
@property(nonatomic,copy) NSString *shutterCaptureID;
@property(nonatomic,copy) NSString *captureBlockMessage;
@property(nonatomic) BOOL sessionRefreshPending;
@property(nonatomic) BOOL memoryPreviewFallback;
@property(atomic) BOOL liveSupported;
@property(nonatomic,strong) UISegmentedControl *mode;
@property(nonatomic,strong) UIProgressView *progress;
@property(nonatomic,strong) UIButton *cancelExportButton;
@property(nonatomic,strong) NSTimer *clockTimer;
@property(nonatomic,strong) NSDate *recordDate;
@property(atomic,copy) NSDictionary *activeSettings;
@property(nonatomic,copy) NSDictionary *captureSettings;
@property(nonatomic,strong) NSDate *captureDate;
@property(atomic) BOOL configured;
@property(nonatomic) BOOL wantsVideo;
@property(nonatomic) BOOL busy;
@property(atomic) BOOL inBackground;
@property(atomic) BOOL applicationInactive;
@property(nonatomic) NSUInteger statusGeneration;
@property(atomic) BOOL editorShown;
@property(nonatomic) BOOL recording;
@property(nonatomic) NSInteger countdown;
@property(nonatomic) NSInteger countdownGeneration;
@property(nonatomic) CGFloat zoomStart;
@property(nonatomic) CGSize feedSize;
@property(nonatomic) CGSize lastOverlaySize;
@property(atomic) AVCaptureVideoOrientation captureOrientation;
@property(nonatomic,strong) NSURL *currentRawURL;
@property(nonatomic,strong) NSURL *activeMetaURL;
@end

@implementation CameraViewController
- (void)viewDidLoad {
 [super viewDidLoad];self.view.backgroundColor=[UIColor colorWithRed:.045 green:.065 blue:.068 alpha:1];self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
 self.sessionQueue=dispatch_queue_create("markcam.capture",DISPATCH_QUEUE_SERIAL);self.framesQueue=dispatch_queue_create("markcam.frames",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));self.renderQueue=dispatch_queue_create("markcam.render",DISPATCH_QUEUE_SERIAL);self.overlayQueue=dispatch_queue_create("markcam.overlay",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0));self.session=[AVCaptureSession new];self.captureOrientation=AVCaptureVideoOrientationPortrait;self.wideReference=1;self.rememberedBackZoom=1;
 self.photoCaptures=[NSMutableDictionary new];
 self.workQueue=[MCProcessingQueue new];self.workQueue.foreground=YES;__weak typeof(self) queueOwner=self;self.workQueue.onChange=^{[queueOwner queueChanged];};[self.workQueue refresh];
 self.activeSettings=[[WMEngine shared] snapshot];self.feedSize=CGSizeMake(3,4);[self makeUI];[self refreshSettings];
 NSNotificationCenter *nc=NSNotificationCenter.defaultCenter;
 [nc addObserver:self selector:@selector(willResignActive:) name:UIApplicationWillResignActiveNotification object:nil];[nc addObserver:self selector:@selector(didBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
 [nc addObserver:self selector:@selector(background:) name:UIApplicationDidEnterBackgroundNotification object:nil];[nc addObserver:self selector:@selector(foreground:) name:UIApplicationWillEnterForegroundNotification object:nil];
 [nc addObserver:self selector:@selector(interrupted:) name:AVCaptureSessionWasInterruptedNotification object:self.session];[nc addObserver:self selector:@selector(interruptionEnded:) name:AVCaptureSessionInterruptionEndedNotification object:self.session];[nc addObserver:self selector:@selector(runtimeError:) name:AVCaptureSessionRuntimeErrorNotification object:self.session];
 self.clockTimer=[NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick) userInfo:nil repeats:YES];[self requestCamera];
}
- (UIButton *)button:(NSString *)title action:(SEL)action {
 UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem];[b setTitle:title forState:UIControlStateNormal];[b setTitleColor:MCAccent() forState:UIControlStateNormal];b.titleLabel.font=[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];b.backgroundColor=[UIColor colorWithWhite:1 alpha:.065];b.layer.cornerRadius=12;[b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:b];return b;
}
- (void)makeUI {
 self.titleLabel=[UILabel new];self.titleLabel.text=@"印记相机  /  MARK";self.titleLabel.font=[UIFont systemFontOfSize:21 weight:UIFontWeightBold];self.titleLabel.textColor=UIColor.whiteColor;[self.view addSubview:self.titleLabel];
 self.watermarkButton=[self button:@"水印开启" action:@selector(toggleWatermark)];
 self.liveButton=[self button:@"LIVE 关" action:@selector(toggleLive)];self.liveButton.accessibilityLabel=@"实况照片开关";
 self.settingsButton=[self button:@"设置" action:@selector(openSettings)];self.settingsButton.accessibilityLabel=@"打开相机设置，曝光和实况照片";
 self.stage=[UIView new];self.stage.backgroundColor=UIColor.blackColor;self.stage.clipsToBounds=YES;[self.view addSubview:self.stage];
 self.preview=[[MCPreviewView alloc]initWithFrame:CGRectZero];[self.stage addSubview:self.preview];__weak typeof(self) weak=self;self.preview.onFailure=^(NSString *reason){weak.gpuFailed=YES;[weak updatePreviewRoute];[weak status:@"已切换系统流畅取景，调色仍应用到成片"];};
 self.nativePreview=[AVCaptureVideoPreviewLayer layerWithSession:self.session];self.nativePreview.videoGravity=AVLayerVideoGravityResizeAspect;[self.stage.layer insertSublayer:self.nativePreview atIndex:0];
 self.previewHint=[UILabel new];self.previewHint.textColor=[UIColor colorWithWhite:1 alpha:.85];self.previewHint.font=[UIFont systemFontOfSize:11 weight:UIFontWeightMedium];self.previewHint.textAlignment=NSTextAlignmentCenter;self.previewHint.backgroundColor=[UIColor colorWithWhite:0 alpha:.3];self.previewHint.layer.cornerRadius=8;self.previewHint.clipsToBounds=YES;[self.stage addSubview:self.previewHint];
 self.overlay=[UIImageView new];self.overlay.contentMode=UIViewContentModeScaleToFill;self.overlay.userInteractionEnabled=NO;[self.stage addSubview:self.overlay];
 self.gridView=[MCGridView new];self.gridView.backgroundColor=UIColor.clearColor;self.gridView.userInteractionEnabled=NO;[self.stage addSubview:self.gridView];
 self.zoomSlider=[UISlider new];self.zoomSlider.minimumValue=1;self.zoomSlider.maximumValue=8;self.zoomSlider.value=1;self.zoomSlider.tintColor=MCAccent();self.zoomSlider.accessibilityLabel=@"相机缩放倍率";[self.zoomSlider addTarget:self action:@selector(zoomSliderChanged:) forControlEvents:UIControlEventValueChanged];[self.stage addSubview:self.zoomSlider];
 self.zoomLabel=[UILabel new];self.zoomLabel.text=@"1.0×";self.zoomLabel.textColor=UIColor.whiteColor;self.zoomLabel.font=[UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];[self.stage addSubview:self.zoomLabel];
 self.lensSelector=[[UISegmentedControl alloc]initWithItems:@[@"1×",@"2×"]];self.lensFactors=@[@1,@2];self.lensSelector.selectedSegmentIndex=0;self.lensSelector.backgroundColor=[UIColor colorWithWhite:0 alpha:.55];self.lensSelector.selectedSegmentTintColor=[UIColor colorWithWhite:1 alpha:.18];[self.lensSelector setTitleTextAttributes:@{NSForegroundColorAttributeName:UIColor.whiteColor} forState:UIControlStateNormal];[self.lensSelector setTitleTextAttributes:@{NSForegroundColorAttributeName:UIColor.systemYellowColor} forState:UIControlStateSelected];[self.lensSelector addTarget:self action:@selector(lensChanged:) forControlEvents:UIControlEventValueChanged];self.lensSelector.accessibilityLabel=@"后置镜头与快捷缩放";[self.stage addSubview:self.lensSelector];
 UITapGestureRecognizer *tap=[[UITapGestureRecognizer alloc]initWithTarget:self action:@selector(focus:)];tap.delegate=self;[self.stage addGestureRecognizer:tap];UIPinchGestureRecognizer *pinch=[[UIPinchGestureRecognizer alloc]initWithTarget:self action:@selector(zoom:)];pinch.delegate=self;[self.stage addGestureRecognizer:pinch];
 self.recordLabel=[UILabel new];self.recordLabel.textColor=UIColor.systemRedColor;self.recordLabel.font=[UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];self.recordLabel.textAlignment=NSTextAlignmentCenter;[self.stage addSubview:self.recordLabel];
 self.countdownLabel=[UILabel new];self.countdownLabel.font=[UIFont systemFontOfSize:68 weight:UIFontWeightLight];self.countdownLabel.textColor=UIColor.whiteColor;self.countdownLabel.textAlignment=NSTextAlignmentCenter;[self.stage addSubview:self.countdownLabel];
 self.statusLabel=[UILabel new];self.statusLabel.numberOfLines=2;self.statusLabel.textAlignment=NSTextAlignmentCenter;self.statusLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightMedium];self.statusLabel.textColor=[UIColor colorWithWhite:.72 alpha:1];[self.view addSubview:self.statusLabel];
 self.progress=[UIProgressView new];self.progress.progressTintColor=MCAccent();self.progress.hidden=YES;[self.view addSubview:self.progress];
 self.cancelExportButton=[self button:@"取消合成" action:@selector(cancelExport)];self.cancelExportButton.hidden=YES;
 self.mode=[[UISegmentedControl alloc]initWithItems:@[@"照片",@"视频"]];self.mode.selectedSegmentIndex=0;self.mode.selectedSegmentTintColor=MCAccent();[self.mode setTitleTextAttributes:@{NSForegroundColorAttributeName:UIColor.blackColor} forState:UIControlStateSelected];[self.mode addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];[self.view addSubview:self.mode];
 self.shutter=[self button:@"" action:@selector(capturePressed)];self.shutter.backgroundColor=UIColor.whiteColor;self.shutter.layer.borderColor=[UIColor colorWithWhite:1 alpha:.35].CGColor;self.shutter.layer.borderWidth=5;
 self.filesButton=[self button:@"待保存" action:@selector(showFiles)];self.switchButton=[self button:@"翻转" action:@selector(switchCamera)];self.editButton=[self button:@"水印 · 模板 · 调色" action:@selector(openEditor)];
 self.filesButton.accessibilityLabel=@"待保存作品与失败重试";self.shutter.accessibilityLabel=@"拍照";self.stage.accessibilityLabel=@"相机取景，轻点对焦，双指变焦";
}
- (void)viewDidLayoutSubviews {
 [super viewDidLayoutSubviews];UIEdgeInsets s=self.view.safeAreaInsets;CGFloat w=self.view.bounds.size.width,h=self.view.bounds.size.height;
 MCCameraLayout a=MCLayout(w,h,s.top,s.bottom,s.left,s.right,self.feedSize.width/MAX(1,self.feedSize.height));
 #define BOX(r) CGRectMake((r).x,(r).y,(r).w,(r).h)
 [CATransaction begin];[CATransaction setDisableActions:YES];
 self.stage.frame=BOX(a.stage);self.preview.frame=self.stage.bounds;self.nativePreview.frame=self.stage.bounds;self.overlay.frame=self.stage.bounds;self.gridView.frame=self.stage.bounds;[self.gridView setNeedsDisplay];
 self.mode.frame=BOX(a.mode);self.shutter.frame=BOX(a.shutter);self.filesButton.frame=BOX(a.files);self.switchButton.frame=BOX(a.flip);self.editButton.frame=BOX(a.edit);
 self.watermarkButton.frame=BOX(a.watermark);self.liveButton.frame=BOX(a.live);self.settingsButton.frame=BOX(a.settings);self.previewHint.frame=BOX(a.hint);self.titleLabel.hidden=YES;
 self.zoomLabel.frame=BOX(a.zoomLabel);self.zoomSlider.frame=BOX(a.zoomSlider);self.lensSelector.frame=BOX(a.lenses);
 self.statusLabel.frame=BOX(a.status);self.statusLabel.backgroundColor=[UIColor colorWithWhite:0 alpha:.38];self.statusLabel.layer.cornerRadius=7;self.statusLabel.clipsToBounds=YES;
 self.shutter.layer.cornerRadius=a.shutter.w/2;self.recordLabel.frame=CGRectMake(0,80,a.stage.w,24);self.countdownLabel.frame=self.stage.bounds;
 self.progress.frame=CGRectMake(a.stage.x+12,a.stage.y+a.stage.h-3,MAX(1,a.stage.w-24),2);self.cancelExportButton.frame=CGRectMake(a.stage.x+a.stage.w-114,a.status.y-46,102,40);
 [self.editButton setTitle:w>h?@"水印 · 调色":@"水印 · 模板 · 调色" forState:UIControlStateNormal];self.editButton.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
 for(UIView *v in @[self.mode,self.shutter,self.filesButton,self.switchButton,self.editButton,self.watermarkButton,self.liveButton,self.settingsButton,self.progress,self.cancelExportButton,self.statusLabel])[self.view bringSubviewToFront:v];
 [self.stage bringSubviewToFront:self.previewHint];[CATransaction commit];
 #undef BOX
 CGSize os=self.stage.bounds.size;if(!CGSizeEqualToSize(os,self.lastOverlaySize)){self.lastOverlaySize=os;[self invalidateOverlay];}
}
- (AVCaptureVideoOrientation)orientation {
 UIInterfaceOrientation o=self.view.window.windowScene.interfaceOrientation;
 switch(o){case UIInterfaceOrientationLandscapeLeft:return AVCaptureVideoOrientationLandscapeLeft;case UIInterfaceOrientationLandscapeRight:return AVCaptureVideoOrientationLandscapeRight;case UIInterfaceOrientationPortraitUpsideDown:return AVCaptureVideoOrientationPortraitUpsideDown;default:return AVCaptureVideoOrientationPortrait;}
}
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)c {
 self.preview.renderingEnabled=NO;[self.preview reset];
 [super viewWillTransitionToSize:size withTransitionCoordinator:c];[c animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context){[self.view setNeedsLayout];} completion:^(id<UIViewControllerTransitionCoordinatorContext> context){if(!self.busy&&!self.recording&&!self.photoCaptures.count){self.captureOrientation=[self orientation];dispatch_async(self.sessionQueue,^{[self applyConnections];});}}];
}
- (void)status:(NSString *)s {dispatch_async(dispatch_get_main_queue(),^{self.statusLabel.text=s;self.statusLabel.alpha=1;NSUInteger generation=++self.statusGeneration;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(generation==self.statusGeneration&&!self.busy&&!self.recording&&!self.captureBlockMessage.length)[UIView animateWithDuration:.2 animations:^{self.statusLabel.alpha=0;}];});});}
- (void)alert:(NSString *)title message:(NSString *)message {
 dispatch_async(dispatch_get_main_queue(),^{if(self.inBackground){[self status:message];return;}UIViewController *vc=self;while(vc.presentedViewController)vc=vc.presentedViewController;UIAlertController *a=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];[vc presentViewController:a animated:YES completion:nil];});
}
- (void)permissionAlert:(NSString *)message {
 UIAlertController *a=[UIAlertController alertControllerWithTitle:@"需要授权" message:message preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"暂不" style:UIAlertActionStyleCancel handler:nil]];[a addAction:[UIAlertAction actionWithTitle:@"打开设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[UIApplication.sharedApplication openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{} completionHandler:nil];}]];[self presentViewController:a animated:YES completion:nil];
}
- (void)requestCamera {
 AVAuthorizationStatus st=[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];if(st==AVAuthorizationStatusAuthorized){[self configure];return;}if(st==AVAuthorizationStatusNotDetermined){[AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL ok){dispatch_async(dispatch_get_main_queue(),^{if(ok)[self configure];else{[self status:@"相机未授权；仍可编辑水印模板"];[self permissionAlert:@"拍摄需要相机权限，可在系统设置中开启。"];}});}];}else{[self status:@"相机权限未开启"];[self permissionAlert:@"拍摄需要相机权限，可在系统设置中开启。"];}
}
- (AVCaptureDevice *)deviceForPosition:(AVCaptureDevicePosition)p {
 NSArray *types=p==AVCaptureDevicePositionBack?@[AVCaptureDeviceTypeBuiltInTripleCamera,AVCaptureDeviceTypeBuiltInDualWideCamera,AVCaptureDeviceTypeBuiltInDualCamera,AVCaptureDeviceTypeBuiltInWideAngleCamera]:@[AVCaptureDeviceTypeBuiltInWideAngleCamera];
 for(AVCaptureDeviceType type in types){AVCaptureDevice *d=[AVCaptureDevice defaultDeviceWithDeviceType:type mediaType:AVMediaTypeVideo position:p];if(d)return d;}return nil;
}
- (CGFloat)wideReferenceForDevice:(AVCaptureDevice *)device {
 NSArray *parts=device.constituentDevices,*factors=device.virtualDeviceSwitchOverVideoZoomFactors;
 for(NSUInteger i=0;i<parts.count;i++)if([((AVCaptureDevice *)parts[i]).deviceType isEqual:AVCaptureDeviceTypeBuiltInWideAngleCamera]){
  if(i>0&&i-1<factors.count){double f=[factors[i-1]doubleValue];return isfinite(f)&&f>=1?f:1;}return 1;
 }
 return 1;
}
- (BOOL)applyDisplayZoom:(CGFloat)display error:(NSError **)error {
 AVCaptureDevice *d=self.cameraInput.device;if(!d)return NO;
 if(![d lockForConfiguration:error])return NO;
 @try{d.videoZoomFactor=MCZoomHardware(display,[self wideReferenceForDevice:d],d.minAvailableVideoZoomFactor,d.maxAvailableVideoZoomFactor);return YES;}
 @catch(NSException *exception){if(error)*error=[NSError errorWithDomain:@"MarkCam.Zoom" code:1 userInfo:@{NSLocalizedDescriptionKey:exception.reason?:@"镜头倍率不可用"}];return NO;}
 @finally{[d unlockForConfiguration];}
}
- (void)configureZoomForCurrentDevice:(CGFloat)display {
 self.wideReference=[self wideReferenceForDevice:self.cameraInput.device];NSError *error=nil;
 if(![self applyDisplayZoom:display error:&error])[self status:@"无法设置当前倍率，已保留镜头原倍率"];
 [self refreshZoomUI];
}
- (void)configure {
 dispatch_async(self.sessionQueue,^{if(self.configured){if(!self.inBackground&&!self.editorShown)[self.session startRunning];return;}NSError *e=nil;AVCaptureDevice *d=[self deviceForPosition:AVCaptureDevicePositionBack];AVCaptureDeviceInput *i=[AVCaptureDeviceInput deviceInputWithDevice:d error:&e];if(!i||![self.session canAddInput:i]){[self status:e.localizedDescription?:@"无法打开相机"];return;}[self.session beginConfiguration];self.session.sessionPreset=AVCaptureSessionPresetPhoto;[self.session addInput:i];self.cameraInput=i;
 self.photoOutput=[AVCapturePhotoOutput new];self.photoOutput.maxPhotoQualityPrioritization=AVCapturePhotoQualityPrioritizationBalanced;
 if([self.session canAddOutput:self.photoOutput])[self.session addOutput:self.photoOutput];
 self.videoOutput=[AVCaptureVideoDataOutput new];self.videoOutput.alwaysDiscardsLateVideoFrames=YES;self.videoOutput.automaticallyConfiguresOutputBufferDimensions=NO;self.videoOutput.deliversPreviewSizedOutputBuffers=YES;
 NSArray *formats=self.videoOutput.availableVideoCVPixelFormatTypes;NSNumber *format=[formats containsObject:@(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)]?@(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange):([formats containsObject:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)]?@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange):@(kCVPixelFormatType_32BGRA));self.videoOutput.videoSettings=@{(NSString *)kCVPixelBufferPixelFormatTypeKey:format};[self.videoOutput setSampleBufferDelegate:self queue:self.framesQueue];if([self.session canAddOutput:self.videoOutput])[self.session addOutput:self.videoOutput];
 self.nativeVideoPreview=![self.session.outputs containsObject:self.videoOutput];
 self.movieOutput=[AVCaptureMovieFileOutput new];self.movieOutput.maxRecordedDuration=CMTimeMake(300,1);self.movieOutput.minFreeDiskSpaceLimit=150*1024*1024;
 [self configureLiveMode];[self configurePhotoResolution];[self applyConnections];[self.session commitConfiguration];[self configureZoomForCurrentDevice:1];self.configured=YES;if(!self.inBackground&&!self.editorShown)[self.session startRunning];[self status:@"照片模式 · 轻点对焦 / 双指变焦"];dispatch_async(dispatch_get_main_queue(),^{[self updateControls];});});
}
- (BOOL)ensureAudioInput {
 if([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]!=AVAuthorizationStatusAuthorized)return NO;
 if(!self.audioInput){AVCaptureDevice *device=[AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];NSError *error=nil;if(device)self.audioInput=[AVCaptureDeviceInput deviceInputWithDevice:device error:&error];}
 if(self.audioInput&&![self.session.inputs containsObject:self.audioInput]&&[self.session canAddInput:self.audioInput])[self.session addInput:self.audioInput];
 return self.audioInput&&[self.session.inputs containsObject:self.audioInput];
}
// Invoke inside begin/commitConfiguration, on sessionQueue, never during capture.
- (void)configurePhotoResolution {
 if(![self.session.outputs containsObject:self.photoOutput])return;
 CMVideoDimensions best={0,0},small={0,0};int64_t area=0,smallArea=INT64_MAX;
 for(NSValue *value in self.cameraInput.device.activeFormat.supportedMaxPhotoDimensions){CMVideoDimensions size={0,0};[value getValue:&size size:sizeof(size)];int64_t pixels=(int64_t)size.width*size.height;if(pixels>0&&pixels<smallArea){small=size;smallArea=pixels;}if(pixels>area&&pixels<=13000000){area=pixels;best=size;}}
 if(!area)best=small;
 if(best.width>0&&best.height>0){@try{CMVideoDimensions now=self.photoOutput.maxPhotoDimensions;if(now.width!=best.width||now.height!=best.height)self.photoOutput.maxPhotoDimensions=best;}@catch(NSException *e){[self status:@"已保留系统默认照片尺寸"];}}
}
- (void)configureLiveMode {
 BOOL photoMode=[self.session.outputs containsObject:self.photoOutput];self.liveSupported=photoMode&&self.photoOutput.isLivePhotoCaptureSupported;
 if(self.liveSupported){BOOL wanted=[self.activeSettings[@"livePhotoEnabled"]boolValue];
 @try {
 if(wanted&&!self.photoOutput.isLivePhotoCaptureEnabled)self.photoOutput.livePhotoCaptureEnabled=YES;
 if(self.photoOutput.isLivePhotoCaptureEnabled){self.photoOutput.preservesLivePhotoCaptureSuspendedOnSessionStop=YES;
 if(self.photoOutput.isLivePhotoCaptureSuspended==wanted)self.photoOutput.livePhotoCaptureSuspended=!wanted;}
 if(wanted)[self ensureAudioInput];else if(self.audioInput&&[self.session.inputs containsObject:self.audioInput])[self.session removeInput:self.audioInput];
 } @catch(NSException *exception){self.liveSupported=NO;[self status:@"当前配置无法启用 Live Photo，请关闭 LIVE 使用普通照片"];}
 }else if(photoMode&&self.audioInput&&[self.session.inputs containsObject:self.audioInput]){[self.session removeInput:self.audioInput];}
 dispatch_async(dispatch_get_main_queue(),^{[self refreshLiveUI];});
}
- (void)refreshLiveUI {
 BOOL on=[self.activeSettings[@"livePhotoEnabled"]boolValue];NSString *title=on?@"LIVE 开":@"LIVE 关";
 if(!self.liveSupported&&!self.wantsVideo&&self.configured)title=@"LIVE 不支持";
 [self.liveButton setTitle:title forState:UIControlStateNormal];[self.liveButton setTitleColor:on?UIColor.systemYellowColor:MCAccent() forState:UIControlStateNormal];
 self.liveButton.enabled=self.configured&&!self.busy&&!self.recording&&!self.photoCaptures.count&&!self.wantsVideo;self.liveButton.alpha=self.liveButton.enabled?1:.4;
}
- (void)toggleLive {
 if(self.busy||self.recording||self.photoCaptures.count||self.wantsVideo)return;BOOL on=[self.activeSettings[@"livePhotoEnabled"]boolValue];
 if(on){WMEngine.shared.settings[@"livePhotoEnabled"]=@NO;[WMEngine.shared save];[self refreshSettings];return;}
 if(!self.liveSupported){[self alert:@"当前模式不支持实况" message:@"请尝试切换摄像头。普通照片仍可正常拍摄。"];return;}
 if(self.liveSupported&&self.liveButton.isEnabled&&![self.activeSettings[@"livePhotoEnabled"]boolValue]){[self authorizeLive:^{WMEngine.shared.settings[@"livePhotoEnabled"]=@YES;[WMEngine.shared save];[self refreshSettings];[self status:@"LIVE 已开启 · 拍摄前后请保持手机稳定"]; }];}
}
- (void)authorizeLive:(void (^)(void))completion {
 AVAuthorizationStatus status=[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
 if(status==AVAuthorizationStatusAuthorized){completion();return;}
 if(status!=AVAuthorizationStatusNotDetermined){[self permissionAlert:@"有声 Live Photo 需要麦克风权限；也可关闭 LIVE 拍摄普通照片。"];return;}
 self.busy=YES;[self updateControls];[AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL ok){dispatch_async(dispatch_get_main_queue(),^{self.busy=NO;[self updateControls];if(ok&&!self.inBackground)completion();else if(!ok)[self permissionAlert:@"未开启麦克风权限，不能拍摄有声 Live Photo。可关闭 LIVE 使用普通照片。"];});}];
}
- (void)applyConnections {
 [self applyExposureSettings];
 BOOL mirror=self.cameraInput.device.position==AVCaptureDevicePositionFront&&[self.activeSettings[@"mirrorFront"] boolValue];
 for(AVCaptureOutput *out in self.session.outputs){AVCaptureConnection *c=[out connectionWithMediaType:AVMediaTypeVideo];if(c.isVideoOrientationSupported)c.videoOrientation=self.captureOrientation;if(c.isVideoMirroringSupported){c.automaticallyAdjustsVideoMirroring=NO;c.videoMirrored=mirror;}}
 AVCaptureVideoOrientation orientation=self.captureOrientation;BOOL video=[self.session.outputs containsObject:self.movieOutput];
 dispatch_async(dispatch_get_main_queue(),^{[CATransaction begin];[CATransaction setDisableActions:YES];AVCaptureConnection *previewConnection=self.nativePreview.connection;if(previewConnection.isVideoOrientationSupported&&previewConnection.videoOrientation!=orientation)previewConnection.videoOrientation=orientation;if(previewConnection.isVideoMirroringSupported){previewConnection.automaticallyAdjustsVideoMirroring=NO;previewConnection.videoMirrored=mirror;}[CATransaction commit];
 BOOL portrait=orientation==AVCaptureVideoOrientationPortrait||orientation==AVCaptureVideoOrientationPortraitUpsideDown;self.feedSize=video?(portrait?CGSizeMake(9,16):CGSizeMake(16,9)):(portrait?CGSizeMake(3,4):CGSizeMake(4,3));self.expectedAspect=self.feedSize.width/self.feedSize.height;[self.view setNeedsLayout];[self updatePreviewRoute];});
}
- (void)modeChanged {
 if(self.busy||self.recording||self.photoCaptures.count){self.mode.selectedSegmentIndex=self.wantsVideo?1:0;return;}BOOL video=self.mode.selectedSegmentIndex==1;if(video){AVAuthorizationStatus s=[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];if(s==AVAuthorizationStatusNotDetermined){[AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL ok){dispatch_async(dispatch_get_main_queue(),^{if(ok)[self setVideoMode:YES];else{self.mode.selectedSegmentIndex=0;[self permissionAlert:@"有声录像需要麦克风权限。照片拍摄不受影响。"];}});}];return;}if(s!=AVAuthorizationStatusAuthorized){self.mode.selectedSegmentIndex=0;[self permissionAlert:@"有声录像需要麦克风权限，请先开启后再录制。"];return;}}[self setVideoMode:video];
}
- (void)setVideoMode:(BOOL)video {
 self.busy=YES;[self updateControls];dispatch_async(self.sessionQueue,^{
 if(!self.configured){dispatch_async(dispatch_get_main_queue(),^{self.busy=NO;self.mode.selectedSegmentIndex=0;[self updateControls];});return;}
 CGFloat priorZoom=MCZoomDisplay(self.cameraInput.device.videoZoomFactor,[self wideReferenceForDevice:self.cameraInput.device]);
 [self.session beginConfiguration];BOOL success=YES;
 if(video){if([self.session.outputs containsObject:self.photoOutput])[self.session removeOutput:self.photoOutput];if([self.session canSetSessionPreset:AVCaptureSessionPreset1920x1080])self.session.sessionPreset=AVCaptureSessionPreset1920x1080;else self.session.sessionPreset=AVCaptureSessionPresetHigh;
 if(!self.audioInput){NSError *err=nil;AVCaptureDevice *audio=[AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];if(audio)self.audioInput=[AVCaptureDeviceInput deviceInputWithDevice:audio error:&err];}
 if(self.audioInput&&![self.session.inputs containsObject:self.audioInput]&&[self.session canAddInput:self.audioInput])[self.session addInput:self.audioInput];
 if([self.session canAddOutput:self.movieOutput])[self.session addOutput:self.movieOutput];if(![self.session.outputs containsObject:self.movieOutput]){if([self.session.outputs containsObject:self.videoOutput])[self.session removeOutput:self.videoOutput];if([self.session canAddOutput:self.movieOutput])[self.session addOutput:self.movieOutput];}success=[self.session.outputs containsObject:self.movieOutput]&&self.audioInput&&[self.session.inputs containsObject:self.audioInput];
 }else{[self.session removeOutput:self.movieOutput];if(self.audioInput&&[self.session.inputs containsObject:self.audioInput])[self.session removeInput:self.audioInput];self.session.sessionPreset=AVCaptureSessionPresetPhoto;if([self.session canAddOutput:self.photoOutput])[self.session addOutput:self.photoOutput];}
 if(!success){[self.session removeOutput:self.movieOutput];if(self.audioInput&&[self.session.inputs containsObject:self.audioInput])[self.session removeInput:self.audioInput];self.session.sessionPreset=AVCaptureSessionPresetPhoto;if([self.session canAddOutput:self.photoOutput])[self.session addOutput:self.photoOutput];}
 if(!video||!success){if(![self.session.outputs containsObject:self.videoOutput]&&[self.session canAddOutput:self.videoOutput])[self.session addOutput:self.videoOutput];}self.nativeVideoPreview=![self.session.outputs containsObject:self.videoOutput];
 [self configureLiveMode];[self configurePhotoResolution];[self applyConnections];[self.session commitConfiguration];[self configureZoomForCurrentDevice:priorZoom];if(video&&success){AVCaptureDevice *d=self.cameraInput.device;NSError *err=nil;if([d lockForConfiguration:&err]){for(AVFrameRateRange *r in d.activeFormat.videoSupportedFrameRateRanges){if(r.minFrameRate<=30&&r.maxFrameRate>=30){d.activeVideoMinFrameDuration=CMTimeMake(1,30);d.activeVideoMaxFrameDuration=CMTimeMake(1,30);break;}}[d unlockForConfiguration];}}
 dispatch_async(dispatch_get_main_queue(),^{self.wantsVideo=video&&success;[self updatePreviewRoute];self.mode.selectedSegmentIndex=self.wantsVideo?1:0;self.busy=NO;[self updateControls];[self status:success?(video?(self.nativeVideoPreview?@"录像兼容模式 · 水印可见，调色在成片应用":@"1080p · 有声录像 · 单段最长 5 分钟"):@"照片模式 · 原生高画质"):@"当前设备无法启用有声录像"];});});
}
- (void)switchCamera {
 if(self.busy||self.recording||self.photoCaptures.count||!self.configured)return;self.busy=YES;[self updateControls];dispatch_async(self.sessionQueue,^{AVCaptureDevicePosition p=self.cameraInput.device.position==AVCaptureDevicePositionBack?AVCaptureDevicePositionFront:AVCaptureDevicePositionBack;NSError *e=nil;AVCaptureDevice *d=[self deviceForPosition:p];AVCaptureDeviceInput *i=d?[AVCaptureDeviceInput deviceInputWithDevice:d error:&e]:nil;if(i){[self.session beginConfiguration];AVCaptureDeviceInput *old=self.cameraInput;if(old.device.position==AVCaptureDevicePositionBack)self.rememberedBackZoom=MCZoomDisplay(old.device.videoZoomFactor,[self wideReferenceForDevice:old.device]);[self.session removeInput:old];if([self.session canAddInput:i]){[self.session addInput:i];self.cameraInput=i;}else[self.session addInput:old];[self configureLiveMode];[self configurePhotoResolution];[self applyConnections];[self.session commitConfiguration];if(self.cameraInput==i)[self configureZoomForCurrentDevice:p==AVCaptureDevicePositionBack?self.rememberedBackZoom:1];}dispatch_async(dispatch_get_main_queue(),^{self.busy=NO;[self updateControls];if(e)[self alert:@"切换失败" message:e.localizedDescription];});});
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
 UIView *view=touch.view;while(view&&view!=self.stage){if([view isKindOfClass:UIControl.class])return NO;view=view.superview;}return YES;
}
- (void)focus:(UITapGestureRecognizer *)g {
 if(self.busy||self.recording||self.photoCaptures.count||!self.configured)return;CGPoint pt=[g locationInView:self.stage];CGPoint p=[self.nativePreview captureDevicePointOfInterestForPoint:pt];
 UIView *ring=[[UIView alloc]initWithFrame:CGRectMake(pt.x-25,pt.y-25,50,50)];ring.layer.borderColor=MCAccent().CGColor;ring.layer.borderWidth=1.3;ring.layer.cornerRadius=10;[self.stage addSubview:ring];[UIView animateWithDuration:.7 delay:.5 options:0 animations:^{ring.alpha=0;} completion:^(BOOL f){[ring removeFromSuperview];}];
 dispatch_async(self.sessionQueue,^{AVCaptureDevice *d=self.cameraInput.device;NSError *e=nil;if([d lockForConfiguration:&e]){if(d.focusPointOfInterestSupported&&[d isFocusModeSupported:AVCaptureFocusModeAutoFocus]){d.focusPointOfInterest=p;d.focusMode=AVCaptureFocusModeAutoFocus;}if(d.exposurePointOfInterestSupported&&[d isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]){d.exposurePointOfInterest=p;d.exposureMode=AVCaptureExposureModeContinuousAutoExposure;}[d unlockForConfiguration];}});
}
- (void)showZoom:(CGFloat)zoom {
 self.zoomSlider.value=zoom;self.zoomLabel.text=[NSString stringWithFormat:@"%.1f×",zoom];self.zoomSlider.accessibilityValue=self.zoomLabel.text;
 self.lensSelector.selectedSegmentIndex=UISegmentedControlNoSegment;for(NSUInteger i=0;i<self.lensFactors.count;i++)if(fabs(self.lensFactors[i].doubleValue-zoom)<.055){self.lensSelector.selectedSegmentIndex=i;break;}
}
- (void)refreshZoomUI {
 dispatch_async(self.sessionQueue,^{AVCaptureDevice *d=self.cameraInput.device;if(!d)return;CGFloat ref=[self wideReferenceForDevice:d],lo=MCZoomDisplay(d.minAvailableVideoZoomFactor,ref),hi=MAX(lo,MIN(8,MCZoomDisplay(d.maxAvailableVideoZoomFactor,ref))),z=MCZoomDisplay(d.videoZoomFactor,ref);
 NSMutableArray<NSNumber *> *values=[NSMutableArray new];BOOL ultra=NO;for(AVCaptureDevice *part in d.constituentDevices)if([part.deviceType isEqual:AVCaptureDeviceTypeBuiltInUltraWideCamera])ultra=YES;
 if(ultra&&lo<.9)[values addObject:@(lo)];if(lo<=1&&hi>=1)[values addObject:@1];if(lo<=2&&hi>=2)[values addObject:@2];
 for(NSNumber *factor in d.virtualDeviceSwitchOverVideoZoomFactors){double v=MCZoomDisplay(factor.doubleValue,ref);BOOL duplicate=NO;for(NSNumber *n in values)if(fabs(n.doubleValue-v)<.05)duplicate=YES;if(!duplicate&&v>2.1&&v<=hi&&values.count<4)[values addObject:@(v)];}if(!values.count)[values addObject:@(lo)];
 dispatch_async(dispatch_get_main_queue(),^{self.zoomSlider.minimumValue=lo;self.zoomSlider.maximumValue=hi;
 if(![self.lensFactors isEqual:values]){self.lensFactors=values;[self.lensSelector removeAllSegments];for(NSUInteger i=0;i<values.count;i++){double value=values[i].doubleValue;NSString *title=fabs(value-round(value))<.05?[NSString stringWithFormat:@"%.0f×",value]:[NSString stringWithFormat:@"%.1f×",value];[self.lensSelector insertSegmentWithTitle:title atIndex:i animated:NO];}[self.view setNeedsLayout];}
 if(!self.zoomPending)[self showZoom:MAX(lo,MIN(hi,z))];});});
}
- (void)drainZoom {
 dispatch_async(self.sessionQueue,^{CGFloat display=self.requestedZoom;NSError *error=nil;
 BOOL applied=[self applyDisplayZoom:display error:&error];
 dispatch_async(dispatch_get_main_queue(),^{if(applied&&fabs(self.requestedZoom-display)>.001&&!self.busy&&!self.recording){[self drainZoom];return;}self.zoomPending=NO;[self refreshZoomUI];if(error)[self status:@"当前镜头倍率不可用，请重试"];});});
}
- (void)setZoomFactor:(CGFloat)factor {
 if(self.busy||self.recording||!self.configured||!isfinite(factor))return;self.requestedZoom=MAX(self.zoomSlider.minimumValue,MIN(self.zoomSlider.maximumValue,factor));[self showZoom:self.requestedZoom];
 if(self.zoomPending)return;self.zoomPending=YES;[self drainZoom];
}
- (void)lensChanged:(UISegmentedControl *)control {NSInteger i=control.selectedSegmentIndex;if(i>=0&&i<(NSInteger)self.lensFactors.count)[self setZoomFactor:self.lensFactors[i].doubleValue];}
- (void)zoomSliderChanged:(UISlider *)slider { [self setZoomFactor:slider.value]; }
- (void)zoom:(UIPinchGestureRecognizer *)g {
 if(self.busy||self.recording||self.photoCaptures.count)return;if(g.state==UIGestureRecognizerStateBegan)self.zoomStart=self.zoomSlider.value;[self setZoomFactor:self.zoomStart*g.scale];
}
- (void)applyExposureSettings {
 AVCaptureDevice *d=self.cameraInput.device;id raw=self.activeSettings[@"exposureBias"];float value=[raw isKindOfClass:NSNumber.class]?[raw floatValue]:0;if(!isfinite(value))value=0;value=MAX(-2,MIN(2,value));NSError *e=nil;if(d&&[d lockForConfiguration:&e]){float target=MAX(d.minExposureTargetBias,MIN(d.maxExposureTargetBias,value));if(fabs(d.exposureTargetBias-target)>.01)[d setExposureTargetBias:target completionHandler:nil];[d unlockForConfiguration];}
}
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
 @autoreleasepool{
 if(self.inBackground||self.editorShown)return;CVPixelBufferRef pixel=CMSampleBufferGetImageBuffer(sampleBuffer);if(!pixel)return;
 // No 20fps gate, no per-frame UIImage/CGImage conversion, no per-frame main dispatch.
 double width=CVPixelBufferGetWidth(pixel),height=CVPixelBufferGetHeight(pixel),aspect=width/MAX(1,height);
 if(fabs(self.expectedAspect-aspect)>.005&&!self.previewGeometryPending){self.previewGeometryPending=YES;AVCaptureVideoOrientation orientation=connection.videoOrientation;
 dispatch_async(dispatch_get_main_queue(),^{self.previewGeometryPending=NO;if(orientation!=self.captureOrientation)return;self.expectedAspect=aspect;self.feedSize=CGSizeMake(width,height);[self.view setNeedsLayout];});}
 [self.preview submitPixelBuffer:pixel];
 }
}
- (BOOL)toneIsActive {
 NSDictionary *tone=self.activeSettings[@"tone"];
 return fabs([tone[@"brightness"]doubleValue])>.001||fabs(tone[@"contrast"]?[tone[@"contrast"]doubleValue]-1:0)>.001||fabs(tone[@"saturation"]?[tone[@"saturation"]doubleValue]-1:0)>.001||fabs([tone[@"warmth"]doubleValue])>.001;
}
- (void)updatePreviewRoute {
 BOOL toned=[self toneIsActive];BOOL gpu=toned&&!self.workQueue.processing&&!self.memoryPreviewFallback&&![self.activeSettings[@"smoothPreview"]boolValue]&&self.preview.available&&!self.gpuFailed&&!self.nativeVideoPreview;
 BOOL active=!self.inBackground&&!self.applicationInactive&&!self.editorShown;
 if(self.preview.renderingEnabled!=(gpu&&active)){[self.preview reset];self.preview.renderingEnabled=gpu&&active;}
 self.preview.settings=self.activeSettings;self.preview.hidden=!gpu;
 // Keep the system preview connected underneath, including focus coordinate mapping.
 self.nativePreview.hidden=NO;
 self.previewHint.text=gpu?@"GPU 实时调色":(toned?@"流畅取景 · 调色在成片应用":@"系统流畅取景");
}
- (void)refreshSettings {
 NSDictionary *old=self.activeSettings;self.activeSettings=[[WMEngine shared]snapshot];self.gridView.grid=[self.activeSettings[@"gridEnabled"]boolValue];[self.gridView setNeedsDisplay];[self.watermarkButton setTitle:[self.activeSettings[@"watermarkEnabled"]boolValue]?@"水印开":@"水印关" forState:UIControlStateNormal];[self invalidateOverlay];[self refreshLiveUI];[self updatePreviewRoute];
 if(!self.configured||self.editorShown)return;
 BOOL liveChanged=[old[@"livePhotoEnabled"]boolValue]!=[self.activeSettings[@"livePhotoEnabled"]boolValue];
 BOOL connectionsChanged=!old||[old[@"mirrorFront"]boolValue]!=[self.activeSettings[@"mirrorFront"]boolValue]||[old[@"exposureBias"]doubleValue]!=[self.activeSettings[@"exposureBias"]doubleValue];
 if((liveChanged||connectionsChanged)&&self.photoCaptures.count){self.sessionRefreshPending=YES;return;}
 if(liveChanged||connectionsChanged)dispatch_async(self.sessionQueue,^{if(liveChanged)[self.session beginConfiguration];if(liveChanged)[self configureLiveMode];[self applyConnections];if(liveChanged)[self.session commitConfiguration];});
}
- (void)invalidateOverlay {self.overlayRevision++;[self updateOverlay];}
- (void)updateOverlay {
 if(self.inBackground||self.editorShown)return;CGSize s=self.stage.bounds.size;if(s.width<1||s.height<1)return;
 NSDictionary *settings=self.recording?self.captureSettings:self.activeSettings;NSDate *date=self.recording?self.recordDate:NSDate.date;
 if(![settings[@"watermarkEnabled"]boolValue]){self.overlay.image=nil;self.overlayKey=nil;return;}
 if(self.overlayPending)return;
 CGFloat z=MIN(2,1024./MAX(s.width,s.height));s=CGSizeMake(round(s.width*z),round(s.height*z));NSString *clock=@"static";
 for(NSDictionary *layer in settings[@"layers"]){NSString *text=layer[@"text"];if([text containsString:@"{time}"]){clock=[NSString stringWithFormat:@"%.0f",floor(date.timeIntervalSince1970)];break;}if([text containsString:@"{date}"]){NSDateComponents *c=[NSCalendar.currentCalendar components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay fromDate:date];clock=[NSString stringWithFormat:@"%ld-%ld-%ld",(long)c.year,(long)c.month,(long)c.day];}}
 NSDictionary *key=@{@"revision":@(self.overlayRevision),@"size":NSStringFromCGSize(s),@"clock":clock};if([key isEqual:self.overlayKey])return;
 self.overlayPending=YES;NSUInteger revision=self.overlayRevision;
 dispatch_async(self.overlayQueue,^{@autoreleasepool{UIImage *image=[[WMEngine shared]overlayForSize:s settings:settings date:date];dispatch_async(dispatch_get_main_queue(),^{self.overlayPending=NO;if(revision!=self.overlayRevision){[self updateOverlay];return;}if(!self.inBackground&&!self.editorShown){self.overlay.image=image;self.overlayKey=key;}});}});
}
- (void)toggleWatermark {if(self.busy||self.recording||self.photoCaptures.count)return;WMEngine *e=WMEngine.shared;e.settings[@"watermarkEnabled"]=@(![e.settings[@"watermarkEnabled"]boolValue]);[e save];[self refreshSettings];}
- (void)openSettings { [self presentEditorAtSettings:YES]; }
- (void)openEditor { [self presentEditorAtSettings:NO]; }
- (void)presentEditorAtSettings:(BOOL)settings {
 if(self.busy||self.recording||self.photoCaptures.count)return;self.busy=YES;[self updateControls];__weak typeof(self) weak=self;
 [self.preview requestSnapshot:^(UIImage *image){CameraViewController *camera=weak;if(!camera)return;camera.busy=NO;if(camera.inBackground){[camera updateControls];return;}camera.editorShown=YES;[camera updatePreviewRoute];dispatch_async(camera.sessionQueue,^{[camera.session stopRunning];});
 WMEditorViewController *e=[WMEditorViewController new];e.opensSettings=settings;e.backgroundImage=image;e.onChange=^{[weak refreshSettings];};UINavigationController *nav=[[UINavigationController alloc]initWithRootViewController:e];nav.modalPresentationStyle=UIModalPresentationFullScreen;[camera presentViewController:nav animated:YES completion:nil];[camera updateControls];}];
}
- (void)viewDidAppear:(BOOL)animated {[super viewDidAppear:animated];if(self.editorShown&&!self.presentedViewController){self.editorShown=NO;self.gpuFailed=NO;[self refreshSettings];[self updateControls];[self resumeCameraSession];}}
- (void)updateControls {
 BOOL locked=self.busy||self.recording||self.photoCaptures.count>0;self.workQueue.captureBusy=locked||self.editorShown;self.zoomSlider.enabled=!locked&&self.configured;self.lensSelector.enabled=!locked&&self.configured;self.settingsButton.enabled=!locked;[self refreshLiveUI];if(!locked)[self refreshZoomUI];self.mode.enabled=!locked;self.switchButton.enabled=!locked&&self.configured;self.editButton.enabled=!locked;self.filesButton.enabled=!locked;self.watermarkButton.enabled=!locked;self.shutter.enabled=self.configured&&(!self.busy||self.recording)&&!self.inBackground&&!self.editorShown&&!self.applicationInactive;
 self.shutter.backgroundColor=self.wantsVideo?UIColor.systemRedColor:UIColor.whiteColor;[self.shutter setTitle:self.recording?@"■":@"" forState:UIControlStateNormal];[self.shutter setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];self.shutter.accessibilityLabel=self.recording?@"停止录像":(self.wantsVideo?@"开始录像":@"拍照");UIApplication.sharedApplication.idleTimerDisabled=self.busy||self.recording;[self queueChanged];
}
- (NSURL *)pendingDirectory {
 NSURL *u=[[WMEngine.shared documentsURL]URLByAppendingPathComponent:@"Pending" isDirectory:YES];[NSFileManager.defaultManager createDirectoryAtURL:u withIntermediateDirectories:YES attributes:nil error:nil];return u;
}
- (NSURL *)fileForJob:(NSDictionary *)job key:(NSString *)key {
 if(![job isKindOfClass:NSDictionary.class])return nil;NSString *name=job[key];if(![name isKindOfClass:NSString.class]||name.length==0||name.length>150||[name hasPrefix:@"."]||![name.lastPathComponent isEqualToString:name]||![@[@"jpg",@"mp4",@"mov"] containsObject:name.pathExtension.lowercaseString])return nil;NSURL *base=[self pendingDirectory];NSURL *file=[base URLByAppendingPathComponent:name];if(![file.URLByResolvingSymlinksInPath.path hasPrefix:[base.URLByResolvingSymlinksInPath.path stringByAppendingString:@"/"]])return nil;return file;
}
- (BOOL)writeJob:(NSDictionary *)job URL:(NSURL *)url {
 NSError *e=nil;NSData *data=[NSJSONSerialization dataWithJSONObject:job options:NSJSONWritingPrettyPrinted error:&e];BOOL ok=data&&[data writeToURL:url options:NSDataWritingAtomic error:&e];if(!ok)[self status:e.localizedDescription?:@"无法保存恢复信息"];return ok;
}
- (BOOL)hasLiveCapture {
 for(MCPhotoCaptureProcessor *capture in self.photoCaptures.allValues)if(capture.live)return YES;return NO;
}
- (BOOL)requestsLive {return !self.wantsVideo&&[self.activeSettings[@"livePhotoEnabled"]boolValue];}
- (NSString *)captureAdmissionReason {
 if(self.sessionRefreshPending)return @"正在恢复相机，拍摄完成后自动开放快门";
 BOOL live=[self requestsLive];
 if(self.wantsVideo&&self.photoCaptures.count)return @"照片正在暂存，稍后可开始录像";
 if(!self.wantsVideo&&!MCCanAcceptPhotoRequest((unsigned)self.photoCaptures.count,live,[self hasLiveCapture]))return @"正在接收照片，快门将自动恢复";
 if(self.wantsVideo&&self.workQueue.processing)return @"正在处理作品，稍后可开始录像";
 return [self.workQueue captureBlockReasonForLive:live reservedCount:self.photoCaptures.count];
}
- (void)capturePressed {
 if(self.recording){[self status:@"正在结束录像…"];self.shutter.enabled=NO;dispatch_async(self.sessionQueue,^{[self.movieOutput stopRecording];});return;}
 if(self.busy||!self.configured||self.inBackground||self.applicationInactive||self.editorShown)return;
 if(!self.session.running){[self alert:@"相机尚未就绪" message:@"请返回前台，或重新打开相机权限。"];return;}
 NSString *reason=[self captureAdmissionReason];if(reason){[self status:reason];return;}
 PHAuthorizationStatus photos=[PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];if(photos==PHAuthorizationStatusNotDetermined){[self authorizeQueue];return;}
 if([self requestsLive]&&[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]!=AVAuthorizationStatusAuthorized){[self authorizeLive:^{[self refreshSettings];[self status:@"麦克风已开启，取景稳定后再次按快门拍摄 LIVE"]; }];return;}
 NSInteger delay=[self.activeSettings[@"timerSeconds"]integerValue];
 if(delay>0){self.busy=YES;self.countdown=MIN(delay,10);NSInteger generation=++self.countdownGeneration;[self updateControls];[self countdownStep:generation];}else [self startCapture];
}
- (void)countdownStep:(NSInteger)generation {
 if(generation!=self.countdownGeneration||self.inBackground)return;if(self.countdown<=0){self.countdownLabel.text=@"";self.busy=NO;[self startCapture];return;}self.countdownLabel.text=[NSString stringWithFormat:@"%ld",(long)self.countdown--];dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{[self countdownStep:generation];});
}
- (void)startCapture {
 NSString *reason=[self captureAdmissionReason];
 if(self.inBackground||self.applicationInactive||self.editorShown||reason){self.busy=NO;[self updateControls];if(reason)[self status:reason];return;}
 if(!self.captureLeaseActive){self.captureBackgroundTask=[UIApplication.sharedApplication beginBackgroundTaskWithName:@"Save capture to disk" expirationHandler:^{[self endCaptureLease];}];self.captureLeaseActive=self.captureBackgroundTask!=UIBackgroundTaskInvalid;}
 NSDictionary *settings=[[WMEngine shared]snapshot];NSDate *date=NSDate.date;
 self.captureOrientation=[self orientation];self.busy=YES;
 if(self.wantsVideo){
  self.captureSettings=settings;self.captureDate=date;
  NSString *ident=MCID();self.currentRawURL=[[self pendingDirectory]URLByAppendingPathComponent:[ident stringByAppendingString:@"-raw.mov"]];self.activeMetaURL=[[self pendingDirectory]URLByAppendingPathComponent:[ident stringByAppendingString:@".job.json"]];
  NSMutableDictionary *job=[@{@"kind":@"video",@"stage":@"capturing",@"source":self.currentRawURL.lastPathComponent,@"output":[ident stringByAppendingString:@".mp4"],@"settings":settings,@"date":@(date.timeIntervalSince1970)}mutableCopy];
  if(![self writeJob:job URL:self.activeMetaURL]){self.busy=NO;[self endCaptureLease];[self updateControls];return;}
  self.recordDate=date;[self updateControls];[self status:@"正在启动录制…"];
  dispatch_async(self.sessionQueue,^{
   @try {
    if(self.inBackground||!self.session.running)@throw [NSException exceptionWithName:@"MarkCamVideoUnavailable" reason:@"相机暂未就绪" userInfo:nil];
    [self applyConnections];AVCaptureDevice *device=self.cameraInput.device;NSError *error=nil;
    if(device.hasTorch&&[device lockForConfiguration:&error]){device.torchMode=[settings[@"flashMode"]integerValue]==2?AVCaptureTorchModeOn:AVCaptureTorchModeOff;[device unlockForConfiguration];}
    [self.movieOutput startRecordingToOutputFileURL:self.currentRawURL recordingDelegate:self];
   }@catch(NSException *exception){
    NSError *error=[NSError errorWithDomain:@"MarkCam.Capture" code:4 userInfo:@{NSLocalizedDescriptionKey:exception.reason?:@"录像请求失败"}];
    [self captureOutput:self.movieOutput didFinishRecordingToOutputFileAtURL:self.currentRawURL fromConnections:@[] error:error];
   }
  });
 }else{
  MCPhotoCaptureProcessor *capture=[[MCPhotoCaptureProcessor alloc]initWithSettings:settings date:date live:[self requestsLive] diskQueue:self.renderQueue];
  self.photoCaptures[capture.identifier]=capture;self.shutterCaptureID=capture.identifier;
  __weak typeof(self) owner=self;
  capture.onExposureFinished=^(MCPhotoCaptureProcessor *shot){
   CameraViewController *camera=owner;if(!camera||shot.live)return;
   if([camera.shutterCaptureID isEqual:shot.identifier]){camera.shutterCaptureID=nil;camera.busy=NO;[camera updateControls];}
  };
  capture.onCompletion=^(MCPhotoCaptureProcessor *shot,NSDictionary *job,NSURL *meta,NSError *error){[owner finishedPhotoCapture:shot job:job meta:meta error:error];};
  [self updateControls];[self status:capture.live?@"正在拍摄实况 · 请保持稳定":@"正在拍摄…"];
  dispatch_async(self.sessionQueue,^{[self submitPhotoRequest:capture];});
 }
}
- (void)recordCaptureError:(NSError *)error {
 NSDictionary *detail=@{@"appVersion":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]?:@"",@"osVersion":UIDevice.currentDevice.systemVersion?:@"",@"time":@(NSDate.date.timeIntervalSince1970),@"stage":@"photo-request",@"message":error.localizedDescription?:@"未知错误"};
 dispatch_async(self.renderQueue,^{NSData *data=[NSJSONSerialization dataWithJSONObject:detail options:NSJSONWritingPrettyPrinted error:nil];[data writeToURL:[WMEngine.shared.documentsURL URLByAppendingPathComponent:@"LastCaptureError.json"] options:NSDataWritingAtomic error:nil];});
}
- (void)submitPhotoRequest:(MCPhotoCaptureProcessor *)capture {
 // sessionQueue owns native configuration; each delegate owns only its own shot.
 @try {
  NSString *reason=nil;
  if(self.inBackground||self.editorShown||!self.session.isRunning||![self.session.outputs containsObject:self.photoOutput])reason=@"相机暂未就绪，请返回取景画面后重试。";
  AVCaptureConnection *connection=[self.photoOutput connectionWithMediaType:AVMediaTypeVideo];
  if(!reason&&(!connection||!connection.isEnabled||!connection.isActive))reason=@"照片输出暂未连接，请等待取景恢复后重试。";
  if(!reason&&![self.photoOutput.availablePhotoCodecTypes containsObject:AVVideoCodecTypeJPEG])reason=@"当前相机未提供 JPEG 拍照格式。";
  if(!reason&&capture.live&&(!self.photoOutput.isLivePhotoCaptureSupported||!self.photoOutput.isLivePhotoCaptureEnabled||self.photoOutput.isLivePhotoCaptureSuspended))reason=@"当前相机尚不能拍摄 Live Photo，请等待取景稳定或关闭 LIVE。";
  if(!reason&&capture.live&&(!self.audioInput||![self.session.inputs containsObject:self.audioInput]))reason=@"Live Photo 音频输入尚未就绪，请关闭再开启 LIVE 后重试。";
  if(reason){[capture rejectRequest:[NSError errorWithDomain:@"MarkCam.Capture" code:1 userInfo:@{NSLocalizedDescriptionKey:reason}]];return;}
  // Do not relock exposure/reconfigure the preview on every shutter press.
  if(connection.isVideoOrientationSupported&&connection.videoOrientation!=self.captureOrientation)connection.videoOrientation=self.captureOrientation;
  AVCapturePhotoSettings *p=[AVCapturePhotoSettings photoSettingsWithFormat:@{AVVideoCodecKey:AVVideoCodecTypeJPEG}];
  CMVideoDimensions dimensions=self.photoOutput.maxPhotoDimensions;if(dimensions.width>0&&dimensions.height>0)p.maxPhotoDimensions=dimensions;
  // Ordinary bursts favor responsiveness without changing the configured dimensions.
  p.photoQualityPrioritization=MIN((!capture.live&&[capture.settings[@"fastCapture"]boolValue])?AVCapturePhotoQualityPrioritizationSpeed:AVCapturePhotoQualityPrioritizationBalanced,self.photoOutput.maxPhotoQualityPrioritization);
  NSInteger flash=[capture.settings[@"flashMode"]integerValue];AVCaptureFlashMode mode=flash==1?AVCaptureFlashModeAuto:flash==2?AVCaptureFlashModeOn:AVCaptureFlashModeOff;
  if([self.photoOutput.supportedFlashModes containsObject:@(mode)])p.flashMode=mode;
  NSError *error=nil;if(![capture prepare:&error]){[capture rejectRequest:error];return;}
  if(capture.live){p.livePhotoMovieFileURL=capture.movieURL;if([self.photoOutput.availableLivePhotoVideoCodecTypes containsObject:AVVideoCodecTypeH264])p.livePhotoVideoCodecType=AVVideoCodecTypeH264;}
  [self.photoOutput capturePhotoWithSettings:p delegate:capture];
 }@catch(NSException *exception){[capture rejectRequest:[NSError errorWithDomain:@"MarkCam.Capture" code:1 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"%@：%@",exception.name,exception.reason?:@"系统拒绝了拍照请求"]}]];}
}
- (void)finishedPhotoCapture:(MCPhotoCaptureProcessor *)capture job:(NSDictionary *)job meta:(NSURL *)meta error:(NSError *)error {
 [self.photoCaptures removeObjectForKey:capture.identifier];
 if([self.shutterCaptureID isEqual:capture.identifier]){self.shutterCaptureID=nil;self.busy=NO;}
 if(!self.photoCaptures.count)[self endCaptureLease];
 if(job&&meta){[self.workQueue didCapture];[self status:@"原片已暂存 ✓ 可继续拍摄"];}
 else { [self.workQueue refresh];if(error){[self recordCaptureError:error];[self alert:@"拍摄未完整完成" message:error.localizedDescription];} }
 if(!self.photoCaptures.count&&self.sessionRefreshPending)[self resumeCameraSession];
 [self updateControls];
}
- (void)captureOutput:(AVCaptureFileOutput *)output didStartRecordingToOutputFileAtURL:(NSURL *)url fromConnections:(NSArray<AVCaptureConnection *> *)connections {
 dispatch_async(dispatch_get_main_queue(),^{self.recording=YES;self.recordDate=self.captureDate;[self updateControls];[self invalidateOverlay];[self status:@"录制中 · 点击停止后自动合成"];if(self.inBackground)[self.movieOutput stopRecording];});
}
- (void)captureOutput:(AVCaptureFileOutput *)output didFinishRecordingToOutputFileAtURL:(NSURL *)url fromConnections:(NSArray<AVCaptureConnection *> *)connections error:(NSError *)error {
 dispatch_async(self.sessionQueue,^{AVCaptureDevice *d=self.cameraInput.device;NSError *e=nil;if(d.hasTorch&&[d lockForConfiguration:&e]){d.torchMode=AVCaptureTorchModeOff;[d unlockForConfiguration];}});
 dispatch_async(dispatch_get_main_queue(),^{self.recording=NO;self.recordLabel.text=@"";[self updateControls];NSData *d=[NSData dataWithContentsOfURL:self.activeMetaURL];NSMutableDictionary *job=d?[[NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil]mutableCopy]:nil;
 BOOL success=!error||[error.userInfo[AVErrorRecordingSuccessfullyFinishedKey]boolValue];NSNumber *size=nil;[url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];if(!success||size.longLongValue<1024||!job){if(job){job[@"stage"]=@"incomplete";[self writeJob:job URL:self.activeMetaURL];}self.busy=NO;[self endCaptureLease];[self updateControls];[self alert:@"录像未正常完成" message:[NSString stringWithFormat:@"%@\n已保留可用的临时文件，可在“待保存”中重试或导出。",error.localizedDescription?:@"数据不完整"]];return;}
 job[@"stage"]=@"raw";BOOL logged=[self writeJob:job URL:self.activeMetaURL];[self finishedCaptureJob:logged?job:nil meta:logged?self.activeMetaURL:nil error:logged?nil:[NSError errorWithDomain:@"MarkCam.Capture" code:2 userInfo:@{NSLocalizedDescriptionKey:@"无法更新录像恢复记录，原片已保留"}]];});
}
- (void)authorizeQueue {
 [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status){dispatch_async(dispatch_get_main_queue(),^{if(status==PHAuthorizationStatusAuthorized||status==PHAuthorizationStatusLimited){self.workQueue.manuallyPaused=NO;[self.workQueue resumeAfterPhotoAuthorization];[self status:@"相册已授权，等待保存的作品将继续处理"]; }else [self permissionAlert:@"需要添加照片权限。原片和成片都会保留，不会因拒绝而删除。"];});}];
}
- (void)queueChanged {
 NSUInteger count=self.workQueue.pendingCount;
 [self.filesButton setTitle:count?[NSString stringWithFormat:@"待处理 %lu",(unsigned long)count]:@"待保存" forState:UIControlStateNormal];
 self.filesButton.accessibilityValue=self.workQueue.summary;self.progress.hidden=!self.workQueue.processing;self.progress.progress=self.workQueue.progress;self.cancelExportButton.hidden=!self.workQueue.processing;
 [self.cancelExportButton setTitle:@"暂停合成" forState:UIControlStateNormal];
 if(!self.busy&&!self.recording){
  NSString *reason=[self captureAdmissionReason];
  self.shutter.enabled=self.configured&&!self.inBackground&&!self.applicationInactive&&!self.editorShown&&!reason;
  if(![self.captureBlockMessage isEqualToString:reason]&&(self.captureBlockMessage||reason)){self.captureBlockMessage=reason;if(reason)[self status:reason];else if(self.configured)[self status:@"快门已就绪，可继续拍摄"];}
 }
 self.shutter.alpha=self.shutter.enabled?1:.45;
 [self updatePreviewRoute];
}
- (void)processJob:(NSMutableDictionary *)job meta:(NSURL *)meta {
 if([job[@"stage"]isEqual:@"saving"]){UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"上次相册保存结果待确认" message:@"请先检查系统相册，避免同一张照片重复保存。只有确定没有保存成功时才重试。" preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"先检查相册" style:UIAlertActionStyleCancel handler:nil]];[alert addAction:[UIAlertAction actionWithTitle:@"确定未保存，重试" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){[self.workQueue retry:meta];}]];[self presentViewController:alert animated:YES completion:nil];return;}
 [self.workQueue retry:meta];[self status:@"已请求重试，快门不用等待合成"];
}
- (void)cleanupJob:(NSDictionary *)job meta:(NSURL *)meta {
 if([self.workQueue isActive:meta]){[self alert:@"正在处理此作品" message:@"请先暂停合成，待任务停止后再删除。"];return;}
 [MCProcessingQueue cleanupJob:job meta:meta];[self.workQueue refresh];
}
- (void)cancelExport { [self.workQueue pause];[self status:@"合成已暂停，原片仍保留"]; }
- (void)endCaptureLease {
 if(!self.captureLeaseActive)return;self.captureLeaseActive=NO;[UIApplication.sharedApplication endBackgroundTask:self.captureBackgroundTask];
}
- (void)finishedCaptureJob:(NSDictionary *)job meta:(NSURL *)meta error:(NSError *)error {
 // This runs only after the final native capture callback AND serial disk writes.
 self.busy=NO;self.recordLabel.text=@"";self.captureSettings=nil;self.activeMetaURL=nil;self.currentRawURL=nil;[self endCaptureLease];
 if(job&&meta){[self.workQueue didCapture];[self status:@"原片已暂存 ✓ 可继续拍，稍后自动合成"];}
 else if(error)[self alert:@"拍摄未完整完成" message:error.localizedDescription];
 [self updateControls];
}
- (void)didReceiveMemoryWarning {
 [super didReceiveMemoryWarning];self.memoryPreviewFallback=YES;[self.workQueue memoryPressure];[self.preview clearCaches];[WMEngine.shared clearCaches];self.overlay.image=nil;self.overlayKey=nil;[self updatePreviewRoute];[self writeMemoryDiagnostic:@"memory-warning"];[self status:@"内存压力：已暂停合成并改用系统取景"]; 
}
- (void)writeMemoryDiagnostic:(NSString *)event {
 task_vm_info_data_t info={0};mach_msg_type_number_t count=TASK_VM_INFO_COUNT;uint64_t footprint=0;
 if(task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&info,&count)==KERN_SUCCESS)footprint=info.phys_footprint;
 NSDictionary *record=@{@"event":event,@"time":@(NSDate.date.timeIntervalSince1970),@"appFootprintBytes":@(footprint),@"processAvailableBytes":@(os_proc_available_memory()),@"queued":@(self.workQueue.pendingCount),@"processing":@(self.workQueue.processing),@"thermalState":@(NSProcessInfo.processInfo.thermalState),@"note":@"Local app metrics only; not proof that this app caused another process termination."};
 dispatch_async(self.renderQueue,^{NSData *data=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:nil];[data writeToURL:[WMEngine.shared.documentsURL URLByAppendingPathComponent:@"LastMemoryStatus.json"] options:NSDataWritingAtomic error:nil];});
}
- (void)anchor:(UIViewController *)vc button:(UIView *)b {if(vc.popoverPresentationController){vc.popoverPresentationController.sourceView=b;vc.popoverPresentationController.sourceRect=b.bounds;}}
- (NSMutableDictionary *)readJobForDisplay:(NSURL *)meta {
 NSNumber *size=nil;[meta getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
 if(!size||size.unsignedLongLongValue>4*1024*1024)return nil;
 NSData *data=[NSData dataWithContentsOfURL:meta];id job=data?[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil]:nil;
 return [job isKindOfClass:NSMutableDictionary.class]?job:nil;
}
- (void)showFiles {
 [self writeMemoryDiagnostic:@"queue-panel"];
 NSArray<NSURL *> *files=[NSFileManager.defaultManager contentsOfDirectoryAtURL:[self pendingDirectory] includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:0 error:nil];NSMutableArray<NSURL *> *jobs=[NSMutableArray new];for(NSURL *u in files)if([u.lastPathComponent hasSuffix:@".job.json"])[jobs addObject:u];[jobs sortUsingComparator:^NSComparisonResult(NSURL *a,NSURL *b){NSDate *da=nil,*db=nil;[a getResourceValue:&da forKey:NSURLContentModificationDateKey error:nil];[b getResourceValue:&db forKey:NSURLContentModificationDateKey error:nil];return [db compare:da];}];
 UIAlertController *a=[UIAlertController alertControllerWithTitle:@"待保存作品" message:[NSString stringWithFormat:@"%@\n待处理 %lu。切到其他 App 后可能暂停，回到此 App 继续。",self.workQueue.summary,(unsigned long)self.workQueue.pendingCount] preferredStyle:UIAlertControllerStyleActionSheet];NSUInteger count=0;for(NSURL *u in jobs){if(count++>=15)break;NSDictionary *j=[self readJobForDisplay:u];id savedDate=j[@"date"];BOOL validDate=[savedDate isKindOfClass:NSNumber.class]&&isfinite([savedDate doubleValue]);NSString *t=[NSString stringWithFormat:@"%@ · %@",[j[@"kind"]isEqual:@"video"]?@"视频":([j[@"kind"]isEqual:@"live"]?@"实况":@"照片"),(validDate?[NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:[savedDate doubleValue]] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle]:@"恢复记录损坏")];[a addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault handler:^(UIAlertAction *act){[self showJob:u];}]];}
 if(self.workQueue.processing)[a addAction:[UIAlertAction actionWithTitle:@"暂停后台合成" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[self cancelExport];}]];
 else [a addAction:[UIAlertAction actionWithTitle:@"继续自动合成" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){self.workQueue.manuallyPaused=NO;[self.workQueue refresh];[self status:@"已恢复队列；失败作品需单独点重试"]; }]];
 [a addAction:[UIAlertAction actionWithTitle:@"相册授权并继续" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[self authorizeQueue];}]];
 [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[self anchor:a button:self.filesButton];[self presentViewController:a animated:YES completion:nil];
}
- (void)shareJob:(NSDictionary *)job {
 NSMutableArray<NSURL *> *items=[NSMutableArray new];BOOL live=[job[@"kind"]isEqual:@"live"];BOOL useOutput=[job[@"stage"]isEqual:@"ready"];
 NSArray *keys=live?(useOutput?@[@"output",@"outputMovie"]:@[@"source",@"sourceMovie"]):(useOutput?@[@"output"]:@[@"source"]);
 for(NSString *key in keys){NSURL *url=[self fileForJob:job key:key];if(url&&[NSFileManager.defaultManager fileExistsAtPath:url.path])[items addObject:url];}
 if(!items.count){[self alert:@"没有可分享的文件" message:@"请在文件 App 检查暂存目录。"];return;}
 UIActivityViewController *share=[[UIActivityViewController alloc]initWithActivityItems:items applicationActivities:nil];[self anchor:share button:self.filesButton];[self presentViewController:share animated:YES completion:nil];
}
- (void)showJob:(NSURL *)meta {
 NSMutableDictionary *job=[self readJobForDisplay:meta];if(!job){[self alert:@"无法读取记录" message:@"可通过文件 App 的“我的 iPhone → 印记相机 → Pending”查找原始文件。"];return;}
 NSURL *output=[self fileForJob:job key:@"output"],*source=[self fileForJob:job key:@"source"];BOOL hasShare=([NSFileManager.defaultManager fileExistsAtPath:output.path]||[NSFileManager.defaultManager fileExistsAtPath:source.path]);if([job[@"kind"]isEqual:@"live"])hasShare=hasShare||[NSFileManager.defaultManager fileExistsAtPath:[self fileForJob:job key:@"sourceMovie"].path];
 UIAlertController *a=[UIAlertController alertControllerWithTitle:@"作品恢复" message:[NSString stringWithFormat:@"%@\n%@",job[@"processingError"]?:@"按拍摄时的水印和时间处理",[job[@"stage"]isEqual:@"saving"]?@"上次保存结果不确定，请先检查系统相册":@"分享不会删除暂存。处理中的作品须先暂停再操作。"] preferredStyle:UIAlertControllerStyleActionSheet];[a addAction:[UIAlertAction actionWithTitle:@"重试合成 / 保存相册" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self processJob:job meta:meta];}]];if(hasShare)[a addAction:[UIAlertAction actionWithTitle:[job[@"kind"]isEqual:@"live"]?@"导出实况资源文件（照片 + MOV）":@"分享已有成品或原片" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self shareJob:job];}]];[a addAction:[UIAlertAction actionWithTitle:@"删除此暂存作品…" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){UIAlertController *q=[UIAlertController alertControllerWithTitle:@"永久删除暂存？" message:@"如果尚未保存或分享，作品将无法恢复。" preferredStyle:UIAlertControllerStyleAlert];[q addAction:[UIAlertAction actionWithTitle:@"保留" style:UIAlertActionStyleCancel handler:nil]];[q addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *v){[self cleanupJob:job meta:meta];[self status:@"已删除此暂存作品"]; }]];[self presentViewController:q animated:YES completion:nil];}]];[a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[self anchor:a button:self.filesButton];[self presentViewController:a animated:YES completion:nil];
}
- (void)tick {
 if(self.recording){NSInteger sec=(NSInteger)(-[self.recordDate timeIntervalSinceNow]);self.recordLabel.text=[NSString stringWithFormat:@"● %02ld:%02ld",(long)(sec/60),(long)(sec%60)];}else if(!self.busy&&!self.editorShown&&!self.inBackground)[self updateOverlay];[self.workQueue tick];
}
- (void)willResignActive:(NSNotification *)notification {self.applicationInactive=YES;[self updatePreviewRoute];[self queueChanged];}
- (void)didBecomeActive:(NSNotification *)notification {self.applicationInactive=NO;[self updatePreviewRoute];[self updateControls];}
- (void)background:(NSNotification *)n {
 self.inBackground=YES;[self updatePreviewRoute];self.countdownGeneration++;if(self.countdownLabel.text.length){self.countdownLabel.text=@"";self.busy=NO;}self.workQueue.foreground=NO;dispatch_async(self.sessionQueue,^{if(self.movieOutput.isRecording)[self.movieOutput stopRecording];[self.session stopRunning];});[self updateControls];UIApplication.sharedApplication.idleTimerDisabled=NO;
}
- (void)resumeCameraSession {
 // Foreground can arrive before pending JPEG/Live callbacks. Keep the current
 // topology until every request has finished; changing audio/format early can
 // interrupt those resources and leave the shutter locked again.
 if(!self.configured){self.sessionRefreshPending=NO;return;}
 self.sessionRefreshPending=YES;
 if(self.inBackground||self.editorShown)return;
 if(self.photoCaptures.count){dispatch_async(self.sessionQueue,^{if(!self.inBackground&&!self.editorShown)[self.session startRunning];});return;}
 self.busy=YES;[self updateControls];
 dispatch_async(self.sessionQueue,^{
  if(!self.inBackground&&!self.editorShown){[self.session beginConfiguration];[self configureLiveMode];[self configurePhotoResolution];[self applyConnections];[self.session commitConfiguration];[self.session startRunning];}
  dispatch_async(dispatch_get_main_queue(),^{self.sessionRefreshPending=NO;self.busy=NO;[self updateControls];});
 });
}
- (void)foreground:(NSNotification *)n {
 self.inBackground=NO;self.workQueue.foreground=YES;self.gpuFailed=NO;[self refreshSettings];if(!self.configured){[self requestCamera];return;}[self resumeCameraSession];[self updateControls];
}
- (void)interrupted:(NSNotification *)n {[self status:@"相机暂时被系统中断，录像原片将保留"];}
- (void)interruptionEnded:(NSNotification *)n {dispatch_async(self.sessionQueue,^{if(!self.inBackground&&!self.editorShown)[self.session startRunning];});[self status:@"相机已恢复"];}
- (void)runtimeError:(NSNotification *)n {NSError *e=n.userInfo[AVCaptureSessionErrorKey];[self status:e.localizedDescription?:@"相机出现系统错误"];if(e.code==AVErrorMediaServicesWereReset)dispatch_async(self.sessionQueue,^{if(!self.inBackground&&!self.editorShown)[self.session startRunning];});}
- (BOOL)shouldAutorotate {return !self.busy&&!self.recording&&!self.photoCaptures.count;}
- (UIStatusBarStyle)preferredStatusBarStyle {return UIStatusBarStyleLightContent;}
- (void)dealloc {[[NSNotificationCenter defaultCenter]removeObserver:self];[self.clockTimer invalidate];[self.videoOutput setSampleBufferDelegate:nil queue:NULL];}
@end
