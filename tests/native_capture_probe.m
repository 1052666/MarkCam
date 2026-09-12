// Host-only integration test: real delegate, simulated native callbacks and
// temporary files. It does not exercise a camera, JPEG codec, or iPhone runtime.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "MCPhotoCaptureProcessor.h"
#import "MCProcessingQueue.h"

static NSURL *ProbeDirectory;
static BOOL FailWrites;
static NSUInteger CheckCount;
static NSMutableArray<NSString *> *Scenarios;
static void Require(BOOL condition,NSString *message) {
 CheckCount++;
 if(!condition){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}
}
static void WaitFor(BOOL (^done)(void),NSString *message) {
 NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];
 while(!done()&&deadline.timeIntervalSinceNow>0)
  [[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
 Require(done(),message);
}
static NSDictionary *ReadJob(MCPhotoCaptureProcessor *capture) {
 NSURL *meta=[ProbeDirectory URLByAppendingPathComponent:[capture.identifier stringByAppendingString:@".job.json"]];
 NSData *data=[NSData dataWithContentsOfURL:meta];
 return data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
}
static NSData *Bytes(NSString *text) {return [text dataUsingEncoding:NSUTF8StringEncoding];}
static NSURL *Source(MCPhotoCaptureProcessor *capture) {
 return [ProbeDirectory URLByAppendingPathComponent:[capture.identifier stringByAppendingString:@"-raw.jpg"]];
}

// Only replace the queue boundary. MCPhotoCaptureProcessor.m is compiled intact.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation MCProcessingQueue
+ (NSURL *)directory {return ProbeDirectory;}
+ (NSURL *)fileForJob:(NSDictionary *)job key:(NSString *)key {
 NSString *name=job[key];return name?[ProbeDirectory URLByAppendingPathComponent:name]:nil;
}
+ (BOOL)writeJob:(NSDictionary *)job URL:(NSURL *)meta {
 if(FailWrites)return NO;
 NSData *data=[NSJSONSerialization dataWithJSONObject:job options:0 error:nil];
 return data&&[data writeToURL:meta options:NSDataWritingAtomic error:nil];
}
@end
#pragma clang diagnostic pop

@interface MCProbePhoto:NSObject
@property(nonatomic,strong) NSData *bytes;
@end
@implementation MCProbePhoto
- (NSData *)fileDataRepresentation {return self.bytes;}
@end
static void DeliverPhoto(MCPhotoCaptureProcessor *capture,NSData *bytes,NSError *error) {
 MCProbePhoto *photo=[MCProbePhoto new];photo.bytes=bytes;
 [capture captureOutput:nil didFinishProcessingPhoto:(AVCapturePhoto *)(id)photo error:error];
}
static void Finish(MCPhotoCaptureProcessor *capture,NSError *error) {
 [capture captureOutput:nil didFinishCaptureForResolvedSettings:nil error:error];
}
static MCPhotoCaptureProcessor *NewCapture(NSDictionary *settings,BOOL live,dispatch_queue_t queue) {
 return [[MCPhotoCaptureProcessor alloc]initWithSettings:settings
  date:[NSDate dateWithTimeIntervalSince1970:1700000000] live:live diskQueue:queue];
}

int main(void) {@autoreleasepool {
 Scenarios=[NSMutableArray new];
 // Check the actual framework protocol as well as our app's required contract.
 for(NSString *name in @[@"captureOutput:didCapturePhotoForResolvedSettings:",
  @"captureOutput:didFinishProcessingPhoto:error:",
  @"captureOutput:didFinishCaptureForResolvedSettings:error:",
  @"captureOutput:didFinishProcessingLivePhotoToMovieFileAtURL:duration:photoDisplayTime:resolvedSettings:error:"]){
  SEL selector=NSSelectorFromString(name);
  struct objc_method_description method=protocol_getMethodDescription(@protocol(AVCapturePhotoCaptureDelegate),selector,NO,YES);
  Require(method.name!=NULL,[@"callback exists in native framework protocol: " stringByAppendingString:name]);
 }

 ProbeDirectory=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"markcam-capture-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
 Require([NSFileManager.defaultManager createDirectoryAtURL:ProbeDirectory withIntermediateDirectories:YES attributes:nil error:nil],@"create isolated fixture directory");
 dispatch_queue_t disk=dispatch_queue_create("markcam.capture.probe",DISPATCH_QUEUE_SERIAL);
 NSError *expectedError=[NSError errorWithDomain:@"Probe" code:41 userInfo:@{NSLocalizedDescriptionKey:@"native capture failed"}];

 // The second exposure finishes first; its bytes/settings must never populate A.
 NSMutableDictionary *original=[@{@"marker":@"A",@"keepOriginal":@YES}mutableCopy];
 MCPhotoCaptureProcessor *a=NewCapture(original,NO,disk),*b=NewCapture(@{@"marker":@"B",@"keepOriginal":@NO},NO,disk);
 original[@"marker"]=@"changed after creation";
 Require(![a.identifier isEqual:b.identifier],@"requests receive distinct identities");
 Require([a.settings[@"marker"]isEqual:@"A"],@"request settings are snapshotted");
 Require([a prepare:nil]&&[b prepare:nil],@"two recovery journals prepared");
 __block NSUInteger exposures=0,completions=0;
 __block BOOL aDone=NO,bDone=NO;
 NSMutableArray *order=[NSMutableArray new];
 a.onExposureFinished=^(MCPhotoCaptureProcessor *shot){exposures++;Require(shot==a,@"exposure callback keeps request identity");};
 b.onExposureFinished=^(MCPhotoCaptureProcessor *shot){exposures++;Require(shot==b,@"second exposure keeps identity");};
 a.onCompletion=^(MCPhotoCaptureProcessor *shot,NSDictionary *job,NSURL *meta,NSError *error){
  completions++;aDone=YES;[order addObject:@"A"];
  Require(!error&&meta&&[job[@"stage"]isEqual:@"raw"],@"A completion follows ready journal");
  Require([job[@"settings"][@"marker"]isEqual:@"A"],@"A settings stay isolated");
  Require([[NSData dataWithContentsOfURL:Source(shot)]isEqual:Bytes(@"photo-A")],@"A completion follows A disk write");
  Require([ReadJob(shot)[@"stage"]isEqual:@"raw"],@"A raw journal is durable before completion");
 };
 b.onCompletion=^(MCPhotoCaptureProcessor *shot,NSDictionary *job,NSURL *meta,NSError *error){
  completions++;bDone=YES;[order addObject:@"B"];
  Require(!error&&meta&&[job[@"stage"]isEqual:@"raw"],@"B completion follows ready journal");
  Require([job[@"settings"][@"marker"]isEqual:@"B"],@"B settings stay isolated");
  Require([[NSData dataWithContentsOfURL:Source(shot)]isEqual:Bytes(@"photo-B")],@"B completion follows B disk write");
  Require(!aDone,@"second request can finish before first request");
 };
 [a captureOutput:nil didCapturePhotoForResolvedSettings:nil];
 [b captureOutput:nil didCapturePhotoForResolvedSettings:nil];
 WaitFor(^BOOL{return exposures==2;},@"exposure callback precedes delivery and disk completion");
 Require(completions==0&&!aDone&&!bDone,@"exposure does not falsely complete requests");
 Require([ReadJob(a)[@"stage"]isEqual:@"capturing"],@"exposure keeps recovery journal capturing");
 DeliverPhoto(b,Bytes(@"photo-B"),nil);Finish(b,nil);
 WaitFor(^BOOL{return bDone;},@"second request completes independently");
 DeliverPhoto(a,Bytes(@"photo-A"),nil);Finish(a,nil);
 WaitFor(^BOOL{return aDone;},@"first request completes after second");
 Require([order isEqual:@[@"B",@"A"]],@"completion order follows callbacks instead of shutter order");
 Finish(a,nil);Finish(b,nil);dispatch_sync(disk,^{});
 [[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
 Require(completions==2,@"final completion is idempotent");
 [Scenarios addObject:@"two overlapping photos; exposure before delivery; reverse completion order"];

 // A processing error is propagated even if the final native callback has no error.
 for(NSNumber *nativeError in @[@NO,@YES]){
  MCPhotoCaptureProcessor *capture=NewCapture(@{@"marker":@"failure"},NO,disk);
  Require([capture prepare:nil],@"failure scenario journal prepared");
  __block BOOL done=NO;
  capture.onCompletion=^(MCPhotoCaptureProcessor *shot,NSDictionary *job,NSURL *meta,NSError *error){
   done=YES;Require(error&&!job&&!meta,@"missing data cannot become a ready job");
   Require([ReadJob(shot)[@"stage"]isEqual:@"incomplete"],@"failed capture recovery journal persists");
   if(nativeError.boolValue)Require([error.domain isEqual:@"Probe"]&&error.code==41,@"processing error survives final callback");
  };
  DeliverPhoto(capture,nil,nativeError.boolValue?expectedError:nil);Finish(capture,nil);
  WaitFor(^BOOL{return done;},@"failed data delivery completes with error");
 }
 [Scenarios addObject:@"empty photo and processing-error recovery"];

 MCPhotoCaptureProcessor *failed=NewCapture(@{@"marker":@"final-error"},NO,disk);
 Require([failed prepare:nil],@"final-error journal prepared");
 __block BOOL failedDone=NO;
 failed.onCompletion=^(MCPhotoCaptureProcessor *shot,NSDictionary *job,NSURL *meta,NSError *error){
  failedDone=YES;Require(error==expectedError&&!job&&!meta,@"final native error prevents successful completion");
  Require([[NSData dataWithContentsOfURL:Source(shot)]isEqual:Bytes(@"retained")],@"native error preserves already-written raw data");
  Require([ReadJob(shot)[@"stage"]isEqual:@"incomplete"],@"final error records incomplete stage");
 };
 DeliverPhoto(failed,Bytes(@"retained"),nil);Finish(failed,expectedError);
 WaitFor(^BOOL{return failedDone;},@"final-error completion delivered");
 [Scenarios addObject:@"final native error retains raw resource"];

 MCPhotoCaptureProcessor *rejected=NewCapture(@{@"marker":@"rejected"},NO,disk);
 Require([rejected prepare:nil],@"rejected request journal prepared");
 __block BOOL rejectedDone=NO;
 rejected.onCompletion=^(MCPhotoCaptureProcessor *shot,NSDictionary *job,NSURL *meta,NSError *error){
  rejectedDone=YES;Require(error==expectedError&&!job&&!meta,@"rejected request reports failure");
  Require(ReadJob(shot)==nil,@"rejected empty journal does not consume queue capacity");
 };
 [rejected rejectRequest:expectedError];
 WaitFor(^BOOL{return rejectedDone;},@"rejection completes without native callbacks");
 [Scenarios addObject:@"rejected request releases empty recovery record"];

 MCPhotoCaptureProcessor *unwritable=NewCapture(@{@"marker":@"disk-full"},NO,disk);
 FailWrites=YES;NSError *storageError=nil;
 Require(![unwritable prepare:&storageError]&&storageError,@"preparation failure is returned to caller");
 FailWrites=NO;__block BOOL unwritableDone=NO;
 unwritable.onCompletion=^(MCPhotoCaptureProcessor *shot,NSDictionary *job,NSURL *meta,NSError *error){
  unwritableDone=YES;Require(error==storageError&&!job&&!meta,@"unprepared request reports storage failure");
  Require(ReadJob(shot)==nil,@"failed preparation leaves no ready journal");
 };
 [unwritable rejectRequest:storageError];
 WaitFor(^BOOL{return unwritableDone;},@"storage rejection completes");
 [Scenarios addObject:@"recovery journal preparation failure"];

 for(NSNumber *withMovie in @[@NO,@YES]){
  MCPhotoCaptureProcessor *live=NewCapture(@{@"marker":@"live"},YES,disk);
  Require([live prepare:nil],@"Live journal prepared");
  __block BOOL done=NO;
  live.onCompletion=^(MCPhotoCaptureProcessor *shot,NSDictionary *job,NSURL *meta,NSError *error){
   done=YES;
   if(withMovie.boolValue){
    Require(!error&&meta&&[job[@"kind"]isEqual:@"live"],@"complete Live pair becomes a queued job");
    Require(job[@"sourceMovie"]&&job[@"outputMovie"],@"Live pair paths remain in the job");
    Require([ReadJob(shot)[@"stage"]isEqual:@"raw"],@"complete Live pair records raw stage");
   }else{
    Require(error&&!job&&!meta,@"missing movie never degrades silently to ordinary photo");
    Require([ReadJob(shot)[@"stage"]isEqual:@"incomplete"],@"incomplete Live pair remains recoverable");
   }
   Require([[NSData dataWithContentsOfURL:Source(shot)]isEqual:Bytes(@"live-photo")],@"Live still resource remains isolated");
  };
  if(withMovie.boolValue){
   NSData *movie=[NSMutableData dataWithLength:2048];
   Require([movie writeToURL:live.movieURL options:NSDataWritingAtomic error:nil],@"prepare simulated movie resource");
   [live captureOutput:nil didFinishProcessingLivePhotoToMovieFileAtURL:live.movieURL duration:kCMTimeZero photoDisplayTime:kCMTimeZero resolvedSettings:nil error:nil];
  }
  DeliverPhoto(live,Bytes(@"live-photo"),nil);Finish(live,nil);
  WaitFor(^BOOL{return done;},@"Live callback barrier completes");
 }
 [Scenarios addObject:@"Live photo requires both resources and accepts reverse resource order"];

 NSDictionary *report=@{@"scope":@"Host-executed production MCPhotoCaptureProcessor with simulated callbacks and temporary file I/O; no camera, codec or iPhone execution",@"passed":@(CheckCount),@"failed":@0,@"scenarios":Scenarios,@"device_tested":@NO};
 NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
 fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);
 [NSFileManager.defaultManager removeItemAtURL:ProbeDirectory error:nil];
 return 0;
}}
