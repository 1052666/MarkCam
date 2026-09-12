#import "MCPhotoCaptureProcessor.h"
#import "MCProcessingQueue.h"

static NSError *CaptureError(NSString *message) {
 return [NSError errorWithDomain:@"MarkCam.Capture" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
@interface MCPhotoCaptureProcessor ()
@property(nonatomic,strong) dispatch_queue_t diskQueue;
@property(nonatomic,strong) NSURL *meta;
@property(nonatomic,strong) NSMutableDictionary *job;
// Per-request results, confined to diskQueue; never shared with the next shot.
@property(nonatomic) BOOL photoWritten;
@property(nonatomic) BOOL movieWritten;
@property(nonatomic) BOOL finished;
@property(nonatomic,strong) NSError *resourceError;
@end

@implementation MCPhotoCaptureProcessor
- (instancetype)initWithSettings:(NSDictionary *)settings date:(NSDate *)date live:(BOOL)live diskQueue:(dispatch_queue_t)queue {
 if((self=[super init])) {
  _identifier=[NSString stringWithFormat:@"%013lld-%@",(long long)(date.timeIntervalSince1970*1000),NSUUID.UUID.UUIDString];
  _settings=[settings copy];_live=live;_diskQueue=queue;
  _meta=[MCProcessingQueue.directory URLByAppendingPathComponent:[_identifier stringByAppendingString:@".job.json"]];
  _job=[@{@"kind":live?@"live":@"photo",@"stage":@"capturing",@"source":[_identifier stringByAppendingString:@"-raw.jpg"],@"output":[_identifier stringByAppendingString:@".jpg"],@"settings":_settings,@"date":@(date.timeIntervalSince1970)} mutableCopy];
  if(live){_job[@"sourceMovie"]=[_identifier stringByAppendingString:@"-raw.mov"];_job[@"outputMovie"]=[_identifier stringByAppendingString:@".mov"];}
 }
 return self;
}
- (NSURL *)movieURL {return [MCProcessingQueue fileForJob:self.job key:@"sourceMovie"];}
- (BOOL)prepare:(NSError **)error {
 // Called on sessionQueue before submitting to AVFoundation.
 BOOL ok=[MCProcessingQueue writeJob:self.job URL:self.meta];
 if(!ok&&error)*error=CaptureError(@"无法创建拍摄恢复记录，请检查存储空间");
 return ok;
}
- (void)complete:(NSError *)error {
 // diskQueue has drained all data callbacks before this method runs.
 if(self.finished)return;self.finished=YES;
 BOOL ready=self.photoWritten&&(!self.live||self.movieWritten)&&!error;
 if(!ready&&!error)error=CaptureError(@"未收到完整拍摄资源，已有文件保留在待保存");
 self.job[@"stage"]=ready?@"raw":@"incomplete";
 if(error)self.job[@"captureError"]=error.localizedDescription;
 if(![MCProcessingQueue writeJob:self.job URL:self.meta]){ready=NO;error=CaptureError(@"无法更新拍摄恢复记录，原片已保留");}
 NSDictionary *job=ready?[self.job copy]:nil;NSError *failure=error;
 dispatch_async(dispatch_get_main_queue(),^{if(self.onCompletion)self.onCompletion(self,job,ready?self.meta:nil,failure);self.onCompletion=nil;self.onExposureFinished=nil;});
}
- (void)rejectRequest:(NSError *)error {
 dispatch_async(self.diskQueue,^{
  if(self.finished)return;
  // The native request was rejected before any resource was accepted. Do not
  // let an empty capturing record consume a pending slot forever.
  if(!self.photoWritten&&!self.movieWritten){
   self.finished=YES;[NSFileManager.defaultManager removeItemAtURL:self.meta error:nil];
   dispatch_async(dispatch_get_main_queue(),^{if(self.onCompletion)self.onCompletion(self,nil,nil,error);self.onCompletion=nil;self.onExposureFinished=nil;});
  }else [self complete:error];
 });
}
- (void)captureOutput:(AVCapturePhotoOutput *)output didCapturePhotoForResolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings {
 // Exposure is over: a second ordinary shot can start while JPEG delivery and
 // disk writes finish. The controller still owns this delegate until completion.
 dispatch_async(dispatch_get_main_queue(),^{if(self.onExposureFinished)self.onExposureFinished(self);});
}
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
 NSData *data=error?nil:[photo fileDataRepresentation];
 dispatch_async(self.diskQueue,^{@autoreleasepool{
  NSError *failure=error;NSURL *raw=[MCProcessingQueue fileForJob:self.job key:@"source"];
  self.photoWritten=data.length>0&&raw&&[data writeToURL:raw options:NSDataWritingAtomic error:&failure];
  if(!self.photoWritten)self.resourceError=failure?:CaptureError(@"没有收到照片数据或原片暂存失败");
 }});
}
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingLivePhotoToMovieFileAtURL:(NSURL *)url duration:(CMTime)duration photoDisplayTime:(CMTime)photoDisplayTime resolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings error:(NSError *)error {
 dispatch_async(self.diskQueue,^{
  NSNumber *bytes=nil;[url getResourceValue:&bytes forKey:NSURLFileSizeKey error:nil];
  self.movieWritten=!error&&[url.path isEqual:self.movieURL.path]&&bytes.unsignedLongLongValue>1024;
  if(!self.movieWritten)self.resourceError=error?:CaptureError(@"实况动态片段未完成");
 });
}
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings error:(NSError *)error {
 dispatch_async(self.diskQueue,^{@autoreleasepool{[self complete:error?:self.resourceError];}});
}
@end
