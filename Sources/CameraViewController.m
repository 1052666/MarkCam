#import "CameraViewController.h"
#import "WMEngine.h"
#import "WMEditorViewController.h"
#import "MCLivePhotoProcessor.h"
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <CoreImage/CoreImage.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static UIColor *MCAccent(void){return [UIColor colorWithRed:.48 green:.92 blue:.78 alpha:1];}
static NSString *MCID(void){return NSUUID.UUID.UUIDString;}
@interface MCGridView:UIView
@property(nonatomic) BOOL grid;
@end
@implementation MCGridView
- (void)drawRect:(CGRect)rect {if(!self.grid)return;CGContextRef c=UIGraphicsGetCurrentContext();CGContextSetStrokeColorWithColor(c,[UIColor colorWithWhite:1 alpha:.25].CGColor);CGContextSetLineWidth(c,.5);for(int i=1;i<3;i++){CGFloat x=rect.size.width*i/3.,y=rect.size.height*i/3.;CGContextMoveToPoint(c,x,0);CGContextAddLineToPoint(c,x,rect.size.height);CGContextMoveToPoint(c,0,y);CGContextAddLineToPoint(c,rect.size.width,y);}CGContextStrokePath(c);}
@end
// AVFoundation marks these optional in its protocol, but JPEG capture requires
// didFinishProcessingPhoto at runtime. Redeclare required to catch selector typos.
@protocol MCPhotoCaptureContract <AVCapturePhotoCaptureDelegate>
@required
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error;
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings error:(NSError *)error;
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingLivePhotoToMovieFileAtURL:(NSURL *)url duration:(CMTime)duration photoDisplayTime:(CMTime)photoDisplayTime resolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings error:(NSError *)error;
@end
@interface CameraViewController ()<AVCaptureVideoDataOutputSampleBufferDelegate,MCPhotoCaptureContract,AVCaptureFileOutputRecordingDelegate,UIGestureRecognizerDelegate>
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
@property(nonatomic,strong) CIContext *ciContext;
@property(nonatomic,strong) UIImageView *preview;
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
@property(nonatomic,strong) MCLivePhotoProcessor *liveProcessor;
@property(atomic) BOOL liveSupported;
@property(atomic) BOOL capturingLive;
@property(atomic,strong) NSURL *captureLiveMeta;
@property(atomic,strong) NSDictionary *captureLiveJob;
// These three capture result flags are confined to the serial renderQueue.
@property(nonatomic,strong) NSError *liveCaptureError;
@property(nonatomic) BOOL livePhotoWritten;
@property(nonatomic) BOOL liveMovieWritten;
@property(nonatomic,strong) UISegmentedControl *mode;
@property(nonatomic,strong) UIProgressView *progress;
@property(nonatomic,strong) UIButton *cancelExportButton;
@property(nonatomic,strong) UIImage *lastFrame;
@property(nonatomic,strong) UIImage *lastRawFrame;
@property(nonatomic,strong) NSTimer *clockTimer;
@property(nonatomic,strong) NSDate *recordDate;
@property(nonatomic,strong) AVAssetExportSession *exportSession;
@property(atomic,copy) NSDictionary *activeSettings;
@property(nonatomic,copy) NSDictionary *captureSettings;
@property(nonatomic,strong) NSDate *captureDate;
@property(atomic) BOOL configured;
@property(nonatomic) BOOL wantsVideo;
@property(nonatomic) BOOL busy;
@property(atomic) BOOL inBackground;
@property(atomic) BOOL editorShown;
@property(nonatomic) BOOL recording;
@property(nonatomic) NSInteger countdown;
@property(nonatomic) NSInteger countdownGeneration;
@property(nonatomic) CGFloat zoomStart;
@property(nonatomic) CFTimeInterval lastFrameAt;
@property(atomic) BOOL photoProcessed;
@property(atomic) BOOL framePending;
@property(nonatomic) CGSize feedSize;
@property(nonatomic) CGSize lastOverlaySize;
@property(atomic) AVCaptureVideoOrientation captureOrientation;
@property(nonatomic,strong) NSURL *currentRawURL;
@property(nonatomic,strong) NSURL *activeMetaURL;
@end

@implementation CameraViewController
- (void)viewDidLoad {
 [super viewDidLoad];self.view.backgroundColor=[UIColor colorWithRed:.045 green:.065 blue:.068 alpha:1];self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
 self.sessionQueue=dispatch_queue_create("markcam.capture",DISPATCH_QUEUE_SERIAL);self.framesQueue=dispatch_queue_create("markcam.frames",DISPATCH_QUEUE_SERIAL);self.renderQueue=dispatch_queue_create("markcam.render",DISPATCH_QUEUE_SERIAL);self.ciContext=[CIContext contextWithOptions:@{kCIContextCacheIntermediates:@NO}];self.session=[AVCaptureSession new];self.captureOrientation=AVCaptureVideoOrientationPortrait;
 self.activeSettings=[[WMEngine shared] snapshot];self.feedSize=CGSizeMake(3,4);[self makeUI];[self refreshSettings];
 NSNotificationCenter *nc=NSNotificationCenter.defaultCenter;
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
 self.stage=[UIView new];self.stage.backgroundColor=UIColor.blackColor;self.stage.layer.cornerRadius=20;self.stage.clipsToBounds=YES;[self.view addSubview:self.stage];
 self.preview=[UIImageView new];self.preview.contentMode=UIViewContentModeScaleAspectFit;[self.stage addSubview:self.preview];
 self.nativePreview=[AVCaptureVideoPreviewLayer layerWithSession:self.session];self.nativePreview.videoGravity=AVLayerVideoGravityResizeAspect;self.nativePreview.hidden=YES;[self.stage.layer insertSublayer:self.nativePreview atIndex:0];
 self.overlay=[UIImageView new];self.overlay.contentMode=UIViewContentModeScaleToFill;self.overlay.userInteractionEnabled=NO;[self.stage addSubview:self.overlay];
 self.gridView=[MCGridView new];self.gridView.backgroundColor=UIColor.clearColor;self.gridView.userInteractionEnabled=NO;[self.stage addSubview:self.gridView];
 self.zoomSlider=[UISlider new];self.zoomSlider.minimumValue=1;self.zoomSlider.maximumValue=8;self.zoomSlider.value=1;self.zoomSlider.tintColor=MCAccent();self.zoomSlider.accessibilityLabel=@"相机缩放倍率";[self.zoomSlider addTarget:self action:@selector(zoomSliderChanged:) forControlEvents:UIControlEventValueChanged];[self.stage addSubview:self.zoomSlider];
 self.zoomLabel=[UILabel new];self.zoomLabel.text=@"1.0×";self.zoomLabel.textColor=UIColor.whiteColor;self.zoomLabel.font=[UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];[self.stage addSubview:self.zoomLabel];
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
 [super viewDidLayoutSubviews];UIEdgeInsets s=self.view.safeAreaInsets;CGFloat w=self.view.bounds.size.width,h=self.view.bounds.size.height;BOOL landscape=w>h;
 if(landscape){self.titleLabel.frame=CGRectMake(s.left+16,s.top+8,w-s.left-s.right-210,32);self.watermarkButton.frame=CGRectMake(w-s.right-130,s.top+7,114,34);CGFloat availH=h-s.top-s.bottom-84,availW=w-s.left-s.right-174;CGFloat ratio=self.feedSize.width/MAX(1,self.feedSize.height);CGSize fs=CGSizeMake(MIN(availW,availH*ratio),0);fs.height=fs.width/ratio;self.stage.frame=CGRectMake(s.left+12+(availW-fs.width)/2,s.top+48+(availH-fs.height)/2,fs.width,fs.height);CGFloat x=w-s.right-148;self.mode.frame=CGRectMake(x,s.top+52,134,30);self.shutter.frame=CGRectMake(x+35,s.top+90,64,64);self.filesButton.frame=CGRectMake(x,s.top+163,64,35);self.switchButton.frame=CGRectMake(x+70,s.top+163,64,35);self.editButton.frame=CGRectMake(x,s.top+207,134,40);self.editButton.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];self.statusLabel.frame=CGRectMake(s.left+16,h-s.bottom-34,availW,30);
 }else{self.titleLabel.frame=CGRectMake(20,s.top+8,w-155,36);self.watermarkButton.frame=CGRectMake(w-124,s.top+8,104,34);CGFloat top=s.top+58,availH=h-s.bottom-top-200,availW=w-24;CGFloat ratio=self.feedSize.width/MAX(1,self.feedSize.height);CGFloat fw=MIN(availW,availH*ratio),fh=fw/ratio;self.stage.frame=CGRectMake((w-fw)/2,top+(availH-fh)/2,fw,fh);CGFloat base=h-s.bottom-185;self.statusLabel.frame=CGRectMake(16,base,w-32,34);self.mode.frame=CGRectMake((w-160)/2,base+40,160,30);self.shutter.frame=CGRectMake((w-70)/2,base+80,70,70);self.filesButton.frame=CGRectMake(26,base+94,84,40);self.switchButton.frame=CGRectMake(w-110,base+94,84,40);self.editButton.frame=CGRectMake((w-220)/2,base+157,220,34);}
 self.shutter.layer.cornerRadius=self.shutter.bounds.size.width/2;self.preview.frame=self.stage.bounds;self.nativePreview.frame=self.stage.bounds;self.overlay.frame=self.stage.bounds;self.gridView.frame=self.stage.bounds;[self.gridView setNeedsDisplay];self.recordLabel.frame=CGRectMake(0,12,self.stage.bounds.size.width,24);self.countdownLabel.frame=self.stage.bounds;
 self.zoomLabel.frame=CGRectMake(12,self.stage.bounds.size.height-40,55,34);self.zoomSlider.frame=CGRectMake(70,self.stage.bounds.size.height-44,MAX(40,self.stage.bounds.size.width-88),44);
 self.titleLabel.text=@"印记相机";self.titleLabel.font=[UIFont systemFontOfSize:18 weight:UIFontWeightBold];self.titleLabel.frame=CGRectMake(s.left+14,s.top+8,100,36);
 CGFloat right=w-s.right-12;self.settingsButton.frame=CGRectMake(right-48,s.top+8,48,34);self.liveButton.frame=CGRectMake(right-122,s.top+8,68,34);self.watermarkButton.frame=CGRectMake(right-208,s.top+8,80,34);self.liveButton.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];self.watermarkButton.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
 self.progress.frame=CGRectMake(24,CGRectGetMaxY(self.stage.frame)-5,MAX(50,self.stage.bounds.size.width-24),2);self.cancelExportButton.frame=CGRectMake(CGRectGetMaxX(self.stage.frame)-108,CGRectGetMaxY(self.stage.frame)-44,100,30);
 CGSize os=self.stage.bounds.size;if(!CGSizeEqualToSize(os,self.lastOverlaySize)){self.lastOverlaySize=os;[self updateOverlay];}
}
- (AVCaptureVideoOrientation)orientation {
 UIInterfaceOrientation o=self.view.window.windowScene.interfaceOrientation;
 switch(o){case UIInterfaceOrientationLandscapeLeft:return AVCaptureVideoOrientationLandscapeLeft;case UIInterfaceOrientationLandscapeRight:return AVCaptureVideoOrientationLandscapeRight;case UIInterfaceOrientationPortraitUpsideDown:return AVCaptureVideoOrientationPortraitUpsideDown;default:return AVCaptureVideoOrientationPortrait;}
}
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)c {
 [super viewWillTransitionToSize:size withTransitionCoordinator:c];[c animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context){[self.view setNeedsLayout];} completion:^(id<UIViewControllerTransitionCoordinatorContext> context){if(!self.busy&&!self.recording){self.captureOrientation=[self orientation];dispatch_async(self.sessionQueue,^{[self applyConnections];});}}];
}
- (void)status:(NSString *)s {dispatch_async(dispatch_get_main_queue(),^{self.statusLabel.text=s;});}
- (void)alert:(NSString *)title message:(NSString *)message {
 dispatch_async(dispatch_get_main_queue(),^{if(self.inBackground){[self status:message];return;}UIViewController *vc=self;while(vc.presentedViewController)vc=vc.presentedViewController;UIAlertController *a=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];[vc presentViewController:a animated:YES completion:nil];});
}
- (void)permissionAlert:(NSString *)message {
 UIAlertController *a=[UIAlertController alertControllerWithTitle:@"需要授权" message:message preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"暂不" style:UIAlertActionStyleCancel handler:nil]];[a addAction:[UIAlertAction actionWithTitle:@"打开设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[UIApplication.sharedApplication openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{} completionHandler:nil];}]];[self presentViewController:a animated:YES completion:nil];
}
- (void)requestCamera {
 AVAuthorizationStatus st=[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];if(st==AVAuthorizationStatusAuthorized){[self configure];return;}if(st==AVAuthorizationStatusNotDetermined){[AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL ok){dispatch_async(dispatch_get_main_queue(),^{if(ok)[self configure];else{[self status:@"相机未授权；仍可编辑水印模板"];[self permissionAlert:@"拍摄需要相机权限，可在系统设置中开启。"];}});}];}else{[self status:@"相机权限未开启"];[self permissionAlert:@"拍摄需要相机权限，可在系统设置中开启。"];}
}
- (AVCaptureDevice *)deviceForPosition:(AVCaptureDevicePosition)p {return [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo position:p];}
- (void)configure {
 dispatch_async(self.sessionQueue,^{if(self.configured){if(!self.inBackground&&!self.editorShown)[self.session startRunning];return;}NSError *e=nil;AVCaptureDevice *d=[self deviceForPosition:AVCaptureDevicePositionBack];AVCaptureDeviceInput *i=[AVCaptureDeviceInput deviceInputWithDevice:d error:&e];if(!i||![self.session canAddInput:i]){[self status:e.localizedDescription?:@"无法打开相机"];return;}[self.session beginConfiguration];self.session.sessionPreset=AVCaptureSessionPresetPhoto;[self.session addInput:i];self.cameraInput=i;
 self.photoOutput=[AVCapturePhotoOutput new];self.photoOutput.maxPhotoQualityPrioritization=AVCapturePhotoQualityPrioritizationQuality;self.photoOutput.highResolutionCaptureEnabled=YES;
 if([self.session canAddOutput:self.photoOutput])[self.session addOutput:self.photoOutput];
 self.videoOutput=[AVCaptureVideoDataOutput new];self.videoOutput.alwaysDiscardsLateVideoFrames=YES;self.videoOutput.videoSettings=@{(NSString *)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)};[self.videoOutput setSampleBufferDelegate:self queue:self.framesQueue];if([self.session canAddOutput:self.videoOutput])[self.session addOutput:self.videoOutput];
 self.movieOutput=[AVCaptureMovieFileOutput new];self.movieOutput.maxRecordedDuration=CMTimeMake(300,1);self.movieOutput.minFreeDiskSpaceLimit=150*1024*1024;
 [self configureLiveMode];[self applyConnections];[self.session commitConfiguration];self.configured=YES;if(!self.inBackground&&!self.editorShown)[self.session startRunning];[self status:@"照片模式 · 轻点对焦 / 双指变焦"];dispatch_async(dispatch_get_main_queue(),^{[self updateControls];});});
}
- (BOOL)ensureAudioInput {
 if([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]!=AVAuthorizationStatusAuthorized)return NO;
 if(!self.audioInput){AVCaptureDevice *device=[AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];NSError *error=nil;if(device)self.audioInput=[AVCaptureDeviceInput deviceInputWithDevice:device error:&error];}
 if(self.audioInput&&![self.session.inputs containsObject:self.audioInput]&&[self.session canAddInput:self.audioInput])[self.session addInput:self.audioInput];
 return self.audioInput&&[self.session.inputs containsObject:self.audioInput];
}
// Invoke inside begin/commitConfiguration, on sessionQueue, never during capture.
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
 self.liveButton.enabled=self.configured&&!self.busy&&!self.recording&&!self.wantsVideo;self.liveButton.alpha=self.liveButton.enabled?1:.4;
}
- (void)toggleLive {
 if(self.busy||self.recording||self.wantsVideo)return;BOOL on=[self.activeSettings[@"livePhotoEnabled"]boolValue];
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
 AVCaptureVideoOrientation orientation=self.captureOrientation;dispatch_async(dispatch_get_main_queue(),^{AVCaptureConnection *previewConnection=self.nativePreview.connection;if(previewConnection.isVideoOrientationSupported)previewConnection.videoOrientation=orientation;if(previewConnection.isVideoMirroringSupported){previewConnection.automaticallyAdjustsVideoMirroring=NO;previewConnection.videoMirrored=mirror;}if(self.nativeVideoPreview){BOOL portrait=orientation==AVCaptureVideoOrientationPortrait||orientation==AVCaptureVideoOrientationPortraitUpsideDown;self.feedSize=portrait?CGSizeMake(9,16):CGSizeMake(16,9);[self.view setNeedsLayout];}});
}
- (void)modeChanged {
 if(self.busy||self.recording){self.mode.selectedSegmentIndex=self.wantsVideo?1:0;return;}BOOL video=self.mode.selectedSegmentIndex==1;if(video){AVAuthorizationStatus s=[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];if(s==AVAuthorizationStatusNotDetermined){[AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL ok){dispatch_async(dispatch_get_main_queue(),^{if(ok)[self setVideoMode:YES];else{self.mode.selectedSegmentIndex=0;[self permissionAlert:@"有声录像需要麦克风权限。照片拍摄不受影响。"];}});}];return;}if(s!=AVAuthorizationStatusAuthorized){self.mode.selectedSegmentIndex=0;[self permissionAlert:@"有声录像需要麦克风权限，请先开启后再录制。"];return;}}[self setVideoMode:video];
}
- (void)setVideoMode:(BOOL)video {
 self.busy=YES;[self updateControls];dispatch_async(self.sessionQueue,^{
 if(!self.configured){dispatch_async(dispatch_get_main_queue(),^{self.busy=NO;self.mode.selectedSegmentIndex=0;[self updateControls];});return;}
 [self.session beginConfiguration];BOOL success=YES;
 if(video){if([self.session.outputs containsObject:self.photoOutput])[self.session removeOutput:self.photoOutput];if([self.session canSetSessionPreset:AVCaptureSessionPreset1920x1080])self.session.sessionPreset=AVCaptureSessionPreset1920x1080;else self.session.sessionPreset=AVCaptureSessionPresetHigh;
 if(!self.audioInput){NSError *err=nil;AVCaptureDevice *audio=[AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];if(audio)self.audioInput=[AVCaptureDeviceInput deviceInputWithDevice:audio error:&err];}
 if(self.audioInput&&![self.session.inputs containsObject:self.audioInput]&&[self.session canAddInput:self.audioInput])[self.session addInput:self.audioInput];
 if([self.session canAddOutput:self.movieOutput])[self.session addOutput:self.movieOutput];if(![self.session.outputs containsObject:self.movieOutput]){if([self.session.outputs containsObject:self.videoOutput])[self.session removeOutput:self.videoOutput];if([self.session canAddOutput:self.movieOutput])[self.session addOutput:self.movieOutput];}success=[self.session.outputs containsObject:self.movieOutput]&&self.audioInput&&[self.session.inputs containsObject:self.audioInput];
 }else{[self.session removeOutput:self.movieOutput];if(self.audioInput&&[self.session.inputs containsObject:self.audioInput])[self.session removeInput:self.audioInput];self.session.sessionPreset=AVCaptureSessionPresetPhoto;if([self.session canAddOutput:self.photoOutput])[self.session addOutput:self.photoOutput];}
 if(!success){[self.session removeOutput:self.movieOutput];if(self.audioInput&&[self.session.inputs containsObject:self.audioInput])[self.session removeInput:self.audioInput];self.session.sessionPreset=AVCaptureSessionPresetPhoto;if([self.session canAddOutput:self.photoOutput])[self.session addOutput:self.photoOutput];}
 if(!video||!success){if(![self.session.outputs containsObject:self.videoOutput]&&[self.session canAddOutput:self.videoOutput])[self.session addOutput:self.videoOutput];}self.nativeVideoPreview=video&&success&&![self.session.outputs containsObject:self.videoOutput];
 [self configureLiveMode];[self applyConnections];[self.session commitConfiguration];if(video&&success){AVCaptureDevice *d=self.cameraInput.device;NSError *err=nil;if([d lockForConfiguration:&err]){for(AVFrameRateRange *r in d.activeFormat.videoSupportedFrameRateRanges){if(r.minFrameRate<=30&&r.maxFrameRate>=30){d.activeVideoMinFrameDuration=CMTimeMake(1,30);d.activeVideoMaxFrameDuration=CMTimeMake(1,30);break;}}[d unlockForConfiguration];}}
 dispatch_async(dispatch_get_main_queue(),^{self.wantsVideo=video&&success;self.nativePreview.hidden=!self.nativeVideoPreview;self.preview.hidden=self.nativeVideoPreview;self.mode.selectedSegmentIndex=self.wantsVideo?1:0;self.busy=NO;[self updateControls];[self status:success?(video?(self.nativeVideoPreview?@"录像兼容模式 · 水印可见，调色在成片应用":@"1080p · 有声录像 · 单段最长 5 分钟"):@"照片模式 · 原生高画质"):@"当前设备无法启用有声录像"];});});
}
- (void)switchCamera {
 if(self.busy||self.recording||!self.configured)return;self.busy=YES;[self updateControls];dispatch_async(self.sessionQueue,^{AVCaptureDevicePosition p=self.cameraInput.device.position==AVCaptureDevicePositionBack?AVCaptureDevicePositionFront:AVCaptureDevicePositionBack;NSError *e=nil;AVCaptureDevice *d=[self deviceForPosition:p];AVCaptureDeviceInput *i=d?[AVCaptureDeviceInput deviceInputWithDevice:d error:&e]:nil;if(i){[self.session beginConfiguration];AVCaptureDeviceInput *old=self.cameraInput;[self.session removeInput:old];if([self.session canAddInput:i]){[self.session addInput:i];self.cameraInput=i;}else[self.session addInput:old];[self configureLiveMode];[self applyConnections];[self.session commitConfiguration];}dispatch_async(dispatch_get_main_queue(),^{self.busy=NO;[self updateControls];if(e)[self alert:@"切换失败" message:e.localizedDescription];});});
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
 UIView *view=touch.view;while(view&&view!=self.stage){if([view isKindOfClass:UIControl.class])return NO;view=view.superview;}return YES;
}
- (void)focus:(UITapGestureRecognizer *)g {
 if(self.busy||self.recording||!self.configured)return;CGPoint pt=[g locationInView:self.stage];CGFloat u=pt.x/MAX(1,self.stage.bounds.size.width),v=pt.y/MAX(1,self.stage.bounds.size.height);BOOL mirrored=self.cameraInput.device.position==AVCaptureDevicePositionFront&&[self.activeSettings[@"mirrorFront"] boolValue];if(mirrored)u=1-u;CGPoint p;switch(self.captureOrientation){case AVCaptureVideoOrientationLandscapeRight:p=CGPointMake(u,v);break;case AVCaptureVideoOrientationLandscapeLeft:p=CGPointMake(1-u,1-v);break;case AVCaptureVideoOrientationPortraitUpsideDown:p=CGPointMake(1-v,u);break;default:p=CGPointMake(v,1-u);break;}
 UIView *ring=[[UIView alloc]initWithFrame:CGRectMake(pt.x-25,pt.y-25,50,50)];ring.layer.borderColor=MCAccent().CGColor;ring.layer.borderWidth=1.3;ring.layer.cornerRadius=10;[self.stage addSubview:ring];[UIView animateWithDuration:.7 delay:.5 options:0 animations:^{ring.alpha=0;} completion:^(BOOL f){[ring removeFromSuperview];}];
 dispatch_async(self.sessionQueue,^{AVCaptureDevice *d=self.cameraInput.device;NSError *e=nil;if([d lockForConfiguration:&e]){if(d.focusPointOfInterestSupported&&[d isFocusModeSupported:AVCaptureFocusModeAutoFocus]){d.focusPointOfInterest=p;d.focusMode=AVCaptureFocusModeAutoFocus;}if(d.exposurePointOfInterestSupported&&[d isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]){d.exposurePointOfInterest=p;d.exposureMode=AVCaptureExposureModeContinuousAutoExposure;}[d unlockForConfiguration];}});
}
- (void)refreshZoomUI {
 dispatch_async(self.sessionQueue,^{AVCaptureDevice *d=self.cameraInput.device;CGFloat lo=MAX(1,d.minAvailableVideoZoomFactor),hi=MAX(lo,MIN(8,d.maxAvailableVideoZoomFactor)),z=d.videoZoomFactor;
 dispatch_async(dispatch_get_main_queue(),^{self.zoomSlider.minimumValue=lo;self.zoomSlider.maximumValue=hi;self.zoomSlider.value=MAX(lo,MIN(hi,z));self.zoomLabel.text=[NSString stringWithFormat:@"%.1f×",self.zoomSlider.value];self.zoomSlider.accessibilityValue=self.zoomLabel.text;});});
}
- (void)setZoomFactor:(CGFloat)factor {
 if(self.busy||self.recording||!isfinite(factor))return;dispatch_async(self.sessionQueue,^{AVCaptureDevice *d=self.cameraInput.device;NSError *error=nil;if([d lockForConfiguration:&error]){d.videoZoomFactor=MAX(MAX(1,d.minAvailableVideoZoomFactor),MIN(MIN(d.maxAvailableVideoZoomFactor,8),factor));[d unlockForConfiguration];}[self refreshZoomUI];});
}
- (void)zoomSliderChanged:(UISlider *)slider { [self setZoomFactor:slider.value]; }
- (void)zoom:(UIPinchGestureRecognizer *)g {
 if(self.busy||self.recording)return;if(g.state==UIGestureRecognizerStateBegan)self.zoomStart=self.zoomSlider.value;[self setZoomFactor:self.zoomStart*g.scale];
}
- (void)applyExposureSettings {
 AVCaptureDevice *d=self.cameraInput.device;id raw=self.activeSettings[@"exposureBias"];float value=[raw isKindOfClass:NSNumber.class]?[raw floatValue]:0;if(!isfinite(value))value=0;value=MAX(-2,MIN(2,value));NSError *e=nil;if(d&&[d lockForConfiguration:&e]){float target=MAX(d.minExposureTargetBias,MIN(d.maxExposureTargetBias,value));if(fabs(d.exposureTargetBias-target)>.01)[d setExposureTargetBias:target completionHandler:nil];[d unlockForConfiguration];}
}
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
 @autoreleasepool {CFTimeInterval now=CACurrentMediaTime();if(now-self.lastFrameAt<1./20||self.inBackground||self.framePending)return;self.lastFrameAt=now;CVPixelBufferRef pixel=CMSampleBufferGetImageBuffer(sampleBuffer);if(!pixel)return;CIImage *source=[CIImage imageWithCVPixelBuffer:pixel];CGFloat scale=MIN(1.,720./MAX(source.extent.size.width,source.extent.size.height));source=[source imageByApplyingTransform:CGAffineTransformMakeScale(scale,scale)];NSDictionary *settings=self.activeSettings;CIImage *toned=[[WMEngine shared]applyTone:source settings:settings];CGImageRef cg=[self.ciContext createCGImage:toned fromRect:source.extent];if(!cg)return;UIImage *frame=[UIImage imageWithCGImage:cg];CGImageRelease(cg);CGImageRef rawCG=[self.ciContext createCGImage:source fromRect:source.extent];UIImage *raw=rawCG?[UIImage imageWithCGImage:rawCG]:frame;if(rawCG)CGImageRelease(rawCG);
 self.framePending=YES;dispatch_async(dispatch_get_main_queue(),^{self.framePending=NO;if(self.editorShown||self.inBackground)return;self.lastFrame=frame;self.lastRawFrame=raw;self.preview.image=frame;if(fabs(self.feedSize.width/MAX(1,self.feedSize.height)-frame.size.width/MAX(1,frame.size.height))>.005){self.feedSize=frame.size;[self.view setNeedsLayout];[self.view layoutIfNeeded];[self updateOverlay];}});}
}
- (void)refreshSettings {
 self.activeSettings=[[WMEngine shared]snapshot];self.gridView.grid=[self.activeSettings[@"gridEnabled"]boolValue];[self.gridView setNeedsDisplay];[self.watermarkButton setTitle:[self.activeSettings[@"watermarkEnabled"]boolValue]?@"水印开启":@"水印关闭" forState:UIControlStateNormal];[self updateOverlay];[self refreshLiveUI];if(self.configured)dispatch_async(self.sessionQueue,^{[self.session beginConfiguration];[self configureLiveMode];[self applyConnections];[self.session commitConfiguration];});
}
- (void)updateOverlay {
 CGSize s=self.stage.bounds.size;if(s.width<1||s.height<1)return;CGFloat z=MIN(2,720./MAX(s.width,s.height));s=CGSizeMake(s.width*z,s.height*z);self.overlay.image=[[WMEngine shared]overlayForSize:s settings:self.recording?self.captureSettings:self.activeSettings date:self.recording?self.recordDate:NSDate.date];
}
- (void)toggleWatermark {if(self.busy||self.recording)return;WMEngine *e=WMEngine.shared;e.settings[@"watermarkEnabled"]=@(![e.settings[@"watermarkEnabled"]boolValue]);[e save];[self refreshSettings];}
- (void)openSettings { [self presentEditorAtSettings:YES]; }
- (void)openEditor { [self presentEditorAtSettings:NO]; }
- (void)presentEditorAtSettings:(BOOL)settings {
 if(self.busy||self.recording)return;self.editorShown=YES;dispatch_async(self.sessionQueue,^{[self.session stopRunning];});WMEditorViewController *e=[WMEditorViewController new];e.opensSettings=settings;e.backgroundImage=self.nativeVideoPreview?nil:self.lastRawFrame;__weak typeof(self) weak=self;e.onChange=^{[weak refreshSettings];};UINavigationController *nav=[[UINavigationController alloc]initWithRootViewController:e];nav.modalPresentationStyle=UIModalPresentationFullScreen;[self presentViewController:nav animated:YES completion:nil];
}
- (void)viewDidAppear:(BOOL)animated {[super viewDidAppear:animated];if(self.editorShown&&!self.presentedViewController){self.editorShown=NO;[self refreshSettings];dispatch_async(self.sessionQueue,^{if(self.configured&&!self.inBackground)[self.session startRunning];});}}
- (void)updateControls {
 BOOL locked=self.busy||self.recording;self.zoomSlider.enabled=!locked&&self.configured;self.settingsButton.enabled=!locked;[self refreshLiveUI];if(!locked)[self refreshZoomUI];self.mode.enabled=!locked;self.switchButton.enabled=!locked&&self.configured;self.editButton.enabled=!locked;self.filesButton.enabled=!locked;self.watermarkButton.enabled=!locked;self.shutter.enabled=self.configured&&(!self.busy||self.recording)&&!self.inBackground;
 self.shutter.backgroundColor=self.wantsVideo?UIColor.systemRedColor:UIColor.whiteColor;[self.shutter setTitle:self.recording?@"■":@"" forState:UIControlStateNormal];[self.shutter setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];self.shutter.accessibilityLabel=self.recording?@"停止录像":(self.wantsVideo?@"开始录像":@"拍照");UIApplication.sharedApplication.idleTimerDisabled=self.busy||self.recording;
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
- (void)capturePressed {
 if(self.recording){[self status:@"正在结束录像…"];self.shutter.enabled=NO;dispatch_async(self.sessionQueue,^{[self.movieOutput stopRecording];});return;}if(self.busy||!self.configured)return;if(!self.session.running){[self alert:@"相机尚未就绪" message:@"请返回前台，或重新打开相机权限。"];return;}
 NSInteger delay=[self.activeSettings[@"timerSeconds"]integerValue];
 if(!self.wantsVideo&&[self.activeSettings[@"livePhotoEnabled"]boolValue]&&[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]!=AVAuthorizationStatusAuthorized){[self authorizeLive:^{[self refreshSettings];[self status:@"麦克风已开启，取景稳定后再次按快门拍摄 LIVE"]; }];return;}
 if(delay>0){self.busy=YES;self.countdown=MIN(delay,10);NSInteger generation=++self.countdownGeneration;[self updateControls];[self countdownStep:generation];}else [self startCapture];
}
- (void)countdownStep:(NSInteger)generation {
 if(generation!=self.countdownGeneration||self.inBackground)return;if(self.countdown<=0){self.countdownLabel.text=@"";self.busy=NO;[self startCapture];return;}self.countdownLabel.text=[NSString stringWithFormat:@"%ld",(long)self.countdown--];dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{[self countdownStep:generation];});
}
- (void)startCapture {
 self.photoProcessed=NO;self.captureSettings=[[WMEngine shared]snapshot];self.captureDate=NSDate.date;self.captureOrientation=[self orientation];self.busy=YES;[self updateControls];
 if(self.wantsVideo){NSString *ident=MCID();self.currentRawURL=[[self pendingDirectory]URLByAppendingPathComponent:[ident stringByAppendingString:@"-raw.mov"]];self.activeMetaURL=[[self pendingDirectory]URLByAppendingPathComponent:[ident stringByAppendingString:@".job.json"]];NSMutableDictionary *j=[@{@"kind":@"video",@"stage":@"raw",@"source":self.currentRawURL.lastPathComponent,@"output":[ident stringByAppendingString:@".mp4"],@"settings":self.captureSettings,@"date":@([self.captureDate timeIntervalSince1970])}mutableCopy];if(![self writeJob:j URL:self.activeMetaURL]){self.busy=NO;[self updateControls];return;}self.recordDate=self.captureDate;[self status:@"正在启动录制…"];dispatch_async(self.sessionQueue,^{[self applyConnections];AVCaptureDevice *d=self.cameraInput.device;NSError *e=nil;if(d.hasTorch&&[d lockForConfiguration:&e]){d.torchMode=[self.captureSettings[@"flashMode"]integerValue]==2?AVCaptureTorchModeOn:AVCaptureTorchModeOff;[d unlockForConfiguration];}[self.movieOutput startRecordingToOutputFileURL:self.currentRawURL recordingDelegate:self];});
 }else{[self status:@"正在拍摄…"];dispatch_async(self.sessionQueue,^{[self submitPhotoRequest];});}
}
// Runs on sessionQueue. A rejected request must restore the UI, never silently
// retry or pretend a photo was captured. Retain the exact error locally.
- (void)rejectPhotoRequest:(NSString *)message {
 self.photoProcessed=YES;self.capturingLive=NO;
 dispatch_async(dispatch_get_main_queue(),^{self.recordLabel.text=@"";});
 NSDictionary *detail=@{@"appVersion":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]?:@"",
 @"osVersion":UIDevice.currentDevice.systemVersion?:@"",@"time":@([NSDate.date timeIntervalSince1970]),
 @"stage":@"photo-request",@"message":message?:@"未知错误"};
 NSData *data=[NSJSONSerialization dataWithJSONObject:detail options:NSJSONWritingPrettyPrinted error:nil];
 [data writeToURL:[[WMEngine.shared documentsURL]URLByAppendingPathComponent:@"LastCaptureError.json"] options:NSDataWritingAtomic error:nil];
 dispatch_async(dispatch_get_main_queue(),^{self.busy=NO;[self updateControls];[self status:@"拍照请求未完成，错误已记录"];[self alert:@"拍照未完成" message:message?:@"请稍后重试。"];});
}
- (void)submitPhotoRequest {
 if(self.inBackground||self.editorShown||!self.session.isRunning||![self.session.outputs containsObject:self.photoOutput]){[self rejectPhotoRequest:@"相机暂未就绪，请返回取景画面后重试。"];return;}
 if(![self respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]||![self respondsToSelector:@selector(captureOutput:didFinishCaptureForResolvedSettings:error:)]){[self rejectPhotoRequest:@"拍照回调校验失败，请安装修复版本。"];return;}
 @try {
  [self applyConnections];AVCaptureConnection *connection=[self.photoOutput connectionWithMediaType:AVMediaTypeVideo];
  if(!connection||!connection.isEnabled||!connection.isActive){[self rejectPhotoRequest:@"照片输出暂未连接，请等待取景恢复后重试。"];return;}
  if(![self.photoOutput.availablePhotoCodecTypes containsObject:AVVideoCodecTypeJPEG]){[self rejectPhotoRequest:@"当前相机未提供 JPEG 拍照格式。"];return;}
  AVCapturePhotoSettings *p=[AVCapturePhotoSettings photoSettingsWithFormat:@{AVVideoCodecKey:AVVideoCodecTypeJPEG}];
  p.highResolutionPhotoEnabled=self.photoOutput.isHighResolutionCaptureEnabled;
  p.photoQualityPrioritization=MIN(AVCapturePhotoQualityPrioritizationQuality,self.photoOutput.maxPhotoQualityPrioritization);
  NSInteger f=[self.captureSettings[@"flashMode"]integerValue];AVCaptureFlashMode fm=f==1?AVCaptureFlashModeAuto:f==2?AVCaptureFlashModeOn:AVCaptureFlashModeOff;
  if([self.photoOutput.supportedFlashModes containsObject:@(fm)])p.flashMode=fm;
  self.capturingLive=NO;
  if([self.captureSettings[@"livePhotoEnabled"]boolValue]){
   p.photoQualityPrioritization=MIN(AVCapturePhotoQualityPrioritizationBalanced,self.photoOutput.maxPhotoQualityPrioritization);
   if(!self.photoOutput.isLivePhotoCaptureSupported||!self.photoOutput.isLivePhotoCaptureEnabled||self.photoOutput.isLivePhotoCaptureSuspended){[self rejectPhotoRequest:@"当前相机尚不能拍摄 Live Photo，请等待取景稳定或关闭 LIVE。"];return;}
   if(!self.audioInput||![self.session.inputs containsObject:self.audioInput]){[self rejectPhotoRequest:@"Live Photo 音频输入尚未就绪，请关闭再开启 LIVE 后重试。"];return;}
   if(![self respondsToSelector:@selector(captureOutput:didFinishProcessingLivePhotoToMovieFileAtURL:duration:photoDisplayTime:resolvedSettings:error:)]){[self rejectPhotoRequest:@"实况回调校验失败"];return;}
   NSString *ident=MCID();NSURL *dir=[self pendingDirectory];
   NSDictionary *job=@{@"kind":@"live",@"stage":@"capturing",@"source":[ident stringByAppendingString:@"-raw.jpg"],@"sourceMovie":[ident stringByAppendingString:@"-raw.mov"],@"output":[ident stringByAppendingString:@".jpg"],@"outputMovie":[ident stringByAppendingString:@".mov"],@"settings":self.captureSettings,@"date":@([self.captureDate timeIntervalSince1970])};
   NSURL *meta=[dir URLByAppendingPathComponent:[ident stringByAppendingString:@".job.json"]];if(![self writeJob:job URL:meta]){[self rejectPhotoRequest:@"无法为 Live Photo 创建安全暂存记录"];return;}
   self.captureLiveMeta=meta;self.captureLiveJob=job;self.capturingLive=YES;
   dispatch_async(self.renderQueue,^{self.livePhotoWritten=NO;self.liveMovieWritten=NO;self.liveCaptureError=nil;});
   p.livePhotoMovieFileURL=[self fileForJob:job key:@"sourceMovie"];
   if([self.photoOutput.availableLivePhotoVideoCodecTypes containsObject:AVVideoCodecTypeH264])p.livePhotoVideoCodecType=AVVideoCodecTypeH264;
   dispatch_async(dispatch_get_main_queue(),^{self.recordLabel.text=@"● LIVE 拍摄中";[self status:@"正在拍摄实况 · 请保持稳定"];});
  }
  [self.photoOutput capturePhotoWithSettings:p delegate:self];
 } @catch(NSException *exception) {
  [self rejectPhotoRequest:[NSString stringWithFormat:@"%@：%@",exception.name,exception.reason?:@"系统拒绝了拍照请求"]];
 }
}
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
 if(self.capturingLive){
  NSData *data=error?nil:[photo fileDataRepresentation];NSDictionary *job=self.captureLiveJob;
  dispatch_async(self.renderQueue,^{NSError *writeError=error;NSURL *raw=[self fileForJob:job key:@"source"];BOOL ok=data&&raw&&[data writeToURL:raw options:NSDataWritingAtomic error:&writeError];self.livePhotoWritten=ok;if(!ok)self.liveCaptureError=writeError?:[NSError errorWithDomain:@"MarkCam.LivePhoto" code:2 userInfo:@{NSLocalizedDescriptionKey:@"实况主照片未收到或暂存失败"}];});return;
 }
 self.photoProcessed=YES;NSData *data=error?nil:[photo fileDataRepresentation];if(!data){dispatch_async(dispatch_get_main_queue(),^{self.busy=NO;[self updateControls];[self alert:@"拍照失败" message:error.localizedDescription?:@"没有收到照片数据。"];});return;}
 NSDictionary *settings=self.captureSettings;NSDate *date=self.captureDate;
 dispatch_async(self.renderQueue,^{NSString *ident=MCID();NSURL *dir=[self pendingDirectory],*raw=[dir URLByAppendingPathComponent:[ident stringByAppendingString:@"-raw.jpg"]],*meta=[dir URLByAppendingPathComponent:[ident stringByAppendingString:@".job.json"]];NSError *e=nil;
 if(![data writeToURL:raw options:NSDataWritingAtomic error:&e]){dispatch_async(dispatch_get_main_queue(),^{self.busy=NO;[self updateControls];[self alert:@"暂存失败" message:e.localizedDescription?:@"请检查剩余空间。"];});return;}
 NSMutableDictionary *job=[@{@"kind":@"photo",@"stage":@"raw",@"source":raw.lastPathComponent,@"output":[ident stringByAppendingString:@".jpg"],@"settings":settings,@"date":@([date timeIntervalSince1970])}mutableCopy];[self writeJob:job URL:meta];dispatch_async(dispatch_get_main_queue(),^{self.activeMetaURL=meta;[self processJob:job meta:meta];});});
}
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingLivePhotoToMovieFileAtURL:(NSURL *)url duration:(CMTime)duration photoDisplayTime:(CMTime)photoDisplayTime resolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings error:(NSError *)error {
 NSDictionary *job=self.captureLiveJob;
 dispatch_async(self.renderQueue,^{NSNumber *bytes=nil;[url getResourceValue:&bytes forKey:NSURLFileSizeKey error:nil];NSURL *expected=[self fileForJob:job key:@"sourceMovie"];self.liveMovieWritten=!error&&[url.path isEqual:expected.path]&&bytes.unsignedLongLongValue>1024;
 if(!self.liveMovieWritten)self.liveCaptureError=error?:[NSError errorWithDomain:@"MarkCam.LivePhoto" code:3 userInfo:@{NSLocalizedDescriptionKey:@"实况动态片段未完成"}];});
}
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings error:(NSError *)error {
 if(self.capturingLive){
  NSDictionary *snapshot=self.captureLiveJob;NSURL *meta=self.captureLiveMeta;
  dispatch_async(self.renderQueue,^{NSMutableDictionary *job=[snapshot mutableCopy];NSError *failure=error?:self.liveCaptureError;BOOL ready=self.livePhotoWritten&&self.liveMovieWritten&&!failure;job[@"stage"]=ready?@"raw":@"incomplete";if(failure)job[@"captureError"]=failure.localizedDescription;[self writeJob:job URL:meta];
   dispatch_async(dispatch_get_main_queue(),^{self.capturingLive=NO;self.photoProcessed=YES;self.recordLabel.text=@"";if(!ready||self.inBackground){self.busy=NO;[self updateControls];[self status:ready?@"实况原片已暂存，可在待保存继续":@"实况未完成，已有素材均保留"];if(!ready)[self alert:@"实况拍摄未完成" message:failure.localizedDescription?:@"未收到完整照片与动态片段；未按普通照片静默保存。"];return;}[self processJob:job meta:meta];});
  });return;
 }
 if(!self.photoProcessed){self.photoProcessed=YES;dispatch_async(dispatch_get_main_queue(),^{self.busy=NO;[self updateControls];[self alert:@"拍摄未完成" message:error.localizedDescription?:@"系统没有返回照片，请重试。"];});}
}
- (void)captureOutput:(AVCaptureFileOutput *)output didStartRecordingToOutputFileAtURL:(NSURL *)url fromConnections:(NSArray<AVCaptureConnection *> *)connections {
 dispatch_async(dispatch_get_main_queue(),^{self.recording=YES;self.recordDate=self.captureDate;[self updateControls];[self updateOverlay];[self status:@"录制中 · 点击停止后自动合成"];if(self.inBackground)[self.movieOutput stopRecording];});
}
- (void)captureOutput:(AVCaptureFileOutput *)output didFinishRecordingToOutputFileAtURL:(NSURL *)url fromConnections:(NSArray<AVCaptureConnection *> *)connections error:(NSError *)error {
 dispatch_async(self.sessionQueue,^{AVCaptureDevice *d=self.cameraInput.device;NSError *e=nil;if(d.hasTorch&&[d lockForConfiguration:&e]){d.torchMode=AVCaptureTorchModeOff;[d unlockForConfiguration];}});
 dispatch_async(dispatch_get_main_queue(),^{self.recording=NO;self.recordLabel.text=@"";[self updateControls];NSData *d=[NSData dataWithContentsOfURL:self.activeMetaURL];NSMutableDictionary *job=d?[[NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil]mutableCopy]:nil;
 BOOL success=!error||[error.userInfo[AVErrorRecordingSuccessfullyFinishedKey]boolValue];NSNumber *size=nil;[url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];if(!success||size.longLongValue<1024||!job){self.busy=NO;[self updateControls];[self alert:@"录像未正常完成" message:[NSString stringWithFormat:@"%@\n已保留可用的临时文件，可在“待保存”中重试或导出。",error.localizedDescription?:@"数据不完整"]];return;}
 if(self.inBackground){self.busy=NO;[self updateControls];[self status:@"录像已暂存，回前台后到“待保存”完成合成"];return;}[self processJob:job meta:self.activeMetaURL];});
}
- (void)processLiveJob:(NSMutableDictionary *)job meta:(NSURL *)meta {
 NSURL *source=[self fileForJob:job key:@"source"],*movie=[self fileForJob:job key:@"sourceMovie"],*dest=[self fileForJob:job key:@"output"],*destMovie=[self fileForJob:job key:@"outputMovie"];
 BOOL valid=source&&movie&&dest&&destMovie&&[job[@"settings"]isKindOfClass:NSDictionary.class]&&[job[@"date"]isKindOfClass:NSNumber.class]&&isfinite([job[@"date"]doubleValue]);
 if(!valid||[NSSet setWithArray:@[source?:NSNull.null,movie?:NSNull.null,dest?:NSNull.null,destMovie?:NSNull.null]].count!=4){self.busy=NO;[self updateControls];[self alert:@"实况恢复信息损坏" message:@"请从文件 App 导出原始照片和 MOV 文件。"];return;}
 if([job[@"stage"]isEqual:@"saved"]){[self cleanupJob:job meta:meta];self.busy=NO;[self updateControls];return;}
 self.busy=YES;self.activeMetaURL=meta;[self updateControls];BOOL ready=[job[@"stage"]isEqual:@"ready"]&&[NSFileManager.defaultManager fileExistsAtPath:dest.path]&&[NSFileManager.defaultManager fileExistsAtPath:destMovie.path];if(ready){[self saveJob:job meta:meta];return;}
 for(NSString *k in @[@"source",@"sourceMovie"]){NSURL *u=[self fileForJob:job key:k];NSNumber *bytes=nil;[u getResourceValue:&bytes forKey:NSURLFileSizeKey error:nil];if(!bytes||bytes.unsignedLongLongValue<1024||bytes.unsignedLongLongValue>512ULL*1024*1024){self.busy=NO;[self updateControls];[self alert:@"实况素材无效" message:@"资源为空、过大或缺失；原文件保留，可从文件 App 导出。"];return;}}
 if(![NSFileManager.defaultManager fileExistsAtPath:source.path]||![NSFileManager.defaultManager fileExistsAtPath:movie.path]){self.busy=NO;[self updateControls];[self alert:@"实况资源不完整" message:@"缺少主照片或动态片段。已有素材仍在待保存目录，不会静默转换为普通照片。"];return;}
 for(NSURL *u in @[dest,destMovie]){if([NSFileManager.defaultManager fileExistsAtPath:u.path]){NSError *error=nil;if(![NSFileManager.defaultManager removeItemAtURL:u error:&error]){self.busy=NO;[self updateControls];[self alert:@"无法重试实况处理" message:error.localizedDescription];return;}}}
 job[@"stage"]=@"raw";[self writeJob:job URL:meta];[self status:@"正在合成 Live Photo · 请保持前台"];self.progress.hidden=NO;self.cancelExportButton.hidden=NO;self.progress.progress=0;
 self.liveProcessor=[MCLivePhotoProcessor new];NSDate *date=[NSDate dateWithTimeIntervalSince1970:[job[@"date"]doubleValue]];
 [self.liveProcessor processPhoto:source movie:movie outputPhoto:dest outputMovie:destMovie settings:job[@"settings"] date:date completion:^(NSError *error){self.liveProcessor=nil;self.progress.hidden=YES;self.cancelExportButton.hidden=YES;
  if(error){self.busy=NO;[self updateControls];[self status:@"实况合成未完成，原始配对资源保留"];[self alert:@"Live Photo 未完成" message:error.localizedDescription];return;}
  job[@"stage"]=@"ready";[self writeJob:job URL:meta];[self saveJob:job meta:meta];
 }];
}
- (void)processJob:(NSMutableDictionary *)job meta:(NSURL *)meta {
 if([job isKindOfClass:NSDictionary.class]&&[job[@"kind"]isEqual:@"live"]){[self processLiveJob:job meta:meta];return;}
 NSURL *source=[self fileForJob:job key:@"source"],*dest=[self fileForJob:job key:@"output"];if(!source||!dest||[source.path isEqual:dest.path]||![@[@"photo",@"video"] containsObject:job[@"kind"]]||![@[@"raw",@"ready",@"saved"] containsObject:job[@"stage"]]||![job[@"date"]isKindOfClass:NSNumber.class]||!isfinite([job[@"date"]doubleValue])||![job[@"settings"]isKindOfClass:NSDictionary.class]){self.busy=NO;[self updateControls];[self alert:@"无法恢复" message:@"恢复信息损坏；请用文件 App 导出原始文件。"];return;}
 self.busy=YES;self.activeMetaURL=meta;[self updateControls];if([job[@"stage"]isEqual:@"raw"]&&[NSFileManager.defaultManager fileExistsAtPath:dest.path]){NSError *cleanupError=nil;if(![NSFileManager.defaultManager removeItemAtURL:dest error:&cleanupError]){self.busy=NO;[self updateControls];[self alert:@"无法重试" message:cleanupError.localizedDescription?:@"无法清理上次未完成的合成文件，原片未删除。"];return;}}if([job[@"stage"]isEqual:@"ready"]&&[NSFileManager.defaultManager fileExistsAtPath:dest.path]){[self saveJob:job meta:meta];return;}
 if([job[@"stage"]isEqual:@"saved"]){[self cleanupJob:job meta:meta];self.busy=NO;[self updateControls];[self status:@"此前已保存，已清理暂存文件"];return;}
 NSDate *date=[NSDate dateWithTimeIntervalSince1970:[job[@"date"]doubleValue]];NSDictionary *settings=job[@"settings"];
 if([job[@"kind"]isEqual:@"video"]){[self status:@"正在合成视频，请保持前台；原片已安全暂存"];self.progress.hidden=NO;self.progress.progress=0;self.cancelExportButton.hidden=NO;__weak typeof(self) weak=self;
 self.exportSession=[[WMEngine shared]exportVideo:source destination:dest settings:settings date:date completion:^(NSError *e){CameraViewController *strong=weak;if(!strong)return;strong.exportSession=nil;strong.progress.hidden=YES;strong.cancelExportButton.hidden=YES;if(e){strong.busy=NO;[strong updateControls];[strong status:@"合成未完成，原片保留在待保存"];if(!strong.inBackground)[strong alert:@"视频合成未完成" message:e.localizedDescription];return;}job[@"stage"]=@"ready";[strong writeJob:job URL:meta];[strong saveJob:job meta:meta];}];
 }else{[self status:@"正在调色并合成水印…"];dispatch_async(self.renderQueue,^{@autoreleasepool{UIImage *image=[UIImage imageWithContentsOfFile:source.path];if(!image){dispatch_async(dispatch_get_main_queue(),^{self.busy=NO;[self updateControls];[self alert:@"原片不可读" message:@"原片数据可能不完整，文件仍保留在待保存目录。"];});return;}UIImage *result=[[WMEngine shared]processPhoto:image settings:settings date:date];NSData *data=result?UIImageJPEGRepresentation(result,.96):nil;NSError *e=nil;BOOL ok=data&&[data writeToURL:dest options:NSDataWritingAtomic error:&e];dispatch_async(dispatch_get_main_queue(),^{if(!ok){self.busy=NO;[self updateControls];[self alert:@"合成失败" message:e.localizedDescription?:@"无法生成照片，原片已保留。"];return;}job[@"stage"]=@"ready";[self writeJob:job URL:meta];[self saveJob:job meta:meta];});}});}
}
- (void)saveJob:(NSMutableDictionary *)job meta:(NSURL *)meta {
 if(self.inBackground){self.busy=NO;[self updateControls];[self status:@"成品已暂存，回前台后可继续保存"];return;}[self status:@"正在保存到系统相册…"];
 [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus st){dispatch_async(dispatch_get_main_queue(),^{if(st!=PHAuthorizationStatusAuthorized&&st!=PHAuthorizationStatusLimited){self.busy=NO;[self updateControls];[self status:@"相册权限未开启，成品已保留在待保存"];[self permissionAlert:@"保存成片需要“添加照片”权限。拒绝不会删除作品，可在“待保存”中分享或重试。"];return;}NSURL *dest=[self fileForJob:job key:@"output"],*raw=[self fileForJob:job key:@"source"];BOOL video=[job[@"kind"]isEqual:@"video"],live=[job[@"kind"]isEqual:@"live"],keep=[job[@"settings"][@"keepOriginal"]boolValue];NSURL *paired=[self fileForJob:job key:@"outputMovie"],*rawPaired=[self fileForJob:job key:@"sourceMovie"];NSDate *date=[NSDate dateWithTimeIntervalSince1970:[job[@"date"]doubleValue]];
 [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{PHAssetCreationRequest *r=[PHAssetCreationRequest creationRequestForAsset];r.creationDate=date;PHAssetResourceCreationOptions *o=[PHAssetResourceCreationOptions new];o.shouldMoveFile=NO;[r addResourceWithType:video?PHAssetResourceTypeVideo:PHAssetResourceTypePhoto fileURL:dest options:o];if(live)[r addResourceWithType:PHAssetResourceTypePairedVideo fileURL:paired options:o];if(keep){PHAssetCreationRequest *original=[PHAssetCreationRequest creationRequestForAsset];original.creationDate=date;PHAssetResourceCreationOptions *opt=[PHAssetResourceCreationOptions new];opt.shouldMoveFile=NO;[original addResourceWithType:video?PHAssetResourceTypeVideo:PHAssetResourceTypePhoto fileURL:raw options:opt];if(live)[original addResourceWithType:PHAssetResourceTypePairedVideo fileURL:rawPaired options:opt];}} completionHandler:^(BOOL ok,NSError *e){dispatch_async(dispatch_get_main_queue(),^{self.busy=NO;[self updateControls];if(ok){job[@"stage"]=@"saved";[self writeJob:job URL:meta];[self cleanupJob:job meta:meta];[self status:live?(keep?@"已保存实况成片与原片 ✓":@"Live Photo 已保存 · 到相册长按播放"):keep?@"已保存成片与原片 ✓":@"已保存到系统相册 ✓"];UIImpactFeedbackGenerator *f=[[UIImpactFeedbackGenerator alloc]initWithStyle:UIImpactFeedbackStyleLight];[f impactOccurred];}else{[self status:@"保存失败，成品未删除，可重试"];[self alert:@"相册保存失败" message:e.localizedDescription?:@"请检查相册权限及剩余存储空间。"];}});}];});}];
}
- (void)cleanupJob:(NSDictionary *)job meta:(NSURL *)meta {
 for(NSString *key in @[@"source",@"output",@"sourceMovie",@"outputMovie"]){NSURL *u=[self fileForJob:job key:key];if(u)[NSFileManager.defaultManager removeItemAtURL:u error:nil];}[NSFileManager.defaultManager removeItemAtURL:meta error:nil];
}
- (void)cancelExport {[self.exportSession cancelExport];[self.liveProcessor cancel];[self status:@"已请求取消，原片仍保留"];}
- (void)anchor:(UIViewController *)vc button:(UIView *)b {if(vc.popoverPresentationController){vc.popoverPresentationController.sourceView=b;vc.popoverPresentationController.sourceRect=b.bounds;}}
- (void)showFiles {
 NSArray<NSURL *> *files=[NSFileManager.defaultManager contentsOfDirectoryAtURL:[self pendingDirectory] includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:0 error:nil];NSMutableArray<NSURL *> *jobs=[NSMutableArray new];for(NSURL *u in files)if([u.lastPathComponent hasSuffix:@".job.json"])[jobs addObject:u];[jobs sortUsingComparator:^NSComparisonResult(NSURL *a,NSURL *b){NSDate *da=nil,*db=nil;[a getResourceValue:&da forKey:NSURLContentModificationDateKey error:nil];[b getResourceValue:&db forKey:NSURLContentModificationDateKey error:nil];return [db compare:da];}];
 UIAlertController *a=[UIAlertController alertControllerWithTitle:@"待保存作品" message:jobs.count?@"系统相册保存成功后，暂存文件自动清理。":@"没有待保存作品。已保存的成片请在系统“照片”中查看。" preferredStyle:UIAlertControllerStyleActionSheet];NSUInteger count=0;for(NSURL *u in jobs){if(count++>=15)break;NSDictionary *j=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:u]?:NSData.data options:0 error:nil];NSString *t=[NSString stringWithFormat:@"%@ · %@",[j[@"kind"]isEqual:@"video"]?@"视频":([j[@"kind"]isEqual:@"live"]?@"实况":@"照片"),[NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:[j[@"date"]doubleValue]] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle]];[a addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault handler:^(UIAlertAction *act){[self showJob:u];}]];}
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
 NSData *d=[NSData dataWithContentsOfURL:meta];NSMutableDictionary *job=d?[NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil]:nil;if(!job){[self alert:@"无法读取记录" message:@"可通过文件 App 的“我的 iPhone → 印记相机 → Pending”查找原始文件。"];return;}
 NSURL *output=[self fileForJob:job key:@"output"],*source=[self fileForJob:job key:@"source"];BOOL hasShare=([NSFileManager.defaultManager fileExistsAtPath:output.path]||[NSFileManager.defaultManager fileExistsAtPath:source.path]);if([job[@"kind"]isEqual:@"live"])hasShare=hasShare||[NSFileManager.defaultManager fileExistsAtPath:[self fileForJob:job key:@"sourceMovie"].path];
 UIAlertController *a=[UIAlertController alertControllerWithTitle:@"作品恢复" message:@"重试使用拍摄当时的模板与时间。分享只导出文件，不自动删除暂存。" preferredStyle:UIAlertControllerStyleActionSheet];[a addAction:[UIAlertAction actionWithTitle:@"重试合成 / 保存相册" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self processJob:job meta:meta];}]];if(hasShare)[a addAction:[UIAlertAction actionWithTitle:[job[@"kind"]isEqual:@"live"]?@"导出实况资源文件（照片 + MOV）":@"分享已有成品或原片" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self shareJob:job];}]];[a addAction:[UIAlertAction actionWithTitle:@"删除此暂存作品…" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){UIAlertController *q=[UIAlertController alertControllerWithTitle:@"永久删除暂存？" message:@"如果尚未保存或分享，作品将无法恢复。" preferredStyle:UIAlertControllerStyleAlert];[q addAction:[UIAlertAction actionWithTitle:@"保留" style:UIAlertActionStyleCancel handler:nil]];[q addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *v){[self cleanupJob:job meta:meta];[self status:@"已删除此暂存作品"]; }]];[self presentViewController:q animated:YES completion:nil];}]];[a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[self anchor:a button:self.filesButton];[self presentViewController:a animated:YES completion:nil];
}
- (void)tick {
 if(self.recording){NSInteger sec=(NSInteger)(-[self.recordDate timeIntervalSinceNow]);self.recordLabel.text=[NSString stringWithFormat:@"● %02ld:%02ld",(long)(sec/60),(long)(sec%60)];}else if(!self.busy&&!self.editorShown&&!self.inBackground)[self updateOverlay];if(self.exportSession)self.progress.progress=self.exportSession.progress;if(self.liveProcessor)self.progress.progress=self.liveProcessor.progress;
}
- (void)background:(NSNotification *)n {
 self.inBackground=YES;self.countdownGeneration++;if(self.countdownLabel.text.length){self.countdownLabel.text=@"";self.busy=NO;}[self.exportSession cancelExport];[self.liveProcessor cancel];dispatch_async(self.sessionQueue,^{if(self.movieOutput.isRecording)[self.movieOutput stopRecording];[self.session stopRunning];});[self updateControls];UIApplication.sharedApplication.idleTimerDisabled=NO;
}
- (void)foreground:(NSNotification *)n {
 self.inBackground=NO;[self refreshSettings];if(!self.configured){[self requestCamera];return;}dispatch_async(self.sessionQueue,^{if(!self.editorShown)[self.session startRunning];});[self updateControls];
}
- (void)interrupted:(NSNotification *)n {[self status:@"相机暂时被系统中断，录像原片将保留"];}
- (void)interruptionEnded:(NSNotification *)n {dispatch_async(self.sessionQueue,^{if(!self.inBackground&&!self.editorShown)[self.session startRunning];});[self status:@"相机已恢复"];}
- (void)runtimeError:(NSNotification *)n {NSError *e=n.userInfo[AVCaptureSessionErrorKey];[self status:e.localizedDescription?:@"相机出现系统错误"];if(e.code==AVErrorMediaServicesWereReset)dispatch_async(self.sessionQueue,^{if(!self.inBackground&&!self.editorShown)[self.session startRunning];});}
- (BOOL)shouldAutorotate {return !self.busy&&!self.recording;}
- (UIStatusBarStyle)preferredStatusBarStyle {return UIStatusBarStyleLightContent;}
- (void)dealloc {[[NSNotificationCenter defaultCenter]removeObserver:self];[self.clockTimer invalidate];[self.videoOutput setSampleBufferDelegate:nil queue:NULL];}
@end
