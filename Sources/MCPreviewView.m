#import "MCPreviewView.h"
#import "WMEngine.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <CoreImage/CoreImage.h>

@interface MCPreviewView ()
@property(nonatomic,strong) id<MTLCommandQueue> commandQueue;
@property(nonatomic,strong) CIContext *context;
@property(nonatomic,strong) dispatch_semaphore_t slots;
@property(nonatomic,strong) dispatch_queue_t snapshotQueue;
@property(nonatomic,copy) void (^snapshotCompletion)(UIImage *image);
@property(nonatomic) NSUInteger snapshotGeneration;
@property(nonatomic) BOOL snapshotInFlight;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL failureSent;
@property(nonatomic) NSUInteger received,completed,skipped;
@property(nonatomic) CFTimeInterval started,lastCompleted;
@property(nonatomic) double gpuMilliseconds;
@property(nonatomic) CGSize targetSize;
@end

@implementation MCPreviewView
+ (Class)layerClass { return CAMetalLayer.class; }
- (instancetype)initWithFrame:(CGRect)frame {
 if((self=[super initWithFrame:frame])){
  self.opaque=YES;self.userInteractionEnabled=NO;self.backgroundColor=UIColor.clearColor;
  id<MTLDevice> device=MTLCreateSystemDefaultDevice();
  _commandQueue=[device newCommandQueue];_settings=@{};
  if(_commandQueue)_context=[CIContext contextWithMTLCommandQueue:_commandQueue options:@{kCIContextCacheIntermediates:@NO,kCIContextName:@"MarkCam preview"}];
  CAMetalLayer *layer=(CAMetalLayer *)self.layer;layer.device=device;layer.pixelFormat=MTLPixelFormatBGRA8Unorm;layer.framebufferOnly=NO;layer.maximumDrawableCount=3;layer.allowsNextDrawableTimeout=YES;layer.presentsWithTransaction=NO;
  CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);layer.colorspace=space;CGColorSpaceRelease(space);
  _slots=dispatch_semaphore_create(2);_snapshotQueue=dispatch_queue_create("markcam.preview.snapshot",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0));
 }
 return self;
}
- (BOOL)available {return self.context!=nil&&self.commandQueue!=nil;}
- (void)layoutSubviews {
 [super layoutSubviews];CGFloat w=self.bounds.size.width,h=self.bounds.size.height;if(w<1||h<1)return;
 // Preview only: 1280 long edge cap; full-resolution photo/video pipelines unchanged.
 CGFloat scale=MIN(self.window.screen.scale?:2,1280./MAX(w,h));CGSize size=CGSizeMake(MAX(1,round(w*scale)),MAX(1,round(h*scale)));
 [CATransaction begin];[CATransaction setDisableActions:YES];((CAMetalLayer *)self.layer).drawableSize=size;[CATransaction commit];
 @synchronized(self){self.targetSize=size;}
}
- (void)reset {
 @synchronized(self){self.generation++;self.failureSent=NO;self.received=0;self.completed=0;self.skipped=0;self.started=0;self.lastCompleted=0;self.gpuMilliseconds=0;}
}
- (void)fail:(NSString *)reason generation:(NSUInteger)generation {
 @synchronized(self){if(self.generation!=generation||self.failureSent)return;self.failureSent=YES;}
 dispatch_async(dispatch_get_main_queue(),^{@synchronized(self){if(self.generation!=generation)return;}if(self.onFailure)self.onFailure(reason);});
}
- (void)deliverSnapshot:(UIImage *)image generation:(NSUInteger)generation {
 dispatch_async(dispatch_get_main_queue(),^{void (^done)(UIImage *)=nil;
  @synchronized(self){if(generation!=self.snapshotGeneration)return;done=self.snapshotCompletion;self.snapshotCompletion=nil;self.snapshotInFlight=NO;}
  if(done)done(image);
 });
}
- (void)requestSnapshot:(void (^)(UIImage *))completion {
 NSUInteger generation;@synchronized(self){generation=++self.snapshotGeneration;self.snapshotCompletion=completion;self.snapshotInFlight=NO;}
 // No frame output on a device's movie compatibility path: show the labeled sample instead.
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,700*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[self deliverSnapshot:nil generation:generation];});
}
- (void)takeSnapshotIfRequested:(CVPixelBufferRef)pixel {
 NSUInteger generation;@synchronized(self){if(!self.snapshotCompletion||self.snapshotInFlight)return;self.snapshotInFlight=YES;generation=self.snapshotGeneration;}
 CVPixelBufferRetain(pixel);
 dispatch_async(self.snapshotQueue,^{@autoreleasepool{
  UIImage *image=nil;@try{
   CIImage *input=[CIImage imageWithCVPixelBuffer:pixel];CGFloat scale=MIN(1,720./MAX(input.extent.size.width,input.extent.size.height));input=[input imageByApplyingTransform:CGAffineTransformMakeScale(scale,scale)];
   CIContext *context=self.context?:[CIContext contextWithOptions:@{kCIContextCacheIntermediates:@NO}];
   CGImageRef cg=[context createCGImage:input fromRect:input.extent];if(cg){image=[UIImage imageWithCGImage:cg];CGImageRelease(cg);}
  }@catch(NSException *e){image=nil;}
  CVPixelBufferRelease(pixel);[self deliverSnapshot:image generation:generation];
 }});
}
- (void)submitPixelBuffer:(CVPixelBufferRef)pixel {
 [self takeSnapshotIfRequested:pixel];if(!self.renderingEnabled||!self.available)return;
 NSUInteger generation;CGSize size;
 @synchronized(self){generation=self.generation;size=self.targetSize;self.received++;if(self.started==0)self.started=CACurrentMediaTime();}
 if(size.width<1||size.height<1)return;
 // Drop, never queue stale frames or wait on main. Capture output also discards late frames.
 if(dispatch_semaphore_wait(self.slots,DISPATCH_TIME_NOW)!=0){@synchronized(self){self.skipped++;}return;}
 BOOL submitted=NO;CVPixelBufferRetain(pixel);
 @try {
  if(!self.renderingEnabled)return;
  @synchronized(self){if(self.generation!=generation)return;}
  id<CAMetalDrawable> drawable=[(CAMetalLayer *)self.layer nextDrawable];if(!drawable){@synchronized(self){self.skipped++;}return;}
  size=CGSizeMake(drawable.texture.width,drawable.texture.height);
  CIImage *input=[CIImage imageWithCVPixelBuffer:pixel];CGRect extent=input.extent;
  if(extent.size.width<1||extent.size.height<1)return;
  CGFloat scale=MIN(size.width/extent.size.width,size.height/extent.size.height);
  input=[input imageByApplyingTransform:CGAffineTransformMakeTranslation(-extent.origin.x,-extent.origin.y)];input=[input imageByApplyingTransform:CGAffineTransformMakeScale(scale,scale)];
  input=[input imageByApplyingTransform:CGAffineTransformMakeTranslation((size.width-extent.size.width*scale)/2,(size.height-extent.size.height*scale)/2)];
  CIImage *toned=[[WMEngine shared]applyTone:input settings:self.settings];
  CIImage *black=[[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:1]]imageByCroppingToRect:(CGRect){CGPointZero,size}];
  CIImage *frame=[[toned imageByCompositingOverImage:black]imageByCroppingToRect:(CGRect){CGPointZero,size}];
  if(!self.renderingEnabled)return;
  @synchronized(self){if(self.generation!=generation)return;}
  id<MTLCommandBuffer> command=[self.commandQueue commandBuffer];if(!command){[self fail:@"无法创建GPU指令" generation:generation];return;}
  CIRenderDestination *destination=[[CIRenderDestination alloc]initWithMTLTexture:drawable.texture commandBuffer:command];destination.flipped=YES;destination.alphaMode=CIRenderDestinationAlphaNone;
  NSError *error=nil;CIRenderTask *task=[self.context startTaskToRender:frame toDestination:destination error:&error];
  if(!task){[self fail:error.localizedDescription?:@"GPU取景渲染失败" generation:generation];return;}
  dispatch_semaphore_t slots=self.slots;__weak typeof(self) weak=self;
  // Explicitly keep the CVPixelBuffer-backed CIImage alive until Metal finishes.
  [command addCompletedHandler:^(id<MTLCommandBuffer> done){(void)frame.extent;CVPixelBufferRelease(pixel);dispatch_semaphore_signal(slots);MCPreviewView *view=weak;if(!view)return;
   @synchronized(view){if(view.generation!=generation)return;view.completed++;view.lastCompleted=CACurrentMediaTime();if(done.GPUEndTime>=done.GPUStartTime)view.gpuMilliseconds=(done.GPUEndTime-done.GPUStartTime)*1000;}
   if(done.status==MTLCommandBufferStatusError)[view fail:done.error.localizedDescription?:@"GPU提交失败" generation:generation];
  }];
  [command presentDrawable:drawable];[command commit];submitted=YES;
 }@catch(NSException *e){[self fail:e.reason?:@"GPU取景异常" generation:generation];}
 @finally{if(!submitted){CVPixelBufferRelease(pixel);dispatch_semaphore_signal(self.slots);}}
}
- (NSDictionary *)statistics {
 @synchronized(self){double elapsed=self.started?CACurrentMediaTime()-self.started:0;return @{@"scope":@"GPU submissions/completions, NOT measured display FPS",@"received":@(self.received),@"gpuCompleted":@(self.completed),@"backpressureSkips":@(self.skipped),@"elapsedSeconds":@(elapsed),@"lastGPUms":@(self.gpuMilliseconds),@"completionRate":@(elapsed>0?self.completed/elapsed:0)};}
}
@end
