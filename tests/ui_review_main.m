// Simulator-only UIKit harness. This file is never compiled into the release IPA.
// The geometric scene is a labelled fixture, not a photograph or camera test.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>
#import <AVFoundation/AVFoundation.h>
#import "CameraViewController.h"
#import "WMEditorViewController.h"
#import "WMEngine.h"
#import "MCInterface.h"
#import "MCProcessingQueue.h"

@interface CameraViewController (ReviewAccess)
- (void)updateControls;
- (void)requestCamera;
- (void)modeChanged;
- (void)capturePressed;
- (void)resumeCameraSession;
- (void)configure;
- (void)configureLiveMode;
- (void)configurePhotoResolution;
- (void)applyConnections;
- (BOOL)applicationIsActive;
- (AVAuthorizationStatus)cameraAuthorizationStatus;
- (void)didBecomeActive:(NSNotification *)notification;
- (void)willResignActive:(NSNotification *)notification;
- (void)background:(NSNotification *)notification;
- (void)foreground:(NSNotification *)notification;
- (void)runtimeError:(NSNotification *)notification;
@end
@interface WMEditorViewController (ReviewAccess)
- (NSInteger)sourceSectionForVisibleSection:(NSInteger)section;
- (void)sliderChanged:(UISlider *)slider;
- (void)flushContinuousChanges;
@end

static NSMutableArray *checks;
static NSUInteger saveCount;
static NSUInteger glassFactoryCalls;
static id (*originalGlassFactory)(id,SEL);
static id countedGlassFactory(id cls,SEL sel) {glassFactoryCalls++;return originalGlassFactory(cls,sel);}
static void (*originalSave)(id,SEL);
static void countedSave(id engine,SEL selector) { saveCount++;originalSave(engine,selector); }
static void Check(NSString *name,BOOL passed) { [checks addObject:@{@"check":name,@"passed":@(passed)}]; }

static UIImage *Fixture(void) {
    UIGraphicsImageRendererFormat *format=[UIGraphicsImageRendererFormat defaultFormat];format.scale=1;format.opaque=YES;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(750,1000) format:format] imageWithActions:^(UIGraphicsImageRendererContext *context){
        CGContextRef c=context.CGContext;
        CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
        NSArray *colors=@[(id)[UIColor colorWithRed:.32 green:.42 blue:.42 alpha:1].CGColor,(id)[UIColor colorWithRed:.09 green:.13 blue:.15 alpha:1].CGColor];
        CGGradientRef gradient=CGGradientCreateWithColors(space,(__bridge CFArrayRef)colors,NULL);
        CGContextDrawLinearGradient(c,gradient,CGPointZero,CGPointMake(750,1000),0);CGGradientRelease(gradient);CGColorSpaceRelease(space);
        [[UIColor colorWithRed:.76 green:.68 blue:.53 alpha:1] setFill];UIRectFill(CGRectMake(0,730,750,270));
        [[UIColor colorWithRed:.83 green:.81 blue:.72 alpha:1] setFill];[[UIBezierPath bezierPathWithRoundedRect:CGRectMake(250,390,235,340) cornerRadius:54] fill];
        [[UIColor colorWithRed:.18 green:.30 blue:.25 alpha:1] setFill];
        for(int i=0;i<5;i++)[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(205+i*30,220+i*25,120,220)] fill];
        [@"模拟取景 · UI 检查" drawAtPoint:CGPointMake(36,120) withAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:22 weight:UIFontWeightMedium],NSForegroundColorAttributeName:UIColor.whiteColor}];
    }];
}

// The simulator has no iPhone process-memory budget. Control that dependency
// here; production admission itself is executed by the native C policy tests.
@interface ReviewQueue : MCProcessingQueue
@property(nonatomic,copy) NSString *reviewBlockReason;
@end
@implementation ReviewQueue
- (NSString *)captureBlockReasonForLive:(BOOL)live reservedCount:(NSUInteger)reserved { return self.reviewBlockReason; }
- (void)tick { }
@end

@interface ReviewCamera : CameraViewController
@property(nonatomic) NSUInteger pressCount;
@end
@implementation ReviewCamera
- (void)requestCamera {
    [(MCProcessingQueue *)[self valueForKey:@"workQueue"] setOnChange:nil];
    [self setValue:[ReviewQueue new] forKey:@"workQueue"];
    [self setValue:@YES forKey:@"configured"];
}
- (void)capturePressed { self.pressCount++; }
- (void)runtimeError:(NSNotification *)notification { /* No sensor in this UI fixture. */ }
- (void)resumeCameraSession {
    // A sensorless Simulator cannot start a real capture session. Keep lifecycle
    // readiness controlled while exercising the production UI state machine.
    [self setValue:@NO forKey:@"busy"];[self setValue:@NO forKey:@"sessionRefreshPending"];[self updateControls];
}
- (void)modeChanged {
    BOOL video=[(UISegmentedControl *)[self valueForKey:@"mode"] selectedSegmentIndex]==1;
    [self setValue:@(video) forKey:@"wantsVideo"];
    BOOL landscape=self.view.bounds.size.width>self.view.bounds.size.height;
    [self setValue:[NSValue valueWithCGSize:landscape?(video?CGSizeMake(16,9):CGSizeMake(4,3)):(video?CGSizeMake(9,16):CGSizeMake(3,4))] forKey:@"feedSize"];
    [self updateControls];[self.view setNeedsLayout];
}
- (void)viewDidLoad {
    [super viewDidLoad];UIView *stage=[self valueForKey:@"stage"];
    UIImageView *fixture=[[UIImageView alloc] initWithImage:Fixture()];fixture.frame=stage.bounds;fixture.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;fixture.contentMode=UIViewContentModeScaleToFill;
    [stage insertSubview:fixture belowSubview:[self valueForKey:@"overlay"]];[self updateControls];
}
@end

// Only OS hardware/memory boundaries are replaced. Queue disk scanning,
// requestCamera, lifecycle notifications and resumeCameraSession are production.
@interface RecoveryQueue : MCProcessingQueue
@end
@implementation RecoveryQueue
+ (NSURL *)directory {return [WMEngine.shared.documentsURL URLByAppendingPathComponent:@"RecoveryFixture" isDirectory:YES];}
- (uint64_t)availableCaptureMemory {return 1024ULL*1024*1024;}
@end
@interface LifecycleSession : AVCaptureSession
@property(atomic) BOOL testRunning;
@property(atomic) NSUInteger starts;
@end
@implementation LifecycleSession
- (BOOL)isRunning {return self.testRunning;}
- (void)startRunning {self.starts++;self.testRunning=YES;}
- (void)stopRunning {self.testRunning=NO;}
- (void)beginConfiguration {}
- (void)commitConfiguration {}
@end
@interface LifecycleCamera : CameraViewController
@property(nonatomic,strong) LifecycleSession *testSession;
@property(nonatomic) NSUInteger configurations;
@end
@implementation LifecycleCamera
- (BOOL)applicationIsActive {return NO;} // view loads before cold-launch activation
- (AVAuthorizationStatus)cameraAuthorizationStatus {return AVAuthorizationStatusAuthorized;}
- (void)configure {
 self.configurations++;
 self.testSession=[LifecycleSession new];[self setValue:self.testSession forKey:@"session"];
 [(MCProcessingQueue *)[self valueForKey:@"workQueue"] setOnChange:nil];
 [self setValue:[ReviewQueue new] forKey:@"workQueue"];
 [self setValue:@YES forKey:@"configured"];[self resumeCameraSession];
}
- (void)configureLiveMode {}
- (void)configurePhotoResolution {}
- (void)applyConnections {}
- (void)runtimeError:(NSNotification *)notification {[super runtimeError:notification];}
@end

@interface ReviewSlider : UISlider
@property(nonatomic) BOOL handTracking;
@end
@implementation ReviewSlider
- (BOOL)isTracking { return self.handTracking; }
@end

@interface ReviewHost : UIViewController
@property(nonatomic,strong) UIViewController *content;
- (void)show:(UIViewController *)controller;
@end
@implementation ReviewHost
- (void)show:(UIViewController *)controller {
    if(self.content){[self.content willMoveToParentViewController:nil];[self.content.view removeFromSuperview];[self.content removeFromParentViewController];}
    self.content=controller;[self addChildViewController:controller];controller.view.frame=self.view.bounds;controller.view.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;[self.view addSubview:controller.view];[controller didMoveToParentViewController:self];
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAllButUpsideDown; }
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
@end

@interface ReviewScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) ReviewHost *host;
@property(nonatomic,strong) ReviewCamera *camera;
@property(nonatomic,strong) WMEditorViewController *editor;
@property(nonatomic,strong) NSURL *directory;
@property(nonatomic,strong) NSMutableArray *screenshots;
@property(nonatomic) NSInteger step;
@property(nonatomic,strong) RecoveryQueue *recoveryQueue;
@property(nonatomic,strong) LifecycleCamera *lifecycleCamera;
@end
@implementation ReviewScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    checks=[NSMutableArray new];self.screenshots=[NSMutableArray new];
    NSInteger launches=[NSUserDefaults.standardUserDefaults integerForKey:@"reviewLaunches"]+1;
    [NSUserDefaults.standardUserDefaults setInteger:launches forKey:@"reviewLaunches"];
    [NSUserDefaults.standardUserDefaults synchronize];
    if(@available(iOS 26.0,*)){
        Method method=class_getClassMethod(UIButtonConfiguration.class,@selector(glassButtonConfiguration));
        originalGlassFactory=(void *)method_getImplementation(method);method_setImplementation(method,(IMP)countedGlassFactory);
    }
    Method save=class_getInstanceMethod(WMEngine.class,@selector(save));originalSave=(void *)method_getImplementation(save);method_setImplementation(save,(IMP)countedSave);
    self.directory=[[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"UIReview" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:self.directory withIntermediateDirectories:YES attributes:nil error:nil];
    self.window=[[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];self.window.overrideUserInterfaceStyle=UIUserInterfaceStyleLight;self.window.tintColor=MCInterfaceAccent();
    self.host=[ReviewHost new];self.window.rootViewController=self.host;[self.window makeKeyAndVisible];
    self.camera=[ReviewCamera new];[self.host show:self.camera];
    [self nextAfter:1];
}
- (void)nextAfter:(double)seconds { dispatch_after(dispatch_time(DISPATCH_TIME_NOW,seconds*NSEC_PER_SEC),dispatch_get_main_queue(),^{[self runStep];}); }
- (void)snapshot:(NSString *)name {
    [self.window layoutIfNeeded];
    UIGraphicsImageRendererFormat *format=[UIGraphicsImageRendererFormat defaultFormat];format.scale=2;format.opaque=YES;
    UIImage *image=[[[UIGraphicsImageRenderer alloc] initWithSize:self.window.bounds.size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context){[self.window drawViewHierarchyInRect:self.window.bounds afterScreenUpdates:YES];}];
    NSString *file=[name stringByAppendingString:@".png"];
    Check([@"Screenshot " stringByAppendingString:name],[UIImagePNGRepresentation(image) writeToURL:[self.directory URLByAppendingPathComponent:file] atomically:YES]);
    [self.screenshots addObject:@{@"file":file,@"width":@(image.size.width),@"height":@(image.size.height),@"fixture":@YES}];
}
- (void)checkCamera:(NSString *)name {
    [self.camera.view layoutIfNeeded];
    if(@available(iOS 26.0,*)){
        UIButton *tool=[self.camera valueForKey:@"settingsButton"];
        Check(@"iOS 26 native glass configuration is installed",tool.configuration!=nil&&glassFactoryCalls>=6);
        Check(@"Native glass has no custom blur behind it",[tool valueForKey:@"fallbackMaterial"]==nil);
    }
    for(NSString *key in @[@"shutter",@"filesButton",@"switchButton",@"editButton",@"watermarkButton",@"settingsButton",@"liveButton",@"mode",@"lensSelector",@"zoomSlider"]){
        UIView *view=[self.camera valueForKey:key];CGRect rect=[view convertRect:view.bounds toView:self.camera.view];
        Check([NSString stringWithFormat:@"%@ %@ 44pt target",name,key],view.bounds.size.width>=43.9&&view.bounds.size.height>=43.9);
        Check([NSString stringWithFormat:@"%@ %@ onscreen",name,key],CGRectContainsRect(CGRectInset(self.camera.view.bounds,-.1,-.1),rect));
    }
    UIButton *shutter=[self.camera valueForKey:@"shutter"];Check([name stringByAppendingString:@" shutter ready"],shutter.enabled);
    if(!shutter.enabled) NSLog(@"UI readiness: busy=%@ configured=%@ inactive=%@ background=%@ editor=%@ block=%@",[self.camera valueForKey:@"busy"],[self.camera valueForKey:@"configured"],[self.camera valueForKey:@"applicationInactive"],[self.camera valueForKey:@"inBackground"],[self.camera valueForKey:@"editorShown"],[self.camera valueForKey:@"captureBlockMessage"]);
    NSUInteger initial=self.camera.pressCount;
    for(int i=0;i<100;i++){shutter.highlighted=YES;[shutter sendActionsForControlEvents:UIControlEventTouchUpInside];shutter.highlighted=NO;}
    Check([name stringByAppendingString:@" 100 immediate UIKit action deliveries"],self.camera.pressCount==initial+100);
    Check([name stringByAppendingString:@" shutter has no queued animations"],shutter.layer.animationKeys.count==0);
    [self.camera setValue:@YES forKey:@"busy"];[self.camera updateControls];Check(@"Busy capture disables the shutter",!shutter.enabled);
    [self.camera setValue:@NO forKey:@"busy"];[self.camera updateControls];Check(@"Capture completion restores the shutter",shutter.enabled);
    ReviewQueue *queue=[self.camera valueForKey:@"workQueue"];queue.reviewBlockReason=@"模拟队列等待";[self.camera updateControls];Check(@"Queue backpressure disables the shutter",!shutter.enabled);
    queue.reviewBlockReason=nil;[self.camera updateControls];Check(@"Queue recovery restores the shutter",shutter.enabled);
}
- (void)selectTab:(NSInteger)index {
    UISegmentedControl *picker=[self.editor valueForKey:@"sectionPicker"];picker.selectedSegmentIndex=index;[picker sendActionsForControlEvents:UIControlEventValueChanged];
}
- (void)checkEditorTab:(NSInteger)tab {
    UITableView *table=[self.editor valueForKey:@"table"];
    Check([NSString stringWithFormat:@"Tab %ld contains only relevant sections",(long)tab],table.numberOfSections==(tab==0?2:1));
    for(NSInteger section=0;section<table.numberOfSections;section++){
        Check(@"Visible section keeps its model identity",[self.editor sourceSectionForVisibleSection:section]==(tab==0?section:tab+1));
        Check(@"Visible section contains rows",[table numberOfRowsInSection:section]>0);
    }
    CGRect first=[table rectForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    Check(@"First tool row starts near the picker",first.origin.y-table.contentOffset.y<90);
    Check([NSString stringWithFormat:@"Tab %ld leaves usable scroll area",(long)tab],table.bounds.size.height>120);
    UIView *picker=[self.editor valueForKey:@"sectionPicker"];Check(@"Editor picker has 44pt hit area",picker.bounds.size.height>=43.9);
}
- (void)testContinuousEdits {
    UITableView *table=[self.editor valueForKey:@"table"];
    UITableViewCell *cell=[table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:0]];
    NSMutableArray *views=[NSMutableArray arrayWithArray:cell.contentView.subviews];UISlider *visibleSlider=nil;
    while(views.count){UIView *view=views.lastObject;[views removeLastObject];if([view isKindOfClass:UISlider.class]){visibleSlider=(UISlider *)view;break;}[views addObjectsFromArray:view.subviews];}
    Check(@"Visible tone slider has value-change action",[[visibleSlider actionsForTarget:self.editor forControlEvent:UIControlEventValueChanged] containsObject:@"sliderChanged:"]);
    for(NSNumber *event in @[@(UIControlEventTouchUpInside),@(UIControlEventTouchUpOutside),@(UIControlEventTouchCancel)])
        Check(@"Visible tone slider persists on release or cancellation",[[visibleSlider actionsForTarget:self.editor forControlEvent:event.unsignedIntegerValue] containsObject:@"flushContinuousChanges"]);
    ReviewSlider *slider=[ReviewSlider new];slider.tag=2;slider.accessibilityIdentifier=@"brightness";slider.minimumValue=-.3;slider.maximumValue=.3;slider.handTracking=YES;
    NSUInteger initial=saveCount;
    for(int i=0;i<50;i++){slider.value=-.25+i*.01;[self.editor sliderChanged:slider];}
    Check(@"50 drag updates do not write settings to disk",saveCount==initial);
    Check(@"Drag changes the live settings immediately",fabs([WMEngine.shared.settings[@"tone"][@"brightness"] doubleValue]-slider.value)<.0001);
    [self.editor flushContinuousChanges];Check(@"Gesture completion saves once",saveCount==initial+1);
    [self.editor flushContinuousChanges];Check(@"Repeated completion is idempotent",saveCount==initial+1);
    slider.handTracking=NO;slider.value=0;[self.editor sliderChanged:slider];Check(@"VoiceOver-style discrete adjustment saves immediately",saveCount==initial+2);
    slider.handTracking=YES;slider.value=.1;[self.editor sliderChanged:slider];
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationWillResignActiveNotification object:nil];
    Check(@"Interruption flushes unfinished drag",saveCount==initial+3);
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
    slider.handTracking=NO;slider.value=0;[self.editor sliderChanged:slider];
}
- (void)runStep {
    @try {
        switch(self.step++) {
            case 0: [self checkCamera:@"Portrait photo"];[self snapshot:@"01-camera-photo"];
                [(UISegmentedControl *)[self.camera valueForKey:@"mode"] setSelectedSegmentIndex:1];[[self.camera valueForKey:@"mode"] sendActionsForControlEvents:UIControlEventValueChanged];break;
            case 1: [self checkCamera:@"Portrait video"];[self snapshot:@"02-camera-video"];
                [self.host setNeedsUpdateOfSupportedInterfaceOrientations];
                [self.window.windowScene requestGeometryUpdateWithPreferences:[[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:UIInterfaceOrientationMaskLandscapeRight] errorHandler:^(NSError *error){Check(@"Landscape rotation accepted",NO);}];break;
            case 2: [self.camera modeChanged];[self.window layoutIfNeeded];break;
            case 3: Check(@"Simulator rotated to landscape",self.window.bounds.size.width>self.window.bounds.size.height);[self checkCamera:@"Landscape video"];[self snapshot:@"03-camera-landscape"];
                [self.window.windowScene requestGeometryUpdateWithPreferences:[[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:UIInterfaceOrientationMaskPortrait] errorHandler:^(NSError *error){Check(@"Portrait rotation accepted",NO);}];break;
            case 4: self.editor=[WMEditorViewController new];self.editor.backgroundImage=Fixture();[self.host show:[[UINavigationController alloc] initWithRootViewController:self.editor]];break;
            case 5: [self checkEditorTab:0];[self snapshot:@"04-editor-layers"];[self selectTab:1];break;
            case 6: [self checkEditorTab:1];[self testContinuousEdits];[self snapshot:@"05-editor-tone"];[self selectTab:2];break;
            case 7: [self checkEditorTab:2];[self snapshot:@"06-editor-templates"];[self selectTab:3];break;
            case 8: [self checkEditorTab:3];[self snapshot:@"07-editor-settings"];
                [self.host setOverrideTraitCollection:[UITraitCollection traitCollectionWithPreferredContentSizeCategory:UIContentSizeCategoryAccessibilityExtraExtraExtraLarge] forChildViewController:self.host.content];break;
            case 9: [self checkEditorTab:3];[self snapshot:@"08-editor-accessibility-text"];
                [self.host show:self.camera];[self.camera modeChanged];[[self.camera valueForKey:@"settingsButton"] sendActionsForControlEvents:UIControlEventTouchUpInside];
                Check(@"Settings presents without waiting for a frame",[self.camera.presentedViewController isKindOfClass:UINavigationController.class]);break;
            case 10: {
                UINavigationController *navigation=(UINavigationController *)self.camera.presentedViewController;
                self.editor=(WMEditorViewController *)navigation.topViewController;
                Check(@"Settings opens its own tab directly",[(UISegmentedControl *)[self.editor valueForKey:@"sectionPicker"] selectedSegmentIndex]==3);[self checkEditorTab:3];
                [self snapshot:@"09-editor-direct-settings"];
                [self.camera dismissViewControllerAnimated:NO completion:nil];break;
            }
            case 11: Check(@"Returning from actual settings restores capture",[(UIButton *)[self.camera valueForKey:@"shutter"] isEnabled]);
                [self.host setOverrideTraitCollection:[UITraitCollection traitCollectionWithAccessibilityContrast:UIAccessibilityContrastHigh] forChildViewController:self.camera];[self.camera modeChanged];break;
            case 12: {
                UIButton *tool=[self.camera valueForKey:@"settingsButton"];
                Check(@"High contrast retains a native accessible control",tool.accessibilityLabel.length>0&&tool.bounds.size.width>=44);
                [self snapshot:@"10-camera-high-contrast"];[self beginRecoveryChecks];break;
            }
            case 13: [self checkRecovery:NO];break;
            case 14: [self checkRecovery:YES];[self beginLifecycleChecks];break;
            case 15: [self checkActivatedLifecycle];break;
            case 16: [self checkInactiveLifecycle];break;
            case 17: [self checkReactivatedLifecycle];[self finish];return;
            default: [self finish];return;
        }
        [self nextAfter:.7];
    } @catch(NSException *exception) {
        Check([NSString stringWithFormat:@"Uncaught %@: %@",exception.name,exception.reason],NO);[self finish];
    }
}
- (void)beginRecoveryChecks {
    NSURL *directory=RecoveryQueue.directory;
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSArray *stages=@[@"capturing",@"capturing",@"incomplete",@"incomplete",@"saving",@"saving",@"ready",@"ready",@"raw",@"ready"];
    for(NSUInteger i=0;i<stages.count;i++){
        NSMutableDictionary *job=[@{@"stage":stages[i],@"kind":@"photo",@"date":@0,@"settings":WMEngine.shared.snapshot} mutableCopy];
        if(i==6||i==7)job[@"queueBlocked"]=@YES;
        [MCProcessingQueue writeJob:job URL:[directory URLByAppendingPathComponent:[NSString stringWithFormat:@"%lu.job.json",(unsigned long)i]]];
    }
    self.recoveryQueue=[RecoveryQueue new];[self.recoveryQueue refresh];
}
- (void)checkRecovery:(BOOL)recreated {
    Check(recreated?@"Recreated queue preserves all recovery entries":@"Disk scan preserves interrupted and failed photos",self.recoveryQueue.pendingCount==10);
    Check(@"Only runnable jobs occupy the capture budget",self.recoveryQueue.queuedCount==2);
    Check(@"Six interrupted and two failed jobs do not gray out the shutter",[self.recoveryQueue captureBlockReasonForLive:NO reservedCount:0]==nil);
    NSDictionary *saving=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:[RecoveryQueue.directory URLByAppendingPathComponent:@"4.job.json"]] options:0 error:nil];
    Check(@"Uncertain Photos save is never automatically retried",[saving[@"stage"] isEqual:@"saving"]);
    self.recoveryQueue=[RecoveryQueue new];[self.recoveryQueue refresh];
}
- (void)beginLifecycleChecks {
    self.lifecycleCamera=[LifecycleCamera new];[self.lifecycleCamera loadViewIfNeeded];
    Check(@"Authorized cold launch waits for active state",self.lifecycleCamera.configurations==0);
    [self.lifecycleCamera didBecomeActive:nil];
}
- (void)checkActivatedLifecycle {
    Check(@"Activation configures the previously authorized camera",self.lifecycleCamera.configurations==1);
    Check(@"Activation starts the session",self.lifecycleCamera.testSession.starts==1&&self.lifecycleCamera.testSession.running);
    Check(@"Activation releases the shutter",[(UIButton *)[self.lifecycleCamera valueForKey:@"shutter"] isEnabled]);
    [self.lifecycleCamera willResignActive:nil];[self.lifecycleCamera background:nil];
}
- (void)checkInactiveLifecycle {
    Check(@"Background stops the capture session",!self.lifecycleCamera.testSession.running);
    [self.lifecycleCamera foreground:nil];
    Check(@"willEnterForeground alone does not start an inactive camera",self.lifecycleCamera.testSession.starts==1);
    [self.lifecycleCamera didBecomeActive:nil];
}
- (void)checkReactivatedLifecycle {
    Check(@"Reactivation restarts the existing session",self.lifecycleCamera.configurations==1&&self.lifecycleCamera.testSession.starts==2);
    Check(@"Returning to the app clears stale busy and pending state",![[self.lifecycleCamera valueForKey:@"busy"] boolValue]&&![[self.lifecycleCamera valueForKey:@"sessionRefreshPending"] boolValue]);
    Check(@"Returning to the app restores the shutter",[(UIButton *)[self.lifecycleCamera valueForKey:@"shutter"] isEnabled]);
    [(NSTimer *)[self.lifecycleCamera valueForKey:@"clockTimer"] invalidate];
}
- (void)finish {
    NSUInteger failed=0;for(NSDictionary *check in checks)if(![check[@"passed"] boolValue])failed++;
    NSDictionary *report=@{@"scope":@"Actual UIKit execution on iOS Simulator. Camera callbacks and preview scene are fixtures; no sensor throughput or photo quality measurement.",@"passed":@(checks.count-failed),@"failed":@(failed),@"checks":checks,@"screenshots":self.screenshots,@"device_tested":@NO,@"simulator_tested":@YES,@"os":UIDevice.currentDevice.systemVersion,@"launch_number":@([NSUserDefaults.standardUserDefaults integerForKey:@"reviewLaunches"]),@"native_glass_configurations":@(glassFactoryCalls)};
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToURL:[self.directory URLByAppendingPathComponent:@"ui-review-report.json"] atomically:YES];
}
@end

@interface ReviewApp : UIResponder <UIApplicationDelegate>
@end
@implementation ReviewApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options { return YES; }
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(ReviewApp.class));}}
