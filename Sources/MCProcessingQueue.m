#import "MCProcessingQueue.h"
#import "MCPhotoRenderer.h"
#import "MCLivePhotoProcessor.h"
#import "WMEngine.h"
#import "MCWorkPolicy.h"
#import <Photos/Photos.h>
#import <UIKit/UIKit.h>
#import <os/proc.h>
#include <limits.h>

static NSError *QError(NSString *s){return [NSError errorWithDomain:@"MarkCam.Queue" code:1 userInfo:@{NSLocalizedDescriptionKey:s}];}
static BOOL QValidJob(NSDictionary *job){
 return [job isKindOfClass:NSDictionary.class]&&[@[@"photo",@"live",@"video"]containsObject:job[@"kind"]]&&[WMEngine isValidSettingsSnapshot:job[@"settings"]]&&[job[@"date"]isKindOfClass:NSNumber.class]&&isfinite([job[@"date"]doubleValue]);
}
@interface MCProcessingQueue ()
@property(nonatomic,readwrite) BOOL processing;
@property(nonatomic,readwrite) BOOL heavyProcessing;
@property(nonatomic,readwrite) NSUInteger pendingCount;
@property(nonatomic,readwrite) NSUInteger queuedCount;
@property(nonatomic) BOOL storageLow;
@property(nonatomic,readwrite,copy) NSString *summary;
@property(nonatomic,strong,readwrite) NSURL *activeMeta;
@property(nonatomic,strong) dispatch_queue_t io;
@property(nonatomic,strong) NSArray<NSURL *> *jobs;
@property(nonatomic) BOOL scanning;
@property(nonatomic) BOOL authorizationResumeRequested;
@property(nonatomic) NSUInteger scanRevision;
@property(nonatomic) CFTimeInterval lastShot,pressureUntil;
@property(nonatomic,strong) MCLivePhotoProcessor *live;
@property(atomic,strong) AVAssetExportSession *video;
@property(atomic) BOOL stopRequested;
@property(nonatomic) UIBackgroundTaskIdentifier lease;
@property(nonatomic) BOOL leaseActive;
@property(nonatomic) NSUInteger leaseGeneration;
@property(nonatomic,strong) dispatch_source_t memorySource;
@property(nonatomic,strong) NSMutableSet<NSString *> *blocked;
@end
@implementation MCProcessingQueue
+ (NSURL *)directory {return [[WMEngine shared].documentsURL URLByAppendingPathComponent:@"Pending" isDirectory:YES];}
+ (NSURL *)fileForJob:(NSDictionary *)job key:(NSString *)key {
 if(![job isKindOfClass:NSDictionary.class])return nil;id name=job[key];if(![name isKindOfClass:NSString.class]||![name length]||[name length]>150||[name hasPrefix:@"."]||![[name lastPathComponent]isEqual:name]||![@[@"jpg",@"mp4",@"mov"]containsObject:[name pathExtension].lowercaseString])return nil;
 NSURL *dir=self.directory,*url=[dir URLByAppendingPathComponent:name];return [url.URLByResolvingSymlinksInPath.path hasPrefix:[dir.URLByResolvingSymlinksInPath.path stringByAppendingString:@"/"]]?url:nil;
}
+ (BOOL)writeJob:(NSDictionary *)job URL:(NSURL *)meta {
 if(!meta||!job||![NSJSONSerialization isValidJSONObject:job])return NO;
 NSData *data=[NSJSONSerialization dataWithJSONObject:job options:0 error:nil];return data&&[data writeToURL:meta options:NSDataWritingAtomic error:nil];
}
+ (void)cleanupJob:(NSDictionary *)job meta:(NSURL *)meta {
 for(NSString *key in @[@"source",@"sourceMovie",@"output",@"outputMovie"]){NSURL *file=[self fileForJob:job key:key];if(file)[NSFileManager.defaultManager removeItemAtURL:file error:nil];}
 [NSFileManager.defaultManager removeItemAtURL:meta error:nil];
}
- (instancetype)init {if((self=[super init])){_io=dispatch_queue_create("markcam.queue.worker",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));_jobs=@[];_blocked=[NSMutableSet new];_summary=@"队列就绪";
 _memorySource=dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE,0,DISPATCH_MEMORYPRESSURE_WARN|DISPATCH_MEMORYPRESSURE_CRITICAL,dispatch_get_main_queue());__weak typeof(self) weak=self;dispatch_source_set_event_handler(_memorySource,^{[weak memoryPressure];});dispatch_resume(_memorySource);
 [NSFileManager.defaultManager createDirectoryAtURL:self.class.directory withIntermediateDirectories:YES attributes:nil error:nil];}return self;}
- (void)endLease {if(!self.leaseActive)return;self.leaseActive=NO;[UIApplication.sharedApplication endBackgroundTask:self.lease];}
- (void)beginLease {
 [self endLease];NSUInteger generation=++self.leaseGeneration;
 self.lease=[UIApplication.sharedApplication beginBackgroundTaskWithName:@"Finish pending media write" expirationHandler:^{if(generation!=self.leaseGeneration)return;self.stopRequested=YES;[self.live cancel];[self.video cancelExport];[self endLease];}];self.leaseActive=self.lease!=UIBackgroundTaskInvalid;
}
- (void)dealloc {if(_memorySource)dispatch_source_cancel(_memorySource);}
- (void)notify {if(self.onChange)self.onChange();}
- (float)progress {return self.live?self.live.progress:self.video?self.video.progress:self.processing?.1:0;}
- (BOOL)isActive:(NSURL *)meta {return self.processing&&[self.activeMeta.path isEqual:meta.path];}
- (void)setForeground:(BOOL)value {_foreground=value;if(!value){self.stopRequested=YES;[self.live cancel];[self.video cancelExport];}else{[self resumeAfterPhotoAuthorization];[self refresh];}[self notify];}
- (void)setCaptureBusy:(BOOL)value {BOOL changed=_captureBusy!=value;_captureBusy=value;if(changed&&!value)self.lastShot=CACurrentMediaTime();}
- (void)didCapture {self.pendingCount++;self.queuedCount++;self.scanRevision++;self.lastShot=CACurrentMediaTime();[self refresh];[self notify];}
- (BOOL)allowsCaptureLive:(BOOL)live {
 return [self allowsCaptureLive:live reservedCount:0];
}
- (BOOL)allowsCaptureLive:(BOOL)live reservedCount:(NSUInteger)reserved {
 return [self captureBlockReasonForLive:live reservedCount:reserved]==nil;
}
- (uint64_t)availableCaptureMemory {return os_proc_available_memory();}
- (NSString *)captureBlockReasonForLive:(BOOL)live reservedCount:(NSUInteger)reserved {
 if(self.storageLow)return @"存储空间不足，请先导出或清理作品";
 BOOL pressure=CACurrentMediaTime()<self.pressureUntil||NSProcessInfo.processInfo.thermalState>=NSProcessInfoThermalStateSerious;
 MCCaptureAdmissionResult result=MCCaptureAdmission((unsigned)MIN(self.queuedCount,(NSUInteger)UINT_MAX),(unsigned)MIN(reserved,(NSUInteger)UINT_MAX),live,pressure,self.heavyProcessing,self.processing,[self availableCaptureMemory]);
 switch(result){
  case MCAdmissionAllowed:return nil;
  case MCAdmissionHeavyProcessing:return @"正在合成实况或视频，完成后可继续拍摄";
  case MCAdmissionLiveProcessing:return @"正在处理照片，完成后可拍摄实况";
  case MCAdmissionPressure:return @"设备温度或内存压力较高，恢复后自动开放快门";
  case MCAdmissionInFlight:return @"正在接收照片，稍后可继续拍摄";
  case MCAdmissionPending:return @"待处理作品已满，请等待保存或前往待保存处理";
  case MCAdmissionMemory:return @"可用内存暂时不足，恢复后自动开放快门";
 }
 return @"相机正在准备";
}
- (void)pause {self.manuallyPaused=YES;self.stopRequested=YES;[self.live cancel];[self.video cancelExport];self.summary=@"合成已暂停，素材保留";[self notify];}
- (void)memoryPressure {self.pressureUntil=CACurrentMediaTime()+15;self.stopRequested=YES;[self.live cancel];[self.video cancelExport];self.summary=@"内存压力：暂停合成，稍后继续";[self notify];}
- (void)refresh {
 if(self.scanning){self.scanRevision++;return;}self.scanning=YES;NSUInteger revision=self.scanRevision;
 dispatch_async(self.io,^{@autoreleasepool{
  NSArray *files=[NSFileManager.defaultManager contentsOfDirectoryAtURL:self.class.directory includingPropertiesForKeys:nil options:0 error:nil];NSMutableArray *jobs=[NSMutableArray new];
  NSNumber *capacity=nil;[self.class.directory getResourceValue:&capacity forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil];
  BOOL low=capacity&&capacity.unsignedLongLongValue<256ULL*1024*1024;
  NSUInteger queued=0;
  for(NSURL *url in files)if([url.lastPathComponent hasSuffix:@".job.json"]){
   [jobs addObject:url];NSDictionary *job=[self readJob:url];
   // A killed process cannot finish its old capture or Photos transaction.
   // Keep those files for explicit recovery; never reset "saving" to "ready"
   // automatically (Photos may already have committed the asset).
   if(QValidJob(job)&&!job[@"queueBlocked"]&&([job[@"stage"]isEqual:@"raw"]||[job[@"stage"]isEqual:@"ready"]))queued++;
  }
  [jobs sortUsingComparator:^NSComparisonResult(NSURL *a,NSURL *b){return [a.lastPathComponent compare:b.lastPathComponent];}];
  dispatch_async(dispatch_get_main_queue(),^{self.scanning=NO;if(revision!=self.scanRevision){[self refresh];return;}self.jobs=jobs;self.pendingCount=jobs.count;self.queuedCount=queued;self.storageLow=low;[self notify];});
 }});
}
- (void)retry:(NSURL *)meta {
 if(self.processing||self.captureBusy){self.summary=@"拍摄或处理尚未结束，请稍后重试";[self notify];return;}self.manuallyPaused=NO;[self.blocked removeObject:meta.path];
 dispatch_async(self.io,^{NSMutableDictionary *job=[self readJob:meta];[job removeObjectForKey:@"processingError"];[job removeObjectForKey:@"queueBlocked"];[job removeObjectForKey:@"queueBlockReason"];if([job[@"stage"]isEqual:@"capturing"]||[job[@"stage"]isEqual:@"incomplete"])job[@"stage"]=@"raw";if([job[@"stage"]isEqual:@"saving"]){job[@"stage"]=@"ready";}if(job)[self.class writeJob:job URL:meta];dispatch_async(dispatch_get_main_queue(),^{[self refresh];});});
}
- (void)resumeAfterPhotoAuthorization {
 PHAuthorizationStatus status=[PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
 if(status!=PHAuthorizationStatusAuthorized&&status!=PHAuthorizationStatusLimited)return;
 self.authorizationResumeRequested=YES;
 if(self.processing||self.scanning)return;
 self.authorizationResumeRequested=NO;self.scanning=YES;
 dispatch_async(self.io,^{@autoreleasepool{
  NSMutableArray<NSString *> *resumed=[NSMutableArray new];
  NSArray<NSURL *> *files=[NSFileManager.defaultManager contentsOfDirectoryAtURL:self.class.directory includingPropertiesForKeys:nil options:0 error:nil];
  for(NSURL *meta in files){
   if(![meta.lastPathComponent hasSuffix:@".job.json"])continue;
   NSMutableDictionary *job=[self readJob:meta];
   // The legacy text identifies a pre-save permission denial from 1.2.0. Never
   // automatically reset "saving": its Photos transaction may have succeeded.
   BOOL permission=[job[@"queueBlockReason"]isEqual:@"photo-permission"]||[job[@"processingError"]isEqual:@"需要相册权限：请点待保存 → 授权并继续"];
   if(!MCShouldResumePermissionJob([job[@"stage"]isEqual:@"ready"],job[@"queueBlocked"]!=nil,permission))continue;
   [job removeObjectForKey:@"queueBlocked"];[job removeObjectForKey:@"queueBlockReason"];[job removeObjectForKey:@"processingError"];
   if([self.class writeJob:job URL:meta])[resumed addObject:meta.path];
  }
  dispatch_async(dispatch_get_main_queue(),^{self.scanning=NO;[self.blocked minusSet:[NSSet setWithArray:resumed]];self.scanRevision++;[self refresh];});
 }});
}
- (NSMutableDictionary *)readJob:(NSURL *)meta {
 if(![meta.URLByResolvingSymlinksInPath.path hasPrefix:[self.class.directory.URLByResolvingSymlinksInPath.path stringByAppendingString:@"/"]])return nil;
 NSNumber *size=nil;[meta getResourceValue:&size forKey:NSURLFileSizeKey error:nil];if(!size||size.unsignedLongLongValue>4*1024*1024)return nil;
 NSData *data=[NSData dataWithContentsOfURL:meta];id job=data?[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil]:nil;return [job isKindOfClass:NSMutableDictionary.class]?job:nil;
}
- (void)tick {
 // Capture and rendering have different memory thresholds. Always refresh the
 // shutter even when rendering cannot start (including after pressure expires).
 [self notify];
 if(self.processing)return;
 if(self.authorizationResumeRequested)[self resumeAfterPhotoAuthorization];
 if(self.scanning)return;
 BOOL pause=self.manuallyPaused||CACurrentMediaTime()<self.pressureUntil;
 if(!MCCanRender(self.foreground,self.captureBusy,self.processing,pause,(int)NSProcessInfo.processInfo.thermalState,os_proc_available_memory()))return;
 if(CACurrentMediaTime()-self.lastShot<1.2)return; // Prefer shutter bursts before starting the worker.
 NSURL *next=nil;for(NSURL *meta in self.jobs)if(![self.blocked containsObject:meta.path]){next=meta;break;}
 if(!next){if(self.pendingCount&&!self.manuallyPaused)self.summary=@"有失败/未完整作品，请在待保存查看";[self notify];return;}
 self.processing=YES;[self beginLease];self.activeMeta=next;self.stopRequested=NO;self.summary=@"异步合成中，可继续拍普通照片";[self notify];
 dispatch_async(self.io,^{@autoreleasepool{
  NSMutableDictionary *job=[self readJob:next];NSString *stage=job[@"stage"];
  BOOL valid=QValidJob(job);
  if(!valid||job[@"queueBlocked"]||![@[@"raw",@"ready",@"saved"]containsObject:stage]){dispatch_async(dispatch_get_main_queue(),^{[self.blocked addObject:next.path];[self finish:QError(@"恢复信息不完整或已暂停，请在待保存查看") job:job meta:next block:YES];});return;}
  if([stage isEqual:@"saved"]){[self.class cleanupJob:job meta:next];dispatch_async(dispatch_get_main_queue(),^{[self finish:nil job:nil meta:next block:NO];});return;}
  dispatch_async(dispatch_get_main_queue(),^{[self beginJob:job meta:next];});
 }});
}
- (void)finish:(NSError *)error job:(NSMutableDictionary *)job meta:(NSURL *)meta block:(BOOL)block {
 [self endLease];self.processing=NO;self.heavyProcessing=NO;self.activeMeta=nil;self.live=nil;self.video=nil;
 if(block)[self.blocked addObject:meta.path];
 self.summary=error?(error.localizedDescription?:@"未完成，原片保留"):@"已处理一张，原片按设置保留";
 self.scanRevision++;[self refresh];[self notify];
}
- (void)beginJob:(NSMutableDictionary *)job meta:(NSURL *)meta {
 if(!self.foreground||self.captureBusy||self.stopRequested||self.manuallyPaused){[self finish:QError(@"拍摄优先，稍后继续") job:job meta:meta block:NO];return;}
 NSURL *source=[self.class fileForJob:job key:@"source"],*dest=[self.class fileForJob:job key:@"output"];
 BOOL live=[job[@"kind"]isEqual:@"live"],video=[job[@"kind"]isEqual:@"video"];
 NSURL *movie=live?[self.class fileForJob:job key:@"sourceMovie"]:nil,*outMovie=live?[self.class fileForJob:job key:@"outputMovie"]:nil;
 NSArray *urls=live?@[source?:NSNull.null,dest?:NSNull.null,movie?:NSNull.null,outMovie?:NSNull.null]:@[source?:NSNull.null,dest?:NSNull.null];
 if([urls containsObject:NSNull.null]||[NSSet setWithArray:urls].count!=urls.count){[self failed:QError(@"恢复路径无效，原片保留") job:job meta:meta];return;}
 self.heavyProcessing=live||video;[self notify]; // Heavy codecs don't overlap a new capture.
 dispatch_async(self.io,^{@autoreleasepool{
  BOOL ready=[job[@"stage"]isEqual:@"ready"];
  if(ready){BOOL present=[NSFileManager.defaultManager fileExistsAtPath:dest.path]&&(!live||[NSFileManager.defaultManager fileExistsAtPath:outMovie.path]);if(present){dispatch_async(dispatch_get_main_queue(),^{[self save:job meta:meta];});return;}job[@"stage"]=@"raw";}
  for(NSURL *url in live?@[source,movie]:@[source]){NSNumber *bytes=nil;[url getResourceValue:&bytes forKey:NSURLFileSizeKey error:nil];if(!bytes||bytes.unsignedLongLongValue<128){[self reportFailure:QError(@"原始素材缺失，已有文件保留") job:job meta:meta];return;}}
  for(NSURL *url in live?@[dest,outMovie]:@[dest]){NSError *e=nil;if([NSFileManager.defaultManager fileExistsAtPath:url.path]&&![NSFileManager.defaultManager removeItemAtURL:url error:&e]){[self reportFailure:e job:job meta:meta];return;}}
  NSDate *date=[NSDate dateWithTimeIntervalSince1970:[job[@"date"]doubleValue]];
  if(self.stopRequested){dispatch_async(dispatch_get_main_queue(),^{[self finish:QError(@"已暂停，原片保留") job:job meta:meta block:NO];});return;}
  if(live){dispatch_async(dispatch_get_main_queue(),^{
   if(!self.foreground||self.stopRequested){[self finish:QError(@"实况已暂停") job:job meta:meta block:NO];return;}
   self.live=[MCLivePhotoProcessor new];[self.live processPhoto:source movie:movie outputPhoto:dest outputMovie:outMovie settings:job[@"settings"] date:date completion:^(NSError *error){if(error)[self failed:error job:job meta:meta];else [self rendered:job meta:meta];}];
  });
  }else if(video){
   self.video=[[WMEngine shared]exportVideo:source destination:dest settings:job[@"settings"] date:date completion:^(NSError *e){if(e)[self failed:e job:job meta:meta];else [self rendered:job meta:meta];}];if(self.stopRequested)[self.video cancelExport];
  }else{
   NSError *error=nil;BOOL ok=[MCPhotoRenderer renderSource:source destination:dest settings:job[@"settings"] date:date error:&error];
   dispatch_async(dispatch_get_main_queue(),^{if(ok)[self rendered:job meta:meta];else [self failed:error?:QError(@"照片合成失败") job:job meta:meta];});
  }
 }});
}
- (void)reportFailure:(NSError *)error job:(NSMutableDictionary *)job meta:(NSURL *)meta {dispatch_async(dispatch_get_main_queue(),^{[self failed:error job:job meta:meta];});}
- (void)failed:(NSError *)error job:(NSMutableDictionary *)job meta:(NSURL *)meta {
 BOOL interrupted=self.stopRequested||!self.foreground;
 if(interrupted){[self finish:error job:job meta:meta block:NO];return;}
 if([error.domain isEqual:MCPhotoRendererErrorDomain]&&error.code==MCPhotoRendererErrorInsufficientMemory){
  // A momentary shortage must not permanently poison a recoverable raw job.
  self.pressureUntil=CACurrentMediaTime()+15;[self finish:error job:job meta:meta block:NO];return;
 }
 job[@"queueBlocked"]=@YES;job[@"processingError"]=error.localizedDescription?:@"处理失败";
 dispatch_async(self.io,^{[self.class writeJob:job URL:meta];dispatch_async(dispatch_get_main_queue(),^{[self finish:error job:job meta:meta block:YES];});});
}
- (void)rendered:(NSMutableDictionary *)job meta:(NSURL *)meta {
 self.live=nil;self.video=nil;self.heavyProcessing=NO;job[@"stage"]=@"ready";
 dispatch_async(self.io,^{[WMEngine.shared clearCaches];BOOL ok=[self.class writeJob:job URL:meta];dispatch_async(dispatch_get_main_queue(),^{if(ok)[self save:job meta:meta];else [self failed:QError(@"无法写入成片恢复记录") job:job meta:meta];});});
}
- (void)save:(NSMutableDictionary *)job meta:(NSURL *)meta {
 if(!self.foreground||self.stopRequested){[self finish:QError(@"成片已暂存，返回后继续保存") job:job meta:meta block:NO];return;}
 PHAuthorizationStatus st=[PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
 if(st!=PHAuthorizationStatusAuthorized&&st!=PHAuthorizationStatusLimited){job[@"queueBlockReason"]=@"photo-permission";[self failed:QError(@"需要相册权限：请点待保存 → 授权并继续") job:job meta:meta];return;}
 self.summary=@"异步保存到相册";[self notify];
 job[@"stage"]=@"saving";dispatch_async(self.io,^{BOOL written=[self.class writeJob:job URL:meta];dispatch_async(dispatch_get_main_queue(),^{if(!written){[self failed:QError(@"保存前日志写入失败") job:job meta:meta];return;}[self commitPhotos:job meta:meta];});});
}
- (void)commitPhotos:(NSMutableDictionary *)job meta:(NSURL *)meta {
 if(!self.foreground||self.stopRequested){job[@"stage"]=@"ready";dispatch_async(self.io,^{[self.class writeJob:job URL:meta];dispatch_async(dispatch_get_main_queue(),^{[self finish:QError(@"成片已暂存") job:job meta:meta block:NO];});});return;}
 NSURL *dest=[self.class fileForJob:job key:@"output"],*source=[self.class fileForJob:job key:@"source"],*movie=[self.class fileForJob:job key:@"outputMovie"],*originalMovie=[self.class fileForJob:job key:@"sourceMovie"];
 BOOL live=[job[@"kind"]isEqual:@"live"],video=[job[@"kind"]isEqual:@"video"],keep=[job[@"settings"][@"keepOriginal"]boolValue];
 [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
  PHAssetCreationRequest *request=[PHAssetCreationRequest creationRequestForAsset];request.creationDate=[NSDate dateWithTimeIntervalSince1970:[job[@"date"]doubleValue]];PHAssetResourceCreationOptions *options=[PHAssetResourceCreationOptions new];options.shouldMoveFile=NO;
  [request addResourceWithType:video?PHAssetResourceTypeVideo:PHAssetResourceTypePhoto fileURL:dest options:options];
  if(live)[request addResourceWithType:PHAssetResourceTypePairedVideo fileURL:movie options:options];
  if(keep){PHAssetCreationRequest *raw=[PHAssetCreationRequest creationRequestForAsset];raw.creationDate=request.creationDate;[raw addResourceWithType:video?PHAssetResourceTypeVideo:PHAssetResourceTypePhoto fileURL:source options:options];if(live)[raw addResourceWithType:PHAssetResourceTypePairedVideo fileURL:originalMovie options:options];}
 } completionHandler:^(BOOL success,NSError *error){
  dispatch_async(self.io,^{@autoreleasepool{
   BOOL logged=NO;if(success){job[@"stage"]=@"saved";logged=[self.class writeJob:job URL:meta];if(logged)[self.class cleanupJob:job meta:meta];}else{job[@"stage"]=@"ready";[self.class writeJob:job URL:meta];}
   dispatch_async(dispatch_get_main_queue(),^{if(success){if(logged)[self.blocked removeObject:meta.path];[self finish:logged?nil:QError(@"相册已保存，但恢复记录未更新，请勿直接重复保存") job:job meta:meta block:!logged];}else [self failed:error?:QError(@"相册保存失败，成片保留") job:job meta:meta];});
  }});
 }];
}
@end
